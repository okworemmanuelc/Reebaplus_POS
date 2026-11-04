@Tags(['benchmark'])
library;

// history_benchmark_test.dart
//
// #682 (PRD #680) — the "before" timing run. Builds file-backed history shops of
// 6 / 12 / 24 months (see test/support/history_shop_generator.dart) and times
// the work the slow screens do, so each timing can be compared across history
// sizes and again after the later slices (#683+) change how it is computed.
//
// Run (6 months ~3 min, 12 months ~10 min, 24 months ~1 hour: the app's own
// per-sale cost grows with history, and building goes through it):
//   flutter test --run-skipped -t benchmark test/benchmark
// Lighter days (building 24 months at full volume took over 2.5 hours, because
// the app's own sale save slows as history grows): BENCH_MIN_SALES=4 BENCH_MAX_SALES=10
// Pick sizes: BENCH_MONTHS=6,12 flutter test --run-skipped -t benchmark test/benchmark
//
// Everything prints as one markdown table at the end (all figures in ms).
// Timings are wall clock on a desktop CPU with a real file on disk — read them
// as a growth curve, not as phone speeds (the phone steps give those).

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/local_database_connection.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

import '../support/history_reports.dart';
import '../support/history_shop_generator.dart';

typedef _Row = Map<String, String>;

Future<T> _ms<T>(_Row out, String key, Future<T> Function() fn) async {
  final sw = Stopwatch()..start();
  final r = await fn();
  out[key] = (sw.elapsedMicroseconds / 1000).toStringAsFixed(1);
  return r;
}

T _msSync<T>(_Row out, String key, T Function() fn) {
  final sw = Stopwatch()..start();
  final r = fn();
  out[key] = (sw.elapsedMicroseconds / 1000).toStringAsFixed(1);
  return r;
}

/// The Profit report's aggregation loop (the screen's `_compute` is private to
/// its State): same helpers, same per-line maths, same period test.
double _profitLoop(List<OrderWithItems> orders, String period, DateTime now) {
  final byProduct = <String, int>{};
  var revenue = 0;
  var cogs = 0;
  var concession = 0;
  for (final e in saleDayEntries(orders)) {
    if (!isDateInPeriod(e.day, period, now: now)) continue;
    for (final i in e.o.items) {
      concession +=
          e.sign *
          lineConcessionKobo(
            cataloguePriceKobo: i.item.cataloguePriceKobo,
            unitPriceKobo: i.item.unitPriceKobo,
            quantity: i.item.quantity,
          );
      final p = i.product;
      if (p == null || i.item.buyingPriceKobo <= 0) continue;
      final rev = lineTotalKobo(i.item.unitPriceKobo, i.item.quantity);
      final cost = lineTotalKobo(i.item.buyingPriceKobo, i.item.quantity);
      revenue += e.sign * rev;
      cogs += e.sign * cost;
      byProduct[p.id] = (byProduct[p.id] ?? 0) + e.sign * (rev - cost);
    }
  }
  return (revenue - cogs + concession + byProduct.length).toDouble();
}


