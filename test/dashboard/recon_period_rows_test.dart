// #683 (PRD #680 S2) — the Daily Reconciliation detail and the day close load
// only the rows their period needs (`loadReconPeriodRows`), then hand them to
// the SAME pure `reconDataFrom`. These tests prove the narrowing changes no
// figure: for every day, week and month, at every scope and role, the period's
// rows give exactly the figures the whole history gives.
//
// Two shops:
//   * the generated multi-month history shop (#682): sales, later-day cancels,
//     van sales, deposits held / released / forfeited, expenses, stock
//     adjustments, counts, crate damages, supplier entries;
//   * the shared report test shop (report_fixture.dart) plus hand-placed rows
//     on the edges the narrowing must get right: a sale cancelled on a later
//     day, a backdated expense, a stock movement whose adjustment sits on the
//     other side of midnight, stock movements after the period (the stock-card
//     rewind) and count sessions whose shortage rows must be matched across
//     the period's edge (#186), including a backdated count.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

import '../helpers/screen_harness.dart';
import '../support/history_reports.dart';
import '../support/history_shop_generator.dart';
import 'report_fixture.dart';

/// Every figure a [ReconData] carries, as plain values, so two roll-ups can
/// be compared with one `expect`.
Map<String, Object?> fingerprint(ReconData d) => {
  'totalRevenue': d.totalRevenueKobo,
  'costedRevenue': d.costedRevenueKobo,
  'cogs': d.cogsKobo,
  'discounts': d.discountsKobo,
  'vat': d.vatKobo,
  'itemsSold': d.itemsSold,
  'skus': d.skus,
  'uncostedItems': d.uncostedItems,
  'refunds': d.refundsKobo,
  'cashSales': d.cashSalesKobo,
  'cashDebts': d.cashDebtsCollectedKobo,
  'cashRefunds': d.cashRefundsKobo,
  'cashExpenses': d.cashExpensesKobo,
  'cashSupplierPaid': d.cashSupplierPaidKobo,
  'cashCrateDeposits': d.cashCrateDepositsKobo,
  'cashCrateDepositsPlaced': d.cashCrateDepositsPlacedKobo,
  'crateShortfallWrittenOff': d.crateShortfallWrittenOffKobo,
  'crateForfeitNetted': d.crateForfeitNettedKobo,
  'bestStaff': d.bestStaff,
  'bestStaffKobo': d.bestStaffKobo,
  'expenses': d.expensesKobo,
  'expensesCount': d.expensesCount,
  'dailyAllowances': d.dailyAllowancesKobo,
  'salaries': d.salariesKobo,
  'damageUnits': d.damageUnits,
  'damageCost': d.damageCostKobo,
  'damageRetail': d.damageRetailKobo,
  'crateDamageDeposit': d.crateDamageDepositKobo,
  'hasStockCount': d.hasStockCount,
  'productsCounted': d.productsCounted,
  'shortageCount': d.shortageCount,
  'shortageUnits': d.shortageUnits,
  'surplusCount': d.surplusCount,
  'surplusUnits': d.surplusUnits,
  'shortageCost': d.shortageCostKobo,
  'shortageRetail': d.shortageRetailKobo,
  'shortages': [
    for (final s in d.shortages) '${s.name}|${s.system}|${s.actual}|${s.diff}',
  ],
  'goodsReceived': d.goodsReceivedKobo,
  'supplierPaid': d.supplierPaidKobo,
  'totalOwed': d.totalOwedKobo,
  'crateUnits': d.crateUnits,
  'crateDeposit': d.crateDepositKobo,
  'supplierPayable': d.supplierPayableKobo,
  'inventoryOnHand': d.inventoryOnHandKobo,
  'inTransit': d.inTransitValueKobo,
  'uncostedInventory': d.uncostedInventoryItems,
  'surplusCost': d.surplusCostKobo,
  'stockOpening': d.stockOpeningKobo,
  'stockReceived': d.stockReceivedKobo,
  'stockCogs': d.stockCogsKobo,
  'stockDamages': d.stockDamagesKobo,
  'stockExpired': d.stockExpiredKobo,
  'stockOther': d.stockOtherMovementsKobo,
  'stockExpectedClosing': d.stockExpectedClosingKobo,
  'topItems': [for (final t in d.topItems) '${t.name}|${t.qty}'],
  'manufacturerEmpties': [
    for (final m in d.manufacturerEmpties)
      '${m.manufacturerName}|${m.count}|${m.valueKobo}',
  ],
  'salesPaidNow': d.salesPaidNowKobo,
  'salesOnCredit': d.salesOnCreditKobo,
  'forfeitIncome': d.forfeitIncomeKobo,
  'uncostedTakings': d.uncostedTakingsKobo,
  'stockTransfers': d.stockTransfersKobo,
  'stockCountAdjustments': d.stockCountAdjustmentsKobo,
  'stockDeletions': d.stockDeletionsKobo,
  'legacyDamageRows': d.legacyValuedDamageRows,
  'legacyShortageRows': d.legacyValuedShortageRows,
  'deletionCost': d.deletionCostKobo,
  'totalSales': d.totalSalesKobo,
  'returns': d.returnsKobo,
  'netProfit': d.netProfitKobo,
  'netResult': d.periodNetResultKobo,
  'netPosition': d.businessNetPositionKobo,
  'van': [
    d.van.salesKobo,
    d.van.remittedKobo,
    d.van.cashRemittedKobo,
    d.van.profitKobo,
    d.van.cogsKobo,
    d.van.openRevenueKobo,
    d.van.openTripCount,
    d.van.closedTripCount,
  ],
};

