// #528 (follow-up to #427): two phones link the same Shopper to DIFFERENT
// Customers at the same moment. The cloud keeps one live Customer per Shopper
// per business (0208's unique index customers_business_shopper_account), so the
// second phone's `customers` push fails with 23505 on that index. That refusal
// must NOT become a Sync Issues orphan: the phone adopts the cloud's linked
// Customer, re-points its order to it and keeps its own Customer, unlinked.

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

const _shopper = 'shopper-auth-1';

/// The cloud's partial unique index on (business_id, shopper_account_id)
/// WHERE shopper_account_id IS NOT NULL AND NOT is_deleted.
class _IndexedCloud extends InMemoryCloudTransport {
  _IndexedCloud() : super(authUserId: 'user-1');

  @override
  Future<void> upsertRows(
    String table,
    List<Map<String, dynamic>> rows, {
    String? onConflict,
  }) async {
    if (table == 'customers') {
      for (final r in rows) {
        final link = r['shopper_account_id'];
        if (link == null || r['is_deleted'] == true) continue;
        final clash = rowsOf(table).any(
          (c) =>
              c['id'] != r['id'] &&
              c['business_id'] == r['business_id'] &&
              c['shopper_account_id'] == link &&
              c['is_deleted'] != true,
        );
        if (clash) {
          throw const PostgrestException(
            message: 'duplicate key value violates unique constraint '
                '"customers_business_shopper_account"',
            code: '23505',
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
  late _IndexedCloud cloud;
  late SupabaseSyncService sync;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
    await initTestSupabase();
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
    cloud = _IndexedCloud();
    sync = SupabaseSyncService(db, cloud)..isOnline.value = true;
  });

  tearDown(() async {
    await cloud.dispose();
    await db.close();
  });

  Future<OnlineOrderData> order(String id) =>
      (db.select(db.onlineOrders)..where((t) => t.id.equals(id))).getSingle();

  Future<CustomerData?> customer(String id) =>
      (db.select(db.customers)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  test('a lost Shopper-link race adopts the cloud Customer, never orphaned',
      () async {
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: _shopper,
    );
    cloud.seed('online_orders', [cloudOnlineOrder(await order(id))]);
    // The other phone linked this Shopper to its own Customer first.
    const winnerId = 'customer-from-other-phone';
    final at = DateTime.utc(2026, 10, 25, 9, 5).toIso8601String();
    cloud.seed('customers', [
      {
        'id': winnerId,
        'business_id': businessId,
        'store_id': storeId,
        'name': 'Ada (other phone)',
        'phone': '08030000000',
        'price_tier': 'retailer',
        'wallet_limit_kobo': 0,
        'shopper_account_id': _shopper,
        'is_deleted': false,
        'created_at': at,
        'last_updated_at': at,
      },
    ]);

    expect(
      await db.onlineOrdersDao.accept(
        onlineOrderId: id,
        link: const CreateRetailerCustomer(),
      ),
      OnlineOrderAnswerOutcome.answered,
    );
    final localId = (await order(id)).customerId!;
    expect(localId, isNot(winnerId));

    await sync.pushPending();

    expect(await db.select(db.syncQueueOrphans).get(), isEmpty,
        reason: 'the race is benign: no Sync Issues orphan');

    // The cloud's linked Customer is now the local one too.
    expect((await customer(winnerId))?.shopperAccountId, _shopper);
    expect((await order(id)).customerId, winnerId);
    // This phone's Customer stays, unlinked, locally and in the cloud.
    expect((await customer(localId))?.shopperAccountId, isNull);
    final cloudLocal =
        cloud.rowsOf('customers').firstWhere((c) => c['id'] == localId);
    expect(cloudLocal['shopper_account_id'], isNull);

    // The re-pointed order goes up on the next drain.
    await sync.pushPending();
    final cloudOrder =
        cloud.rowsOf('online_orders').firstWhere((o) => o['id'] == id);
    expect(cloudOrder['customer_id'], winnerId);
    expect(cloudOrder['status'], 'accepted');
    expect(await db.select(db.syncQueueOrphans).get(), isEmpty);
  });

  test('a clean first-order link still lands in the cloud', () async {
    final id = await seedOnlineOrder(
      db,
      businessId: businessId,
      storeId: storeId,
      shopperAccountId: _shopper,
    );
    cloud.seed('online_orders', [cloudOnlineOrder(await order(id))]);
    await db.onlineOrdersDao.accept(
      onlineOrderId: id,
      link: const CreateRetailerCustomer(),
    );
    final localId = (await order(id)).customerId!;
    await sync.pushPending();
    final linked =
        cloud.rowsOf('customers').firstWhere((c) => c['id'] == localId);
    expect(linked['shopper_account_id'], _shopper);
    expect(await db.select(db.syncQueueOrphans).get(), isEmpty);
  });
}
