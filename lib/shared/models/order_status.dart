/// Canonical order-status helpers for the agreed revenue model.
///
/// Revenue is recognized at **checkout** — the moment the sale is settled and
/// the order is written with status `pending` (wallet legs booked, inventory
/// deducted; see `OrderService.addOrder`). The later **Confirm** step
/// (`OrdersDao.markCompleted`, status `completed`) is ceremonial: it records
/// the customer's receipt of goods and any returned empty crates. It does NOT
/// create revenue.
///
/// A `cancelled`/`refunded` order is a reversed sale and never counts. So a
/// "recognized sale" is any order that has been checked out and not reversed —
/// i.e. `pending` or `completed`.
///
/// Every money/sales aggregation (dashboard, reconciliation, profit, staff and
/// product sales) must use this predicate, not a bare `== 'completed'` check.
const Set<String> orderRevenueStatuses = {'pending', 'completed'};

/// True when [status] represents a recognized (non-reversed) sale.
bool orderCountsAsSale(String status) => orderRevenueStatuses.contains(status);

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