/// The figures a day close freezes, as plain values.
Map<String, num> frozen(ReconData d) {
  final f = dailyClosingFiguresFrom(d);
  return {
    'totalSales': f.totalSalesKobo,
    'refunds': f.refundsKobo,
    'discounts': f.discountsKobo,
    'cogs': f.cogsKobo,
    'grossProfit': f.grossProfitKobo,
    'netProfit': f.netProfitKobo,
    'expenses': f.expensesKobo,
    'damages': f.damagesCostKobo,
    'cashSales': f.cashSalesKobo,
    'cashIn': f.cashInKobo,
    'cashOut': f.cashOutKobo,
    'netCash': f.netCashMovementKobo,
    'stockCogs': f.stockCogsKobo,
    'stockExpectedClosing': f.stockExpectedClosingKobo,
    'itemsSold': f.itemsSold,
    'shortageUnits': f.shortageUnits,
  };
}

/// Everything a comparison needs from one shop.
class _Shop {
  _Shop({
    required this.db,
    required this.full,
    required this.forfeits,
    required this.manufacturers,
    required this.vanTrips,
    required this.vanStoreIds,
    required this.storeId,
  });

  final AppDatabase db;
  final ReconLists full;
  final List<WalletTransactionData> forfeits;
  final List<ManufacturerData> manufacturers;
  final List<VanTripData> vanTrips;
  final Set<String> vanStoreIds;
  final String storeId;

  static Future<_Shop> load(
    AppDatabase db, {
    required String storeId,
    Set<String> vanStoreIds = const {},
  }) async => _Shop(
    db: db,
    full: await loadReconLists(db),
    forfeits: await db.walletTransactionsDao.watchForfeitRows().first,
    manufacturers: await db.inventoryDao.watchAllManufacturers().first,
    vanTrips: await db.vanTripsDao.watchAllTrips().first,
    vanStoreIds: vanStoreIds,
    storeId: storeId,
  );

  /// One roll-up. [rows] null = the whole history (today's path).
  ReconData compute(
    DateTime start,
    DateTime end, {
    ReconPeriodRows? rows,
    required bool isCeo,
    required bool Function(String?) inScope,
    bool dayClose = false,
  }) => reconDataFrom(
    ReconInputs(
      orders: rows?.orders ?? full.orders,
      expenses: rows?.expenses ?? full.expenses,
      adjustments: rows?.adjustments ?? full.adjustments,
      supplierLedger: rows?.supplierLedger ?? full.supplierLedger,
      // What `computeReconData` hands in on the period path.
      supplierBalanceLedger: rows == null
          ? null
          : (isCeo && !dayClose ? full.supplierLedger : const []),
      payments: rows?.payments ?? full.payments,
      stockTxns: rows?.stockTxns ?? full.stockTxns,
      stockCounts: rows?.stockCounts ?? full.stockCounts,
      crateDamages: rows?.crateDamages ?? full.crateDamages,
      crateForfeitRows: rows?.crateForfeitRows ?? forfeits,
      productsWithStock: full.products,
      manufacturers: manufacturers,
      vanTrips: vanTrips,
      showCrates: true,
      isCeo: isCeo,
      inScope: inScope,
      start: start,
      endExclusive: end,
    ),
  );

