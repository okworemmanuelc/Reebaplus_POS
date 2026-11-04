import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncValueX;
import 'package:drift/drift.dart' show TableInfo, TableUpdateQuery;
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/inventory_reasons.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart' show allDailyClosingsProvider;
import 'package:reebaplus_pos/core/utils/perf_log.dart';

/// One reconciliation period, `[start, endExclusive)`. A record, so two equal
/// periods are the same family key.
typedef ReconPeriod = ({DateTime start, DateTime endExclusive});

/// The rows ONE Daily Reconciliation period needs (#683, PRD #680), instead of
/// the shop's whole history.
///
/// This only narrows what is LOADED. The figures are still added up by the one
/// pure calculation, `reconDataFrom`, which applies the exact period and store
/// rules itself. So each list below is the period's rows **plus every row whose
/// effect lands in the period**, and loading a few extra rows is harmless while
/// loading one too few changes a figure. The window per list:
///
/// | list | rows loaded | why |
/// |---|---|---|
/// | orders (+ items) | created in the period, OR cancelled in it | #549: a cancel is a negative entry on its cancel day |
/// | expenses | `expense_date` in the period | the reporting basis (#198) |
/// | stock adjustments | dated in the period, OR named by a period stock movement, OR a count-shortage row the period's count sessions can own | damages / deletions are dated; the stock card reads a movement's reason; #186 matches shortage rows to sessions by time |
/// | supplier ledger | `activity_date` in the period | every period supplier flow |
/// | payments | `created_at` in the period | refunds, cash card, driver cash |
/// | stock movements | `created_at` at or after the period start | the stock card rewinds LATER movements from today's stock to find opening and closing |
/// | stock counts | `business_date` in the period, plus the sessions around them that the shortage-row match needs | see `StockCountsDao.getCountWindowForPeriod` |
/// | crate damages | `created_at` in the period | |
/// | crate forfeits | `created_at` in the period | forfeit income |
///
/// Point-in-time figures that genuinely need all history are NOT here: the
/// supplier payable (the whole ledger, CEO only) and the stock, debt and crate
/// balances, which come from their own providers as before.
class ReconPeriodRows {
  const ReconPeriodRows({
    this.orders = const [],
    this.expenses = const [],
    this.adjustments = const [],
    this.supplierLedger = const [],
    this.payments = const [],
    this.stockTxns = const [],
    this.stockCounts = const [],
    this.crateDamages = const [],
    this.crateForfeitRows = const [],
  });

  static const empty = ReconPeriodRows();

  final List<OrderWithItems> orders;
  final List<ExpenseWithCategory> expenses;
  final List<StockAdjustmentData> adjustments;
  final List<SupplierLedgerEntryData> supplierLedger;
  final List<PaymentTransactionData> payments;
  final List<StockTransactionData> stockTxns;
  final List<StockCountData> stockCounts;
  final List<CrateLedgerData> crateDamages;
  final List<WalletTransactionData> crateForfeitRows;

  int get rowCount =>
      orders.length +
      expenses.length +
      adjustments.length +
      supplierLedger.length +
      payments.length +
      stockTxns.length +
      stockCounts.length +
      crateDamages.length +
      crateForfeitRows.length;
}

