# The closing report reconciles from recorded flows, not a cash balance

**Status:** accepted (2026-07-05); **amended 2026-07-30 (PRD #203 slice #215)** —
see "Amendment: the sixth card" at the foot of this file before changing the
card count; **amended 2026-07-30 (#186)** — see "Amendment: which basis each
figure stands on" for the loss-valuation and count-session rules that supersede
the "current cost" wording below.

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

  **Addendum 2026-07-25 (PRD #155, slices #170 + #182).** The *loss* surfaces no
  longer share this card's current-cost basis. Damages (#170) and count
  shortages (#182) are now valued from the write-time
  `stock_adjustments.value_kobo` snapshot, so a later cost-price edit cannot
  restate a past period's loss (ADR 0021 §4). **This card keeps current cost on
  purpose** — its closing identity must tie to the rewound perpetual figure — so
  the flow-equation Damages/Expired terms and the P&L Damages/Shortage lines can
  legitimately differ after a price change. Count *surplus* remains current-cost
  everywhere (a gain draws no batch). The residual "Other movements" is now
  broken out by cause (transfers / count corrections / product deletions) per
  #155 US 30.

  **Addendum 2026-07-30 (#186).** Valuation was only half the basis. Which
  ROWS a figure is built from is the other half, and the count-shortage money
  now shares the units' answer — the latest count session per business date and
  store, bucketed on `business_date`, not every adjustment in the period on its
  `created_at`. See "Amendment: which basis each figure stands on" at the foot
  of this file; it supersedes any reading of the paragraph above that assumes
  one basis covers the whole report.

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
  **→ No longer deferred: landed 2026-07-25 via PRD #155 slice #174** as the
  synced `daily_closings` table (one first-writer-wins row per business × day,
  frozen on the first review of a finished day) plus a per-card
  "changed since review" delta. See ADR 0021 §2. Purely observational — no money
  flow changed.
- **Book revenue net of discount with no discount line** — rejected: correct
  bottom line but hides how much was discounted; the ask names discounts as an
  explicit subtraction.
- **Keep the perpetual count only / implement the literal equation** — rejected:
  the first omits the opening→closing story asked for; the second double-counts
  shortages so expected-vs-actual never ties out.

## Amendment: the sixth card (2026-07-30, PRD #203 slice #215)

This ADR cut the reconciliation from nine cards to five, and the cut is still
the rule: every figure that can live on an existing card must. **One exception
is now granted, deliberately and by the owner: a sixth card, "Crate money with
suppliers (business-wide)".** Design record: ADR 0023, whose Consequences name
this amendment as a required part of the slice.

**Why it earns a card rather than a line.** Before PRD #203 a distributor could
hand a depot ₦180,000 for their crates and *every money figure in the app read
exactly the same afterwards* (ADR 0023 finding #1). Slice #215 fixes the total —
a Placed Deposit is now an asset inside `businessNetPositionKobo`, and it gets
its own cash line outside `cashInKobo`/`cashOutKobo`/net, the same treatment
`cashCrateDepositsKobo` has had for the customer leg since #175. But a total
answers "how much?", and the question an owner acts on is "**who** is holding
it?" — that is who they ring, and who they settle with. Only a card can carry
the per-supplier breakdown. Folding it into Business worth would have kept the
figure invisible in the way that mattered.

**Why it is business-wide, even under a locked store.** Supplier crate money is
a company obligation: the depot invoices the business, not the branch. The card
says "(business-wide)" on its face and its provider never reads the active
store. Splitting it per store would repeat the defect `CRATE_TRACKING_AUDIT` C4
already names — point-in-time business-wide crate figures presented inside a
store-scoped report — and would let two branches each believe the same money was
theirs.

**Why the count is not really six for anyone yet.** The Crate Money Arrangement
defaults to `none` on every manufacturer (ADR 0023 rule 3, slice #211), and the
card renders only when a brand actually moves crate money. Every business that
has not deliberately switched a brand on still reads exactly the five cards this
ADR specified — which is also the release gate PRD #203 ships on.

**To anyone re-tightening the card count:** this exception is deliberate, and
the reasoning is here so you can weigh it rather than discover it. If crate
money can be made legible without a card of its own, replacing it is a decision
to record, not a tidy-up to perform.

## Amendment: which basis each figure stands on (2026-07-30, #186)

This ADR was written when one sentence — "every term is valued at the product's
*current* per-product buying price" — covered the whole report. It no longer
does, and reading it as though it still did is what produced #186. Two
independent axes now decide a figure, and **every figure has to name both**:

| Axis | The two answers | Who is on which |
|---|---|---|
| **Valuation** | *current cost* (today's `products.buying_price_kobo`) vs *write-time snapshot* (`stock_adjustments.value_kobo`, #170) | Flow-equation terms are current cost. Every **loss** — Damages (#170), count shortages (#182), product-delete write-offs (#193) — is the snapshot. |
| **Selection** | *all rows in the period* (bucketed on `created_at`) vs *the winning count session* (latest per `business_date` + store, bucketed on `business_date`) | The stock card's "Count corrections" line is all-rows. Everything on the **variance card** — units, retail, lines, products counted **and the money** — is the winning session (#186). |

The 2026-07-25 addendum above settled the valuation axis. #186 settles the
selection axis, which had never been stated at all: the money summed every
count-reconciliation adjustment in the period while the units beside it reported
only the latest count of each day. A same-day recount therefore charged a day
twice in money and once in units, and a count saved after midnight put its units
in one period and its money in another. **Decision: the money follows the units
— the winning session, bucketed on `business_date`.** Three reasons, in
ascending weight:

1. It is the only reading under which a matching latest count shows **zero**
   variance and raises no integrity flag — the behaviour the report promises in
   words on the card ("the physical count matches recorded sales…").
2. **Count surplus cannot move to the adjustment rows.** A gain draws no FIFO
   batch, so no snapshot exists to sum, and `surplus` is therefore session-
   sourced by nature. Since `variance = surplus − shortage`, only a
   session-based shortage puts both halves of that subtraction on one basis.
   `productsCounted` and `shortageCount` are session-only facts as well: no
   adjustment row knows how many products someone counted.
3. The card would otherwise carry two bases without saying so — exactly the
   failure `stockCountAdjustmentsKobo`'s own dartdoc already named when it
   deferred a real basis change to "#186".

**Cumulative shrinkage is not lost, and that is why the stock card was left
alone.** "Count corrections" still sums *every* count of *every* day at current
cost, so the day-total view survives — it is now the only place it lives, and
the card and the export label it as such. The flow-equation terms keep current
cost for the reason this ADR always gave: `stockDerivedClosingKobo` ties to the
rewound perpetual figure only while every term shares one basis, and breaking
that tie-out would be a worse failure than the one #186 fixed.

**Implementation note, because it constrains future changes.**
`stock_adjustments` has no `count_id`, and #186 deliberately added none — that
would be a Drift + cloud migration for a reporting question. A row is attributed
to a session by a `created_at` window instead: the save loop writes each changed
line's adjustment immediately *before* `recordCount`, so a row belongs to the
earliest session of its own store whose `created_at` is not before the row's.
Its known imperfections (a save whose session never landed, two saves inside one
second, a null-store session) are documented at
`countShortageRowsBySession`, and a session with no attributable rows falls back
to valuing its own count lines at current cost — **counted and labelled** through
the existing `legacyValuedShortageRows` footnote (#200 / PRD #155 US 20), so
money and units can never disagree about whether a shortage happened at all.
