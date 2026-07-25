import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

import '../helpers/dispatch_test_utils.dart';

/// Money-integrity #182 (audit #30, the deferral #170 left open): the Daily
/// Reconciliation's count-SHORTAGE loss must be valued at the FIFO cost
/// SNAPSHOTTED when the count was saved (`stock_adjustments.value_kobo`, #170),
/// not recomputed at today's cost — so a later product-cost edit can never
/// restate a past period's shortage/variance figure (the same immutability the
/// Damages figure already got in #170).
///
/// Seam: the pure `countShortageLossKobo` reducer the recon engine calls, driven
/// against real `stock_adjustments` rows the mutator wrote through a stock count.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 path so adjustStock draws the FIFO queue down + snapshots value_kobo
    // locally (v2 defers minting the row to the cloud RPC — out of scope).
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

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
              name: 'Stock Keeper',
              pin: '0000'),
        );
  });

  tearDown(() => db.close());

  Future<String> newProduct({int buyingKobo = 0, int stock = 0}) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: 'Star 60cl',
            retailerPriceKobo: const Value(100000),
            buyingPriceKobo: Value(buyingKobo),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: id,
            storeId: storeId,
            quantity: Value(stock),
          ),
        );
    return id;
  }

  Future<List<StockAdjustmentData>> allAdjustments() =>
      db.select(db.stockAdjustments).get();

  Future<Map<String, ProductData>> productById() async {
    final rows = await db.select(db.products).get();
    return {for (final p in rows) p.id: p};
  }

  Future<void> editCost(String productId, int newCost) => (db.update(db.products)
        ..where((p) => p.id.equals(productId)))
      .write(ProductsCompanion(buyingPriceKobo: Value(newCost)));

  // The reason the stock count screen stamps on each applied line.
  const countReason = 'Daily stock count adjustment';
  bool always(Object? _) => true;

  test('a count shortage is valued at the write-time snapshot, and a LATER '
      'cost edit does not restate it', () async {
    // Costed layer of 20 @ 10,000, then a physical count finds 3 short.
    final productId = await newProduct();
    await db.inventoryDao.adjustStock(
      productId, storeId, 20, 'Stock in', staffId,
      inflowUnitCostKobo: 10000,
    );
    await db.inventoryDao.adjustStock(productId, storeId, -3, countReason, staffId);

    // At save time the shortage is worth 3 × 10,000.
    final before = countShortageLossKobo(
      await allAdjustments(),
      productById: await productById(),
      inSpan: always,
      inScope: always,
    );
    expect(before, 30000);

    // The owner later edits the buying price to 99,000.
    await editCost(productId, 99000);

    final after = countShortageLossKobo(
      await allAdjustments(),
      productById: await productById(),
      inSpan: always,
      inScope: always,
    );
    // The whole point: the past shortage is UNCHANGED (snapshot), NOT the
    // 3 × 99,000 = 297,000 the old current-cost basis would have produced.
    expect(after, 30000);
    expect(after, isNot(297000));
    expect(after, before);
  });

  test('a legacy quantity-only shortage (no snapshot) falls back to current '
      'cost', () async {
    // Simulate a pre-#170 row: a count-reconciliation removal with a NULL
    // value_kobo (the mutator never drew a batch for it).
    final productId = await newProduct(buyingKobo: 12000);
    await db.into(db.stockAdjustments).insert(
          StockAdjustmentsCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantityDiff: -4,
            reason: countReason,
            // unitCostKobo / valueKobo left Absent → NULL (legacy).
          ),
        );

    final value = countShortageLossKobo(
      await allAdjustments(),
      productById: await productById(),
      inSpan: always,
      inScope: always,
    );
    expect(value, 48000); // 4 × current cost 12,000 (labelled fallback)
  });

  test('only count-reconciliation removals count — damages, surplus and '
      'out-of-scope/span rows are excluded', () async {
    final productId = await newProduct();
    await db.inventoryDao.adjustStock(
      productId, storeId, 30, 'Stock in', staffId,
      inflowUnitCostKobo: 10000,
    );
    // A count shortage (counts), a damage (belongs to the Damages figure), and
    // a surplus increase (a gain, no loss snapshot).
    await db.inventoryDao.adjustStock(productId, storeId, -3, countReason, staffId);
    await db.inventoryDao.adjustStock(
      productId, storeId, -2, 'damage:breakage', staffId,
    );
    await db.inventoryDao.adjustStock(
      productId, storeId, 5, countReason, staffId, // recount found MORE
    );

    final adjustments = await allAdjustments();
    final pById = await productById();

    // Only the -3 count removal is valued: 3 × 10,000. The damage (-2) and the
    // surplus (+5) are not shortages.
    expect(
      countShortageLossKobo(adjustments,
          productById: pById, inSpan: always, inScope: always),
      30000,
    );
    // Store-scoped out: nothing in scope → 0.
    expect(
      countShortageLossKobo(adjustments,
          productById: pById, inSpan: always, inScope: (_) => false),
      0,
    );
    // Span-scoped out: nothing in span → 0.
    expect(
      countShortageLossKobo(adjustments,
          productById: pById, inSpan: (_) => false, inScope: always),
      0,
    );
  });

  test('a deleted product keeps its shortage value from the snapshot', () async {
    // The count-shortage snapshot survives even when the product row is gone —
    // the old current-cost lookup fell to 0 for a deleted product.
    final productId = await newProduct();
    await db.inventoryDao.adjustStock(
      productId, storeId, 8, 'Stock in', staffId,
      inflowUnitCostKobo: 10000,
    );
    await db.inventoryDao.adjustStock(productId, storeId, -3, countReason, staffId);

    // Product no longer resolvable (deleted / filtered out of productById).
    final value = countShortageLossKobo(
      await allAdjustments(),
      productById: const {}, // product missing
      inSpan: always,
      inScope: always,
    );
    expect(value, 30000); // still the snapshot, not 0
  });
}
