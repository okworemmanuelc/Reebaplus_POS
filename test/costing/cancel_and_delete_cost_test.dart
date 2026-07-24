import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// Money-integrity #7c (#170, PRD #155): cancel restores the consumed cost
/// LAYER locally (the FIFO queue and the shelf stay in step) and the cancel push
/// triggers the same server recost a sale push does; deleting a product writes
/// off its remaining stock value visibly (drawing the batches down + snapshotting
/// the value + returning the total).
///
/// Seam: the DAO transaction boundary against in-memory Drift + the pure recost
/// pair collector.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);

    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
              id: Value(staffId),
              businessId: businessId,
              name: 'Cashier',
              pin: '0000'),
        );
  });

  tearDown(() => db.close());

  Future<String> addProduct({required int buyingKobo, required int stock}) {
    return db.catalogDao.insertProductWithInitialStock(
      ProductsCompanion.insert(
        name: 'Cola',
        businessId: businessId,
        retailerPriceKobo: const Value(100000),
        buyingPriceKobo: Value(buyingKobo),
        unit: const Value('Piece'),
      ),
      initialStock: stock,
      storeId: storeId,
      performedBy: staffId,
    );
  }

  Future<List<CostBatchData>> batchesFor(String productId) =>
      (db.select(db.costBatches)..where((b) => b.productId.equals(productId)))
          .get();

  List<Map<String, dynamic>> cartOf(String productId, int qty) => [
        {
          'id': productId,
          'qty': qty,
          'unitPriceKobo': 100000,
          'buyingPriceKobo': 0,
          'name': 'Cola',
        },
      ];

  // ─── 7c: cancel restores the consumed cost layer ───────────────────────────

  test('cancelling a sale restores the consumed cost LAYER at the snapshot cost',
      () async {
    final productId = await addProduct(buyingKobo: 15000, stock: 10);
    final svc = OrderService(db);

    final orderNumber = await svc.addOrder(
      customerId: null,
      cart: cartOf(productId, 4),
      totalAmountKobo: 400000,
      amountPaidKobo: 400000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    final order = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(orderNumber)))
        .getSingle();

    // The sale drew 10 → 6 off the opening batch and snapshotted 15000/unit.
    expect(
        (await batchesFor(productId)).fold<int>(0, (s, b) => s + b.qtyRemaining),
        6);

    await db.ordersDao.markCancelled(order.id, 'customer changed mind', staffId);

    // The 4 units come back as a costed LAYER (total covered back to 10).
    final batches = await batchesFor(productId);
    expect(batches.fold<int>(0, (s, b) => s + b.qtyRemaining), 10);
    // The restored layer carries the snapshot cost (a re-sale draws 15000).
    final perUnit = await db.costBatchesDao.drawDownSale([
      SaleCostLine(index: 0, productId: productId, storeId: storeId, quantity: 1),
    ]);
    expect(perUnit[0], 15000);
  });

  test('the cancel push emits a `return` stock_transaction whose (product, '
      'store) pair the recost collector picks up', () async {
    final productId = await addProduct(buyingKobo: 15000, stock: 10);
    final svc = OrderService(db);
    final orderNumber = await svc.addOrder(
      customerId: null,
      cart: cartOf(productId, 4),
      totalAmountKobo: 400000,
      amountPaidKobo: 400000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    final order = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(orderNumber)))
        .getSingle();
    await db.ordersDao.markCancelled(order.id, 'reason', staffId);

    // A `return` stock_transaction exists for the cancelled line.
    final returnTx = await (db.select(db.stockTransactions)
          ..where((t) => t.movementType.equals('return')))
        .get();
    expect(returnTx, isNotEmpty);

    // The collector turns pushed `return` rows into recost candidates — the same
    // pass a sale push triggers, so the server recost supersedes the local layer.
    final pairs = <({String productId, String storeId})>{};
    SupabaseSyncService.collectReturnStockTxPairs(
      returnTx.map((t) => {
            'movement_type': t.movementType,
            'product_id': t.productId,
            'location_id': t.locationId,
          }),
      pairs,
    );
    expect(pairs, contains((productId: productId, storeId: storeId)));
  });

  test('collectReturnStockTxPairs ignores non-return movements', () {
    final pairs = <({String productId, String storeId})>{};
    SupabaseSyncService.collectReturnStockTxPairs([
      {'movement_type': 'sale', 'product_id': 'p', 'location_id': 's'},
      {'movement_type': 'adjustment', 'product_id': 'p', 'location_id': 's'},
      {'movement_type': 'return', 'product_id': 'p2', 'location_id': 's2'},
      {'movement_type': 'return', 'product_id': null, 'location_id': 's'},
    ], pairs);
    expect(pairs, {(productId: 'p2', storeId: 's2')});
  });

  // ─── 7c: product-delete write-off ──────────────────────────────────────────

  test('writeOffAllStockForDelete draws the batches down and returns the '
      'snapshotted total value', () async {
    final productId = await addProduct(buyingKobo: 15000, stock: 8);

    final total = await db.inventoryDao.writeOffAllStockForDelete(
      productId,
      staffId,
    );

    // 8 units × 15000 written off.
    expect(total, 120000);
    // The open batch is drawn to zero (no residual coverage).
    expect(
        (await batchesFor(productId)).fold<int>(0, (s, b) => s + b.qtyRemaining),
        0);
    // The write-off adjustment carries the snapshotted value (booked, visible).
    final adj = await (db.select(db.stockAdjustments)
          ..where((a) =>
              a.productId.equals(productId) &
              a.reason.equals(InventoryDao.productDeletedReason)))
        .getSingle();
    expect(adj.valueKobo, 120000);
  });

  test('writeOffAllStockForDelete on an empty product writes nothing and '
      'returns 0', () async {
    final productId = await addProduct(buyingKobo: 15000, stock: 0);
    final total = await db.inventoryDao.writeOffAllStockForDelete(
      productId,
      staffId,
    );
    expect(total, 0);
    final adjs = await (db.select(db.stockAdjustments)
          ..where((a) =>
              a.productId.equals(productId) &
              a.reason.equals(InventoryDao.productDeletedReason)))
        .get();
    expect(adjs, isEmpty);
  });
}
