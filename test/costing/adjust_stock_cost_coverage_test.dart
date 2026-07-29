import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Money-integrity #7a (#170, PRD #155): the central mutator
/// `InventoryDao.adjustStock` now carries value with quantity. An increase
/// creates a Cost Batch so later sales draw real COGS not phantom 0; a decrease
/// draws the FIFO queue down oldest-first and SNAPSHOTS the drawn value onto its
/// `stock_adjustments` row, so a later cost-price edit cannot restate the loss.
///
/// What an increase's batch COSTS runs down a three-step ladder:
///   1. #197 (US 22) — the cost the stock-adjustment REQUEST captured, stated by
///      the person holding the invoice. It always wins.
///   2. #189 — else the product's recorded scalar price (ADR 0005's derived
///      display cache over the batch queue).
///   3. Uncosted (0) — only when neither is on file, or when a caller states 0.
///
/// Seam: the DAO transaction boundary against in-memory Drift — `adjustStock`
/// itself for the ladder's lower rungs, and `StockAdjustmentRequestsDao`
/// (request → approve) for the captured-cost rung.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 path so adjustStock writes the batch + snapshot locally (v2 defers to
    // the cloud RPC, which is out of scope for #170).
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

    storeId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );
    staffId = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: businessId,
            name: 'Stock Keeper',
            pin: '0000',
          ),
        );
  });

  tearDown(() => db.close());

  Future<String> newProduct({int buyingKobo = 0, int stock = 0}) async {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: 'Widget',
            retailerPriceKobo: const Value(100000),
            buyingPriceKobo: Value(buyingKobo),
          ),
        );
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: id,
            storeId: storeId,
            quantity: Value(stock),
          ),
        );
    return id;
  }

  Future<List<CostBatchData>> batchesFor(String productId) => (db.select(
    db.costBatches,
  )..where((b) => b.productId.equals(productId))).get();

  // The seed increase and the decrease can share a second-granularity
  // createdAt, so target the exact row by its signed quantity diff.
  Future<StockAdjustmentData> adjustmentWithDiff(String productId, int diff) =>
      (db.select(db.stockAdjustments)..where(
            (a) => a.productId.equals(productId) & a.quantityDiff.equals(diff),
          ))
          .getSingle();

  // ─── Increase: creates a Cost Batch ────────────────────────────────────────

  test('an increase WITH a cost creates a costed batch; a later sale draws '
      'real COGS not 0', () async {
    final productId = await newProduct(buyingKobo: 0, stock: 0);

    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      12,
      'Add quantity',
      staffId,
      inflowUnitCostKobo: 15000,
    );

    final batch = (await batchesFor(productId)).single;
    expect(batch.qtyRemaining, 12);
    expect(batch.qtyOriginal, 12);
    expect(batch.costKobo, 15000);

    // A later sale draws the real cost off the batch, not 0.
    final perUnit = await db.costBatchesDao.drawDownSale([
      SaleCostLine(
        index: 0,
        productId: productId,
        storeId: storeId,
        quantity: 4,
      ),
    ]);
    expect(perUnit[0], 15000);
  });

  test('#189: an increase WITHOUT a cost is batched at the product\'s recorded '
      'buying price, and a later sale draws it', () async {
    final productId = await newProduct(buyingKobo: 15000);

    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      10,
      'Recount found more',
      staffId,
    );

    // The scalar cache is the oldest COSTED batch (or the price the owner
    // entered) — the best available basis, and the same rule F1's opening-batch
    // migration used. Without it these units would sell at 0 COGS FOREVER: #41's
    // backfill only fires on a 0 → positive cost edit, which a product that
    // already has a price can never make again.
    final batch = (await batchesFor(productId)).single;
    expect(batch.qtyRemaining, 10);
    expect(batch.costKobo, 15000);

    final perUnit = await db.costBatchesDao.drawDownSale([
      SaleCostLine(
        index: 0,
        productId: productId,
        storeId: storeId,
        quantity: 4,
      ),
    ]);
    expect(perUnit[0], 15000);
  });

  test('#189: an increase WITHOUT a cost stays Uncosted (0) when the product '
      'has no cost on file', () async {
    final productId = await newProduct();

    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      10,
      'Recount found more',
      staffId,
    );

    // No cost is knowable, so the batch is genuinely Uncosted — the state #41's
    // backfill exists to resolve.
    final batch = (await batchesFor(productId)).single;
    expect(batch.qtyRemaining, 10);
    expect(batch.costKobo, 0);
  });

  test('#189: an explicit inflow cost still WINS over the recorded buying '
      'price', () async {
    final productId = await newProduct(buyingKobo: 15000);

    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      10,
      'Add quantity',
      staffId,
      inflowUnitCostKobo: 22000,
    );

    final batch = (await batchesFor(productId)).single;
    expect(batch.costKobo, 22000);
  });

  test('#189: an explicit inflow cost of 0 is a deliberate Uncosted batch, not '
      'a missing one', () async {
    final productId = await newProduct(buyingKobo: 15000);

    // The fallback keys on the caller saying NOTHING (null). A caller that hands
    // over 0 — Add Product with the buying price left blank — is stating there
    // is no cost, and that must not be silently overridden.
    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      10,
      'Opening stock, price skipped',
      staffId,
      inflowUnitCostKobo: 0,
    );

    final batch = (await batchesFor(productId)).single;
    expect(batch.costKobo, 0);
  });

  // ─── #197 (US 22): the approval path carries a REAL cost ───────────────────
  //
  // The seam one level up from `adjustStock`: `StockAdjustmentRequestsDao`. The
  // stock keeper filing the request is the one holding the invoice, so the cost
  // is captured on the request row and threaded into the approval's inflow
  // batch. #189's recorded-price fallback becomes what runs only when nobody
  // stated a cost.

  Future<String> fileRequest({
    required String productId,
    required int quantityDiff,
    int? unitCostKobo,
  }) async {
    await db.stockAdjustmentRequestsDao.requestStockAdjustment(
      productId: productId,
      storeId: storeId,
      quantityDiff: quantityDiff,
      reason: 'delivery from supplier',
      summary: 'Stock Keeper added $quantityDiff',
      requestedBy: staffId,
      unitCostKobo: unitCostKobo,
    );
    final row = await (db.select(
      db.stockAdjustmentRequests,
    )..where((r) => r.productId.equals(productId))).getSingle();
    return row.id;
  }

  test('#197: the cost captured on the request prices the approved increase\'s '
      'batch, beating the recorded price', () async {
    // The product's recorded price is stale (15000); this delivery cost 18000.
    final productId = await newProduct(buyingKobo: 15000);
    final requestId = await fileRequest(
      productId: productId,
      quantityDiff: 10,
      unitCostKobo: 18000,
    );

    // The cost survives the pending round-trip — the approval may happen days
    // later, on another device, off a pull.
    final pending = await (db.select(
      db.stockAdjustmentRequests,
    )..where((r) => r.id.equals(requestId))).getSingle();
    expect(pending.unitCostKobo, 18000);

    await db.stockAdjustmentRequestsDao.approveRequest(
      requestId: requestId,
      approverId: staffId,
    );

    final batch = (await batchesFor(productId)).single;
    expect(batch.qtyRemaining, 10);
    expect(batch.costKobo, 18000);

    // …and the units sell at what they actually cost.
    final perUnit = await db.costBatchesDao.drawDownSale([
      SaleCostLine(
        index: 0,
        productId: productId,
        storeId: storeId,
        quantity: 4,
      ),
    ]);
    expect(perUnit[0], 18000);
  });

  test('#197: a captured cost prices the batch even when the product has no '
      'recorded price at all', () async {
    final productId = await newProduct();
    final requestId = await fileRequest(
      productId: productId,
      quantityDiff: 10,
      unitCostKobo: 18000,
    );

    await db.stockAdjustmentRequestsDao.approveRequest(
      requestId: requestId,
      approverId: staffId,
    );

    // Before #197 this was the worst case: an Uncosted batch on a product with
    // no price on file, sellable at 0 COGS until someone noticed.
    final batch = (await batchesFor(productId)).single;
    expect(batch.costKobo, 18000);
  });

  test('#197: a request that states NO cost still falls back to the recorded '
      'price (#189)', () async {
    final productId = await newProduct(buyingKobo: 15000);
    final requestId = await fileRequest(productId: productId, quantityDiff: 10);

    final pending = await (db.select(
      db.stockAdjustmentRequests,
    )..where((r) => r.id.equals(requestId))).getSingle();
    expect(pending.unitCostKobo, isNull);

    await db.stockAdjustmentRequestsDao.approveRequest(
      requestId: requestId,
      approverId: staffId,
    );

    final batch = (await batchesFor(productId)).single;
    expect(batch.costKobo, 15000);
  });

  test('#197: a REMOVAL request never records a cost — the loss is valued by '
      'the store\'s FIFO queue, not by the requester', () async {
    final productId = await newProduct(buyingKobo: 15000, stock: 20);
    await db.costBatchesDao.recordInflowBatch(
      productId: productId,
      storeId: storeId,
      quantity: 20,
      costKobo: 12000,
    );

    // Even handed a cost, a decrease must not keep it: the requester is not the
    // authority on what a loss cost, and `adjustStock` would ignore it anyway.
    final requestId = await fileRequest(
      productId: productId,
      quantityDiff: -5,
      unitCostKobo: 99000,
    );
    final pending = await (db.select(
      db.stockAdjustmentRequests,
    )..where((r) => r.id.equals(requestId))).getSingle();
    expect(pending.unitCostKobo, isNull);

    await db.stockAdjustmentRequestsDao.approveRequest(
      requestId: requestId,
      approverId: staffId,
    );

    // Valued at the 12000 the queue actually held, not the 99000 handed over.
    final adj = await adjustmentWithDiff(productId, -5);
    expect(adj.valueKobo, 60000);
    expect(adj.unitCostKobo, 12000);
  });

  // ─── Decrease: snapshots the drawn value ───────────────────────────────────

  test(
    'a decrease draws the FIFO queue down and SNAPSHOTS the drawn value onto '
    'the adjustment row',
    () async {
      final productId = await newProduct();
      // Seed a costed layer of 20 @ 15000.
      await db.inventoryDao.adjustStock(
        productId,
        storeId,
        20,
        'Stock in',
        staffId,
        inflowUnitCostKobo: 15000,
      );

      await db.inventoryDao.adjustStock(
        productId,
        storeId,
        -3,
        'damage:breakage',
        staffId,
      );

      final adj = await adjustmentWithDiff(productId, -3);
      expect(adj.quantityDiff, -3);
      expect(adj.valueKobo, 45000); // 3 × 15000, drawn at write time
      expect(adj.unitCostKobo, 15000);

      // The batch it drew from is decremented.
      final batch = (await batchesFor(productId)).single;
      expect(batch.qtyRemaining, 17);
    },
  );

  test(
    'a later cost-price edit does NOT restate a past loss snapshot',
    () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId,
        storeId,
        20,
        'Stock in',
        staffId,
        inflowUnitCostKobo: 15000,
      );
      await db.inventoryDao.adjustStock(
        productId,
        storeId,
        -3,
        'damage:breakage',
        staffId,
      );

      // Cost edit after the loss.
      await (db.update(db.products)..where((p) => p.id.equals(productId)))
          .write(const ProductsCompanion(buyingPriceKobo: Value(99000)));

      final adj = await adjustmentWithDiff(productId, -3);
      // Still the snapshotted 45000 — immutable under the later cost edit.
      expect(adj.valueKobo, 45000);
    },
  );

  test('a decrease against a partially-covered queue snapshots only what was '
      'drawn (uncovered units cost 0)', () async {
    // On-hand is 5, but only 2 units are covered by a costed batch (the other 3
    // are pre-FIFO / uncosted history).
    final productId = await newProduct(stock: 5);
    await db.costBatchesDao.recordInflowBatch(
      productId: productId,
      storeId: storeId,
      quantity: 2,
      costKobo: 10000,
    );

    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      -5,
      'damage:flood',
      staffId,
    );

    final adj = await adjustmentWithDiff(productId, -5);
    // Only the 2 covered units carry cost (2 × 10000); the other 3 are uncosted.
    expect(adj.valueKobo, 20000);
    expect(adj.unitCostKobo, (20000 / 5).round()); // 4000
  });

  test('the stock_adjustments push carries the snapshot columns', () async {
    final productId = await newProduct();
    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      10,
      'Stock in',
      staffId,
      inflowUnitCostKobo: 12000,
    );
    await db.inventoryDao.adjustStock(
      productId,
      storeId,
      -4,
      'damage:breakage',
      staffId,
    );

    final queue = await getPendingQueue(db);
    final push = queue.lastWhere(
      (r) => r.actionType == 'stock_adjustments:upsert',
    );
    final payload = decodePayload(push);
    expect(payload['quantity_diff'], -4);
    expect(payload['value_kobo'], 48000);
    expect(payload['unit_cost_kobo'], 12000);
  });

  // ─── An increase snapshots NO loss ─────────────────────────────────────────

  test(
    'an increase leaves the snapshot columns NULL (no loss on an inflow)',
    () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId,
        storeId,
        7,
        'Recount',
        staffId,
      );
      final adj = await adjustmentWithDiff(productId, 7);
      expect(adj.valueKobo, isNull);
      expect(adj.unitCostKobo, isNull);
    },
  );
}
