// pull_offline_and_extra_reads_test.dart
//
// #839 S3 — the pull must not waste time or reads:
//  - a pull that starts with no network at all fetches nothing and is not
//    counted as a failed download (no streak, no error_logs row, cursor kept);
//  - the one-by-one (cellular/poor) path stops at the first network failure
//    and reports every table it did not get, but a server error still moves on;
//  - an incremental snapshot that carries `users: []` makes no extra `users`
//    read; one with no `users` key still does;
//  - the payroll (permission-gated) tables are not fetched when the user does
//    not hold the key, and still are when they do; a key gained later is
//    caught up in full.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;
  String? signedIn;

  void reportConnectivity(List<String> results) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? results : null,
        );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    reportConnectivity(['wifi']);
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    signedIn = null;
    db.userIdResolver = () => signedIn;
    transport = InMemoryCloudTransport(authUserId: 'auth-1');
    sync = SupabaseSyncService(db, transport);
  });

  tearDown(() async {
    await transport.dispose();
    await db.close();
  });

  List<String> fetchedTables() =>
      transport.fetchQueries.map((q) => q.table).toList();

  group('no network when the pull starts', () {
    test('fetches nothing and is not a failed download', () async {
      reportConnectivity(['none']);
      final prefs = await SharedPreferences.getInstance();
      const cursor = '2026-11-01T00:00:00.000Z';
      await prefs.setString('last_sync_timestamp::$businessId', cursor);
      await prefs.setString('backfill_tables::$businessId', 'notifications');

      await expectLater(
        sync.pullChanges(businessId),
        throwsA(isA<PullSkippedOfflineException>()),
      );

      expect(transport.fetchQueries, isEmpty);
      expect(transport.rpcCalls, isEmpty);
      expect(prefs.getInt('consecutive_pull_failures::$businessId'), isNull);
      expect(prefs.getString('last_sync_timestamp::$businessId'), cursor);
      expect(prefs.getString('backfill_tables::$businessId'), 'notifications');
      final logs = await db.select(db.errorLogs).get();
      expect(logs.where((r) => r.errorType == 'sync.pull_failed'), isEmpty);
      expect(sync.pullStatus.value.stage, PullStage.idle);
      expect(sync.isPullRunning, isFalse);
      expect(sync.pullRunCount, 0);
    });

    test('an empty connectivity list counts as no network too', () async {
      reportConnectivity([]);
      await expectLater(
        sync.pullChanges(businessId),
        throwsA(isA<PullSkippedOfflineException>()),
      );
      expect(transport.fetchQueries, isEmpty);
    });

    test('a background catch-up stays quiet and pulls later', () async {
      reportConnectivity(['none']);
      sync.currentBusinessIdForTesting = businessId;
      await sync.catchUpPull(businessId, reason: 'periodic'); // never throws
      expect(transport.fetchQueries, isEmpty);

      // Connection back: the next pull runs normally.
      reportConnectivity(['wifi']);
      await sync.pullChanges(businessId);
      expect(fetchedTables(), contains('businesses'));
      expect(sync.pullStatus.value.stage, PullStage.completed);
    });
  });

  group('one-by-one path on a dead network', () {
    // The first non-deferrable table after the first one, so there are tables
    // before it (fetched) and critical tables after it (never tried).
    late String failAt;
    late int failIndex;
    setUp(() {
      reportConnectivity(['mobile']); // cellular → sequential path
      failIndex = kSyncPullOrder.indexWhere(
        (t) => !kSyncDeferrableTables.contains(t),
        1,
      );
      failAt = kSyncPullOrder[failIndex];
    });

    test('stops at the first network failure and reports the rest', () async {
      transport.failNext(
        failAt,
        const SocketException('Failed host lookup: example.supabase.co'),
      );
      Object? thrown;
      try {
        await sync.pullInitialData(businessId);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<PartialPullException>());
      expect(
        fetchedTables(),
        kSyncPullOrder.take(failIndex + 1).toList(),
        reason: 'no table after the network failure may be tried',
      );
      final failed = (thrown! as PartialPullException).failedTables;
      final expected = kSyncPullOrder
          .skip(failIndex)
          .where((t) => !kSyncDeferrableTables.contains(t))
          .toSet();
      expect(failed, expected);
      expect(failed, contains(failAt));
      expect(failed.length, greaterThan(1));
    });

    test('a server error still moves on to the next table', () async {
      transport.failNext(
        failAt,
        const PostgrestException(message: 'permission denied', code: '42501'),
      );
      Object? thrown;
      try {
        await sync.pullInitialData(businessId);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<PartialPullException>());
      expect((thrown! as PartialPullException).failedTables, {failAt});
      expect(
        fetchedTables().toSet(),
        kSyncPullOrder.toSet(),
        reason: 'every table is still tried after a non-network error',
      );
    });
  });

  group('supplementary users read on an incremental snapshot', () {
    final since = DateTime.utc(2026, 11, 20);

    test('users: [] in the snapshot makes no users fetch', () async {
      transport.stubRpc('pos_pull_snapshot', (_) => {'users': <dynamic>[]});
      await sync.pullInitialData(businessId, since: since);
      expect(transport.rpcCalls.map((c) => c.name), ['pos_pull_snapshot']);
      expect(fetchedTables(), isNot(contains('users')));
    });

    test('a snapshot with no users key still fetches users', () async {
      transport.stubRpc('pos_pull_snapshot', (_) => <String, dynamic>{});
      await sync.pullInitialData(businessId, since: since);
      expect(fetchedTables().where((t) => t == 'users'), hasLength(1));
    });

    test('a failed users fetch still refuses the pull', () async {
      transport.stubRpc('pos_pull_snapshot', (_) => <String, dynamic>{});
      transport.failNext(
        'users',
        const PostgrestException(message: 'boom', code: '500'),
      );
      await expectLater(
        sync.pullInitialData(businessId, since: since),
        throwsA(
          isA<PartialPullException>().having(
            (e) => e.failedTables,
            'failedTables',
            {'users'},
          ),
        ),
      );
    });
  });

  group('permission-gated (payroll) tables on an incremental snapshot', () {
    final since = DateTime.utc(2026, 11, 20);
    late String roleId;

    setUp(() async {
      roleId = UuidV7.generate();
      await db
          .into(db.roles)
          .insert(
            RolesCompanion.insert(
              id: Value(roleId),
              businessId: businessId,
              name: 'Cashier',
              slug: 'cashier',
            ),
          );
      final userId = UuidV7.generate();
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: businessId,
              name: 'Test Cashier',
              pin: kSetupRequiredPin,
            ),
          );
      await db
          .into(db.userBusinesses)
          .insert(
            UserBusinessesCompanion.insert(
              businessId: businessId,
              userId: userId,
              roleId: roleId,
            ),
          );
      signedIn = userId;
      transport.stubRpc('pos_pull_snapshot', (_) => {'users': <dynamic>[]});
    });

    Future<void> grantPayroll() => db
        .into(db.rolePermissions)
        .insert(
          RolePermissionsCompanion.insert(
            businessId: businessId,
            roleId: roleId,
            permissionKey: kPayrollPermissionKey,
          ),
        );

    test('not fetched when the user does not hold the key', () async {
      await sync.pullInitialData(businessId, since: since);
      for (final table in kSyncPermissionGatedTables.keys) {
        expect(fetchedTables(), isNot(contains(table)));
      }
    });

    test('fetched when the user holds the key', () async {
      await grantPayroll();
      await sync.pullInitialData(businessId, since: since);
      for (final table in kSyncPermissionGatedTables.keys) {
        expect(fetchedTables(), contains(table));
      }
    });

    test('fetched when no user is signed in yet', () async {
      signedIn = null;
      await sync.pullInitialData(businessId, since: since);
      for (final table in kSyncPermissionGatedTables.keys) {
        expect(fetchedTables(), contains(table));
      }
    });

    test('a key gained later is caught up in full', () async {
      await sync.pullInitialData(businessId, since: since);
      expect(
        fetchedTables().where(kSyncPermissionGatedTables.containsKey),
        isEmpty,
      );

      await grantPayroll();
      await sync.enforcePermissionGatedAccessForTesting(businessId);
      final gatedQueries = transport.fetchQueries
          .where((q) => kSyncPermissionGatedTables.containsKey(q.table))
          .toList();
      expect(
        gatedQueries.map((q) => q.table).toSet(),
        kSyncPermissionGatedTables.keys.toSet(),
      );
      expect(gatedQueries.every((q) => q.since == null), isTrue);
    });
  });
}
