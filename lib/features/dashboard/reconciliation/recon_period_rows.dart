import 'dart:async';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
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
Future<ReconPeriodRows> loadReconPeriodRows(
  AppDatabase db,
  DateTime start,
  DateTime endExclusive,
) async {
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
    db.stockLedgerDao.getTransactionsFrom(start),
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
