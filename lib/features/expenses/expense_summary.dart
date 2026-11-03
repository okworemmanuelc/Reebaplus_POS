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

/// #669 — the combined "Daily allowances" lines the Expenses screen shows for
/// [scopeStoreId] (null = All Stores): kind `daily_allowances`, non-zero,
/// newest day first. They name no worker (ADR 0034).
List<StaffPayTotalData> dailyAllowanceLinesInScope(
  Iterable<StaffPayTotalData> totals,
  String? scopeStoreId,
) {
  return [
    for (final t in totals)
      if (t.kind == kStaffPayKindDailyAllowances &&
          t.amountKobo != 0 &&
          (scopeStoreId == null || t.storeId == scopeStoreId))
        t,
  ]..sort((a, b) => b.totalDate.compareTo(a.totalDate));
}

/// #671 — every combined pay line the Expenses screen shows for
/// [scopeStoreId] (null = All Stores): "Daily allowances" (#669) and
/// "Salaries" per payday, non-zero, newest day first. They name no worker
/// (ADR 0034).
List<StaffPayTotalData> staffPayLinesInScope(
  Iterable<StaffPayTotalData> totals,
  String? scopeStoreId,
) {
  return [
    for (final t in totals)
      if (kStaffPayKinds.contains(t.kind) &&
          t.amountKobo != 0 &&
          (scopeStoreId == null || t.storeId == scopeStoreId))
        t,
  ]..sort((a, b) => b.totalDate.compareTo(a.totalDate));
}

/// The title of a combined pay line on the Expenses screen.
String staffPayLineTitle(StaffPayTotalData t) =>
    t.kind == kStaffPayKindSalaries ? 'Salaries' : 'Daily allowances';

/// The calendar day a combined pay line is dated, at local midnight.
DateTime staffPayLineDay(StaffPayTotalData t) =>
    DateTime.tryParse(t.totalDate) ?? t.createdAt;

/// Builds the summary from the viewer's (store-scoped) expenses and, #669, the
/// combined Daily allowances lines in the same scope (already-spent money,
/// counted like an approved expense) — and, #671, the combined Salaries
/// lines passed in the same list.
ExpenseSummary summarizeExpenses(
  Iterable<ExpenseData> expenses, {
  DateTime? now,
  Iterable<StaffPayTotalData> allowanceLines = const [],
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
  for (final t in allowanceLines) {
    if (!kStaffPayKinds.contains(t.kind)) continue;
    final date = staffPayLineDay(t);
    if (isDateInPeriod(date, 'Today', now: now)) today += t.amountKobo;
    if (isDateInPeriod(date, 'This Week', now: now)) week += t.amountKobo;
    if (isDateInPeriod(date, 'This Month', now: now)) {
      budgetSpent += t.amountKobo;
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
