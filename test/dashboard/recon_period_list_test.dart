// #684 (PRD #680 S3) — the Daily Reconciliation LIST of periods and its
// "changed since reviewed" marks come from light reads (dates, quantity, store;
// each reviewed day's own rows) instead of the whole history. These tests prove
// the narrowing changes nothing: the list of periods (with each card's items
// sold and shortage mark) and the changed-since-reviewed set are IDENTICAL to
// what the whole-history lists give, for every grouping, at four scopes/roles,
// including later-day cancels and days whose only activity is a stock count.
//
// The "whole-history version" below (`oracleBuckets`, `oracleChanged`) is a
// frozen copy of the pre-#684 logic, kept here as the independent oracle.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

import '../helpers/screen_harness.dart';
import '../support/history_reports.dart';
import '../support/history_shop_generator.dart';
import 'report_fixture.dart';

typedef ListCard = ({String start, String label, double items, bool shortage});

List<ListCard> _cards(List<ReconBucket> bs) => [
  for (final b in bs)
    (
      start: reconDayKey(b.start),
      label: b.label,
      items: b.itemsSold,
      shortage: b.hasShortage,
    ),
];

/// The pre-#684 list: whole orders and whole count sessions.
List<ListCard> oracleBuckets(
  ReconLists lists,
  ReconGrouping g,
  bool Function(String?) inScope, {
  DateTime? start,
  DateTime? end,
}) {
  bool inSpan(DateTime t) =>
      (start == null || !t.isBefore(start)) && (end == null || t.isBefore(end));
  final by = <int, ({DateTime s, double items, bool short})>{};
  void put(DateTime d, {double add = 0, bool short = false}) {
    final s = g.startOf(d);
    final cur = by[s.millisecondsSinceEpoch];
    by[s.millisecondsSinceEpoch] = (
      s: s,
      items: (cur?.items ?? 0) + add,
      short: (cur?.short ?? false) || short,
    );
  }

  for (final e in saleDayEntries(lists.orders)) {
    if (!inSpan(e.day)) continue;
    var any = false;
    for (final i in e.o.items) {
      if (!inScope(i.item.storeId)) continue;
      any = true;
      put(e.day, add: e.sign * i.item.quantity);
    }
    if (!any) continue;
  }
  final sorted = [...lists.stockCounts]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final seen = <String>{};
  for (final c in sorted) {
    if (!inScope(c.storeId)) continue;
    final day = DateTime.tryParse(c.businessDate);
    if (day == null || !inSpan(day)) continue;
    if (!seen.add('${c.businessDate}|${c.storeId}')) continue;
    put(day, short: c.shortageUnits > 0);
  }
  final out = [
    for (final v in by.values)
      (
        start: reconDayKey(v.s),
        label: g.labelFor(v.s),
        items: v.items,
        shortage: v.short,
      ),
  ]..sort((a, b) => b.start.compareTo(a.start));
  return out;
}

class _Shop {
  _Shop(this.db, this.storeId, this.vanStoreIds);
  final AppDatabase db;
  final String storeId;
  final Set<String> vanStoreIds;
  late ReconLists full;
  late List<WalletTransactionData> forfeits;
  late List<ManufacturerData> manufacturers;
  late ReconListFacts light;

  Future<void> reload() async {
    full = await loadReconLists(db);
    forfeits = await db.walletTransactionsDao.watchForfeitRows().first;
    manufacturers = await db.inventoryDao.watchAllManufacturers().first;
    light = await loadReconListFacts(db);
  }

  bool notVan(String? s) => !vanStoreIds.contains(s);
  bool oneStore(String? s) => s == storeId;

  List<(String, bool Function(String?))> get scopes => [
    ('CEO, All Stores', notVan),
    ('CEO, one store', oneStore),
    ('Manager, All Stores', notVan),
    ('Manager, one store', oneStore),
  ];

  /// The list of periods, light vs whole-history, every grouping and scope,
  /// plus two custom ranges (the Custom range path).
  void expectListIdentical({DateTime? from, DateTime? to}) {
    var checked = 0;
    for (final (name, scope) in scopes) {
      for (final g in ReconGrouping.values) {
        final got = _cards(reconBucketsFrom(light, inScope: scope, grouping: g));
        final want = oracleBuckets(full, g, scope);
        expect(got, want, reason: '$name / ${g.name}');
        checked += got.length;
      }
      if (from != null && to != null) {
        final got = _cards(
          reconBucketsFrom(
            light,
            inScope: scope,
            grouping: ReconGrouping.day,
            start: from,
            endExclusive: to,
          ),
        );
        expect(
          got,
          oracleBuckets(full, ReconGrouping.day, scope, start: from, end: to),
          reason: '$name / custom range',
        );
      }
    }
    expect(checked, greaterThan(0));
  }

