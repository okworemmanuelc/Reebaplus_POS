// cancel_rejected_sale_test.dart
//
// Oversell recovery — Slice 2c (the cashier-tapped Cancel). When the guarded
// `pos_record_sale_v2` permanently rejects a sale, the cashier taps Cancel on
// the `sale_rejected` alert. A v2 sale writes NO local `order_items`, so
// `OrderCommands.cancelRejectedSale` re-sources the sold lines from the orphaned
// envelope's `p_items` (moved to `sync_queue_orphans` on rejection) and then
// runs the complete local reversal (order + inventory + wallet + crate).
//
// Pins: (1) items are sourced from the orphaned envelope → order cancelled +
// inventory refunded; (2) with the orphan already gone, the phantom order header
// is still cancelled (graceful + idempotent).

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

  Future<void> orphanEnvelope(
    String orderId,
    String storeId,
    String productId,
    int qty,
  ) {
    return db.into(db.syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: UuidV7.generate(),
            actionType: 'domain:pos_record_sale_v2',
            payload: jsonEncode({
              'p_order_id': orderId,
              'p_store_id': storeId,
              'p_items': [
                {'product_id': productId, 'quantity': qty},
              ],
            }),
            reason: 'insufficient_stock',
          ),
        );
  }

  test('sources sold lines from the orphaned envelope and reverses the sale',
      () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    expect((await db.select(db.inventory).getSingle()).quantity, 3,
        reason: 'the optimistic pre-check deducted 2');

    // The rejection moved the envelope to sync_queue_orphans.
    await orphanEnvelope(orderId, f.storeId, f.productId, 2);

    await OrderService(db).cancelRejectedSale(orderId, f.staffId);

    final order = await db.select(db.orders).getSingle();
    expect(order.status, 'cancelled');
    expect(order.cancellationReason, 'rejected_by_server');
    expect((await db.select(db.inventory).getSingle()).quantity, 5,
        reason: 'inventory refunded from the envelope p_items');
  });

  test('with the orphan already gone, still cancels the phantom order header',
      () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    // No orphan row seeded → nothing to source items from.

    await OrderService(db).cancelRejectedSale(orderId, f.staffId);

    expect((await db.select(db.orders).getSingle()).status, 'cancelled',
        reason: 'the phantom header is cancelled even with no recoverable lines');
  });

  test('is idempotent — a second Cancel is a no-op', () async {
    final f = await seed();
    final orderId = await sellV2(f, qty: 2);
    await orphanEnvelope(orderId, f.storeId, f.productId, 2);

    final svc = OrderService(db);
    await svc.cancelRejectedSale(orderId, f.staffId);
    final invAfterFirst = (await db.select(db.inventory).getSingle()).quantity;
    expect(invAfterFirst, 5);

    // A second tap must not double-refund (the already-cancelled guard).
    await svc.cancelRejectedSale(orderId, f.staffId);
    expect((await db.select(db.inventory).getSingle()).quantity, invAfterFirst,
        reason: 'no double refund on a second Cancel');
  });
}
