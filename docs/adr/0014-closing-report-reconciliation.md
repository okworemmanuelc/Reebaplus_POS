# The closing report reconciles from recorded flows, not a cash balance

**Status:** accepted (2026-07-05)

The Daily Reconciliation (§25.9, `recon_data.dart` + `daily_reconciliation_detail_screen.dart`)
already ships a store-scoped, Day/Week/Month/Year report with Sales, a CEO
Profit & Loss, a point-in-time "Business worth" net position, a perpetual stock
audit, valued shrinkage, supplier flows, and crates. The ask is to complete it
into a *closing report* with three linked checks — stock reconciliation, cash
reconciliation, and P&L — plus a running business net position with an integrity
flag. This ADR records how each is built given the constraints already in the
codebase.

The defining constraint is **Hard Rule #8**: the Funds Register was removed
entirely (Session 96) — *no cash account, no Open Day / Close Day, no per-store
money accounts; money is tracked as recorded sales, expenses, refunds, and
supplier payments.* A literal cash reconciliation (opening float vs. physically
counted drawer) *is* that removed model, so it is out of scope. Every decision
below stays inside the recorded-flow world.

Decisions locked:

- **Cash reconciliation is a derived cash-flow *summary*, not a drawer count.**
  It reports the period's expected cash *movement* from already-recorded,
  tender-tagged flows — cash sales + debts collected − cash supplier payments −
  cash expenses − cash refunds — with no opening float and no counted-cash
  entry. Every source carries a tender: `payment_transactions.method`,
  `expenses.paymentMethod`, `supplier_ledger_entries.paymentMethod`
  (all `== 'cash'`, matched **case-insensitively** — the data has `'Cash'`/`'cash'`
  drift). The authoritative cash-in source is `payment_transactions`
  (`type` in {sale, wallet_topup, refund, expense}), not `orders.paymentType`, so
  partial cash on a credit order is captured; cash supplier payments (the one
  cash-out not in `payment_transactions`) are summed from `supplier_ledger_entries`
  `payment_*`. No cash *balance* is ever asserted.

- **Stock reconciliation is a cost-valued flow-equation card (a derivation),
  compared to the physical count.** Opening (at cost) + Goods received − COGS −
  Damages − Expired = **Expected closing** (equal to the perpetual SYSTEM
  figure), then **Variance = Physical count − Expected**. "Expired" is broken
  out as its own line (today it is folded into damages via the `expired`
  reason). The literal spec equation (which also subtracts *shortages* from
  expected) is rejected: a shortage **is** the variance, so subtracting it would
  double-count. The one genuinely hard input is *opening stock at cost as of a
  past date* — cost is time-varying under FIFO (ADR 0005). **Basis decided
  as-built (current cost, ledger-rewound):** every term (opening, received,
  COGS, damages, expired) is valued at the product's *current* per-product
  buying price (`products.buyingPriceKobo`; uncosted units, cost ≤ 0, carry
  zero value). Opening and Expected closing are reconstructed by **rewinding the
  recorded `stock_transactions` deltas from the current on-hand figure** — so the
  equation ties to the perpetual SYSTEM figure *by construction* rather than
  pretending to historical-cost precision. Deltas are classified by
  `movementType`/reason (sale → COGS, receipt reasons → Goods received,
  `damage:`/`expired` reasons → Damages/Expired); transfers, count fixes, and
  anything unclassified land in a signed **Other movements** residual so nothing
  is silently folded into opening. Consequence: this card's COGS (current cost)
  can diverge from the P&L COGS (per-line snapshotted FIFO cost) under a price
  change — accepted as the stated current-cost basis.

- **P&L books gross revenue and subtracts an explicit Discounts line.**
  `order_items.unitPriceKobo` is the **gross** list price; the order's real
  payable lives in `netAmountKobo`/`discountKobo` (`order_commands.dart`). The
  report today sums `qty × unitPriceKobo` and never reads `discountKobo`, so
  revenue and net profit are **overstated by the discount given** — a real
  calculation bug in what already ships. Fix: Revenue (gross) − Discounts = Net
  revenue → − COGS = Gross profit → − Expenses − Damages = Net profit. Shipped
  as its own small PR ahead of the report work.

- **The integrity flag reconciles from flows, adding no persistence.** A true
  "Δ net position over the period = reported profit" identity cannot close: the
  net position has no cash leg (Hard Rule #8) and no stored period-start snapshot
  exists. Rather than persist snapshots, the flag derives the period's expected
  asset change from recorded flows and the **physical stock count**, and flags
  the gap against P&L profit. The independent signal it surfaces is stock-count
  variance (shrinkage the flows didn't record) plus the now-corrected
  discounts/refunds — i.e. a *recording error*, per the ask, not a real loss.

- **The new cost/profit/cash-flow surfaces are CEO-only**, following the
  existing cost wall (§25.3): Managers never see cost/COGS/margin/profit and
  keep their retail-valued shrinkage + debts/expenses view.

## Considered Options

- **Reintroduce a lightweight opening-cash + counted-cash for the report only**
  — rejected: it is the Open/Close-Day cash-account model Hard Rule #8 tombstoned
  ("no reintroduction"); overturning it is a separate, deliberate architectural
  reversal, not a report feature.
- **Persist daily net-position snapshots for an exact running Δ** — deferred:
  most faithful to "running net position," but adds a synced snapshot table +
  backfill; the flow-reconciliation flag delivers the recording-error signal now
  without new persistence. Revisit if snapshot-grade history is wanted.
- **Book revenue net of discount with no discount line** — rejected: correct
  bottom line but hides how much was discounted; the ask names discounts as an
  explicit subtraction.
- **Keep the perpetual count only / implement the literal equation** — rejected:
  the first omits the opening→closing story asked for; the second double-counts
  shortages so expected-vs-actual never ties out.
