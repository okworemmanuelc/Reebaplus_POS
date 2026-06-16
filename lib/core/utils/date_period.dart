/// Canonical date-range filter for every Phase-1 browse/report filter chip.
///
/// One source of truth so the same chip means the same thing on every screen.
/// Each window is a *calendar* period anchored to the start of the current
/// day / week / month / year (the week starts on **Sunday**), except [toDate]
/// which is unbounded (everything up to now). Screens must not roll their own
/// date math — route through this helper.
///
/// Because the boundaries are calendar-anchored they are computed from the
/// **local** date parts of "now" (local-zone dependent — e.g. "Today" means
/// since local midnight, not a fixed 24h span).
///
/// Scope note: this governs the browse/report period chips (Home, Reports,
/// Orders, Expenses, Supplier Accounts, Customer wallet, Stock Audit). It does
/// NOT touch the calendar-day-bound machinery — Funds Register Open/Close Day
/// and the daily reconciliation stay per-calendar-day. Inventory History (§16.8)
/// keeps its own ("Today / 7 Days / 30 Days / All") labels by design.
library;

/// The five canonical calendar periods.
enum DatePeriod { today, thisWeek, thisMonth, thisYear, toDate }

extension DatePeriodX on DatePeriod {
  /// Human label shown on the chip / dropdown.
  String get label {
    switch (this) {
      case DatePeriod.today:
        return 'Today';
      case DatePeriod.thisWeek:
        return 'This Week';
      case DatePeriod.thisMonth:
        return 'This Month';
      case DatePeriod.thisYear:
        return 'This Year';
      case DatePeriod.toDate:
        return 'To Date';
    }
  }

  /// The inclusive start of the calendar period relative to [now], or `null`
  /// for [toDate] (unbounded). A timestamp is "in period" iff it is at or after
  /// this instant. Computed from [now]'s local date parts; compare via UTC.
  DateTime? startFrom(DateTime now) {
    final midnight = DateTime(now.year, now.month, now.day);
    switch (this) {
      case DatePeriod.today:
        return midnight;
      case DatePeriod.thisWeek:
        // Week starts Sunday. `weekday` is Mon=1…Sun=7, so `% 7` gives the
        // number of days back to Sunday (Sun=0, Mon=1 … Sat=6).
        return midnight.subtract(Duration(days: midnight.weekday % 7));
      case DatePeriod.thisMonth:
        return DateTime(now.year, now.month, 1);
      case DatePeriod.thisYear:
        return DateTime(now.year, 1, 1);
      case DatePeriod.toDate:
        return null;
    }
  }

  /// True iff [date] falls within this period measured from [now] (defaults to
  /// `DateTime.now()`). Boundary is inclusive at the start; [toDate] includes
  /// everything. Both sides are normalised to UTC so local/UTC timestamps and
  /// the clock are compared as the same instant (no zone drift).
  bool includes(DateTime date, {DateTime? now}) {
    final start = startFrom(now ?? DateTime.now());
    if (start == null) return true;
    return !date.toUtc().isBefore(start.toUtc());
  }
}

/// Canonical chip labels, in display order. Use this for chip rows / dropdowns.
const List<String> kDatePeriodLabels = [
  'Today',
  'This Week',
  'This Month',
  'This Year',
  'To Date',
];

/// Labels a viewer may choose. Roles below Manager (Cashier, Stock keeper) are
/// capped to Today / This Week / This Month (§19.2 / §30.11); Manager & CEO get
/// the full set incl. This Year / To Date.
List<String> datePeriodLabelsForRole({required bool managerUp}) =>
    managerUp ? kDatePeriodLabels : kDatePeriodLabels.sublist(0, 3);

/// Resolves a label to a [DatePeriod]. Tolerant of every legacy label the app
/// used — Day/Week/Month/Year/To Date, the rolling Last 24 hours/Last 7 days/
/// Last 30 days/Last year set, and 7 Days/30 Days/All/All Time — so any
/// persisted or in-flight value still resolves cleanly. Unknown labels fall
/// back to [DatePeriod.toDate] (show everything).
DatePeriod datePeriodFromLabel(String label) {
  switch (label.trim().toLowerCase()) {
    case 'today':
    case 'day':
    case 'last 24 hours':
      return DatePeriod.today;
    case 'this week':
    case 'week':
    case 'last 7 days':
    case '7 days':
      return DatePeriod.thisWeek;
    case 'this month':
    case 'month':
    case 'last 30 days':
    case '30 days':
    case 'this quarter':
      return DatePeriod.thisMonth;
    case 'this year':
    case 'year':
    case 'last year':
      return DatePeriod.thisYear;
    case 'to date':
    case 'all':
    case 'all time':
      return DatePeriod.toDate;
    default:
      return DatePeriod.toDate;
  }
}

/// `(start, end)` range for a [label], for callers that query a DB by date
/// window (start inclusive, end exclusive/`null` = up to now). `start` is `null`
/// for "to date". Computed from [now] (defaults to `DateTime.now()`).
(DateTime?, DateTime?) dateRangeForLabel(String label, {DateTime? now}) {
  final start = datePeriodFromLabel(label).startFrom(now ?? DateTime.now());
  return (start, null);
}