  bool notVan(String? s) => !vanStoreIds.contains(s);
  bool oneStore(String? s) => s == storeId;

  /// Asserts the period's rows give the whole history's figures at every scope
  /// and role, and the same frozen day-close figures. Returns the row counts
  /// (narrowed, whole) so a caller can show the narrowing really narrows.
  Future<(int, int)> expectIdentical(DateTime start, DateTime end) async {
    final rows = await loadReconPeriodRows(db, start, end);
    final label = '${reconDayKey(start)}..${reconDayKey(end)}';
    for (final (name, isCeo, scope) in [
      ('CEO, All Stores', true, notVan),
      ('CEO, one store', true, oneStore),
      ('Manager, All Stores', false, notVan),
      ('Manager, one store', false, oneStore),
    ]) {
      expect(
        fingerprint(
          compute(start, end, rows: rows, isCeo: isCeo, inScope: scope),
        ),
        fingerprint(compute(start, end, isCeo: isCeo, inScope: scope)),
        reason: '$label $name',
      );
    }
    // The day-close basis: business-wide minus vans, CEO flows, no payable.
    expect(
      frozen(
        compute(
          start,
          end,
          rows: rows,
          isCeo: true,
          inScope: notVan,
          dayClose: true,
        ),
      ),
      frozen(compute(start, end, isCeo: true, inScope: notVan)),
      reason: '$label day-close basis',
    );
    return (rows.rowCount, full.rowCount + forfeits.length);
  }
}

/// The Day, Week (Sunday start) and Month periods covering [from]..[to].
List<(DateTime, DateTime)> periodsBetween(DateTime from, DateTime to) {
  final out = <(DateTime, DateTime)>[];
  for (final g in [
    ReconGrouping.day,
    ReconGrouping.week,
    ReconGrouping.month,
  ]) {
    var s = g.startOf(from);
    while (!s.isAfter(to)) {
      final e = g.endOf(s);
      out.add((s, e));
      s = e;
    }
  }
  return out;
}

