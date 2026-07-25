# Van sales: cost travels with the load, cash follows custody, profit is an artifact

**Status:** accepted (2026-07-25)

A driver loads a van from a warehouse and sells route-to-route for days before
reconciling. PRD #139 modelled this as a **consignment ledger**: loading debits
the driver the full load-price value, returns and remittances credit it, a sale
never touches the balance, and the trip reconciles into unremitted cash /
shortage / damage. That ledger math is sound — the worked trip in
`docs/design/van-sales-spec.md` §6.3 balances to the kobo.

What the follow-the-money audit found (`MONEY_FLOW_AUDIT.md` §5) is that the
plan broke at **three seams with the rest of the app**, and each break is a
different confusion between *a physical event* and *a book entry*:

1. **Cost stayed behind.** Cost Batches are per `(product, store)` and a load
   moved quantity only. The warehouse kept phantom batch coverage for goods that
   had driven away; the van sold at zero COGS; returned goods re-entered
   cost-less; and with two vans out, the cost of goods became order-of-close
   dependent — profit per trip a race, not a fact.
2. **Cash was booked in the wrong custody at the wrong time.** A road sale was an
   ordinary order, so it wrote a `payment_transactions` row the moment the driver
   rang it. "Cash sales" rose while the money sat in a pocket on a route. The
   remittance days later landed only in the driver ledger, which the Daily
   Reconciliation never reads — so recorded cash was overstated forever by every
   unremitted naira, and `payment_transactions` had no store column with which to
   filter it back out.
3. **Profit landed nowhere.** Per-sale COGS was skipped by design, close-time
   "store profit" was persisted in no table any report reads, and the rollup
   slice added a revenue-only line. The van was a channel whose entire P&L
   contribution was revenue.

Two smaller cracks compound them: zero-cost van lines are *exactly* the F5
cost-backfill's gather set (one accepted prompt double-counts cost against
close-time profit), and the report exclusions shipped last, leaving five slices
where road revenue inflated All-Stores figures at zero cost.

## Decision

**Three rules, each about keeping a book entry attached to the physical fact it
describes.**

### 1. Cost travels with the load — the lot snapshot is the van's cost truth

Dispatch draws the source warehouse's FIFO cost batches down through the
existing non-sale outflow primitive (`CostBatchesDao.drawDownOutflow`, the same
one transfer dispatch and valued damages use) and **snapshots the drawn per-unit
cost onto the load lot**, alongside the load price. No cost batch is created on
the van store — that would put the same goods in two queues. A good return
creates a warehouse batch **at the lot's snapshotted cost**, so the goods
re-enter carrying the cost they left with. Close computes
`cogs = Σ consumed lot units × that lot's unit cost`.

This is deterministic and two-van safe by construction: a trip's COGS depends
only on its own lots' snapshots, so interleaved loads and closes over one product
give identical per-trip COGS regardless of close order. There is no replay
dependency — which is also why the van is **fenced out of** the cost backfill's
gather set and the cloud `pos_recost_product_store` replay. Van cost truth is
the snapshot; the batch queue must not be allowed to have a second opinion.

### 2. Cash follows custody — a road sale writes no payment record

A van sale writes **no** `payment_transactions` row. The trip, not the payment
ledger, carries road takings. The **remittance** writes both legs: the
driver-ledger credit *and* a payment row typed `van_remittance`, store-stamped to
the source warehouse, on the day the money physically arrived. The Daily
Reconciliation gains a **"Cash from drivers"** line from those rows.

The owner's cash figure then means what it says: money the business holds.

### 3. Profit is a persisted artifact, not a screen calculation

Closing a trip writes onto `van_trips`: COGS, recovered value, the shortage and
damage write-offs, profit, closed-at and source warehouse. The closing report
**reads closed trips** for van P&L and prints, for any trip still open,
*"₦X van revenue awaiting trip close — profit not yet booked."*

