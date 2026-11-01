// download_true_state_test.dart
//
// #643: the Sync Issues screen must show the true download state.
//  - one download at a time (a second trigger starts no second download)
//  - the guard flag can't stay stuck true
//  - live per-page fetch progress reaches pullStatus
//  - a failed pull writes ONE error_logs row per failure streak, no shop data
//  - the card wording never reads as all clear before the first full pull

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_download_card.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// Holds every fetch until [release] is called, so a pull stays "in flight".
class _GatedCloud extends InMemoryCloudTransport {
  _GatedCloud({super.authUserId});
  final gate = Completer<void>();
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<List<dynamic>> fetchTable(TableQuery query) async {
    await gate.future;
    return super.fetchTable(query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late String businessId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // connectivity_plus: report wifi so the pull picks the wifi page size.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => ['wifi'],
        );
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<ErrorLogData>> pullFailureLogs() async => [
    for (final r in await db.select(db.errorLogs).get())
      if (r.errorType == 'sync.pull_failed') r,
  ];

  test('a second pull while one runs starts no second download', () async {
    final transport = _GatedCloud(authUserId: 'user-1');
    final sync = SupabaseSyncService(db, transport);

    final first = sync.pullChanges(businessId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sync.isPullRunning, isTrue);
    expect(sync.pullRunCount, 1);

    // A connectivity flip / retry tap lands mid-download.
    await sync.pullChanges(businessId);
    expect(sync.pullRunCount, 1, reason: 'the second call must be a no-op');

    transport.release();
    await first;
    expect(sync.isPullRunning, isFalse);

    // Each table was fetched once (pos_pull_snapshot is bypassed on a full pull).
    final tables = transport.fetchQueries.map((q) => q.table).toList();
    expect(tables.where((t) => t == 'businesses').length, 1);

    await sync.pullChanges(businessId);
    expect(sync.pullRunCount, 2);
    await transport.dispose();
  });

  test('per-page fetch progress reaches pullStatus', () async {
    final transport = InMemoryCloudTransport(authUserId: 'user-1');
    final sync = SupabaseSyncService(db, transport);
    var maxFetched = 0;
    String? table;
    sync.pullStatus.addListener(() {
      final s = sync.pullStatus.value;
      if (s.rowsFetched > maxFetched) maxFetched = s.rowsFetched;
      table ??= s.currentTable;
    });

    transport.seed('roles', [
      for (var i = 0; i < 3; i++)
        {
          'id': 'role-$i',
          'business_id': businessId,
          'name': 'Role $i',
          'last_updated_at': '2026-01-01T00:00:00Z',
        },
    ]);
    try {
      await sync.pullChanges(businessId);
    } catch (_) {
      // Restoring the stub rows is not under test; the fetch progress is.
    }

    expect(maxFetched, greaterThan(0));
    expect(table, isNotNull);
    await transport.dispose();
  });

  test('a failed pull logs once per failure streak, without shop data',
      () async {
    final transport = InMemoryCloudTransport(authUserId: 'user-1');
    final sync = SupabaseSyncService(db, transport);
    const boom = PostgrestException(message: 'secret shop detail 08012345678');

    // 'roles' is critical (not deferrable): first pass + retry both fail.
    transport.failNext('roles', boom, count: 40);
    await expectLater(
      sync.pullChanges(businessId),
      throwsA(isA<PartialPullException>()),
    );
    await expectLater(
      sync.pullChanges(businessId),
      throwsA(isA<PartialPullException>()),
    );
    await expectLater(
      sync.pullChanges(businessId),
      throwsA(isA<PartialPullException>()),
    );

    var logs = await pullFailureLogs();
    expect(logs, hasLength(1), reason: 'retries must not spam error_logs');
    expect(logs.single.message, contains('roles'));
    expect(logs.single.message, isNot(contains('secret')));
    expect(logs.single.message, isNot(contains('0801')));
    expect(sync.isPullRunning, isFalse);
    expect(sync.pullStatus.value.stage, PullStage.failed);

    // A clean pull ends the streak; the next failure logs again.
    final fresh = InMemoryCloudTransport(authUserId: 'user-1');
    final sync2 = SupabaseSyncService(db, fresh);
    await sync2.pullChanges(businessId); // clean: resets the streak counter
    // Back to a full (paginated) pull so the fault is actually hit.
    (await SharedPreferences.getInstance()).remove(
      'last_sync_timestamp::$businessId',
    );
    fresh.failNext('roles', boom, count: 40);
    await expectLater(
      sync2.pullChanges(businessId),
      throwsA(isA<PartialPullException>()),
    );
    logs = await pullFailureLogs();
    expect(logs, hasLength(2));
    await transport.dispose();
    await fresh.dispose();
  });

  group('download card wording', () {
    test('never reads as all clear before the first full pull', () {
      final idle = describeDownload(PullStatus.idle, firstPullDone: false);
      expect(idle.title, 'Not fully downloaded');
      final failed = describeDownload(
        const PullStatus(
          stage: PullStage.failed,
          failedReason: 'PartialPullException: 1 table(s) failed: order_items',
        ),
        firstPullDone: false,
      );
      expect(failed.lines.join(' '), contains('order items'));
      expect(failed.lines.join(' '), contains('Not fully downloaded'));
      expect(
        describeDownload(PullStatus.idle, firstPullDone: true).title,
        'Downloaded',
      );
    });

    test('shows fetching progress, then rows saved of total', () {
      final fetching = describeDownload(
        const PullStatus(
          stage: PullStage.background,
          currentTable: 'order_items',
          rowsFetched: 1200,
        ),
        firstPullDone: false,
      );
      expect(fetching.lines.first, contains('order items'));
      expect(fetching.lines.first, contains('1200'));
      expect(fetching.progress, isNull);

      final saving = describeDownload(
        const PullStatus(
          stage: PullStage.background,
          rowsTotal: 200,
          rowsDone: 50,
          tablesTotal: 4,
          tablesDone: 1,
        ),
        firstPullDone: false,
      );
      expect(saving.lines.first, contains('50 of 200'));
      expect(saving.progress, 0.25);
    });
  });
}
