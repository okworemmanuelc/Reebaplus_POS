// #427 (PRD #421 story 70): the customer cancels while the shop's phone is
// accepting. The cloud transition guard refuses the late Accept with P0001
// `online_order_transition_rejected`. That refusal must NOT become a Sync
// Issues orphan: the stale answer is dropped, the cloud row wins locally
// (even though the local Accept is newer), and the person who accepted is
// told "Cancelled by the customer before you accepted".

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_answer.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';
import '../helpers/screen_harness.dart' show initTestSupabase;
import 'online_order_fixtures.dart';

/// The cloud's status machine for `online_orders` (0205/0208): an answer is
/// accepted only while the stored row is still `new`.
class _GuardedCloud extends InMemoryCloudTransport {
  _GuardedCloud() : super(authUserId: 'user-1');

  @override
  Future<void> upsertRows(
    String table,
    List<Map<String, dynamic>> rows, {
    String? onConflict,
  }) async {
    if (table == 'online_orders') {
      final stored = {for (final r in rowsOf(table)) r['id']: r};
      for (final r in rows) {
        final cloud = stored[r['id']];
        if (cloud != null &&
            cloud['status'] != 'new' &&
            cloud['status'] != r['status']) {
          throw const PostgrestException(
            message: 'online_order_transition_rejected',
            code: 'P0001',
          );
        }
      }
    }
    return super.upsertRows(table, rows, onConflict: onConflict);
  }
}

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late _GuardedCloud cloud;
  late SupabaseSyncService sync;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
    await initTestSupabase(); // pushPending logs the (absent) JWT claims
  });

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    db.userIdResolver = () => 'staff-1';
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value('staff-1'),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ));
    storeId = await seedStore(db, businessId);
    cloud = _GuardedCloud();
    sync = SupabaseSyncService(db, cloud)..isOnline.value = true;
  });

  tearDown(() async {
    await cloud.dispose();
    await db.close();
  });

  Future<OnlineOrderData> local(String id) =>
      (db.select(db.onlineOrders)..where((t) => t.id.equals(id))).getSingle();

  test('a refused Accept is reconciled from the cloud, never orphaned',
      () async {
    final id = await seedOnlineOrder(db, businessId: businessId, storeId: storeId);
    // The customer cancels in the cloud before this phone's Accept lands.
    cloud.seed('online_orders', [
      cloudOnlineOrder(await local(id), status: 'cancelled_by_customer'),
    ]);

    expect(
      await db.onlineOrdersDao.accept(onlineOrderId: id),
      OnlineOrderAnswerOutcome.answered,
    );
    expect((await local(id)).status, 'accepted');

    await sync.pushPending();

    expect(await db.select(db.syncQueueOrphans).get(), isEmpty,
        reason: 'the race is benign: no Sync Issues orphan');
    final pending = await (db.select(db.syncQueue)
          ..where((t) =>
              t.status.isNotIn(['completed']) &
              t.actionType.equals('online_orders:upsert')))
        .get();
    expect(pending, isEmpty, reason: 'the stale answer is dropped');

    final row = await local(id);
    expect(row.status, 'cancelled_by_customer',
        reason: 'the cloud row wins over the newer local Accept');

    final note = (await db.select(db.notifications).get()).single;
    expect(note.message, contains(kCancelledBeforeAcceptText));
    expect(note.linkedRecordId, id);
    expect(note.recipientUserId, 'staff-1');
  });

  test('a clean Accept still lands in the cloud', () async {
    final id = await seedOnlineOrder(db, businessId: businessId, storeId: storeId);
    cloud.seed('online_orders', [cloudOnlineOrder(await local(id))]);
    await db.onlineOrdersDao.accept(onlineOrderId: id);
    await sync.pushPending();
    expect(cloud.rowsOf('online_orders').single['status'], 'accepted');
    expect((await local(id)).status, 'accepted');
    expect(await db.select(db.syncQueueOrphans).get(), isEmpty);
  });
}
