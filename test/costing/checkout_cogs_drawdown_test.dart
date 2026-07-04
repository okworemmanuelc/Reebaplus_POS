import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// Checkout wiring for FIFO costing (Epic 2 / ADR 0005, issue #38): a sale
/// snapshots a provisional COGS from the local batch queue onto
/// `OrderItems.buyingPriceKobo`, decrements the consumed `cost_batches`, and
/// re-points the product's scalar `buying_price_kobo` display cache — all while
/// selling price is untouched.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 record-sale path so createOrder writes order_items locally (v2 defers
    // the line write to the cloud RPC response).
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
              id: Value(staffId),
              businessId: businessId,
              name: 'Cashier',
              pin: '0000'),
        );
    return (storeId, staffId);
  }

  Future<String> seedProduct(String storeId, {required int scalarCostKobo}) async {
    final productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Cola',
            retailerPriceKobo: const Value(100000),
            buyingPriceKobo: Value(scalarCostKobo),
            unit: const Value('Piece'),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(100),
          ),
        );
    return productId;
  }

  Future<String> seedBatch(
    String productId,
    String storeId, {
    required int qty,
    required int costKobo,
    required DateTime receivedAt,
  }) async {
    final id = UuidV7.generate();
    await db.into(db.costBatches).insert(
          CostBatchesCompanion.insert(
            id: Value(id),
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            qtyRemaining: qty,
            qtyOriginal: qty,
            costKobo: Value(costKobo),
            receivedAt: Value(receivedAt),
          ),
        );
    return id;
  }

  List<Map<String, dynamic>> cartOf(String productId, int qty, int scalarKobo) =>
      [
        {
          'id': productId,
          'qty': qty,
          'unitPriceKobo': 100000,
          'buyingPriceKobo': scalarKobo,
          'name': 'Cola',
        },
      ];

  Future<OrderItemData> lineForOrder(String orderNumber) async {
    final order = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(orderNumber)))
        .getSingle();
    return (db.select(db.orderItems)..where((i) => i.orderId.equals(order.id)))
        .getSingle();
  }

  Future<ProductData> product(String productId) =>
      (db.select(db.products)..where((p) => p.id.equals(productId))).getSingle();

  Future<CostBatchData> batch(String id) =>
      (db.select(db.costBatches)..where((b) => b.id.equals(id))).getSingle();

  test('sale across a batch boundary snapshots weighted COGS, draws FIFO, and '
      'recomputes the scalar cache; selling price untouched', () async {
    final (storeId, staffId) = await seedBase();
    final productId = await seedProduct(storeId, scalarCostKobo: 100);
    final older =
        DateTime.utc(2026, 1, 1); // 6 @100 — the oldest, drawn first
    final newer = DateTime.utc(2026, 6, 1); // 10 @150
    final b1 = await seedBatch(productId, storeId,
        qty: 6, costKobo: 100, receivedAt: older);
    final b2 = await seedBatch(productId, storeId,
        qty: 10, costKobo: 150, receivedAt: newer);

    final svc = OrderService(db);
    final number = await svc.addOrder(
      customerId: null,
      cart: cartOf(productId, 10, 100),
      totalAmountKobo: 1000000,
      amountPaidKobo: 1000000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );

    final line = await lineForOrder(number);
    // COGS = 6*100 + 4*150 = 1200 over 10 units → 120/unit.
    expect(line.buyingPriceKobo, 120);
    // Selling price is one scalar, applied regardless of batch.
    expect(line.unitPriceKobo, 100000);

    // FIFO decrement: oldest batch exhausted, newer partially drawn.
    expect((await batch(b1)).qtyRemaining, 0);
    expect((await batch(b2)).qtyRemaining, 6);

    // Scalar cache = cost of the oldest REMAINING batch (b1 is spent → b2).
    expect((await product(productId)).buyingPriceKobo, 150);

    // The batch draw-down was queued for the cloud.
    final queued = await getPendingQueue(db);
    expect(queued.any((r) => r.actionType == 'cost_batches:upsert'), isTrue);
  });

  test('a partially-covered line costs only the covered units — the shortfall '
      'is uncosted, dragging the per-unit COGS down', () async {
    final (storeId, staffId) = await seedBase();
    final productId = await seedProduct(storeId, scalarCostKobo: 100);
    // Only 3 units on a batch, but the till sells 5 (inventory 100 allows it).
    final b1 = await seedBatch(productId, storeId,
        qty: 3, costKobo: 100, receivedAt: DateTime.utc(2026, 1, 1));

    final svc = OrderService(db);
    final number = await svc.addOrder(
      customerId: null,
      cart: cartOf(productId, 5, 100),
      totalAmountKobo: 500000,
      amountPaidKobo: 500000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );

    final line = await lineForOrder(number);
    // 3*100 covered + 2 uncosted = 300 over 5 units → 60/unit.
    expect(line.buyingPriceKobo, 60);
    expect((await batch(b1)).qtyRemaining, 0); // drained
  });

  test('product with no batch is uncosted (0), matching the server — no '
      'scalar fallback that a sync would silently rewrite', () async {
    final (storeId, staffId) = await seedBase();
    final productId = await seedProduct(storeId, scalarCostKobo: 250);
    // No cost_batches seeded for this product.

    final svc = OrderService(db);
    final number = await svc.addOrder(
      customerId: null,
      cart: cartOf(productId, 3, 250),
      totalAmountKobo: 300000,
      amountPaidKobo: 300000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );

    final line = await lineForOrder(number);
    // Local batch-queue view is empty → uncosted, exactly what the server's
    // authoritative recost would derive (so the correction never contradicts it).
    expect(line.buyingPriceKobo, 0);
    // Scalar untouched (no batch to recompute from).
    expect((await product(productId)).buyingPriceKobo, 250);
    final queued = await getPendingQueue(db);
    expect(queued.any((r) => r.actionType == 'cost_batches:upsert'), isFalse);
  });

  test('uncosted (cost-0) batch snapshots 0 COGS and never clobbers a '
      'user-set scalar to 0', () async {
    final (storeId, staffId) = await seedBase();
    // The scalar was set to 250 after an uncosted opening batch was seeded.
    final productId = await seedProduct(storeId, scalarCostKobo: 250);
    final uncosted = await seedBatch(productId, storeId,
        qty: 10, costKobo: 0, receivedAt: DateTime.utc(2026, 1, 1));

    final svc = OrderService(db);
    final number = await svc.addOrder(
      customerId: null,
      cart: cartOf(productId, 4, 250),
      totalAmountKobo: 400000,
      amountPaidKobo: 400000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );

    final line = await lineForOrder(number);
    expect(line.buyingPriceKobo, 0); // drawn from the uncosted batch
    expect((await batch(uncosted)).qtyRemaining, 6); // still decremented
    // No costed batch remains → scalar preserved, not zeroed (backfill is #41).
    expect((await product(productId)).buyingPriceKobo, 250);
  });
}
