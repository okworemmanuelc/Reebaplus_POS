import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Prompted cost backfill (Epic 2 / ADR 0005 "Cost backfill", issue #41). When
/// a product's cost first becomes real (`0 → real value`), the still-uncosted
/// batches are costed for the future and the past uncosted sales are gathered
/// into a one-time [CostBackfillOffer] the user can apply: gap-only, each line
/// left in its own period, once per batch, one Activity Log row. Quick Sale and
/// migration-era (no-batch) lines are both handled by the same uncosted set.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
  });

  tearDown(() => db.close());

  Future<String> seedProduct({required int scalarCostKobo}) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: 'Cola',
            retailerPriceKobo: const Value(100000),
            buyingPriceKobo: Value(scalarCostKobo),
            unit: const Value('Piece'),
          ),
        );
    return id;
  }

  Future<String> seedBatch(
    String productId, {
    required int qty,
    required int costKobo,
    DateTime? receivedAt,
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
            receivedAt: Value(receivedAt ?? DateTime.utc(2026, 1, 1)),
          ),
        );
    return id;
  }

  /// Seeds one recognized order carrying a single line for [productId] at the
  /// given [buyingPriceKobo] snapshot. `productId == null` is a Quick Sale line.
  Future<String> seedSaleLine({
    String? productId,
    required int quantity,
    required int buyingPriceKobo,
    String status = 'pending',
    DateTime? at,
  }) async {
    final orderId = UuidV7.generate();
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: businessId,
            orderNumber: 'ORD-$orderId',
            totalAmountKobo: 100000,
            netAmountKobo: 100000,
            paymentType: 'cash',
            status: status,
            storeId: Value(storeId),
            createdAt: Value(at ?? DateTime.utc(2026, 3, 1)),
          ),
        );
    final lineId = UuidV7.generate();
    await db.into(db.orderItems).insert(
          OrderItemsCompanion.insert(
            id: Value(lineId),
            businessId: businessId,
            orderId: orderId,
            productId: Value(productId),
            storeId: storeId,
            quantity: quantity,
            unitPriceKobo: 100000,
            totalKobo: 100000 * quantity,
            buyingPriceKobo: Value(buyingPriceKobo),
          ),
        );
    return lineId;
  }

  Future<OrderItemData> line(String id) =>
      (db.select(db.orderItems)..where((t) => t.id.equals(id))).getSingle();
  Future<CostBatchData> batch(String id) =>
      (db.select(db.costBatches)..where((t) => t.id.equals(id))).getSingle();
  Future<OrderData> orderOf(String lineId) async {
    final item = await line(lineId);
    return (db.select(db.orders)..where((o) => o.id.equals(item.orderId)))
        .getSingle();
  }

  test('0→real transition: costs the uncosted batch, offers exactly the past '
      'uncosted lines, and leaves a costed line out', () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    final uncostedBatch = await seedBatch(productId, qty: 20, costKobo: 0);

    final uncostedA = await seedSaleLine(productId: productId, quantity: 4, buyingPriceKobo: 0);
    final uncostedB = await seedSaleLine(productId: productId, quantity: 3, buyingPriceKobo: 0);
    // A line already costed (e.g. drew from a later real batch) is NOT a gap.
    final costed = await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 200);

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);

    // The uncosted batch is now costed for the future (and pushed).
    expect((await batch(uncostedBatch)).costKobo, 500);
    final queued = await getPendingQueue(db);
    expect(queued.any((r) => r.actionType == 'cost_batches:upsert'), isTrue);

    // The offer names exactly the two gaps, 7 units total; the costed line is out.
    expect(offer.lineIds.toSet(), {uncostedA, uncostedB});
    expect(offer.unitsUncosted, 7);
    expect(offer.newCostKobo, 500);
    expect(offer.isEmpty, isFalse);

    final restated = await db.costBatchesDao
        .applyCostBackfill(offer, description: 'backfill', staffId: null);
    expect(restated, 2);
    expect((await line(uncostedA)).buyingPriceKobo, 500);
    expect((await line(uncostedB)).buyingPriceKobo, 500);
    // Gap-only: the already-costed line is untouched.
    expect((await line(costed)).buyingPriceKobo, 200);

    // The restated lines were re-pushed.
    final q2 = await getPendingQueue(db);
    expect(q2.where((r) => r.actionType == 'order_items:upsert').length, 2);
  });

  test('writes exactly one Activity Log row for the whole backfill', () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    await seedBatch(productId, qty: 10, costKobo: 0);
    await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 0);
    await seedSaleLine(productId: productId, quantity: 1, buyingPriceKobo: 0);

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    await db.costBatchesDao.applyCostBackfill(offer, description: 'Applied cost to 3 past sales');

    final logs = await (db.select(db.activityLogs)
          ..where((t) => t.action.equals('cost.backfill')))
        .get();
    expect(logs, hasLength(1));
    expect(logs.single.entityType, 'product');
    expect(logs.single.entityId, productId);
    expect(logs.single.description, 'Applied cost to 3 past sales');
  });

  test('each restated line keeps its own sale date so profit lands in its '
      'original period', () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    await seedBatch(productId, qty: 10, costKobo: 0);
    final jan = DateTime.utc(2026, 1, 15);
    final jun = DateTime.utc(2026, 6, 20);
    final lineJan = await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 0, at: jan);
    final lineJun = await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 0, at: jun);

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    await db.costBatchesDao.applyCostBackfill(offer, description: 'backfill');

    // Only the snapshot changed; the order's own timestamp is preserved (so
    // restated profit lands back in that sale's original period).
    expect((await orderOf(lineJan)).createdAt.isAtSameMomentAs(jan), isTrue);
    expect((await orderOf(lineJun)).createdAt.isAtSameMomentAs(jun), isTrue);
    expect((await line(lineJan)).buyingPriceKobo, 500);
    expect((await line(lineJun)).buyingPriceKobo, 500);
  });

  test('Quick Sale (no-product) lines are never offered and stay uncosted',
      () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    await seedBatch(productId, qty: 10, costKobo: 0);
    await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 0);
    final quickSale = await seedSaleLine(productId: null, quantity: 5, buyingPriceKobo: 0);

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    expect(offer.lineIds, isNot(contains(quickSale)));

    await db.costBatchesDao.applyCostBackfill(offer, description: 'backfill');
    expect((await line(quickSale)).buyingPriceKobo, 0);
  });

  test('migration-era fallback: a product with NO batch still backfills its '
      'pre-FIFO uncosted lines', () async {
    // No cost_batches at all — these lines drew from no batch (pre-FIFO).
    final productId = await seedProduct(scalarCostKobo: 0);
    final l1 = await seedSaleLine(productId: productId, quantity: 6, buyingPriceKobo: 0);

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    expect(offer.lineIds, [l1]);
    expect(offer.unitsUncosted, 6);

    final restated = await db.costBatchesDao
        .applyCostBackfill(offer, description: 'backfill');
    expect(restated, 1);
    expect((await line(l1)).buyingPriceKobo, 500);
  });

  test('a reversed sale (cancelled/refunded) is not a gap and is never '
      'restated', () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    await seedBatch(productId, qty: 10, costKobo: 0);
    final live = await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 0);
    final cancelled = await seedSaleLine(
        productId: productId, quantity: 3, buyingPriceKobo: 0, status: 'cancelled');
    final refunded = await seedSaleLine(
        productId: productId, quantity: 4, buyingPriceKobo: 0, status: 'refunded');

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    expect(offer.lineIds, [live]);

    await db.costBatchesDao.applyCostBackfill(offer, description: 'backfill');
    expect((await line(cancelled)).buyingPriceKobo, 0);
    expect((await line(refunded)).buyingPriceKobo, 0);
  });

  test('fires once: re-applying a stale offer restates nothing (gap-only re-'
      'check) and logs no second row', () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    await seedBatch(productId, qty: 10, costKobo: 0);
    await seedSaleLine(productId: productId, quantity: 2, buyingPriceKobo: 0);

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    expect(await db.costBatchesDao.applyCostBackfill(offer, description: 'backfill'), 1);
    // The very same offer, applied again: lines are no longer 0, so nothing.
    expect(await db.costBatchesDao.applyCostBackfill(offer, description: 'backfill'), 0);

    final logs = await (db.select(db.activityLogs)
          ..where((t) => t.action.equals('cost.backfill')))
        .get();
    expect(logs, hasLength(1));
  });

  test('nothing to backfill: an empty offer costs the batch but writes no log',
      () async {
    final productId = await seedProduct(scalarCostKobo: 0);
    final b = await seedBatch(productId, qty: 10, costKobo: 0);
    // No past uncosted sales.

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 500);
    expect(offer.isEmpty, isTrue);
    expect((await batch(b)).costKobo, 500); // future draws are costed

    expect(await db.costBatchesDao.applyCostBackfill(offer, description: 'x'), 0);
    final logs = await (db.select(db.activityLogs)
          ..where((t) => t.action.equals('cost.backfill')))
        .get();
    expect(logs, isEmpty);
  });
}
