/// Canonical date-range filter for every Phase-1 browse/report filter chip.
///
/// One source of truth so the same chip means the same thing on every screen.
/// Each window is a *rolling* span measured back from "now" (e.g. "Last 7 days"
/// = the last 7×24 hours), except [toDate] which is unbounded (everything up to
/// now). Screens must not roll their own date math — route through this helper.
///
/// Scope note: this governs the browse/report period chips (Home, Reports,
/// Orders, Expenses, Supplier Accounts, Customer wallet, Stock Audit). It does
/// NOT touch the calendar-day-bound machinery — Funds Register Open/Close Day
/// and the daily reconciliation stay per-calendar-day. Inventory History (§16.8)
/// keeps its own ("Today / 7 Days / 30 Days / All") labels by design.
library;

/// The five canonical rolling windows.
enum DatePeriod {
  last24Hours,
  last7Days,
  last30Days,
  lastYear,
  toDate,
}

extension DatePeriodX on DatePeriod {
  /// Human label shown on the chip / dropdown.
  String get label {
    switch (this) {
      case DatePeriod.last24Hours:
        return 'Last 24 hours';
      case DatePeriod.last7Days:
        return 'Last 7 days';
      case DatePeriod.last30Days:
        return 'Last 30 days';
      case DatePeriod.lastYear:
        return 'Last year';
      case DatePeriod.toDate:
        return 'To date';
    }
  }

  /// The inclusive start of the window relative to [now], or `null` for
  /// [toDate] (unbounded). A timestamp is "in period" iff it is at or after
  /// this instant. Returned in the same zone as [now]; compare via UTC.
  DateTime? startFrom(DateTime now) {
    switch (this) {
      case DatePeriod.last24Hours:
        return now.subtract(const Duration(hours: 24));
      case DatePeriod.last7Days:
        return now.subtract(const Duration(days: 7));
      case DatePeriod.last30Days:
        return now.subtract(const Duration(days: 30));
      case DatePeriod.lastYear:
        return now.subtract(const Duration(days: 365));
      case DatePeriod.toDate:
        return null;
    }
  }

  /// True iff [date] falls within this window measured from [now] (defaults to
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
  'Last 24 hours',
  'Last 7 days',
  'Last 30 days',
  'Last year',
  'To date',
];

/// Resolves a label to a [DatePeriod]. Tolerant of every legacy label the app
/// used before this standardization — Day/Week/Month/Year/To Date,
/// Today/This Week/This Month/This Year/This Quarter, All/All Time, 7 Days/30
/// Days — so any persisted or in-flight value still resolves cleanly.
/// Unknown labels fall back to [DatePeriod.toDate] (show everything).
DatePeriod datePeriodFromLabel(String label) {
  switch (label.trim().toLowerCase()) {
    case 'last 24 hours':
    case 'day':
    case 'today':
      return DatePeriod.last24Hours;
    case 'last 7 days':
    case '7 days':
    case 'week':
    case 'this week':
      return DatePeriod.last7Days;
    case 'last 30 days':
    case '30 days':
    case 'month':
    case 'this month':
    case 'this quarter':
      return DatePeriod.last30Days;
    case 'last year':
    case 'year':
    case 'this year':
      return DatePeriod.lastYear;
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