/// Loads [ReconPeriodRows] for `[start, endExclusive)` through the
/// business-scoped DAOs. One-shot; [watchReconPeriodRows] re-runs it.
///
/// [stockTxnsInPeriodOnly] (#684) loads the stock movements dated inside the
/// period only, not the open-ended "from the start" window the stock card's
/// rewind needs. The reviewed-day sweep compares day-local figures only, so it
/// never needs the later movements.
Future<ReconPeriodRows> loadReconPeriodRows(
  AppDatabase db,
  DateTime start,
  DateTime endExclusive, {
  bool stockTxnsInPeriodOnly = false,
}) async {
  final countWindow = await db.stockCountsDao.getCountWindowForPeriod(
    start,
    endExclusive,
  );
  final results = await Future.wait<Object>([
    db.ordersDao.getOrdersWithItemsForPeriod(start, endExclusive),
    db.expensesDao.getForPeriod(start, endExclusive),
    db.inventoryDao.getAdjustmentsForPeriod(
      start,
      endExclusive,
      countRowsAfter: countWindow.rowsAfter,
      countRowsUpTo: countWindow.rowsUpTo,
    ),
    db.supplierLedgerDao.getForPeriod(start, endExclusive),
    db.ordersDao.getPaymentTransactionsForPeriod(start, endExclusive),
    stockTxnsInPeriodOnly
        ? db.stockLedgerDao.getTransactionsForPeriod(start, endExclusive)
        : db.stockLedgerDao.getTransactionsFrom(start),
    db.inventoryDao.getCrateDamagesForPeriod(start, endExclusive),
    db.walletTransactionsDao.getForfeitRowsForPeriod(start, endExclusive),
  ]);
  return ReconPeriodRows(
    orders: results[0] as List<OrderWithItems>,
    expenses: results[1] as List<ExpenseWithCategory>,
    adjustments: results[2] as List<StockAdjustmentData>,
    supplierLedger: results[3] as List<SupplierLedgerEntryData>,
    payments: results[4] as List<PaymentTransactionData>,
    stockTxns: results[5] as List<StockTransactionData>,
    stockCounts: countWindow.sessions,
    crateDamages: results[6] as List<CrateLedgerData>,
    crateForfeitRows: results[7] as List<WalletTransactionData>,
  );
}

/// [loadReconPeriodRows], re-run whenever one of the tables it reads changes
/// (a sale, a cancel, a peer's sync), like the Drift watch streams it
/// replaces. Writes that land while a load is running are folded into ONE
/// re-run after it, so a sync burst never queues a load per row.
Stream<ReconPeriodRows> watchReconPeriodRows(
  AppDatabase db,
  DateTime start,
  DateTime endExclusive,
) {
  final updates = db.tableUpdates(
    TableUpdateQuery.onAllTables([
      db.orders,
      db.orderItems,
      db.customers,
      db.products,
      db.expenses,
      db.expenseCategories,
      db.stockAdjustments,
      db.supplierLedgerEntries,
      db.paymentTransactions,
      db.stockTransactions,
      db.stockCounts,
      db.crateLedger,
      db.walletTransactions,
    ]),
  );
  late final StreamController<ReconPeriodRows> out;
  StreamSubscription<Object?>? sub;
  var running = false;
  var again = false;

  Future<void> run() async {
    if (running) {
      again = true;
      return;
    }
    running = true;
    try {
      do {
        again = false;
        try {
          final rows = await perfLogAsync(
            'recon period rows load',
            () => loadReconPeriodRows(db, start, endExclusive),
          );
          if (!out.isClosed) out.add(rows);
        } catch (e, st) {
          if (!out.isClosed) out.addError(e, st);
        }
      } while (again && !out.isClosed);
    } finally {
      running = false;
    }
  }

  out = StreamController<ReconPeriodRows>(
    onListen: () {
      sub = updates.listen((_) => run());
      run();
    },
    onCancel: () => sub?.cancel(),
  );
  return out.stream;
}

/// The Daily Reconciliation detail's rows for one period (#683). Torn down
/// when the screen closes, so an old period never keeps re-loading on every
/// later sale.
final reconPeriodRowsProvider =
    businessScopedStreamAutoDisposeFamily<ReconPeriodRows, ReconPeriod>(
      (ref, db, businessId, period) =>
          watchReconPeriodRows(db, period.start, period.endExclusive),
      whenAbsent: ReconPeriodRows.empty,
    );

// ── The period LIST (#684, PRD #680 S3) ──────────────────────────────────────

/// One order line that can count as a sale, reduced to what the period list
/// needs: the order's status and dates, the line's store and its quantity.
typedef ReconSaleLine = ({
  String status,
  DateTime createdAt,
  DateTime? cancelledAt,
  String? cancellationReason,
  String? storeId,
  double quantity,
});

/// One stock-count session, reduced to what the period list needs.
typedef ReconCountFact = ({
  String? storeId,
  String businessDate,
  DateTime createdAt,
  double shortageUnits,
});