/// The pre-#684 "changed since reviewed" sweep, frozen as the "before": the
/// whole history is filed under the reviewed days, then each day is run
/// through the real [reconDataFrom].
Set<String> _oldSweep(
  List<DailyClosingData> snaps,
  ReconLists l,
  List<WalletTransactionData> forfeits,
  List<ManufacturerData> manufacturers,
) {
  final wanted = {for (final s in snaps) s.businessDate};
  Map<String, List<T>> file<T>(
    Iterable<T> rows,
    Iterable<DateTime> Function(T) datesOf,
  ) {
    final out = <String, List<T>>{};
    for (final r in rows) {
      for (final d in datesOf(r)) {
        final k = reconDayKey(d);
        if (wanted.contains(k)) (out[k] ??= <T>[]).add(r);
      }
    }
    return out;
  }

  final orders = file<OrderWithItems>(l.orders, (o) => [
    o.order.createdAt,
    if (o.order.cancelledAt != null) o.order.cancelledAt!.toLocal(),
  ]);
  final expenses = file<ExpenseWithCategory>(
    l.expenses,
    (e) => [e.expense.expenseDate, e.expense.createdAt],
  );
  final adj = file<StockAdjustmentData>(l.adjustments, (a) => [a.createdAt]);
  final ledger = file<SupplierLedgerEntryData>(
    l.supplierLedger,
    (e) => [e.activityDate, e.createdAt],
  );
  final pay = file<PaymentTransactionData>(l.payments, (p) => [p.createdAt]);
  final txns = file<StockTransactionData>(l.stockTxns, (t) => [t.createdAt]);
  final counts = file<StockCountData>(
    l.stockCounts,
    (c) => [DateTime.tryParse(c.businessDate) ?? c.createdAt, c.createdAt],
  );
  final dmg = file<CrateLedgerData>(l.crateDamages, (c) => [c.createdAt]);
  final forf = file<WalletTransactionData>(forfeits, (w) => [w.createdAt]);
  final changed = <String>{};
  for (final snap in snaps) {
    final day = snap.businessDate;
    final start = DateTime.parse(day);
    final live = reconDataFrom(
      ReconInputs(
        orders: orders[day] ?? const [],
        expenses: expenses[day] ?? const [],
        adjustments: adj[day] ?? const [],
        supplierLedger: ledger[day] ?? const [],
        payments: pay[day] ?? const [],
        stockTxns: txns[day] ?? const [],
        stockCounts: counts[day] ?? const [],
        productsWithStock: l.products,
        manufacturers: manufacturers,
        crateDamages: dmg[day] ?? const [],
        crateForfeitRows: forf[day] ?? const [],
        showCrates: true,
        isCeo: true,
        inScope: (s) => true,
        start: start,
        endExclusive: start.add(const Duration(days: 1)),
      ),
    );
    if (reconClosingComparison(snap, live).anyDayLocalChanged) {
      changed.add(day);
    }
  }
  return changed;
}

/// Reads every synced table of [db] and shapes the rows the way the cloud
/// returns them (snake_case keys, native bools, ISO-8601 timestamps).
Future<Map<String, List<Map<String, dynamic>>>> _cloudShapedRows(
  AppDatabase db,
) async {
  final out = <String, List<Map<String, dynamic>>>{};
  for (final table in kSyncPullOrder) {
    final meta = await db
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
          variables: [Variable<String>(table)],
        )
        .getSingleOrNull();
    if (meta == null) continue;
    final sql = meta.read<String?>('sql') ?? '';
    final bools = {
      for (final m in RegExp(
        r'"(\w+)" INTEGER[^,]*CHECK \("\1" IN \(0, 1\)\)',
      ).allMatches(sql))
        m.group(1)!,
    };
    final rows = await db.customSelect('SELECT * FROM $table').get();
    if (rows.isEmpty) continue;
    out[table] = [
      for (final r in rows)
        {
          for (final e in r.data.entries)
            e.key: e.value == null
                ? null
                : bools.contains(e.key)
                ? e.value == 1
                : (e.value is int &&
                      (e.key.endsWith('_at') || e.key.endsWith('_date')))
                ? DateTime.fromMillisecondsSinceEpoch(
                    (e.value as int) * 1000,
                    isUtc: true,
                  ).toIso8601String()
                : e.value,
        },
    ];
  }
  return out;
}