Revenue is still recognised when the driver rings the sale (consistent with
`orderCountsAsSale`), but van orders are excluded from every per-store figure
**from the first road sale** — the exclusion predicate lands in the prefactor,
not the last slice — and surface only as one aggregated "Van Sales" line. Van
*stock*, by contrast, **counts as company stock** in All-Stores inventory and
business worth: it is the company's goods on wheels, and excluding it would make
net worth drop by the value of every load.

**Write-offs are dual-valued**: the driver-ledger credit is at **load price**
(that is the debt being forgiven), the company loss is at **snapshotted cost**
(the business lost the goods, not the margin it never earned).

## Rejected alternatives

**Create cost batches on the van store and let the van sell at real per-sale
COGS.** This is the obvious symmetry — a van is a store, so give it a batch
queue. Rejected: it re-introduces the two-queue problem the snapshot avoids
(returns would have to draw the van queue down and re-create warehouse batches
with a blended cost), it makes van COGS depend on the order in which offline
sales sync, and it re-opens the backfill/recost hazard because the van's batches
would be indistinguishable from a store's. The lot snapshot is the smaller,
tamper-evident representation: one number, written once, at the moment the goods
physically left.

**Book the driver's cash as "cash in transit" at ring time and clear it on
remittance.** More conventional accounting, and it would keep road revenue and
its cash leg together. Rejected for this codebase: it requires a second money
representation for exactly one channel, and the Daily Reconciliation's cash card
is deliberately *"what could I count in the drawer"*. A pocket on a route is not
the drawer. Suppressing the sale-side payment row and booking the remittance when
it lands is fewer moving parts and cannot overstate cash even transiently.

**Compute van profit at report time from lots, sales and returns.** Rejected:
this is root cause #4 from the money audit ("reports re-derive instead of read")
applied to the one figure that is genuinely a settlement outcome. A trip's profit
is decided by a manager's write-off decisions at a moment in time; re-deriving it
later means a subsequent cost edit or a late sale silently restates a settled
trip. Persisting the artifact makes a restatement **visible** — it sets
`restated_at` and writes an audit row — instead of invisible.

**Keep the original slice order and ship exclusions last (#147).** Rejected: it
guarantees five slices during which every road sale inflates All-Stores revenue
with zero cost against it and inflates the business-wide cash figure. Moving the
predicate into the prefactor costs one slice of extra work and removes the
window entirely. For the same reason #144 (remittance) now ships **before** #142
(road sales stop writing payment rows), so cash is never in a state where it
enters the books nowhere at all.

**Full crate handling in v1.** Rejected as scope, but *not* deferred to nothing:
v1 writes **memo counts** (`shells_out` / `shells_back`) with no money and no
crate-pool writes, surfaced at reconcile time. A 100-crate load carries
~₦180,000 of deposit-value shells; without the memo a trip closes "balance 0 =
settled" having lost every shell and the data to reconstruct it never existed.
The full pass is filed as **Van Sales v2** and cross-linked from #139 so the
deferral cannot quietly become permanent.

## Consequences

- `van_trip_lots.unit_cost_kobo` is load-bearing. If a dispatch ever writes a lot
  without drawing the source batches down, that trip's COGS is silently wrong and
  nothing downstream will catch it — the dispatch transaction must do both or
  neither.
- Van cost is deliberately **outside** the batch/recost machinery. Anyone
  extending the backfill or the recost RPC must preserve the van fence, and the
  regression tests exist to say so.
- "Cash sales" and "Cash from drivers" are different lines with different
  meanings. A future report that sums all `payment_transactions` regardless of
  type will double-count neither, but a report that treats `van_remittance` as a
  sale will.
- A trip open across a month boundary puts revenue in one month and profit in
  the next, **by design**, with the caveat line making it visible.
- `payment_transactions` gains a sixth parent FK (`van_trip_id`) inside its
  exactly-one-parent CHECK — a Drift table rebuild and a cloud CHECK-widening.
- The dormant legacy `drivers` / `delivery_receipts` tables are **ignored**, not
  reused: a van-sales driver is a `users` row with the Driver role.

Full design, worked money trail, and the complete edge-case list:
`docs/design/van-sales-spec.md`. Product record: PRD #139 as amended by PRD #161.
