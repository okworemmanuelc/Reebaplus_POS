import 'dart:convert';

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
/// Seam: `countShortageRows` (which rows) + `countShortageRowsValueKobo` (what
/// they are worth), driven against real `stock_adjustments` rows the mutator
/// wrote through a stock count.
///
/// **#186 group at the foot of this file**: the same money, now selected on the
/// count SESSION basis the units already used, driven end-to-end through the
/// real `reconDataFrom`. Those tests are the reason the two halves above are
/// separate functions — #186 changed only the selection.
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

  /// The recon engine's shortage money over a row set: select the count-shortage
  /// rows, then value them at their write-time snapshot. Composed here exactly as
  /// [countSessionShortage] composes it in production.
  int shortageValueKobo(
    Iterable<StockAdjustmentData> rows, {
    required Map<String, ProductData> productById,
    bool Function(DateTime)? inSpan,
    bool Function(String?)? inScope,
  }) => countShortageRowsValueKobo(
        countShortageRows(
          rows,
          inSpan: inSpan ?? always,
          inScope: inScope ?? always,
        ),
        productById: productById,
      );

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
    final before = shortageValueKobo(
      await allAdjustments(),
      productById: await productById(),
    );
    expect(before, 30000);

    // The owner later edits the buying price to 99,000.
    await editCost(productId, 99000);

    final after = shortageValueKobo(
      await allAdjustments(),
      productById: await productById(),
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

    final value = shortageValueKobo(
      await allAdjustments(),
      productById: await productById(),
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
    expect(shortageValueKobo(adjustments, productById: pById), 30000);
    // Store-scoped out: nothing in scope → 0.
    expect(
      shortageValueKobo(adjustments,
          productById: pById, inScope: (_) => false),
      0,
    );
    // Span-scoped out: nothing in span → 0.
    expect(
      shortageValueKobo(adjustments,
          productById: pById, inSpan: (_) => false),
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
    final value = shortageValueKobo(
      await allAdjustments(),
      productById: const {}, // product missing
    );
    expect(value, 30000); // still the snapshot, not 0
  });

  // ── #186: money and units on ONE basis — the winning count session ─────────
  //
  // Everything below runs the REAL `reconDataFrom`, because the bug was never in
  // the valuation: it was in which rows the period's figure was built from, and
  // that decision only exists inside the compute. The row-level tests above stay
  // as they are — #186 changed the selection, not the valuation.

  /// One saved count SESSION. [businessDate] decides which period it reports in;
  /// [createdAt] decides which adjustment rows attribute to it (the save loop
  /// writes each line's row BEFORE the session row, so a session owns the rows
  /// written since the previous session).
  StockCountData countSession({
    required String businessDate,
    required DateTime createdAt,
    List<({String productId, int system, int diff})> lines = const [],
    int productsCounted = 5,
  }) {
    var shortageCount = 0;
    var surplusCount = 0;
    var shortageUnits = 0;
    var surplusUnits = 0;
    for (final l in lines) {
      if (l.diff < 0) {
        shortageCount++;
        shortageUnits += -l.diff;
      } else if (l.diff > 0) {
        surplusCount++;
        surplusUnits += l.diff;
      }
    }
    return StockCountData(
      id: UuidV7.generate(),
      businessId: businessId,
      storeId: storeId,
      businessDate: businessDate,
      productsCounted: productsCounted,
      shortageCount: shortageCount,
      surplusCount: surplusCount,
      shortageUnits: shortageUnits,
      surplusUnits: surplusUnits,
      linesJson: jsonEncode([
        for (final l in lines)
          {
            'p': l.productId,
            'n': 'Star 60cl',
            's': l.system,
            'a': l.system + l.diff,
            'd': l.diff,
          },
      ]),
      countedBy: staffId,
      createdAt: createdAt,
      lastUpdatedAt: createdAt,
    );
  }

  /// Applies one count shortage line through the real mutator (so it draws the
  /// FIFO queue and snapshots `value_kobo`), then stamps the row's `created_at`
  /// so the attribution window is the test's to decide rather than the clock's —
  /// SQLite stores whole seconds, so two sessions in one test would otherwise be
  /// indistinguishable.
  Future<void> applyCountShortage({
    required String productId,
    required int units,
    required DateTime writtenAt,
  }) async {
    final before = {for (final a in await allAdjustments()) a.id};
    await db.inventoryDao
        .adjustStock(productId, storeId, -units, countReason, staffId);
    final row =
        (await allAdjustments()).firstWhere((a) => !before.contains(a.id));
    await (db.update(db.stockAdjustments)..where((t) => t.id.equals(row.id)))
        .write(StockAdjustmentsCompanion(createdAt: Value(writtenAt)));
  }

  /// The real roll-up for the calendar day [day], over every adjustment in the
  /// database and the [sessions] handed in.
  Future<ReconData> reconForDay(
    DateTime day, {
    required List<StockCountData> sessions,
  }) async {
    final products = await db.select(db.products).get();
    return reconDataFrom(
      ReconInputs(
        adjustments: await allAdjustments(),
        stockCounts: sessions,
        productsWithStock: [
          for (final p in products)
            ProductDataWithStock(product: p, totalStock: 0),
        ],
        isCeo: true,
        start: day,
        endExclusive: day.add(const Duration(days: 1)),
      ),
    );
  }

  final day20 = DateTime(2026, 7, 20);
  final day21 = DateTime(2026, 7, 21);

  group('#186 — the money follows the units onto the count session', () {
    test('a same-day RECOUNT that comes out matching reports zero — no '
        'double-count, no false integrity flag', () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      // Morning count: 3 short, applied and saved.
      await applyCountShortage(
        productId: productId,
        units: 3,
        writtenAt: DateTime(2026, 7, 20, 9),
      );
      final morning = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 9, 5),
        lines: [(productId: productId, system: 20, diff: -3)],
      );
      // Afternoon RECOUNT of the same day: the shelf now matches the system, so
      // it adjusts nothing and saves an all-matched session.
      final afternoon = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 14),
      );

      final d = await reconForDay(day20, sessions: [morning, afternoon]);

      expect(d.hasStockCount, isTrue);
      expect(d.shortageUnits, 0, reason: 'the latest count found nothing short');
      expect(d.shortageCostKobo, 0, reason: 'the money must say the same');
      expect(d.stockVarianceKobo, 0);
      expect(d.hasIntegrityGap, isFalse);

      // Not vacuous: the morning's row is still in the database and still worth
      // its snapshot. The old all-rows basis reported exactly this against zero
      // units, which is the false flag #186 removes.
      expect(
        shortageValueKobo(
          await allAdjustments(),
          productById: await productById(),
        ),
        30000,
      );
    });

    test('a same-day recount that finds a NEW shortage reports the latest '
        'count only, never the sum of both saves', () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await applyCountShortage(
        productId: productId,
        units: 3,
        writtenAt: DateTime(2026, 7, 20, 9),
      );
      final morning = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 9, 5),
        lines: [(productId: productId, system: 20, diff: -3)],
      );
      await applyCountShortage(
        productId: productId,
        units: 2,
        writtenAt: DateTime(2026, 7, 20, 14),
      );
      final afternoon = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 14, 5),
        lines: [(productId: productId, system: 17, diff: -2)],
      );

      final d = await reconForDay(day20, sessions: [morning, afternoon]);

      expect(d.shortageUnits, 2);
      expect(d.shortageCostKobo, 20000, reason: '2 × 10,000 — NOT 50,000');
      expect(d.legacyValuedShortageRows, 0, reason: 'both rows are snapshotted');
      expect(d.stockVarianceKobo, -20000);
      expect(d.hasIntegrityGap, isTrue);
    });

    test('a BACKDATED count keeps its money in the same period as its units',
        () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      // Counted for the 20th, but saved after midnight on the 21st — the
      // day-boundary case that used to split one event across two periods.
      await applyCountShortage(
        productId: productId,
        units: 4,
        writtenAt: DateTime(2026, 7, 21, 0, 30),
      );
      final session = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 21, 0, 35),
        lines: [(productId: productId, system: 20, diff: -4)],
      );

      final reported = await reconForDay(day20, sessions: [session]);
      expect(reported.hasStockCount, isTrue);
      expect(reported.shortageUnits, 4);
      expect(reported.shortageCostKobo, 40000,
          reason: 'the money belongs to the day the count is FOR');

      final nextDay = await reconForDay(day21, sessions: [session]);
      expect(nextDay.hasStockCount, isFalse);
      expect(nextDay.shortageUnits, 0);
      expect(nextDay.shortageCostKobo, 0,
          reason: 'the day the count was keyed in reports none of it');
    });

    test('#182 still holds on the session basis: a later cost edit does not '
        'restate a past shortage', () async {
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await applyCountShortage(
        productId: productId,
        units: 3,
        writtenAt: DateTime(2026, 7, 20, 9),
      );
      final session = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 9, 5),
        lines: [(productId: productId, system: 20, diff: -3)],
      );

      final before = await reconForDay(day20, sessions: [session]);
      expect(before.shortageCostKobo, 30000);

      await editCost(productId, 99000);

      final after = await reconForDay(day20, sessions: [session]);
      expect(after.shortageCostKobo, 30000);
      expect(after.shortageCostKobo, isNot(297000));
      expect(after.stockVarianceKobo, before.stockVarianceKobo);
      expect(after.legacyValuedShortageRows, 0);
    });

    test('a session with no attributable rows is still valued — at current '
        'cost, and LABELLED as such', () async {
      // A legacy session (its device never wrote adjustment rows) or a peer's
      // session whose rows have not synced yet. Units short with ₦0 beside them
      // would be the very divergence #186 exists to end.
      final productId = await newProduct(buyingKobo: 12000);
      final session = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 9, 5),
        lines: [(productId: productId, system: 20, diff: -5)],
      );

      final d = await reconForDay(day20, sessions: [session]);

      expect(d.shortageUnits, 5);
      expect(d.shortageCostKobo, 60000, reason: '5 × today\'s cost 12,000');
      expect(d.legacyValuedShortageRows, 1,
          reason: 'the footnote must say this figure moves with the price');
    });

    test('rows from a save whose session never landed attach to the NEXT '
        'session for that store (documented imperfection)', () async {
      // `_saveCount` applies lines one at a time and can throw mid-loop, leaving
      // rows with no session. They are not dropped — dropping them would hide
      // stock that really did move — so they ride on the next count.
      final productId = await newProduct();
      await db.inventoryDao.adjustStock(
        productId, storeId, 20, 'Stock in', staffId,
        inflowUnitCostKobo: 10000,
      );
      await applyCountShortage(
        productId: productId,
        units: 1,
        writtenAt: DateTime(2026, 7, 20, 9), // the save that never completed
      );
      await applyCountShortage(
        productId: productId,
        units: 2,
        writtenAt: DateTime(2026, 7, 20, 14),
      );
      final session = countSession(
        businessDate: '2026-07-20',
        createdAt: DateTime(2026, 7, 20, 14, 5),
        lines: [(productId: productId, system: 19, diff: -2)],
      );

      final d = await reconForDay(day20, sessions: [session]);
      expect(d.shortageUnits, 2, reason: 'units come from the session alone');
      expect(d.shortageCostKobo, 30000,
          reason: 'both rows attach to the one session that landed');
    });
  });
}