/// What the Daily Reconciliation LIST of periods is built from (#684): sale
/// lines and count sessions in their lightest form. Which days appear, each
/// card's items-sold total and its shortage mark all come from these, through
/// the same rules (`saleDayStamps`, store scope, latest count per store and
/// date) that read full orders and counts before.
class ReconListFacts {
  const ReconListFacts({this.saleLines = const [], this.counts = const []});

  static const empty = ReconListFacts();

  final List<ReconSaleLine> saleLines;
  final List<ReconCountFact> counts;

  /// The same facts out of already-loaded rows — the whole-history shape, used
  /// by tests and fixtures to prove the light read gives an identical list.
  factory ReconListFacts.fromRows({
    required List<OrderWithItems> orders,
    required List<StockCountData> counts,
  }) => ReconListFacts(
    saleLines: [
      for (final o in orders)
        if (const {'pending', 'completed', 'cancelled'}.contains(
          o.order.status,
        ))
          for (final i in o.items)
            (
              status: o.order.status,
              createdAt: o.order.createdAt,
              cancelledAt: o.order.cancelledAt,
              cancellationReason: o.order.cancellationReason,
              storeId: i.item.storeId,
              quantity: i.item.quantity,
            ),
    ],
    counts: [
      for (final c in counts)
        (
          storeId: c.storeId,
          businessDate: c.businessDate,
          createdAt: c.createdAt,
          shortageUnits: c.shortageUnits,
        ),
    ],
  );
}

Future<ReconListFacts> loadReconListFacts(AppDatabase db) async {
  final results = await Future.wait<Object>([
    db.ordersDao.getSaleDayLines(),
    db.stockCountsDao.getCountListFacts(),
  ]);
  return ReconListFacts(
    saleLines: results[0] as List<ReconSaleLine>,
    counts: results[1] as List<ReconCountFact>,
  );
}

/// Re-runs [load] whenever one of [tables] changes, folding writes that land
/// during a load into ONE re-run (same shape as [watchReconPeriodRows]).
Stream<T> _watchLoaded<T>(
  AppDatabase db,
  List<TableInfo> tables,
  Future<T> Function() load,
  String label,
) {
  final updates = db.tableUpdates(TableUpdateQuery.onAllTables(tables));
  late final StreamController<T> out;
  StreamSubscription<Object?>? sub;
  var running = false;
  var again = false;

  Future<void> run() async {
    if (running) {
      again = true;
      return;
    }
    running = true;
    try {
      do {
        again = false;
        try {
          final v = await perfLogAsync(label, load);
          if (!out.isClosed) out.add(v);
        } catch (e, st) {
          if (!out.isClosed) out.addError(e, st);
        }
      } while (again && !out.isClosed);
    } finally {
      running = false;
    }
  }

  out = StreamController<T>(
    onListen: () {
      sub = updates.listen((_) => run());
      run();
    },
    onCancel: () => sub?.cancel(),
  );
  return out.stream;
}

/// The list's light facts, re-loaded when a sale, an item or a count changes.
final reconListFactsProvider = businessScopedStream<ReconListFacts>(
  (ref, db, businessId) => _watchLoaded<ReconListFacts>(
    db,
    [db.orders, db.orderItems, db.stockCounts],
    () => loadReconListFacts(db),
    'recon list facts load',
  ),
  whenAbsent: ReconListFacts.empty,
);

// ── The reviewed days (#684) ─────────────────────────────────────────────────

