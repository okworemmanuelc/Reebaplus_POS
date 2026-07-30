// legacy_valued_loss_label_test.dart
//
// PRD #155 US 20 (#200) — the current-cost fallback must be LABELLED.
//
// #170 made every new loss snapshot the FIFO cost it actually drew
// (`stock_adjustments.value_kobo`), so a later buying-price edit can never
// restate a past damage or shortage. Rows written BEFORE #170 recorded only a
// quantity, so their money DOES move when someone edits a price — the one case
// where a loss figure looks frozen but isn't. That fallback existed and was
// correct, but lived only in a dartdoc: the report just said "Damages (at cost)"
// / "Stock shortages (at cost)" with nothing marking which rows were valued at
// today's rate.
//
// The disclosure needs a count, and the count has to describe EXACTLY the rows
// the money summed — otherwise the footnote and the figure drift. These tests
// drive `countShortageRows` (the one definition of the shortage row set, shared
// with `countShortageLossKobo`) and `legacyValuedRowCount` against real
// `stock_adjustments` rows written by the real mutator.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String otherStoreId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 path so adjustStock draws the FIFO queue down and snapshots value_kobo
    // locally (v2 defers minting the row to the cloud RPC — out of scope).
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

    storeId = UuidV7.generate();
    otherStoreId = UuidV7.generate();
    for (final (id, name) in [(storeId, 'Main'), (otherStoreId, 'Annex')]) {
      await db.into(db.stores).insert(
            StoresCompanion.insert(
                id: Value(id), businessId: businessId, name: name),
          );
    }
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

  Future<String> newProduct({int buyingKobo = 0}) async {
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
    for (final s in [storeId, otherStoreId]) {
      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: id,
              storeId: s,
            ),
          );
    }
    return id;
  }

  /// Writes a pre-#170 row: a quantity, no cost snapshot.
  Future<void> legacyRow(
    String productId,
    int quantityDiff,
    String reason, {
    String? store,
  }) =>
      db.into(db.stockAdjustments).insert(
            StockAdjustmentsCompanion.insert(
              businessId: businessId,
              productId: productId,
              storeId: store ?? storeId,
              quantityDiff: quantityDiff,
              reason: reason,
              // unitCostKobo / valueKobo left Absent → NULL (legacy).
            ),
          );

  Future<List<StockAdjustmentData>> allAdjustments() =>
      db.select(db.stockAdjustments).get();

  Future<Map<String, ProductData>> productById() async {
    final rows = await db.select(db.products).get();
    return {for (final p in rows) p.id: p};
  }

  // The reason the stock count screen stamps on each applied line.
  const countReason = 'Daily stock count adjustment';
  bool always(Object? _) => true;

  Iterable<StockAdjustmentData> shortageRows(
    List<StockAdjustmentData> rows, {
    bool Function(DateTime)? inSpan,
    bool Function(String?)? inScope,
  }) =>
      countShortageRows(
        rows,
        inSpan: inSpan ?? always,
        inScope: inScope ?? always,
      );

  group('legacyValuedRowCount — how many rows took the fallback', () {
    test('a modern shortage carries its own cost, so nothing is disclosed',
        () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await db.inventoryDao
          .adjustStock(productId, storeId, -3, countReason, staffId);

      final rows = await allAdjustments();
      expect(legacyValuedRowCount(shortageRows(rows)), 0,
          reason: 'the mutator snapshotted value_kobo — no footnote owed');
      expect(
        countShortageLossKobo(rows,
            productById: await productById(), inSpan: always, inScope: always),
        30000,
      );
    });

    test('a legacy quantity-only shortage is counted AND still valued', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await legacyRow(productId, -4, countReason);

      final rows = await allAdjustments();
      expect(legacyValuedRowCount(shortageRows(rows)), 1);
      // The money is unchanged behaviour — 4 × today's cost. The count is the
      // new part: it says out loud that this figure moves with the price.
      expect(
        countShortageLossKobo(rows,
            productById: await productById(), inSpan: always, inScope: always),
        48000,
      );
    });

    test('counts only the legacy rows in a mixed period', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await db.inventoryDao
          .adjustStock(productId, storeId, -3, countReason, staffId); // modern
      await legacyRow(productId, -2, countReason); // legacy
      await legacyRow(productId, -5, countReason); // legacy

      final rows = await allAdjustments();
      expect(shortageRows(rows).length, 3);
      expect(legacyValuedRowCount(shortageRows(rows)), 2);
    });
  });

  group('countShortageRows — the footnote and the money see the same rows', () {
    test('a damage, a surplus and an inflow are not count shortages', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await db.inventoryDao.adjustStock(
        productId, storeId, 30, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await legacyRow(productId, -3, countReason); // the only shortage
      await legacyRow(productId, -2, 'damage:breakage'); // Damages figure
      await legacyRow(productId, 5, countReason); // a surplus (a gain)

      final rows = await allAdjustments();
      expect(shortageRows(rows).length, 1);
      expect(shortageRows(rows).single.quantityDiff, -3);
      // The disclosure therefore counts 1, matching the one row the money summed.
      expect(legacyValuedRowCount(shortageRows(rows)), 1);
      expect(
        countShortageLossKobo(rows,
            productById: await productById(), inSpan: always, inScope: always),
        36000, // 3 × 12,000
      );
    });

    test('store scope drops both the money and its footnote together', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await legacyRow(productId, -3, countReason, store: otherStoreId);

      final rows = await allAdjustments();
      bool onlyMain(String? s) => s == storeId;
      expect(shortageRows(rows, inScope: onlyMain), isEmpty);
      expect(legacyValuedRowCount(shortageRows(rows, inScope: onlyMain)), 0);
      expect(
        countShortageLossKobo(rows,
            productById: await productById(),
            inSpan: always,
            inScope: onlyMain),
        0,
        reason: 'a footnote must never outlive the figure it annotates',
      );
    });

    test('period scope drops both together too', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await legacyRow(productId, -3, countReason);

      final rows = await allAdjustments();
      bool never(DateTime _) => false;
      expect(shortageRows(rows, inSpan: never), isEmpty);
      expect(legacyValuedRowCount(shortageRows(rows, inSpan: never)), 0);
    });
  });

  group('damageLossRows — the Damages figure gets the same treatment', () {
    test('a modern damage discloses nothing, a legacy one discloses itself',
        () async {
      final productId = await newProduct(buyingKobo: 12000);
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await db.inventoryDao
          .adjustStock(productId, storeId, -2, 'damage:breakage', staffId);

      var rows = await allAdjustments();
      var damages = damageLossRows(rows, inSpan: always, inScope: always);
      expect(damages.length, 1);
      expect(legacyValuedRowCount(damages), 0);

      // Now a pre-#170 damage lands in the same period.
      await legacyRow(productId, -3, 'Theft');
      rows = await allAdjustments();
      damages = damageLossRows(rows, inSpan: always, inScope: always);
      expect(damages.length, 2);
      expect(legacyValuedRowCount(damages), 1);
    });

    test('damages and count shortages stay disjoint, so neither is '
        'double-disclosed', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await legacyRow(productId, -2, 'damage:breakage');
      await legacyRow(productId, -3, countReason);

      final rows = await allAdjustments();
      final damages = damageLossRows(rows, inSpan: always, inScope: always);
      final shortages = shortageRows(rows);
      expect(damages.length, 1);
      expect(shortages.length, 1);
      expect(
        damages.single.id,
        isNot(shortages.single.id),
        reason: 'one row must never appear in both figures',
      );
      // Each figure discloses its own single legacy row.
      expect(legacyValuedRowCount(damages), 1);
      expect(legacyValuedRowCount(shortages), 1);
    });

    test('an increase is not a damage, however it is worded', () async {
      final productId = await newProduct(buyingKobo: 12000);
      await legacyRow(productId, 4, 'damage:breakage'); // nonsensical, but +ve
      final rows = await allAdjustments();
      expect(damageLossRows(rows, inSpan: always, inScope: always), isEmpty);
    });
  });
}
