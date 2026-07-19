// cancel_rejected_sale_from_orphan_test.dart
//
// Oversell recovery — the Sync Issues fallback route (#150). If the cashier
// swipe-dismissed the `sale_rejected` notification, the rejected v2 sale is
// still recoverable from the Sync Issues screen: its orphaned
// `domain:pos_record_sale_v2` envelope carries `p_order_id` + `p_items`, so a
// "Cancel this sale" action can run the SAME complete local reversal as the
// notification and THEN clear the orphan.
//
// Critical gotcha this pins: the reversal MUST run BEFORE the orphan is cleared.
// `cancelRejectedSale` sources the sold lines from the orphan's `p_items`, so a
// discard-then-recover ordering would delete the payload and refund nothing.
//
// Pins: (1) the sale is reversed (order cancelled + inventory refunded) AND the
// orphan is cleared; (2) the refund proves the reversal ran while the payload
// was still present (reverse-before-clear); (3) idempotent — a second Cancel is
// a no-op; (4) with the orphan already gone, the phantom header is still
// cancelled.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v2 path — the sale writes an order + inventory deduction locally, but NO
    // order_items (they'd come from the RPC), exactly the state a rejected v2
    // sale leaves behind.
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
  });

  tearDown(() => db.close());

  Future<({String storeId, String staffId, String productId})> seed() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Beer',
        retailerPriceKobo: const Value(100000)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(5)));
    return (storeId: storeId, staffId: staffId, productId: productId);
  }

  // A v2 walk-in sale: order header + inventory deduction, no local order_items.
  Future<String> sellV2(
    ({String storeId, String staffId, String productId}) f, {
    required int qty,
  }) {
    final total = qty * 100000;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        totalAmountKobo: total,
        netAmountKobo: total,
        amountPaidKobo: Value(total),
        paymentType: 'cash',
        status: 'completed',
        staffId: Value(f.staffId),
        storeId: Value(f.storeId),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(f.productId),
          storeId: f.storeId,
          quantity: qty,
          unitPriceKobo: 100000,
          totalKobo: total,
        ),
      ],
      customerId: null,
      amountPaidKobo: total,
      totalAmountKobo: total,
      staffId: f.staffId,
      storeId: f.storeId,
      paymentMethod: 'cash',
    );
  }

  // The rejection lifted the envelope into sync_queue_orphans. Returns the
  // orphan's id (what the Sync Issues tile passes as `orphanId`).
  Future<String> orphanEnvelope(
    String orderId,
    String storeId,
    String productId,
    int qty,
  ) async {
    final orphanId = UuidV7.generate();
    await db.into(db.syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            id: Value(orphanId),
            originalId: UuidV7.generate(),
            actionType: 'domain:pos_record_sale_v2',
            payload: jsonEncode({
              'p_order_id': orderId,
              'p_store_id': storeId,
              'p_business_id': businessId,
              'p_items': [
                {'product_id': productId, 'quantity': qty},
              ],
            }),
            reason: 'insufficient_stock',
          ),
        );
    return orphanId;
  }

  Future<int> orphanCount() async =>
      (await db.select(db.syncQueueOrphans).get()).length;

  test('reverses the sale AND clears the orphan', () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    expect((await db.select(db.inventory).getSingle()).quantity, 3,
        reason: 'the optimistic pre-check deducted 2');
    final orphanId = await orphanEnvelope(orderId, f.storeId, f.productId, 2);
    expect(await orphanCount(), 1);

    await OrderService(db).cancelRejectedSaleFromOrphan(
      orderId: orderId,
      orphanId: orphanId,
      staffId: f.staffId,
    );

    final order = await db.select(db.orders).getSingle();
    expect(order.status, 'cancelled');
    expect(order.cancellationReason, 'rejected_by_server');
    expect((await db.select(db.inventory).getSingle()).quantity, 5,
        reason: 'inventory refunded from the envelope p_items');
    expect(await orphanCount(), 0,
        reason: 'the orphan envelope is cleared after recovery');
  });

  test('runs the reversal BEFORE clearing the orphan (refund proves ordering)',
      () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    final orphanId = await orphanEnvelope(orderId, f.storeId, f.productId, 2);

    await OrderService(db).cancelRejectedSaleFromOrphan(
      orderId: orderId,
      orphanId: orphanId,
      staffId: f.staffId,
    );

    // A discard-then-recover ordering would delete the payload first, leaving
    // `cancelRejectedSale` with no lines to refund — inventory would stay at 3.
    expect((await db.select(db.inventory).getSingle()).quantity, 5,
        reason: 'reversal ran while the orphan payload was still present');
    expect(await orphanCount(), 0);
  });

  test('is idempotent — a second Cancel is a no-op', () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    final orphanId = await orphanEnvelope(orderId, f.storeId, f.productId, 2);

    final svc = OrderService(db);
    await svc.cancelRejectedSaleFromOrphan(
      orderId: orderId,
      orphanId: orphanId,
      staffId: f.staffId,
    );
    expect((await db.select(db.inventory).getSingle()).quantity, 5);
    expect(await orphanCount(), 0);

    // A second tap must not double-refund and must not throw on the now-gone
    // orphan.
    await svc.cancelRejectedSaleFromOrphan(
      orderId: orderId,
      orphanId: orphanId,
      staffId: f.staffId,
    );
    expect((await db.select(db.inventory).getSingle()).quantity, 5,
        reason: 'no double refund on a second Cancel');
    expect((await db.select(db.orders).getSingle()).status, 'cancelled');
    expect(await orphanCount(), 0);
  });

  test('with the orphan already gone, still cancels the phantom order header',
      () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    // No orphan seeded → nothing to source items from, nothing to discard.

    await OrderService(db).cancelRejectedSaleFromOrphan(
      orderId: orderId,
      orphanId: UuidV7.generate(),
      staffId: f.staffId,
    );

    expect((await db.select(db.orders).getSingle()).status, 'cancelled',
        reason: 'the phantom header is cancelled even with no recoverable lines');
  });
}
