import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncValueX;
import 'package:drift/drift.dart' show TableInfo, TableUpdateQuery;
import 'package:reebaplus_pos/core/database/app_database.dart';
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
/// "changed since reviewed" sweep. Each day loads only its own rows, through
/// the same bounded reads as the detail screen ([loadReconPeriodRows]); a
/// business with no reviewed day loads nothing.
Future<Map<String, ReconPeriodRows>> loadReviewedDayRows(
  AppDatabase db,
  Set<String> days,
) async {
  final out = <String, ReconPeriodRows>{};
  for (final day in days) {
    final start = DateTime.tryParse(day);
    if (start == null) continue;
    out[day] = await loadReconPeriodRows(
      db,
      start,
      start.add(const Duration(days: 1)),
      stockTxnsInPeriodOnly: true,
    );
  }
  return out;
}

/// The reviewed days' rows, re-loaded when any table they read changes or the
/// set of reviewed days does.
final reviewedDayRowsProvider =
    businessScopedStream<Map<String, ReconPeriodRows>>((ref, db, businessId) {
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