void main() {
  final sizes = (Platform.environment['BENCH_MONTHS'] ?? '6,12,24')
      .split(',')
      .map(int.parse)
      .toList();
  final results = <int, _Row>{};
  final notes = <int, String>{};

  tearDownAll(() {
    final keys = <String>[];
    for (final r in results.values) {
      for (final k in r.keys) {
        if (!keys.contains(k)) keys.add(k);
      }
    }
    final header =
        '| measure (ms) | ${sizes.map((m) => '$m months').join(' | ')} |';
    final buf = StringBuffer()
      ..writeln()
      ..writeln('===== HISTORY BENCHMARK (ms, wall clock, file-backed) =====')
      ..writeln(header)
      ..writeln('|---|${sizes.map((_) => '---:').join('|')}|');
    for (final k in keys) {
      buf.writeln(
        '| $k | ${sizes.map((m) => results[m]?[k] ?? '-').join(' | ')} |',
      );
    }
    for (final e in notes.entries) {
      buf.writeln('${e.key} months: ${e.value}');
    }
    // ignore: avoid_print
    print(buf);
  });

  for (final months in sizes) {
    test('$months-month shop', () async {
      final out = <String, String>{};
      results[months] = out;
      final dir = Directory.systemTemp.createTempSync('hist_bench_');
      final db = newHistoryDb(filePath: '${dir.path}/shop.sqlite');
      late HistoryShop shop;
      try {
        shop = await _ms(
          out,
          '0 build the shop (not a screen)',
          () => buildHistoryShop(
            db,
            HistoryShopSpec(
              months: months,
              minSalesPerDay: int.parse(
                Platform.environment['BENCH_MIN_SALES'] ?? '8',
              ),
              maxSalesPerDay: int.parse(
                Platform.environment['BENCH_MAX_SALES'] ?? '20',
              ),
            ),
          ),
        );
        final c = shop.counts;
        out['sale lines (rows)'] = '${c['saleLines']}';
        out['sales (rows)'] = '${c['sales']}';
        notes[months] =
            'counts $c; file '
            '${(File('${dir.path}/shop.sqlite').lengthSync() / 1048576).toStringAsFixed(1)} MB';

        // ── Daily Reconciliation: load the lists, then compute per period
        final lists = await _ms(
          out,
          'recon: load the 9 lists',
          () => loadReconLists(db),
        );
        out['recon: rows loaded'] = '${lists.rowCount}';
        final p = reconPeriods(DateTime(2026, 10, 15));
        _msSync(
          out,
          'recon: compute DAY',
          () => reconFor(lists, p.day.$1, p.day.$2),
        );
        _msSync(
          out,
          'recon: compute WEEK',
          () => reconFor(lists, p.week.$1, p.week.$2),
        );
        _msSync(
          out,
          'recon: compute MONTH',
          () => reconFor(lists, p.month.$1, p.month.$2),
        );
        // A finished day computes twice (scope + day-close basis).
        out['recon: open DAY (load + 2 computes)'] =
            (double.parse(out['recon: load the 9 lists']!) +
                    2 * double.parse(out['recon: compute DAY']!))
                .toStringAsFixed(1);
        out['recon: open WEEK (load + compute)'] =
            (double.parse(out['recon: load the 9 lists']!) +
                    double.parse(out['recon: compute WEEK']!))
                .toStringAsFixed(1);
        out['recon: open MONTH (load + compute)'] =
            (double.parse(out['recon: load the 9 lists']!) +
                    double.parse(out['recon: compute MONTH']!))
                .toStringAsFixed(1);


        // ── #684: the list's "changed since reviewed" sweep, EVERY day
        // reviewed. Old = load the whole history and file it under the days;
        // new = one bounded load over the reviewed span, split by day.
        final mfrs = await db.inventoryDao.watchAllManufacturers().first;
        final frozenForfeits = await db.walletTransactionsDao
            .watchForfeitRows()
            .first;
        for (
          var d = shop.start;
          !d.isAfter(shop.end);
          d = DateTime(d.year, d.month, d.day + 1)
        ) {
          // Frozen on the sweep's own basis, so a quiet shop flags (almost)
          // nothing and both paths are compared on the same footing.
          final live = reconDataFrom(
            ReconInputs(
              orders: lists.orders,
              expenses: lists.expenses,
              adjustments: lists.adjustments,
              supplierLedger: lists.supplierLedger,
              payments: lists.payments,
              stockTxns: lists.stockTxns,
              stockCounts: lists.stockCounts,
              productsWithStock: lists.products,
              manufacturers: mfrs,
              crateDamages: lists.crateDamages,
              crateForfeitRows: frozenForfeits,
              showCrates: true,
              isCeo: true,
              inScope: (s) => true,
              start: d,
              endExclusive: DateTime(d.year, d.month, d.day + 1),
            ),
          );
          await db.dailyClosingsDao.snapshotIfAbsent(
            businessDate: reconDayKey(d),
            figures: dailyClosingFiguresFrom(live),
          );
        }
        final snaps = await db.dailyClosingsDao.watchAllForBusiness().first;
        out['sweep: reviewed days'] = '${snaps.length}';
        final oldSw = Stopwatch()..start();
        final oldLists = await loadReconLists(db);
        final oldForfeits = await db.walletTransactionsDao
            .watchForfeitRows()
            .first;
        final oldSet = _oldSweep(snaps, oldLists, oldForfeits, mfrs);
        out['sweep: OLD whole-history (load + sweep)'] =
            (oldSw.elapsedMicroseconds / 1000).toStringAsFixed(1);
        final newSw = Stopwatch()..start();
        final dayRows = await loadReviewedDayRows(db, {
          for (final x in snaps) x.businessDate,
        });
        final newSet = changedReviewedDaysFrom(
          snapshots: snaps,
          dayRows: dayRows,
          productsWithStock: lists.products,
          manufacturers: mfrs,
          showCrates: true,
          inScope: (s) => true,
        );
        out['sweep: NEW bounded (load + sweep)'] =
            (newSw.elapsedMicroseconds / 1000).toStringAsFixed(1);
        // Nothing changed since the freeze, so the truth is "no day flagged".
        // The old path's day-sliced inputs can flag days falsely (e.g. stock
        // movements filed without their adjustments); the new one must not.
        expect(newSet, isEmpty);
        out['sweep: days flagged OLD / NEW'] = '${oldSet.length} / ${newSet.length}';

        // ── Profit report: the aggregation per period (orders already loaded)
        final now = kHistoryShopEnd;
        for (final period in const [
          'Today',
          'This Week',
          'This Month',
          'This Year',
          'To Date',
        ]) {
          _msSync(
            out,
            'profit: $period',
            () => _profitLoop(lists.orders, period, now),
          );
        }

        // ── Product Details: the busy product's per-day sales
        final busy = shop.busiestProductId;
        await _ms(
          out,
          'product details: open (busy product)',
          () => db.ordersDao.getProductSalesByDay(busy, now: now),
        );
        await _ms(
          out,
          'product details: refresh (busy product)',
          () => db.ordersDao.getProductSalesByDay(busy, now: now),
        );

        // ── Confirm Payment: the save path, on top of all that history
        final orders = OrderService(db);
        final sw = Stopwatch()..start();
        const sales = 10;
        for (var i = 0; i < sales; i++) {
          await orders.addOrder(
            customerId: null,
            cart: [
              for (final k in [1, 2, 3])
                {
                  'id': shop.productIds[k],
                  'qty': 1,
                  'unitPriceKobo': 100000,
                  'buyingPriceKobo': 0,
                  'name': 'P',
                },
            ],
            totalAmountKobo: 300000,
            amountPaidKobo: 300000,
            paymentType: 'Cash',
            staffId: shop.staffId,
            storeId: shop.storeId,
          );
        }
        out['confirm payment: save (3-line sale, avg)'] =
            (sw.elapsedMicroseconds / 1000 / sales).toStringAsFixed(1);

        // ── Sync Engine save step: apply a full first download to an empty
        // file-backed database, table by table in one transaction each, the
        // way pullInitialData's restore loop does.
        final cloud = await _ms(
          out,
          'sync: (shape rows as cloud rows - setup)',
          () => _cloudShapedRows(db),
        );
        final rowTotal = cloud.values.fold<int>(0, (a, l) => a + l.length);
        out['sync: rows downloaded'] = '$rowTotal';
        // #687: the same download through both connections, the app's real
        // one on each side, so the only difference is where SQLite runs.
        for (final (label, home) in const [
          ('', LocalDatabaseHome.screenThread),
          (' (background worker)', LocalDatabaseHome.backgroundWorker),
        ]) {
          final dir2 = Directory.systemTemp.createTempSync('hist_bench_dl_');
          final fresh = AppDatabase.forTesting(
            openLocalDatabaseFile(File('${dir2.path}/fresh.sqlite'), home),
          );
          fresh.businessIdResolver = () => shop.businessId;
          await fresh.customSelect('SELECT 1').get();
          final sync = SupabaseSyncService(
            fresh,
            SupabaseCloudTransport(
              SupabaseClient('https://placeholder.supabase.co', 'placeholder'),
            ),
          );
          final applySw = Stopwatch()..start();
          for (final table in kSyncPullOrder) {
            final rows = cloud[table];
            if (rows == null) continue;
            await fresh.transaction(
              () => sync.restoreTableDataForTesting(
                table,
                rows,
                fkSkipped: <String>{},
              ),
            );
          }
          out['sync: save a full first download$label'] =
              (applySw.elapsedMicroseconds / 1000).toStringAsFixed(1);
          final applied = await fresh
              .customSelect('SELECT COUNT(*) AS n FROM order_items')
              .getSingle();
          out['sync: order_items applied$label'] = '${applied.read<int>('n')}';
          await fresh.close();
          dir2.deleteSync(recursive: true);
        }
      } finally {
        await db.close();
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 150)));
  }
}