  /// The pre-#684 sweep answer: every reviewed day computed from the WHOLE
  /// history (the application of `inSpan` makes this the ground truth).
  Set<String> oracleChanged(List<DailyClosingData> snaps) {
    final out = <String>{};
    for (final snap in snaps) {
      final start = DateTime.parse(snap.businessDate);
      final live = reconDataFrom(
        ReconInputs(
          orders: full.orders,
          expenses: full.expenses,
          adjustments: full.adjustments,
          supplierLedger: full.supplierLedger,
          payments: full.payments,
          stockTxns: full.stockTxns,
          stockCounts: full.stockCounts,
          productsWithStock: full.products,
          manufacturers: manufacturers,
          crateDamages: full.crateDamages,
          crateForfeitRows: forfeits,
          showCrates: true,
          isCeo: true,
          inScope: notVan,
          start: start,
          endExclusive: start.add(const Duration(days: 1)),
        ),
      );
      if (reconClosingComparison(snap, live).anyDayLocalChanged) {
        out.add(snap.businessDate);
      }
    }
    return out;
  }

  Future<Set<String>> sweep(List<DailyClosingData> snaps) async {
    final rows = await loadReviewedDayRows(db, {
      for (final s in snaps) s.businessDate,
    });
    return changedReviewedDaysFrom(
      snapshots: snaps,
      dayRows: rows,
      productsWithStock: full.products,
      manufacturers: manufacturers,
      showCrates: true,
      inScope: notVan,
    );
  }

  /// Freezes [days] from the CURRENT whole history (as the screen did), and
  /// returns the stored rows.
  Future<List<DailyClosingData>> freeze(Iterable<DateTime> days) async {
    final out = <DailyClosingData>[];
    for (final d in days) {
      final end = DateTime(d.year, d.month, d.day + 1);
      final live = reconDataFrom(
        ReconInputs(
          orders: full.orders,
          expenses: full.expenses,
          adjustments: full.adjustments,
          supplierLedger: full.supplierLedger,
          payments: full.payments,
          stockTxns: full.stockTxns,
          stockCounts: full.stockCounts,
          productsWithStock: full.products,
          manufacturers: manufacturers,
          crateDamages: full.crateDamages,
          crateForfeitRows: forfeits,
          showCrates: true,
          isCeo: true,
          inScope: notVan,
          start: d,
          endExclusive: end,
        ),
      );
      await db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: reconDayKey(d),
        figures: dailyClosingFiguresFrom(live),
      );
      out.add((await db.dailyClosingsDao.getForDay(reconDayKey(d)))!);
    }
    return out;
  }
}

