import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';

/// The figures on the Expenses summary card (#652).
class ExpenseSummary {
  const ExpenseSummary({
    required this.spentTodayKobo,
    required this.spentThisWeekKobo,
    required this.waitingCount,
    required this.budgetSpentKobo,
    required this.budgetPendingKobo,
  });

  /// Money spent today: approved + waiting (a waiting expense is money that
  /// already left the till); rejected never counts.
  final int spentTodayKobo;

  /// Same rule over "This Week".
  final int spentThisWeekKobo;

  /// Expenses waiting for approval, any date.
  final int waitingCount;

  /// Approved spend in "This Month" — the figure the monthly budget compares
  /// against (unchanged from §20.3).
  final int budgetSpentKobo;

  /// Waiting spend in "This Month", shown under the budget bar.
  final int budgetPendingKobo;
}

/// Builds the summary from the viewer's (store-scoped) expenses.
ExpenseSummary summarizeExpenses(
  Iterable<ExpenseData> expenses, {
  DateTime? now,
}) {
  var today = 0;
  var week = 0;
  var waiting = 0;
  var budgetSpent = 0;
  var budgetPending = 0;
  for (final e in expenses) {
    final pending = e.status == 'pending';
    final approved = e.status == 'approved';
    if (pending) waiting++;
    if (!pending && !approved) continue;
    final date = e.expenseDate;
    if (isDateInPeriod(date, 'Today', now: now)) today += e.amountKobo;
    if (isDateInPeriod(date, 'This Week', now: now)) week += e.amountKobo;
    if (isDateInPeriod(date, 'This Month', now: now)) {
      if (approved) {
        budgetSpent += e.amountKobo;
      } else {
        budgetPending += e.amountKobo;
      }
    }
  }
  return ExpenseSummary(
    spentTodayKobo: today,
    spentThisWeekKobo: week,
    waitingCount: waiting,
    budgetSpentKobo: budgetSpent,
    budgetPendingKobo: budgetPending,
  );
}
