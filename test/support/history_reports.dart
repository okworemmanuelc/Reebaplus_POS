// history_reports.dart
//
// #682 — runs the app's EXISTING report computations against a generated
// history shop (see history_shop_generator.dart), the same way the screens do:
// load the eight "all*" lists the Daily Reconciliation reads, hand them to the
// pure reconDataFrom, and read Product Details' derived data. Shared by the
// build test and the benchmark so both time/check the same thing.

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

/// The lists the Daily Reconciliation screen loads (the 8 `all*` streams).
class ReconLists {
  const ReconLists({
    required this.orders,
    required this.expenses,
    required this.adjustments,
    required this.supplierLedger,
    required this.payments,
    required this.stockTxns,
    required this.stockCounts,
    required this.crateDamages,
    required this.products,
  });

  final List<OrderWithItems> orders;
  final List<ExpenseWithCategory> expenses;
  final List<StockAdjustmentData> adjustments;
  final List<SupplierLedgerEntryData> supplierLedger;
  final List<PaymentTransactionData> payments;
  final List<StockTransactionData> stockTxns;
  final List<StockCountData> stockCounts;
  final List<CrateLedgerData> crateDamages;
  final List<ProductDataWithStock> products;

  int get rowCount =>
      orders.length +
      expenses.length +
      adjustments.length +
      supplierLedger.length +
      payments.length +
      stockTxns.length +
      stockCounts.length +
      crateDamages.length;
}

/// Loads the eight lists exactly as the providers do (first emission of each
/// DAO stream).
Future<ReconLists> loadReconLists(AppDatabase db) async {
  final orders = await db.ordersDao.watchAllOrdersWithItems().first;
  final expenses = await db.expensesDao.watchAll().first;
  final adjustments = await db.inventoryDao.watchAllAdjustments().first;
  final ledger = await db.supplierLedgerDao.watchAllHistory().first;
  final payments = await db.ordersDao.watchAllPaymentTransactions().first;
  final stockTxns = await db.stockLedgerDao.watchAllTransactions().first;
  final counts = await db.stockCountsDao.watchAllForBusiness().first;
  final damages = await db.inventoryDao.watchAllCrateDamages().first;
  final products = await db.inventoryDao.watchProductsWithStock().first;
  return ReconLists(
    orders: orders,
    expenses: expenses,
    adjustments: adjustments,
    supplierLedger: ledger,
    payments: payments,
    stockTxns: stockTxns,
    stockCounts: counts,
    crateDamages: damages,
    products: products,
  );
}

/// The Reconciliation roll-up for `[start, endExclusive)` over [lists] — what
/// `computeReconData` does after it has gathered the providers.
ReconData reconFor(ReconLists lists, DateTime start, DateTime endExclusive) =>
    reconDataFrom(
      ReconInputs(
        orders: lists.orders,
        expenses: lists.expenses,
        adjustments: lists.adjustments,
        supplierLedger: lists.supplierLedger,
        payments: lists.payments,
        stockTxns: lists.stockTxns,
        stockCounts: lists.stockCounts,
        crateDamages: lists.crateDamages,
        productsWithStock: lists.products,
        isCeo: true,
        start: start,
        endExclusive: endExclusive,
      ),
    );

/// The three Daily Reconciliation periods the screen opens, anchored on [day]:
/// that day, its Monday-start week, and its calendar month.
({
  (DateTime, DateTime) day,
  (DateTime, DateTime) week,
  (DateTime, DateTime) month,
})
reconPeriods(DateTime day) {
  final d = DateTime(day.year, day.month, day.day);
  final monday = DateTime(d.year, d.month, d.day - (d.weekday - 1));
  return (
    day: (d, DateTime(d.year, d.month, d.day + 1)),
    week: (monday, DateTime(monday.year, monday.month, monday.day + 7)),
    month: (DateTime(d.year, d.month), DateTime(d.year, d.month + 1)),
  );
}