/// The period rows of each reviewed day, keyed `YYYY-MM-DD`, for the
/// "changed since reviewed" sweep.
///
/// ONE bounded load covers the span from the earliest to the latest reviewed
/// day (the same bounded reads as the detail screen, [loadReconPeriodRows]),
/// then [splitReviewedDayRows] files the rows under their days in Dart. A shop
/// that reviews every day therefore costs about ten queries, not ten per day.
/// A business with no reviewed day loads nothing.
Future<Map<String, ReconPeriodRows>> loadReviewedDayRows(
  AppDatabase db,
  Set<String> days,
) async {
  DateTime? first;
  DateTime? last;
  for (final day in days) {
    final d = DateTime.tryParse(day);
    if (d == null) continue;
    if (first == null || d.isBefore(first)) first = d;
    if (last == null || d.isAfter(last)) last = d;
  }
  if (first == null || last == null) return const {};
  final span = await loadReconPeriodRows(
    db,
    first,
    DateTime(last.year, last.month, last.day + 1),
    // The sweep compares day-local figures only, so it never needs the later
    // movements the stock card rewinds.
    stockTxnsInPeriodOnly: true,
  );
  return splitReviewedDayRows(span, days);
}

/// Files the rows of one wide [span] load under each of [days]. Pure.
///
/// Each list is filed by the date its figure is counted on, exactly the basis
/// the one-day bounded read uses: orders on their creation day AND their cancel
/// day (#549), expenses on `expense_date`, supplier entries on `activity_date`,
/// payments, stock movements, crate damages and forfeits on `created_at`.
/// Adjustments are the day's own dated rows, the rows its movements point at,
/// and EVERY count-shortage row of the span: a shortage row belongs to the first
/// session of its store saved at or after it (#186), and the span window
/// already holds each session's neighbours, so handing a day all of them lets
/// the report match them exactly as it does over the whole history. Count
/// sessions are likewise all of the span's. Handing a day extra rows is
/// harmless (the report applies the exact period); handing it too few is not.
Map<String, ReconPeriodRows> splitReviewedDayRows(
  ReconPeriodRows span,
  Set<String> days,
) {
  Map<String, List<T>> byDay<T>(
    Iterable<T> rows,
    Iterable<DateTime?> Function(T) datesOf,
  ) {
    final out = <String, List<T>>{};
    for (final r in rows) {
      for (final d in datesOf(r)) {
        if (d == null) continue;
        final k = _dayKey(d);
        if (!days.contains(k)) continue;
        final list = (out[k] ??= <T>[]);
        // An order created and cancelled on the same day is filed once.
        if (list.isEmpty || !identical(list.last, r)) list.add(r);
      }
    }
    return out;
  }

  final orders = byDay<OrderWithItems>(span.orders, (o) => [
    o.order.createdAt,
    o.order.cancelledAt?.toLocal(),
  ]);
  final expenses = byDay<ExpenseWithCategory>(
    span.expenses,
    (e) => [e.expense.expenseDate],
  );
  final ledger = byDay<SupplierLedgerEntryData>(
    span.supplierLedger,
    (l) => [l.activityDate],
  );
  final payments = byDay<PaymentTransactionData>(
    span.payments,
    (p) => [p.createdAt],
  );
  final txns = byDay<StockTransactionData>(span.stockTxns, (t) => [t.createdAt]);
  final damages = byDay<CrateLedgerData>(span.crateDamages, (c) => [c.createdAt]);
  final forfeits = byDay<WalletTransactionData>(
    span.crateForfeitRows,
    (w) => [w.createdAt],
  );
  final datedAdjustments = byDay<StockAdjustmentData>(
    span.adjustments,
    (a) => [a.createdAt],
  );
  final countRows = [
    for (final a in span.adjustments)
      if (isCountReconciliationReason(a.reason)) a,
  ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final sessionsAsc = [...span.stockCounts]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final adjustmentById = {for (final a in span.adjustments) a.id: a};

  return {
    for (final day in days)
      if (DateTime.tryParse(day) != null)
        day: () {
          final dayTxns = txns[day] ?? const <StockTransactionData>[];
          final win = _countWindowFor(day, sessionsAsc);
          final adj = <String, StockAdjustmentData>{
            for (final a in datedAdjustments[day] ?? const []) a.id: a,
            for (final t in dayTxns)
              if (t.adjustmentId != null &&
                  adjustmentById[t.adjustmentId] != null)
                t.adjustmentId!: adjustmentById[t.adjustmentId]!,
            if (win.upTo != null)
              for (final a in countRows)
                if (!a.createdAt.isAfter(win.upTo!) &&
                    (win.after == null || a.createdAt.isAfter(win.after!)))
                  a.id: a,
          };
          return ReconPeriodRows(
            orders: orders[day] ?? const [],
            expenses: expenses[day] ?? const [],
            adjustments: adj.values.toList(),
            supplierLedger: ledger[day] ?? const [],
            payments: payments[day] ?? const [],
            stockTxns: dayTxns,
            stockCounts: win.sessions,
            crateDamages: damages[day] ?? const [],
            crateForfeitRows: forfeits[day] ?? const [],
          );
        }(),
  };
}

/// The count sessions (and the window of shortage rows) one reviewed [day]
/// needs — the in-memory twin of `StockCountsDao.getCountWindowForPeriod`, run
/// over the span's own sessions (which already hold every day's neighbours):
/// sessions whose business date is within a day of the day, plus every session
/// saved from each counted store's previous session on, so the shortage-row
/// match (#186) comes out as over the whole history. [sessionsAsc] is sorted by
/// save time, oldest first.
({List<StockCountData> sessions, DateTime? after, DateTime? upTo})
_countWindowFor(String day, List<StockCountData> sessionsAsc) {
  final d = DateTime.parse(day);
  final from = _dayKey(d.subtract(const Duration(days: 1)));
  final to = _dayKey(DateTime(d.year, d.month, d.day + 2));
  bool near(StockCountData c) =>
      c.businessDate.compareTo(from) >= 0 && c.businessDate.compareTo(to) <= 0;
  final inPeriod = [
    for (final c in sessionsAsc)
      if (near(c)) c,
  ];
  if (inPeriod.isEmpty) {
    return (sessions: const <StockCountData>[], after: null, upTo: null);
  }
  var upTo = inPeriod.first.createdAt;
  final earliestByStore = <String, DateTime>{};
  for (final c in inPeriod) {
    if (c.createdAt.isAfter(upTo)) upTo = c.createdAt;
    final store = c.storeId;
    if (store == null) continue;
    final e = earliestByStore[store];
    if (e == null || c.createdAt.isBefore(e)) earliestByStore[store] = c.createdAt;
  }
  DateTime? after;
  var unbounded = false;
  for (final entry in earliestByStore.entries) {
    DateTime? prev;
    for (final c in sessionsAsc) {
      if (c.storeId == entry.key && c.createdAt.isBefore(entry.value)) {
        prev = c.createdAt; // ascending: the last one wins = the latest earlier
      }
    }
    if (prev == null) {
      unbounded = true;
      continue;
    }
    if (after == null || prev.isBefore(after)) after = prev;
  }
  if (unbounded || earliestByStore.isEmpty) after = null;
  final rowsAfter = earliestByStore.isEmpty ? upTo : after;
  final sessions = [
    for (final c in sessionsAsc)
      if ((!c.createdAt.isAfter(upTo) &&
              (rowsAfter == null || !c.createdAt.isBefore(rowsAfter))) ||
          near(c))
        c,
  ];
  return (sessions: sessions, after: rowsAfter, upTo: upTo);
}

String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The reviewed days' rows, re-loaded when any table they read changes or the
/// set of reviewed days does.
final reviewedDayRowsProvider =
    businessScopedStreamAutoDispose<Map<String, ReconPeriodRows>>((ref, db, businessId) {
      final snapshots =
          ref.watch(allDailyClosingsProvider).valueOrNull ?? const [];
      final days = {for (final s in snapshots) s.businessDate};
      if (days.isEmpty) {
        return Stream<Map<String, ReconPeriodRows>>.value(const {});
      }
      return _watchLoaded<Map<String, ReconPeriodRows>>(
        db,
        [
          db.orders,
          db.orderItems,
          db.customers,
          db.products,
          db.expenses,
          db.expenseCategories,
          db.stockAdjustments,
          db.supplierLedgerEntries,
          db.paymentTransactions,
          db.stockTransactions,
          db.stockCounts,
          db.crateLedger,
          db.walletTransactions,
        ],
        () => loadReviewedDayRows(db, days),
        'recon reviewed days load',
      );
    }, whenAbsent: const {});