void main() {
  group('the generated history shop (#682)', () {
    late HistoryShop shop;
    late _Shop s;

    setUpAll(() async {
      shop = await buildHistoryShop(
        newHistoryDb(),
        const HistoryShopSpec(
          months: 4,
          minSalesPerDay: 6,
          maxSalesPerDay: 10,
          productCount: 6,
          customerCount: 8,
        ),
      );
      s = _Shop(shop.db, shop.storeId, {shop.vanStoreId});
      await s.reload();
    });
    tearDownAll(() => shop.close());

    test('the list of periods is identical to the whole-history list', () {
      expect(s.full.stockCounts, isNotEmpty);
      expect(
        s.full.orders.where((o) => o.order.cancelledAt != null),
        isNotEmpty,
      );
      s.expectListIdentical(
        from: shop.start.add(const Duration(days: 10)),
        to: shop.start.add(const Duration(days: 40)),
      );
    });

    test('the light read is really lighter than the orders', () {
      final lines = s.light.saleLines.length;
      final items = s.full.orders.fold<int>(0, (a, o) => a + o.items.length);
      // Same number of lines as the item rows, but no whole order rows.
      expect(lines, lessThanOrEqualTo(items));
      expect(s.light.counts.length, s.full.stockCounts.length);
    });

    test(
      'the changed-since-reviewed set is identical, and not empty',
      () async {
        final days = [
          for (var i = 2; i < 100; i += 3)
            DateTime(shop.start.year, shop.start.month, shop.start.day + i),
        ];
        final snaps = await s.freeze(days);
        // Nothing has moved yet.
        expect(await s.sweep(snaps), s.oracleChanged(snaps));
        expect(await s.sweep(snaps), isEmpty);

        // Late changes, one per reviewed day, of every kind the figures see.
        DateTime d(int i, [int h = 12]) => DateTime(
          shop.start.year,
          shop.start.month,
          shop.start.day + i,
          h,
        );
        final db = shop.db;
        // A refund keyed in late on reviewed day 5.
        await db
            .into(db.paymentTransactions)
            .insert(
              PaymentTransactionsCompanion.insert(
                businessId: shop.businessId,
                amountKobo: 123400,
                method: 'cash',
                type: 'refund',
                orderId: Value(s.full.orders.first.order.id),
                storeId: Value(shop.storeId),
                createdAt: Value(d(5)),
              ),
            );
        // A backdated expense onto reviewed day 8.
        await db
            .into(db.expenses)
            .insert(
              ExpensesCompanion.insert(
                businessId: shop.businessId,
                amountKobo: 77700,
                description: 'Late diesel',
                status: const Value('approved'),
                storeId: Value(shop.storeId),
                expenseDate: Value(d(8)),
                createdAt: Value(d(60)),
              ),
            );
        // A sale from reviewed day 11 cancelled on reviewed day 35.
        final sale = s.full.orders.firstWhere(
          (o) =>
              o.order.status == 'completed' &&
              o.order.storeId == shop.storeId &&
              reconDayKey(o.order.createdAt) == reconDayKey(d(11)),
        );
        await (db.update(db.orders)..where((o) => o.id.equals(sale.order.id)))
            .write(
              OrdersCompanion(
                status: const Value('cancelled'),
                cancelledAt: Value(d(35).toUtc()),
              ),
            );
        await s.reload();

        final want = s.oracleChanged(snaps);
        expect(want, isNotEmpty);
        expect(await s.sweep(snaps), want);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
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

    setUpAll(() async {
      env = await setupScreenTestEnvironment(
        productCount: 3,
        businessName: 'Stallion Global',
      );
      final db = env.db;
      final p = env.products;
      otherStoreId = 'store-kano';
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(otherStoreId),
              businessId: env.businessId,
              name: 'Kano Branch',
            ),
          );
      for (final o in sampleReportOrders(env, kReportDay)) {
        await insertOrder(o);
      }
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

      // Cancelled on a LATER day (10 -> 14, 14 -> 20 Jul).
      await insertOrder(cancelled(7, at(10), at(14, 16)));
      await insertOrder(cancelled(8, at(14, 9), at(20, 11)));
      // Around midnight (UTC vs local day edges).
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
          at: at(15, 0, 0, 1),
          lines: [(p[1], 2, 820000, 700000)],
        ),
      );
      // A cancelled order with no cancelled_at (legacy) and a rejected one.
      final legacy = reportOrder(
        env,
        n: 11,
        at: at(17),
        lines: [(p[2], 1, 100000, 80000)],
      );
      await insertOrder(
        OrderWithItems(
          legacy.order.copyWith(status: 'cancelled'),
          legacy.items,
          null,
        ),
      );
      final rejected = cancelled(12, at(18), at(18, 13));
      await insertOrder(
        OrderWithItems(
          rejected.order.copyWith(
            cancellationReason: const Value('rejected_by_server'),
          ),
          rejected.items,
          null,
        ),
      );
      // Days with NO sale: only an expense (3 Jul), only a payment (4 Jul),
      // only a supplier entry (10 Jul, from the fixture), only stock activity.
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              businessId: env.businessId,
              amountKobo: 300000,
              description: 'Only an expense',
              status: const Value('approved'),
              storeId: Value(env.storeId),
              expenseDate: Value(at(3)),
              createdAt: Value(at(3)),
            ),
          );
      await db
          .into(db.paymentTransactions)
          .insert(
            PaymentTransactionsCompanion.insert(
              businessId: env.businessId,
              amountKobo: 90000,
              method: 'cash',
              type: 'sale',
              orderId: const Value('order-1'),
              storeId: Value(env.storeId),
              createdAt: Value(at(4)),
            ),
          );
      await db
          .into(db.stockAdjustments)
          .insert(
            StockAdjustmentsCompanion.insert(
              businessId: env.businessId,
              productId: p[0].id,
              storeId: env.storeId,
              quantityDiff: 10,
              reason: 'Stock received',
              createdAt: Value(at(5)),
            ),
          );
      for (final sup in sampleSuppliers(env)) {
        await db.into(db.suppliers).insert(sup);
      }
      for (final l in sampleLedger(env)) {
        await db.into(db.supplierLedgerEntries).insert(l);
      }
      // Stock-count-only days: a shortage (22 Jul, store A), a clean count
      // (23 Jul, store A), a shortage in the OTHER store (24 Jul), and a
      // re-saved count of 22 Jul that corrects the shortage later that day...
      Future<void> count(
        String storeId,
        String bd,
        DateTime saved,
        double shortage,
      ) => db
          .into(db.stockCounts)
          .insert(
            StockCountsCompanion.insert(
              businessId: env.businessId,
              storeId: Value(storeId),
              businessDate: bd,
              productsCounted: 3,
              shortageCount: shortage > 0 ? 1 : 0,
              surplusCount: 0,
              shortageUnits: shortage,
              surplusUnits: 0,
              linesJson: jsonEncode([]),
              createdAt: Value(saved),
            ),
          );
      await count(env.storeId, '2026-07-22', at(22, 10), 2);
      await count(env.storeId, '2026-07-23', at(23, 10), 0);
      await count(otherStoreId, '2026-07-24', at(24, 10), 3);
      // ...and a day where a shortage is corrected by a later count (25 Jul).
      await count(env.storeId, '2026-07-25', at(25, 9), 5);
      await count(env.storeId, '2026-07-25', at(25, 17), 0);
      // A sale in the other store only (26 Jul): a day that exists in All
      // Stores but not in the first store's view.
      final other = reportOrder(
        env,
        n: 13,
        at: at(26),
        lines: [(p[1], 3, 820000, 700000)],
      );
      await insertOrder(
        OrderWithItems(
          other.order.copyWith(storeId: Value(otherStoreId)),
          [
            for (final i in other.items)
              OrderItemDataWithProductData(
                i.item.copyWith(storeId: otherStoreId),
                i.product,
              ),
          ],
          null,
        ),
      );

      s = _Shop(db, env.storeId, {});
      await s.reload();
    });
    tearDownAll(() => env.dispose());

    test('the list of periods is identical, edges included', () {
      s.expectListIdentical(from: at(1), to: DateTime(2026, 7, 28));
      // The edge days really are in the list.
      final days = _cards(
        reconBucketsFrom(
          s.light,
          inScope: s.notVan,
          grouping: ReconGrouping.day,
        ),
      ).map((c) => c.start).toSet();
      expect(days, contains('2026-07-20')); // cancel-only day (order 8)
      expect(days, contains('2026-07-22')); // count-only day
      expect(days, contains('2026-07-23')); // clean count-only day
      expect(days, isNot(contains('2026-07-03'))); // expense-only: not listed
      expect(days, isNot(contains('2026-07-04'))); // payment-only: not listed
      expect(days, isNot(contains('2026-07-18'))); // rejected sale: nothing
      final one = _cards(
        reconBucketsFrom(
          s.light,
          inScope: s.oneStore,
          grouping: ReconGrouping.day,
        ),
      ).map((c) => c.start).toSet();
      expect(days, contains('2026-07-26'));
      expect(one, isNot(contains('2026-07-26')));
      expect(
        _cards(
          reconBucketsFrom(
            s.light,
            inScope: s.notVan,
            grouping: ReconGrouping.day,
          ),
        ).firstWhere((c) => c.start == '2026-07-25').shortage,
        isFalse,
        reason: 'a shortage corrected by a later count stops flagging',
      );
    });

    test(
      'days with only expenses, payments, stock or supplier activity: changed '
      'marks identical',
      () async {
        final days = [for (var i = 1; i <= 28; i++) at(i, 0)];
        final snaps = await s.freeze(days);
        expect(await s.sweep(snaps), s.oracleChanged(snaps));
        // Move the activity-only days after the review.
        final db = env.db;
        await db
            .into(db.expenses)
            .insert(
              ExpensesCompanion.insert(
                businessId: env.businessId,
                amountKobo: 11100,
                description: 'Late expense on an expense-only day',
                status: const Value('approved'),
                storeId: Value(env.storeId),
                expenseDate: Value(at(3)),
                createdAt: Value(at(27)),
              ),
            );
        await db
            .into(db.paymentTransactions)
            .insert(
              PaymentTransactionsCompanion.insert(
                businessId: env.businessId,
                amountKobo: 22200,
                method: 'cash',
                type: 'refund',
                orderId: const Value('order-1'),
                storeId: Value(env.storeId),
                createdAt: Value(at(4, 18)),
              ),
            );
        await db
            .into(db.stockAdjustments)
            .insert(
              StockAdjustmentsCompanion.insert(
                businessId: env.businessId,
                productId: env.products[1].id,
                storeId: env.storeId,
                quantityDiff: -3,
                reason: 'damage:broken',
                valueKobo: const Value(2100000),
                createdAt: Value(at(5, 15)),
              ),
            );
        // Cancel the 17 Jul legacy-free sale (order 9) on 24 Jul.
        await (db.update(db.orders)..where((o) => o.id.equals('order-9')))
            .write(
              OrdersCompanion(
                status: const Value('cancelled'),
                cancelledAt: Value(at(24, 9).toUtc()),
              ),
            );
        await s.reload();
        final want = s.oracleChanged(snaps);
        expect(want, containsAll(['2026-07-03', '2026-07-04']));
        expect(await s.sweep(snaps), want);
        // And the list still agrees after the late cancel.
        s.expectListIdentical(from: at(1), to: DateTime(2026, 7, 28));
      },
    );
  });
}
