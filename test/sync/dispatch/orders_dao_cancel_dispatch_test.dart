import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/dispatch_test_utils.dart';

class _CancelSeed {
  final String storeId;
  final String staffId;
  final String productId;
  final String customerId;
  _CancelSeed({
    required this.storeId,
    required this.staffId,
    required this.productId,
    required this.customerId,
  });
}

/// Seeds: store, staff, product (+10 inventory), customer (+wallet
/// auto-created by addCustomer). The bootstrapTestDb() fixture supplies
/// the business row, so the test only owns sub-entities.
Future<_CancelSeed> _seedCancelFixtures(
  AppDatabase db,
  String businessId,
) async {
  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main',
        ),
      );
  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );
  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Test Beer',
          retailerPriceKobo: const Value(100000),
        ),
      );
  await db.into(db.inventory).insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: const Value(10),
        ),
      );
  final customerId = await db.customersDao.addCustomer(
    CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
  );
  return _CancelSeed(
    storeId: storeId,
    staffId: staffId,
    productId: productId,
    customerId: customerId,
  );
}

OrdersCompanion _orderCompanion(
  _CancelSeed s,
  String businessId, {
  required String orderNumber,
  int totalKobo = 200000,
  int amountPaidKobo = 200000,
}) {
  return OrdersCompanion.insert(
    businessId: businessId,
    orderNumber: orderNumber,
    customerId: Value(s.customerId),
    totalAmountKobo: totalKobo,
    netAmountKobo: totalKobo,
    amountPaidKobo: Value(amountPaidKobo),
    paymentType: 'cash',
    status: 'completed',
    staffId: Value(s.staffId),
    storeId: Value(s.storeId),
  );
}

OrderItemsCompanion _itemCompanion(_CancelSeed s, String businessId) {
  return OrderItemsCompanion.insert(
    businessId: businessId,
    orderId: 'placeholder', // overwritten by createOrder
    productId: Value(s.productId),
    storeId: s.storeId,
    quantity: 2,
    unitPriceKobo: 100000,
    totalKobo: 200000,
  );
}

/// Returns the orderId after createOrder seeds it. Also drains the queue
/// so subsequent assertions only see rows enqueued by the markCancelled
/// call under test.
Future<String> _createSaleAndDrainQueue(
  AppDatabase db,
  _CancelSeed s,
  String businessId,
) async {
  await db.ordersDao.createOrder(
    order: _orderCompanion(s, businessId, orderNumber: 'ORD-CANCEL-1'),
    items: [_itemCompanion(s, businessId)],
    customerId: s.customerId,
    amountPaidKobo: 200000,
    totalAmountKobo: 200000,
    staffId: s.staffId,
    storeId: s.storeId,
  );
  final orderId = (await db.select(db.orders).getSingle()).id;

  // Drain by deleting all pending rows; we only care about the cancel
  // dispatch's effect on the queue for these tests.
  await db.delete(db.syncQueue).go();

  return orderId;
}

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('OrdersDao.markCancelled dispatch', () {
    test(
        'flag OFF: order + stock_tx (compensation) + inventory + payment void '
        'enqueue, no domain envelope', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
      final s = await _seedCancelFixtures(db, businessId);
      final orderId = await _createSaleAndDrainQueue(db, s, businessId);

      await db.ordersDao.markCancelled(orderId, 'changed mind', s.staffId);

      // Local mirror: order cancelled, compensating stock_tx inserted,
      // payment voided, inventory restored.
      final order = await (db.select(db.orders)..where((t) => t.id.equals(orderId)))
          .getSingle();
      expect(order.status, 'cancelled');

      final stxRows = await db.select(db.stockTransactions).get();
      expect(stxRows, hasLength(2),
          reason: 'one sale + one compensating return row');
      final compensation =
          stxRows.firstWhere((r) => r.movementType == 'return');
      expect(compensation.quantityDelta, 2);

      final paymentRows = await db.select(db.paymentTransactions).get();
      expect(paymentRows, hasLength(1));
      expect(paymentRows.first.voidedAt, isNotNull);

      // Queue: per-table upserts only, no envelope.
      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toSet();
      expect(actionTypes.contains('domain:pos_cancel_order'), isFalse);
      expect(actionTypes, contains('orders:upsert'));
      expect(actionTypes, contains('stock_transactions:upsert'));
      expect(actionTypes, contains('inventory:upsert'));
      expect(actionTypes, contains('payment_transactions:upsert'));
    });

    test(
        'flag ON: one envelope with thin payload, only the order header '
        'is mirrored locally', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: true);
      final s = await _seedCancelFixtures(db, businessId);
      final orderId = await _createSaleAndDrainQueue(db, s, businessId);

      await db.ordersDao.markCancelled(orderId, 'wrong customer', s.staffId);

      // Local: order header flipped, but no new compensating stock_tx row,
      // payment NOT voided, no wallet refund. Those land via
      // _applyDomainResponse when the RPC returns.
      final order = await (db.select(db.orders)..where((t) => t.id.equals(orderId)))
          .getSingle();
      expect(order.status, 'cancelled',
          reason: 'header flips immediately for UI feedback');
      expect(order.cancellationReason, 'wrong customer');

      final stxRows = await db.select(db.stockTransactions).get();
      expect(stxRows, hasLength(1),
          reason: 'no compensating stock_tx until RPC response is applied');
      expect(stxRows.first.movementType, 'sale');

      final paymentRows = await db.select(db.paymentTransactions).get();
      expect(paymentRows, hasLength(1));
      expect(paymentRows.first.voidedAt, isNull,
          reason: 'payment void waits for the RPC response');

      // Queue: exactly one envelope.
      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_cancel_order');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], s.staffId);
      expect(payload['p_order_id'], orderId);
      expect(payload['p_cancellation_reason'], 'wrong customer');
    });
  });
}