void main() {
  group('the generated history shop (#682)', () {
    late HistoryShop shop;
    late _Shop s;

    setUpAll(() async {
      shop = await buildHistoryShop(
        newHistoryDb(),
        const HistoryShopSpec(
          // Busy enough over four months to run stock down to a supplier
          // delivery (the generator restocks below 1,500 units).
          months: 4,
          minSalesPerDay: 6,
          maxSalesPerDay: 10,
          productCount: 6,
          customerCount: 8,
        ),
      );
      s = await _Shop.load(
        shop.db,
        storeId: shop.storeId,
        vanStoreIds: {shop.vanStoreId},
      );
    });
    tearDownAll(() => shop.close());

    test('the shop has the history the comparison is about', () {
      for (final k in const [
        'sales',
        'cancelled',
        'vanSales',
        'depositsHeld',
        'depositsReleased',
        'depositsForfeited',
        'expenses',
        'adjustments',
        'stockCounts',
        'crateDamages',
        'supplierEntries',
      ]) {
        expect(shop.counts[k], greaterThan(0), reason: k);
      }
    });

    test(
      'every day, week and month: the period rows give identical figures',
      () async {
        // One day either side of the history too: edges with nothing in them.
        final periods = periodsBetween(
          shop.start.subtract(const Duration(days: 1)),
          shop.end.add(const Duration(days: 1)),
        );
        expect(periods.length, greaterThan(100));
        var narrowedDay = 0;
        late int whole;
        for (final (start, end) in periods) {
          final (n, w) = await s.expectIdentical(start, end);
          whole = w;
          if (end.difference(start).inDays == 1) {
            narrowedDay = n > narrowedDay ? n : narrowedDay;
          }
        }
        // The point of it: an early day loads far less than the history.
        final early = await loadReconPeriodRows(
          shop.db,
          shop.start.add(const Duration(days: 3)),
          shop.start.add(const Duration(days: 4)),
        );
        expect(early.orders.length, lessThan(s.full.orders.length ~/ 10));
        expect(narrowedDay, lessThan(whole));
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'a sale cancelled on a later day is loaded for the cancel day',
      () async {
        final later = s.full.orders.where(
          (o) =>
              o.order.cancelledAt != null &&
              reconDayKey(o.order.cancelledAt!.toLocal()) !=
                  reconDayKey(o.order.createdAt),
        );
        expect(later, isNotEmpty);
        final o = later.first.order;
        final c = o.cancelledAt!.toLocal();
        final day = DateTime(c.year, c.month, c.day);
        final rows = await loadReconPeriodRows(
          shop.db,
          day,
          day.add(const Duration(days: 1)),
        );
        expect(rows.orders.map((x) => x.order.id), contains(o.id));
      },
    );

    test('no reviewed day shows a false "changed since reviewed"', () async {
      var reviewed = 0;
      for (
        var d = shop.start;
        !d.isAfter(shop.end);
        d = DateTime(d.year, d.month, d.day + 1)
      ) {
        final end = DateTime(d.year, d.month, d.day + 1);
        // Frozen from the whole history, exactly as the screen froze it
        // before #683…
        await shop.db.dailyClosingsDao.snapshotIfAbsent(
          businessDate: reconDayKey(d),
          figures: dailyClosingFiguresFrom(
            s.compute(d, end, isCeo: true, inScope: s.notVan),
          ),
        );
        final snapshot = await shop.db.dailyClosingsDao.getForDay(
          reconDayKey(d),
        );
        // …and compared against the period rows the screen now reads.
        final rows = await loadReconPeriodRows(shop.db, d, end);
        final live = s.compute(
          d,
          end,
          rows: rows,
          isCeo: true,
          inScope: s.notVan,
          dayClose: true,
        );
        final cmp = reconClosingComparison(snapshot!, live);
        expect(
          cmp.anyChanged,
          isFalse,
          reason:
              '${reconDayKey(d)}: ${[for (final f in cmp.all)
                if (f.changed) '${f.reviewed}->${f.current}']}',
        );
        reviewed++;
      }
      expect(reviewed, greaterThan(80));
    });
  });

  group('the shared report shop (report_fixture.dart) and its edges', () {
    late ScreenTestEnvironment env;
    late _Shop s;
    late String otherStoreId;

    DateTime at(int day, [int h = 12, int m = 0, int sec = 0]) =>
        DateTime(2026, 7, day, h, m, sec);

    Future<void> insertOrder(OrderWithItems o) async {
      await env.db.into(env.db.orders).insert(o.order);
      for (final i in o.items) {
        await env.db.into(env.db.orderItems).insert(i.item);
      }
    }

    Future<String> adjustment(
      String storeId,
      String productId,
      double diff,
      String reason,
      DateTime when, {
      int? valueKobo,
    }) async {
      final id = UuidV7.generate();
      await env.db
          .into(env.db.stockAdjustments)
          .insert(
            StockAdjustmentsCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              productId: productId,
              storeId: storeId,
              quantityDiff: diff,
              reason: reason,
              valueKobo: Value(valueKobo),
              createdAt: Value(when),
            ),
          );
      return id;
    }

    Future<void> movement(
      String storeId,
      String productId,
      double delta,
      String type,
      DateTime when, {
      String? adjustmentId,
      String? orderId,
    }) => env.db
        .into(env.db.stockTransactions)
        .insert(
          StockTransactionsCompanion.insert(
            businessId: env.businessId,
            productId: productId,
            locationId: storeId,
            quantityDelta: delta,
            movementType: type,
            adjustmentId: Value(adjustmentId),
            orderId: Value(orderId),
            createdAt: Value(when),
          ),
        );

    Future<void> count(
      String storeId,
      String businessDate,
      DateTime savedAt,
      String productId,
      int diff,
    ) => env.db
        .into(env.db.stockCounts)
        .insert(
          StockCountsCompanion.insert(
            businessId: env.businessId,
            storeId: Value(storeId),
            businessDate: businessDate,
            productsCounted: 3,
            shortageCount: diff < 0 ? 1 : 0,
            surplusCount: diff > 0 ? 1 : 0,
            shortageUnits: diff < 0 ? -diff.toDouble() : 0,
            surplusUnits: diff > 0 ? diff.toDouble() : 0,
            linesJson: jsonEncode([
              {
                'p': productId,
                'n': 'Counted',
                's': 50,
                'a': 50 + diff,
                'd': diff,
              },
            ]),
            createdAt: Value(savedAt),
          ),
        );

    Future<void> payment(
      String type,
      int amountKobo,
      DateTime when, {
      String? orderId,
      String? expenseId,
    }) => env.db
        .into(env.db.paymentTransactions)
        .insert(
          PaymentTransactionsCompanion.insert(
            businessId: env.businessId,
            amountKobo: amountKobo,
            method: 'cash',
            type: type,
            orderId: Value(orderId),
            expenseId: Value(expenseId),
            storeId: Value(env.storeId),
            createdAt: Value(when),
          ),
        );

    setUpAll(() async {
      env = await setupScreenTestEnvironment(
        productCount: 3,
        businessName: 'Stallion Global',
      );
      final db = env.db;
      final p = env.products;
      // Give the products a buying price so the stock card values movements.
      await db.customStatement(
        'UPDATE products SET buying_price_kobo = 60000 WHERE business_id = ?',
        [env.businessId],
      );
      otherStoreId = UuidV7.generate();
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(otherStoreId),
              businessId: env.businessId,
              name: 'Kano Branch',
            ),
          );

      // The report fixture's own sales, on its fixed day (14 Jul).
      for (final o in sampleReportOrders(env, kReportDay)) {
        await insertOrder(o);
      }
      // A sale on 10 Jul cancelled on 14 Jul, and one on 14 Jul cancelled on
      // 20 Jul (#549: each counts on its sale day and, negatively, on its
      // cancel day).
      OrderWithItems cancelled(int n, DateTime made, DateTime cancelledOn) {
        final o = reportOrder(
          env,
          n: n,
          at: made,
          lines: [(p[0], 4, 450000, 380000)],
        );
        return OrderWithItems(
          o.order.copyWith(
            status: 'cancelled',
            cancelledAt: Value(cancelledOn),
          ),
          o.items,
          null,
        );
      }

      await insertOrder(cancelled(7, at(10), at(14, 16)));
      await insertOrder(cancelled(8, at(14, 9), at(20, 11)));
      // A sale just before midnight on the 13th and one just after.
      await insertOrder(
        reportOrder(
          env,
          n: 9,
          at: at(13, 23, 59, 59),
          lines: [(p[1], 1, 820000, 700000)],
        ),
      );
      await insertOrder(
        reportOrder(
          env,
          n: 10,
          at: at(15, 0, 0, 0),
          lines: [(p[1], 2, 820000, 700000)],
        ),
      );
      // Refund paid out on the cancel day, cash sales on the sale days.
      // A backdated expense: spent on the 12th, keyed in on the 14th.
      const expenseId = 'expense-diesel';
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: const Value(expenseId),
              businessId: env.businessId,
              amountKobo: 500000,
              description: 'Diesel',
              status: const Value('approved'),
              storeId: Value(env.storeId),
              expenseDate: Value(at(12, 9)),
              createdAt: Value(at(14, 8)),
            ),
          );
      // Refunds paid out on each cancel day, cash on the sale days, and the
      // expense's cash leg on the day it was keyed in.
      await payment('refund', 1800000, at(14, 16), orderId: 'order-7');
      await payment('refund', 1800000, at(20, 11), orderId: 'order-8');
      await payment('sale', 1800000, at(10), orderId: 'order-7');
      await payment('sale', 820000, at(13, 23, 59, 59), orderId: 'order-9');
      await payment('expense', 500000, at(14, 8), expenseId: expenseId);

      // The supplier entries the fixture uses (10 Jul).
      for (final sup in sampleSuppliers(env)) {
        await db.into(db.suppliers).insert(sup);
      }
      for (final l in sampleLedger(env)) {
        await db.into(db.supplierLedgerEntries).insert(l);
      }

      // Stock movements: received before, in and after the period; a damage
      // whose adjustment row was written a second before midnight but whose
      // movement is a second after it.
      Future<void> received(
        String storeId,
        String productId,
        double qty,
        DateTime when,
      ) async {
        final a = await adjustment(
          storeId,
          productId,
          qty,
          'Stock received',
          when,
        );
        await movement(
          storeId,
          productId,
          qty,
          'adjustment',
          when,
          adjustmentId: a,
        );
      }

      for (final pr in p) {
        await received(env.storeId, pr.id, 100, at(1, 8));
      }
      await received(env.storeId, p[0].id, 20, at(14, 7));
      await movement(
        env.storeId,
        p[0].id,
        -6,
        'sale',
        at(14, 10, 30),
        orderId: 'order-1',
      );
      await received(env.storeId, p[1].id, 12, at(18, 7));
      await received(otherStoreId, p[2].id, 30, at(14, 7));
      final dmg = await adjustment(
        env.storeId,
        p[2].id,
        -2,
        'damage:broken',
        at(13, 23, 59, 59),
        valueKobo: 2500000,
      );
      await movement(
        env.storeId,
        p[2].id,
        -2,
        'adjustment',
        at(14, 0, 0, 1),
        adjustmentId: dmg,
      );
      await adjustment(
        env.storeId,
        p[1].id,
        -1,
        'expired',
        at(14, 15),
        valueKobo: 700000,
      );

      // Counts and their shortage rows (#186: a row belongs to the first
      // session of its store saved at or after it). Store A:
      //   row 08 Jul → S0 (bd 10 Jul, saved 10 Jul)
      //   row 12 Jul → X  (bd 01 Jul, BACKDATED, saved 14 Jul 09:00)
      //   row 14 Jul 12:00 → S1 (bd 14 Jul, saved 14 Jul 18:00)
      //   row 15 Jul → S2 (bd 16 Jul, saved 16 Jul)
      // Store B's first ever count is on 14 Jul, so it owns every earlier row.
      const reason = 'Daily stock count adjustment';
      await adjustment(
        env.storeId,
        p[0].id,
        -1,
        reason,
        at(8),
        valueKobo: 380000,
      );
      await count(env.storeId, '2026-07-10', at(10, 18), p[0].id, -1);
      await adjustment(
        env.storeId,
        p[1].id,
        -2,
        reason,
        at(12),
        valueKobo: 1400000,
      );
      await count(env.storeId, '2026-07-01', at(14, 9), p[1].id, -2);
      await adjustment(
        env.storeId,
        p[0].id,
        -3,
        reason,
        at(14, 12),
        valueKobo: 1140000,
      );
      await count(env.storeId, '2026-07-14', at(14, 18), p[0].id, -3);
      await adjustment(
        env.storeId,
        p[2].id,
        -1,
        reason,
        at(15),
        valueKobo: 1250000,
      );
      await count(env.storeId, '2026-07-16', at(16, 18), p[2].id, -1);
      await adjustment(
        otherStoreId,
        p[2].id,
        -4,
        reason,
        at(3),
        valueKobo: 5000000,
      );
      await count(otherStoreId, '2026-07-14', at(14, 19), p[2].id, -4);

      s = await _Shop.load(db, storeId: env.storeId);
    });
    tearDownAll(() => env.dispose());

    test('every day, week and month of July: identical figures', () async {
      for (final (start, end) in periodsBetween(at(1), DateTime(2026, 7, 31))) {
        await s.expectIdentical(start, end);
      }
    });

    test('the edge rows are really in the 14 Jul figures', () async {
      final day = DateTime(2026, 7, 14);
      final end = DateTime(2026, 7, 15);
      final rows = await loadReconPeriodRows(env.db, day, end);
      final d = s.compute(day, end, rows: rows, isCeo: true, inScope: s.notVan);
      // The 10 Jul sale cancelled today is a return on today.
      expect(d.returnsKobo, lessThan(0));
      // The damage whose adjustment is dated the 13th still classifies today's
      // movement as a damage on the stock card.
      expect(d.stockDamagesKobo, greaterThan(0));
      // Both counted stores' winning sessions are valued from their own rows.
      expect(d.legacyValuedShortageRows, 0);
      expect(d.shortageCostKobo, 1140000 + 5000000);
      // The backdated count's row is not today's money.
      expect(
        rows.stockCounts.map((c) => c.businessDate),
        contains('2026-07-01'),
      );
    });

    test('the feed loads again when a row lands in the period', () async {
      final day = DateTime(2026, 7, 21);
      final seen = <ReconPeriodRows>[];
      final sub = watchReconPeriodRows(
        env.db,
        day,
        DateTime(2026, 7, 22),
      ).listen(seen.add);
      addTearDown(sub.cancel);
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 100));
      await settle();
      expect(seen, isNotEmpty);
      expect(seen.last.payments, isEmpty);
      await payment(
        'sale',
        5000,
        DateTime(2026, 7, 21, 10),
        orderId: 'order-1',
      );
      await settle();
      expect(seen.last.payments, hasLength(1));
    });

    test('a store\'s first count owns every earlier shortage row', () async {
      final day = DateTime(2026, 7, 14);
      final rows = await loadReconPeriodRows(
        env.db,
        day,
        DateTime(2026, 7, 15),
      );
      expect(
        rows.adjustments
            .where(
              (a) =>
                  a.storeId == otherStoreId &&
                  isCountReconciliationReason(a.reason),
            )
            .length,
        1,
        reason: 'the 3 Jul row belongs to the 14 Jul session',
      );
    });
  });
}
