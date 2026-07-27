import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

import '../helpers/dispatch_test_utils.dart';

/// Money-integrity #193 (audit of #170 #7c / US 21): deleting a product with
/// stock on it must show up in the Daily Reconciliation as a VALUED loss, not as
/// ₦0.
///
/// #170 already snapshots the written-off FIFO cost onto the `product_deleted`
/// `stock_adjustments` row, but the report valued the line through `productById`
/// — a map built from NON-deleted products — so the lookup missed the
/// just-deleted product, the row was skipped as "uncosted", and the entire
/// write-off read ₦0. The loss was invisible everywhere except the delete
/// activity-log string.
///
/// Seam: the pure `productDeleteLossByProductKobo` reducer the recon engine
/// calls, driven against the real rows a real product delete writes.
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
              name: 'Manager',
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

  Future<List<StockAdjustmentData>> allAdjustments() =>
      db.select(db.stockAdjustments).get();

  /// `productById` exactly as `computeReconData` builds it — from
  /// products-with-stock, which filters `isDeleted.not()`. This is the map whose
  /// miss caused #193, so the tests must use the real thing, not a hand-made one.
  Future<Map<String, ProductData>> reconProductById() async {
    final rows = await db.inventoryDao.getProductsWithStock();
    return {for (final r in rows) r.product.id: r.product};
  }

  Future<int> deletionLossKobo({
    bool Function(DateTime)? inSpan,
    bool Function(String?)? inScope,
    Map<String, ProductData>? productById,
  }) async {
    return productDeleteLossKobo(
      await allAdjustments(),
      productById: productById ?? await reconProductById(),
      inSpan: inSpan ?? (_) => true,
      inScope: inScope ?? (_) => true,
    );
  }

  /// The full product delete the Product Details screen performs: write off the
  /// remaining stock (#170 #7c), then soft-delete the product.
  Future<int> deleteProduct(String productId) async {
    final writtenOff =
        await db.inventoryDao.writeOffAllStockForDelete(productId, staffId);
    await db.catalogDao.softDeleteProduct(productId);
    return writtenOff;
  }

  test('a deleted product\'s write-off is valued from its own snapshot, not the '
      'deleted-filtered cost lookup', () async {
    final productId = await addProduct(buyingKobo: 15000, stock: 8);

    final writtenOff = await deleteProduct(productId);
    expect(writtenOff, 120000); // 8 × 15,000

    // The bug's precondition: the product is genuinely unresolvable through the
    // map the report values its figures with.
    expect(await reconProductById(), isNot(contains(productId)));

    // The report figure nonetheless reads the full write-off — this was ₦0.
    expect(await deletionLossKobo(), 120000);
  });

  test('a LATER cost edit cannot restate a past write-off', () async {
    final productId = await addProduct(buyingKobo: 15000, stock: 8);
    await deleteProduct(productId);
    expect(await deletionLossKobo(), 120000);

    // Someone edits the (soft-deleted) product's buying price afterwards.
    await (db.update(db.products)..where((p) => p.id.equals(productId)))
        .write(const ProductsCompanion(buyingPriceKobo: Value(99000)));

    // Unchanged: the snapshot is the basis, so a past loss is immutable.
    expect(await deletionLossKobo(), 120000);
    expect(await deletionLossKobo(), isNot(792000)); // 8 × 99,000
  });

  test('a legacy quantity-only write-off (no snapshot) falls back to current '
      'cost', () async {
    // Simulate a pre-#170 row: a product_deleted removal with a NULL value_kobo.
    // The product is left LIVE here — that is the only state in which a current
    // cost is resolvable at all, which is what makes the fallback meaningful.
    final productId = await addProduct(buyingKobo: 12000, stock: 0);
    await db.into(db.stockAdjustments).insert(
          StockAdjustmentsCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantityDiff: -4,
            reason: InventoryDao.productDeletedReason,
            // unitCostKobo / valueKobo left Absent → NULL (legacy).
          ),
        );

    expect(await deletionLossKobo(), 48000); // 4 × current cost 12,000
  });

  test('only product_deleted removals count — damages, count fixes, increases '
      'and out-of-scope/span rows are excluded', () async {
    final productId = await addProduct(buyingKobo: 10000, stock: 30);
    // A damage (belongs to the Damages figure), a count shortage (belongs to
    // Stock shortages) and a free-text "deleted extra" removal (stays in the
    // residual) must not leak into the write-off figure.
    await db.inventoryDao
        .adjustStock(productId, storeId, -2, 'damage:breakage', staffId);
    await db.inventoryDao.adjustStock(
        productId, storeId, -3, 'Daily stock count adjustment', staffId);
    await db.inventoryDao
        .adjustStock(productId, storeId, -1, 'deleted extra stock', staffId);
    expect(await deletionLossKobo(), 0);

    // Now the real delete: the remaining 24 units at 10,000.
    await deleteProduct(productId);
    expect(await deletionLossKobo(), 240000);

    // Store-scoped out / span-scoped out → nothing to report.
    expect(await deletionLossKobo(inScope: (_) => false), 0);
    expect(await deletionLossKobo(inSpan: (_) => false), 0);
  });

  test('write-offs across several deleted products all accumulate', () async {
    final first = await addProduct(buyingKobo: 15000, stock: 8);
    final second = await addProduct(buyingKobo: 5000, stock: 4);
    await deleteProduct(first);
    await deleteProduct(second);

    expect(await deletionLossKobo(), 140000); // 120,000 + 20,000
  });

  test('a multi-store sweep reports every store\'s written-off value', () async {
    // The sweep walks every active store; #193 wrapped that walk in ONE
    // transaction so it can never half-commit and book a loss for a product the
    // caller then leaves alive. Here it succeeds — both legs must be reported.
    final branch = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(branch), businessId: businessId, name: 'Branch'),
        );
    final productId = await addProduct(buyingKobo: 15000, stock: 8);
    await db.inventoryDao
        .adjustStock(productId, branch, 5, 'Stock received', staffId);

    final writtenOff = await deleteProduct(productId);

    // 8 units in Main + 5 in Branch, all at 15,000.
    expect(writtenOff, 195000);
    expect(await deletionLossKobo(), 195000);
    // One write-off row per store that held stock.
    final rows = (await allAdjustments())
        .where((a) => a.reason == InventoryDao.productDeletedReason)
        .toList();
    expect(rows, hasLength(2));
  });
}
