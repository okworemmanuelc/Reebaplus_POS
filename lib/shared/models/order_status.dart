/// Canonical order-status helpers for the agreed revenue model.
///
/// Revenue is recognized at **checkout** — the moment the sale is settled and
/// the order is written with status `pending` (wallet legs booked, inventory
/// deducted; see `OrderService.addOrder`). The later **Confirm** step
/// (`OrdersDao.markCompleted`, status `completed`) is ceremonial: it records
/// the customer's receipt of goods and any returned empty crates. It does NOT
/// create revenue.
///
/// A `cancelled`/`refunded` order is a reversed sale, so a "recognized sale"
/// (this predicate) is any order that has been checked out and not reversed —
/// i.e. `pending` or `completed`. MONEY REPORTS additionally keep a cancelled
/// sale on its original day and book its reversal as a negative entry on the
/// cancel day — see [saleDayStamps] (#549).
///
/// Every money/sales aggregation (dashboard, reconciliation, profit, staff and
/// product sales) must use this predicate, not a bare `== 'completed'` check.
const Set<String> orderRevenueStatuses = {'pending', 'completed'};

/// True when [status] represents a recognized (non-reversed) sale.
bool orderCountsAsSale(String status) => orderRevenueStatuses.contains(status);

/// `orders.cancellation_reason` of a sale the server refused (the phone undid
/// its local copy, see `OrdersDao.reverseRejectedSaleLocal`). It never existed
/// in the cloud, so no report ever counts it, on any day.
const String kRejectedByServerReason = 'rejected_by_server';

/// Which report days ONE order lands on (#549, PRD #337 "a returned sale keeps
/// its original day"). Reviewed days must never change, so a Cancel is not a
/// deletion of the sale:
///
///  * a live order (`pending` / `completed`) is `+1` on its `createdAt` day;
///  * a `cancelled` order is STILL `+1` on its `createdAt` day, plus a `-1`
///    entry of the same amounts on its `cancelledAt` day (a same-day cancel
///    therefore nets to zero on that day, as it always did);
///  * a cancelled order with no `cancelledAt` (legacy) and a
///    [kRejectedByServerReason] order yield nothing — excluded entirely;
///  * `refunded` (retired, nothing writes it) and any unknown status yield
///    nothing.
///
/// This is THE rule behind every money report (Total Sales, costed revenue,
/// COGS, discounts, uncosted takings). Callers multiply each summed amount by
/// `sign` and test `inSpan(day)`. Order COUNTS ("number of sales") do not use
/// it. [saleDayEntries] in `report_revenue.dart` is the `OrderWithItems`
/// wrapper.
///
/// `cancelledAt` is written as UTC; it is converted to local so the day matches
/// how `createdAt` is read.
Iterable<({DateTime day, int sign})> saleDayStamps({
  required String status,
  required DateTime createdAt,
  DateTime? cancelledAt,
  String? cancellationReason,
}) sync* {
  if (orderCountsAsSale(status)) {
    yield (day: createdAt, sign: 1);
    return;
  }
  if (status != 'cancelled') return;
  if (cancellationReason == kRejectedByServerReason) return;
  if (cancelledAt == null) return;
  yield (day: createdAt, sign: 1);
  yield (day: cancelledAt.toLocal(), sign: -1);
}

/// User-facing label for a stored order `paymentType` value
/// (`wallet` / `credit` / `mixed` / `cash` / `transfer` / `card`).
///
/// A customer's prepaid balance is presented as a **credit balance**, never a
/// "wallet" — the app records what is owed/held on account and never holds or
/// transfers value, so it must not read like a regulated e-money wallet
/// (Nigeria / CBN naming convention — see `context/code-standards.md`). The
/// stored column values are left unchanged; only the display label maps.
String paymentMethodLabel(String paymentType) {
  switch (paymentType.toLowerCase()) {
    case 'wallet':
      return 'Credit Payment';
    case 'credit':
      return 'Credit Sale';
    case 'mixed':
      return 'Cash / Transfer / Credit';
    case 'cash':
      return 'Cash / Transfer';
    case 'transfer':
      return 'Transfer';
    case 'card':
    case 'pos':
      return 'Card';
    default:
      return paymentType;
  }
}
