# Van Sales & Driver Reconciliation — design spec (drinks-only v1)

Status: **authoritative design record** for PRD #139 and slices #140–#147, as
amended by PRD #161 (money-trail amendments, 2026-07-21 audits).
Architecture record: **ADR 0019** (`docs/adr/0019-van-money-model.md`).

Sources this file consolidates:

- PRD #139 (product definition, user stories, out-of-scope) and slices #140–#147.
- `MONEY_FLOW_AUDIT.md` §5 — the worked trip, the five recon-integration
  answers, plan adjustments 1–11, and the safe slice order.
- `CRATE_TRACKING_AUDIT.md` §6 — the crate-specific holes and the memo seam.
- PRD #161 — the amendment decisions, restated here as the design.

> **Why this file exists.** Every van issue cites
> `docs/design/van-sales-spec.md` for "the reconciliation math and the complete
> edge-case list". The original was never committed. This is the recreation,
> written from the PRD plus both audits, and it is the document the acceptance
> criteria refer to.

---

## 1. The problem in one paragraph

A driver loads a van with drinks from a warehouse and sells route-to-route,
often reloading and dropping off unsold goods several times before the run ends.
Today the app models only a fixed store till. There is no way to hold a driver
accountable for what left the warehouse, record road sales, reconcile cash
against returns and missing stock, or see what a driver owes. When the numbers
don't add up nobody can tell whether the gap is unremitted cash, missing stock,
or damage.

## 2. The shape of the answer

- A **van is a location** — a `stores` row with `kind = 'van'` — so it holds real
  per-SKU inventory and inherits inventory, transfers, POS, FIFO costing and
  offline sync for free. Vans are hidden from every normal store surface.
- A **driver is a staff member** with the seeded **Driver** role, assigned to the
  van through the existing staff-to-store assignment.
- A **trip** is a first-class `open → closed` aggregate. One open trip per van
  and per driver, enforced by the cloud.
- The money model is **consignment**: an append-only **driver ledger**. Loading
  debits the driver the full load-price value ("they signed for the van").
  Returns, remittances and write-offs credit it. **A sale never touches the
  balance.** Balance = signed sum, negative = the driver owes.
- **Cost travels with the load.** Dispatch draws the warehouse's FIFO cost
  batches down and snapshots the drawn per-unit cost onto each load lot.
- **Cash follows custody.** A road sale writes **no payment record**. The
  remittance does — typed `van_remittance`, store-stamped to the source
  warehouse — so the owner's cash figure only ever counts money the business
  physically holds.
- **Revenue at sale, profit at close.** Van revenue is recognised when the
  driver rings it, but van orders are excluded from every per-store figure and
  surface as one aggregated line; profit is a **persisted close artifact** the
  closing report reads.

---

## 3. Vocabulary

| Term | Meaning |
|---|---|
| **Van** | A `stores` row with `kind = 'van'`. Holds inventory; hidden from normal store pickers, store lists and per-store reports. |
| **Driver** | A `users` row holding the seeded **Driver** role, assigned to a van via `user_stores`. Not the dormant legacy `drivers` table (§14). |
| **Trip** | One run: `van_trips`, `open → closed`, referencing van + driver + source warehouse, stamped with an opening date. |
| **Load / restock** | A dispatch of goods warehouse → van. Each is its own dated event and creates one **load lot** per line. |
| **Load lot** | `van_trip_lots` — a priced FIFO layer `(product, quantity, load price, snapshotted unit cost)`. The unit of both credit valuation and COGS. |
| **Load price** | The price the driver is accountable for per unit. Defaults to the retail tier, editable per line at dispatch. The single valuation for the whole reconciliation. |
| **Driver ledger** | `driver_ledger_entries` — append-only, signed. Balance = `SUM(signed_amount_kobo)`; negative = the driver owes. |
| **Remittance** | Cash the driver hands in, recorded by a manager. A ledger credit **and** a `payment_transactions` row typed `van_remittance`. |
| **Shortage** | `loaded − sold − good returns − damaged`, in units, valued at load price. Goods that left and cannot be accounted for. |
| **Unremitted cash** | Road takings at load price that have not been handed in. |
| **Write-off** | A deliberate, audited forgiveness: a ledger credit at **load price** and a company loss at **snapshotted cost**. |
| **Close artifact** | The figures persisted onto `van_trips` at close — COGS, recovered, write-offs, profit, closed-at, source warehouse. The only thing reports read for van P&L. |
| **Shell memo** | Write-only counts of empty crate shells out and back. Counting only — no money, no crate-pool writes (§11). |

---

## 4. Data model

All money is `bigint` kobo in the cloud and `IntColumn …Kobo` in Drift. Every new
table gets exactly one `SyncedTable` registry entry, placed after its parents in
the ordered list, plus its golden-test literals and a cloud migration that also
re-declares `pos_pull_snapshot`'s `v_tenant_tables` array.

### 4.1 `stores.kind` (#140)

`TEXT NOT NULL DEFAULT 'store'`, CHECK `kind IN ('store','van')`. Add-column on
both sides; `stores` is a pass-through push entry so no registry or golden
change is needed.

The **central predicate** is `isVanStore(storeId)` (and its `Store`-typed
sibling), defined once in core and wired in the same slice into:

- `selectableStoresProvider` / the store picker sheet / `allStoresProvider`
  consumers that render pickers,
- `reconStoreFilter` (`recon_data.dart`),
- the profit report's order set,
- the dashboard sales/profit tiles,
- the orders list, the inventory store filter, and the per-store report screens.

**All-Stores inventory and business worth**: van stock **counts as company
stock**. It is the company's goods on wheels; excluding it would make the net
position drop by the value of every load. The exclusion is about *revenue and
per-store figures*, not about *assets*. `inventoryOnHandKobo` and
`businessNetPositionKobo` therefore include van stores when the viewer is on
All Stores, and exclude them when a concrete store is locked (a van is never the
locked store for a non-driver).

### 4.2 `van_trips` (#141, close artifact added in #145)

| Column | Notes |
|---|---|
| `id`, `business_id` | UUIDv7, tenant. |
| `van_store_id` → `stores` | The van. |
| `driver_user_id` → `users` | The driver. |
| `source_store_id` → `stores` | The warehouse this trip loads from. One warehouse per trip (v1). |
| `status` | CHECK `('open','closed')`. |
| `opened_at`, `opened_by` | Trip list is ordered and filtered by `opened_at`. |
| `closed_at`, `closed_by` | Null while open. |
| `closed_with_balance` | Bool — true when the trip closed with a residual. |
| `shells_out`, `shells_back` | Integer memo counts (§11). Null-safe, default 0. |
| `restated_at`, `restated_reason` | Set when a late sale forces a post-close restatement (§9.4). |
| **Close artifact** — `cogs_kobo`, `recovered_kobo`, `unremitted_kobo`, `shortage_writeoff_kobo`, `damage_writeoff_kobo`, `shortage_loss_kobo`, `damage_loss_kobo`, `profit_kobo` | Written once at close. `recovered_kobo` is the load-price value actually recovered (sold-and-remitted + good returns). Reports read these; they never re-derive van P&L. |

**Cloud uniqueness** (this is what makes double-open impossible across two
offline manager devices):

```sql
CREATE UNIQUE INDEX van_trips_one_open_per_van
  ON public.van_trips (van_store_id) WHERE status = 'open';
CREATE UNIQUE INDEX van_trips_one_open_per_driver
  ON public.van_trips (driver_user_id) WHERE status = 'open';
```

The loser's push lands in the existing orphan/reject flow with a terminal
reason; the Sync Issues screen is the recovery surface. The client also blocks
locally, so this is the second line of defence, not the first.

### 4.3 `van_trip_lots` (#141)

| Column | Notes |
|---|---|
| `id`, `business_id`, `trip_id` | |
| `product_id` | |
| `quantity`, `qty_remaining` | `qty_remaining` is the FIFO draw-down cursor for return credits. |
| `load_price_kobo` | Per unit. What the driver is accountable for. |
| `unit_cost_kobo` | **Snapshotted at dispatch** from the warehouse's FIFO draw-down. `0` only when the source batches were genuinely uncosted. |
| `dispatched_at`, `dispatch_event_id` | The dispatch event groups lots; `dispatch_event_id` is the **client idempotency key** — a retry or double-tap re-uses it and the write is a no-op. |
| `shells_out` | Memo count for this line (§11). |

Lots are **never edited in place** after dispatch except `qty_remaining`, which
only ever decreases through a return event.

### 4.4 `driver_ledger_entries` (#141)

Modelled directly on `supplier_ledger_entries` — append-only, in
`_ledgerTables` (so it gets the immutable + no-delete triggers), and with
`scrubCreatedAt: true` in the sync registry (the cloud owns `created_at`; a void
re-push must drop it — see `[[project_ledger_void_created_at_scrub]]`).

| Column | Notes |
|---|---|
| `id`, `business_id` | |
| `driver_user_id` | The balance axis. Cross-trip. |
| `trip_id` | Nullable only for a cross-trip correction; normally set. |
| `type` | `load` \| `restock` \| `return_good` \| `payment_cash` \| `payment_transfer` \| `shortage_writeoff` \| `damage_writeoff` \| `restatement` \| `void`. |
| `amount_kobo`, `signed_amount_kobo` | Debits negative, credits positive. Balance = `SUM(signed_amount_kobo)`. |
| `reference_type`, `reference_id` | The lot / return event / payment row that caused it. |
| `payment_method`, `receipt_path`, `reference_note` | Remittance proof, mirroring the supplier payment flow. `receipt_path` is device-local. |
| `activity_date`, `performed_by` | |
| `voided_at`, `voided_by`, `void_reason` | A void appends an opposite-sign compensating row; the original is marked, never deleted. |

**A sale writes no driver-ledger row.** This is the invariant that makes the
balance a clean measure of `loaded − returned − paid`.

### 4.5 `van_return_events` (#143)

| Column | Notes |
|---|---|
| `id`, `business_id`, `trip_id` | |
| `product_id`, `quantity` | |
| `condition` | CHECK `('good','damaged')`. |
| `credit_kobo` | Load-price value credited (good returns only; `0` for damaged). |
| `cost_kobo` | Snapshotted cost drawn from the lots — the basis for the warehouse re-batch (good) or the company loss (damaged). |
| `shells_back` | Memo count (§11). |
| `recorded_at`, `recorded_by` | |

### 4.6 Orders — the trip tag (#142)

`orders.van_trip_id` — a new nullable synced column, carried by the sale
envelope contract. Because the v2 envelope RPC gains a parameter, the
**parameter-overload trap** applies: `CREATE OR REPLACE` with a new parameter
mints an *overload*; the old signature must be dropped or PostgREST returns
PGRST203. See `[[project_rpc_param_add_overload_trap]]`.

### 4.7 `payment_transactions` — the remittance type (#144)

The remittance row needs a parent that is neither an order nor an expense. The
table carries a hard exactly-one-parent CHECK over five nullable FK columns, so
this is a **table rebuild** on the Drift side (v64 is the precedent) and a
CHECK-widening `DO` block on the cloud side (0153 is the precedent):

- new nullable FK `van_trip_id` → `van_trips`, added to the exactly-one-parent
  CHECK,
- `type` CHECK widened with `van_remittance`,
- `store_id` set to the **source warehouse** (the column exists since #169).

`van_remittance` is **not** counted in "Cash sales" (that line stays type
`sale`). It gets its own reconciliation line, "Cash from drivers" (§8.2).

---

## 5. The money model

### 5.1 Consignment ledger (unchanged from #139 — it ties out)

```
balance = Σ signed_amount_kobo
        = −(loaded + restocked, at load price)
          + (good returns, at load price, FIFO oldest lot first)
          + (remittances)
          + (write-offs, at load price)
```

Negative = the driver owes. A perfectly settled trip closes at **0**.

### 5.2 Cost travels with the load (amends #141/#143/#145)

The break this fixes: cost batches are per `(product, store)` and a load moved
quantity only — so the warehouse kept phantom batch coverage for goods that had
left, the van sold at zero COGS, returns re-entered cost-less, and with two vans
the cost of goods became order-of-close dependent.

**At dispatch** (inside the same transaction as the inventory move):

1. `CostBatchesDao.drawDownOutflow(productId, sourceStoreId, quantity)` returns
   the total kobo drawn. This is the existing non-sale outflow primitive used by
   transfer dispatch (#7b) and valued damages (#7a) — the van reuses it, it is
   not a new mechanism.
2. `unit_cost_kobo = round(drawn / quantity)` is snapshotted onto the load lot.
3. **No cost batch is created on the van store.** The van's cost truth is the
   lot snapshot; creating a van-side batch would put the same goods in two
   queues.

**At a good return**: `CostBatchesDao.recordInflowBatch(productId,
sourceStoreId, qty, costKobo: lotUnitCost, receivedAt: now)` — the goods
re-enter the warehouse carrying the cost they left with, so their later sale has
real COGS instead of zero. When a return spans two lots at different costs, one
inflow batch per lot segment is created (each at its own cost) rather than a
blended average.

**At a damaged return**: no inflow; the company loss is booked at the
snapshotted cost, not at load price (§5.5).

**At close**: `cogs_kobo = Σ (consumed lot units × that lot's unit_cost_kobo)`,
where consumed = `loaded − good returns` (sold + shortage + damaged). This is
deterministic and **two-van safe**: each trip's COGS depends only on its own
lots' snapshots, so interleaved loads and closes over one product give identical
per-trip COGS regardless of close order. There is no replay dependency.

### 5.3 Cash follows custody (amends #142/#144/#147)

The break this fixes: a route sale wrote a `payment_transactions` row the moment
the driver rang it, so "Cash sales" rose while the money was in a pocket on a
route — and the remittance days later landed only in the driver ledger, which the
reconciliation never reads. Recorded cash was overstated forever by every
unremitted naira.

- **A van sale writes no payment row.** `createOrder` skips
  `_insertCheckoutPaymentRow` entirely when the order is on a van store. The
  trip, not the payment ledger, carries road takings.
- **A remittance writes both legs**: the driver-ledger credit *and* a
  `payment_transactions` row typed `van_remittance`, method from the picker,
  `store_id` = the trip's source warehouse, `van_trip_id` = the trip.
- The reconciliation's cash summary gains **"Cash from drivers"** from those
  rows, on the day they were recorded.

Consequence: the owner's cash figure counts money the business physically holds,
and it moves on the day the money arrives.

### 5.4 Revenue at sale, profit at close

Van revenue is recognised when the driver rings the sale (consistent with
`orderCountsAsSale` — see `[[project_revenue_recognized_at_checkout]]`), but:

- van orders are **excluded from every per-store figure** from the first road
  sale (#140 lands the predicate, #142's definition of done includes the
  exclusion ACs — this is the change that removes the five-slice window of
  corrupted CEO numbers),
- the business-level closing report shows **one aggregated "Van Sales" line**,
- **profit** comes only from the persisted close artifact, and an **open** trip
  prints a caveat instead of a figure:
  *"₦X van revenue awaiting trip close — profit not yet booked."*

A month-straddling trip therefore puts revenue in the month it was rung and
profit in the month the trip closed, and says so on the report rather than
silently.

### 5.5 Write-offs are dual-valued (amends #145)

A write-off does two different things and they are valued differently:

| Leg | Value | Why |
|---|---|---|
| Driver-ledger credit | **Load price** | The driver signed for the load price; that is the debt being forgiven. |
| Company loss (P&L) | **Snapshotted cost** | The business lost the goods, not the margin it never earned. Booking load price as the loss overstates it by the margin. |

The same split applies to shortage and damage that are *not* written off: the
driver stays liable at load price (their balance carries the residual), and no
company loss is booked — the goods are still owed for.

### 5.6 Costing fences (amends #142)

Zero-cost van lines would otherwise be exactly the F5 cost-backfill's gather set
(`buying_price_kobo == 0` + recognised + `product_id`). One accepted prompt would
restate road sales with per-line COGS and **double-count** against close-time
profit. Two fences:

1. `CostBatchesDao.onCostBecameReal` / `applyCostBackfill` exclude order lines
   whose order is on a van store (or carries a `van_trip_id`).
2. The cloud `pos_recost_product_store` replay **skips van stores** — van cost
   truth is the lot snapshot, not the batch queue.

Both get regression tests: a 0→real cost transition gathers no van lines, and
the recost replay leaves a van store's figures untouched.

---

## 6. The reconciliation math

The whole position is computed by one **pure function**, mirroring
`computeReconData`'s role for the daily reconciliation but taking plain data (no
`WidgetRef`):

```dart
VanTripPosition computeVanTripPosition({
  required List<VanTripLotInput> lots,        // qty, loadPrice, unitCost, dispatchedAt
  required List<VanSaleLineInput> sales,      // productId, qty, loadPrice
  required List<VanReturnInput> returns,      // productId, qty, condition, creditKobo, costKobo
  required List<VanLedgerInput> ledger,       // signed amounts by type
  required int shellsOut,
  required int shellsBack,
});
```

### 6.1 Identities it guarantees

```
loadedValue      = Σ lot.qty × lot.loadPrice
soldValue        = Σ sale.qty × sale.loadPrice
goodReturnValue  = Σ good return credits          (FIFO, oldest lot price first)
remitted         = Σ payment credits
writtenOff       = Σ write-off credits

balance          = −loadedValue + goodReturnValue + remitted + writtenOff
                   (negative = driver owes)

shortageUnits    = loaded − sold − goodReturned − damaged      (per product)
shortageValue    = Σ shortageUnits × the load price they were loaded at (FIFO)
damageValue      = Σ damaged qty × its lot's load price
unremittedCash   = soldValue − remitted

outstanding      = unremittedCash + shortageValue + damageValue − writtenOff
```

**Tie-out invariant**: `outstanding == −balance`. The fixture suite asserts this
on every constructed case; if the two ever disagree the function is wrong.

#### The fixed draw order (implementation, #145)

The identities above silently assume **one load price per product per run**.
A restock at a new price breaks that assumption, so the implemented function
pins a **fixed FIFO draw order**: units leave a trip's lots as **returns first**
(both conditions), **then sales**, **then the shortage takes the tail**. That
makes `loaded = goodReturns + damage + sold + shortage` true *by construction*,
per product and in total, so the tie-out stays exact even when a mid-run restock
repriced a product.

A consequence worth naming: `soldValue` is the **accountability** value at load
price, which is not necessarily what the terminal rang. What was actually rung
is carried separately as `rungValue` and shown on the reconcile screen — the gap
is the driver's off-book street markup (§9.2 #9), which v1 does not capture.

#### The three-way split is a waterfall

`unremittedCash` is **not** simply `soldValue − remitted` floored at zero.
Remitted cash is applied as a waterfall — **road takings first, then damage,
then shortage** — and a *typed* write-off hits its own bucket, with any excess
joining the pool. Over-payment surfaces as `residualCredit`. The full identity is:

```
outstanding = unremitted + damage + shortage − residualCredit == −balance
```

which stays exact in the cases a naive floor-at-zero silently breaks: a driver
who over-remits, and a write-off larger than the bucket it names.

### 6.2 What it also returns

- per-product shortage lines (units + value + the lot prices they draw from),
- `cogsKobo` = Σ consumed lot units × lot unit cost,
- `shortageLossKobo` / `damageLossKobo` at **cost** (the P&L legs),
- `profitKobo` = recovered − COGS − written-off losses at cost,
- `rungValue` (what the terminal actually took) alongside `soldValue`,
- `residualCredit` (over-payment),
- `shellsOut` / `shellsBack` and the difference,
- `isSettled` (balance == 0).

### 6.3 Worked trip (the audit's example, amended)

Star 60cl. Warehouse batch: 200 @ ₦10,000 cost. Load 100 @ ₦11,500 load price on
Monday; sell 60 Tuesday; restock 40 Wednesday and sell 30; Thursday return 45
good + 3 damaged, remit ₦900,000, close.

| Day | Physical reality | What the books now show |
|---|---|---|
| **Mon** (load) | 100 crates + 100 shells drive off; driver signs for ₦1,150,000 | Warehouse batch drawn 100 × ₦10,000 = **₦1,000,000 leaves the batch queue**; lot stamped `unit_cost 10,000`, `load_price 11,500`, `shells_out 100`. Driver ledger −₦1,150,000. Inventory moved warehouse→van; **All-Stores worth unchanged** (van stock is company stock). No revenue, no cash. |
| **Tue** (route) | Driver takes ₦720,000 (₦690,000 at load price + ₦30,000 street markup, off-book by design) | Van order tagged to the trip, **no payment row**, no per-sale COGS. Per-store figures: silent. All-Stores: revenue +₦690,000 shown only in the aggregated Van Sales line, with the open-trip caveat; **cash figure unchanged** — the money is in a pocket. |
| **Wed** | Restock 40 @ ₦11,500; sell 30 | Second lot, second batch draw (40 × ₦10,000), ledger −₦460,000. Running balance −₦1,610,000. |
| **Thu** (close) | 45 good back, 3 damaged, ₦900,000 remitted | Good return: credit 45 × ₦11,500 = ₦517,500; **warehouse re-batched 45 @ ₦10,000** so those units sell at real COGS next time. Damaged 3: no credit, loss booked at 3 × ₦10,000 = ₦30,000 if written off. Remittance: ledger +₦900,000 **and** a `van_remittance` payment row → **"Cash from drivers ₦900,000"** on Thursday's reconciliation. |

Position at close:

```
loadedValue   = 140 × 11,500 = 1,610,000
soldValue     =  90 × 11,500 = 1,035,000
goodReturn    =  45 × 11,500 =   517,500
remitted      =               =   900,000
balance       = −1,610,000 + 517,500 + 900,000 = −192,500   (driver owes ₦192,500)

shortage units = 140 − 90 − 45 − 3 = 2  →   2 × 11,500 =  23,000
damage         =  3 × 11,500              =              34,500
unremittedCash = 1,035,000 − 900,000      =             135,000
outstanding    = 135,000 + 23,000 + 34,500 =            192,500   ✓ == −balance
```

Close artifact (assuming both losses written off):

```
consumed units = 140 − 45 = 95
cogs           = 95 × 10,000                       =   950,000
recovered      = remitted 900,000 + goodReturn 517,500 = 1,417,500
shortage loss (cost) =  2 × 10,000                 =    20,000
damage loss   (cost) =  3 × 10,000                 =    30,000
profit         = 1,417,500 − 950,000 − 0           =   467,500
                 (losses already excluded — the written-off units are inside
                  `consumed`, so their cost is already in COGS; the loss lines
                  are reported for transparency, not subtracted twice)
shells: out 100, back 65 → 35 unaccounted (surfaced, not valued in v1)
```

The last line is the point of the shell memo: without it this trip closes at
"balance 0 = settled" having lost 35 shells worth ~₦63,000 of deposit value.

> **Double-count guard.** `consumed` already includes shortage and damaged units,
> so their cost is inside `cogs_kobo`. `shortage_loss_kobo` and
> `damage_loss_kobo` are **disclosure fields**, persisted so the report can show
> *why* profit is what it is. Any report that subtracts them again is wrong; the
> fixture suite pins `profit == recovered − cogs`.

---

## 7. Trip lifecycle

```
                 ┌──────────────────────────────────────────┐
   Load Van ────▶│ OPEN                                     │
   (dispatch)    │  · restock  → new lot + ledger debit     │
                 │  · sale     → van order, no payment row  │
                 │  · return   → FIFO credit / loss         │
                 │  · payment  → ledger credit + cash row   │
                 └──────────────────┬───────────────────────┘
                                    │ Reconcile & close
                                    ▼
                 ┌──────────────────────────────────────────┐
                 │ CLOSED  (artifact persisted)             │
                 │  · residual carries on driver balance    │
                 │  · corrections = compensating entries    │
                 │  · late sale ⇒ restated + audit row      │
                 └──────────────────────────────────────────┘
```

### 7.1 Dispatch is idempotent

Every dispatch carries a client-generated `dispatch_event_id` (the same pattern
the sale envelope uses). A retry or a double-tap re-uses it; the write path
checks for an existing dispatch with that id and returns without debiting twice.

### 7.2 Van load legs are not cancellable through the generic transfer path

A van load is a transfer leg, and the generic transfer-cancel would detach it
from its trip and its ledger debit. The cancel path refuses when either endpoint
is a van store, with a message pointing at the return flow: **corrections are
return events, not cancels.**

### 7.3 Return entry is a forced physical count

The return screen never pre-fills "everything that's left" from system stock. If
the driver's device still has unsynced sales, a system-derived default would
turn unsynced sales into over-returns and misstate the shortage. The manager
types the count they physically see.

### 7.4 Close blocks on a pending outbox, behind an explicit override

The reconcile screen reads the driver device's last-sync state and shows it. If
the driver's device has pending sale envelopes, **Confirm & close warns** (and
may be blocked by a confirm-typed acknowledgement) — you do not assign blame from
an incomplete picture.

**Which reading shipped (#208 item 5).** v1 warned only. The stricter half is
now built: while the outbox is dirty the primary **Confirm & close trip** is
*disabled*, and a quieter **Close anyway** sits under it, routed through the
ordinary close confirmation — retitled *"Close on an incomplete picture?"*,
leading with the risk, and answering *Wait for sync* / *Close anyway*.

It is deliberately **not** a hard block. Sync can be down for days (a device
DNS/VPN failure surfaces as errno 7 and nothing in the app can clear it), and a
trip that cannot close strands the van, the driver's rolling balance and the
next dispatch. A sale that arrives after close posts its own correction anyway
(§9.4 #15), so closing early is recoverable in a way "un-closable" is not.

**The honest limit (#145) is unchanged.** Every string on this barrier says
*this device*. A device can read only its own `sync_queue`; the driver's
un-pushed envelopes live on the driver's phone, and `public.devices` is
cloud-only analytics that never syncs down. A clean barrier means nothing is
stuck *here*, never that the trip is complete.

Not recorded on the artifact: `van_trips` has no column that says the override
was used, and #208 did not add one.

---

## 8. Reporting integration

### 8.1 Exclusions (land in #140, enforced from #142)

Van orders are excluded from: per-store order lists, POS reports, the profit
report, the dashboard sales/profit tiles, and every `reconStoreFilter`-scoped
figure. Van *stock* is **not** excluded from All-Stores inventory value or
business worth (§4.1).

### 8.2 The lines the reconciliation gains (#147)

1. **Van Sales (aggregated)** — the period's van order revenue at load price,
   attributed through each trip's source warehouse. One line, no detail.
2. **Cash from drivers** — the period's `van_remittance` payment rows. Sits in
   the cash-flow summary next to Cash sales.
3. **Van profit (closed trips)** — Σ `profit_kobo` over trips whose `closed_at`
   falls in the period.
4. **Open-trip caveat** — for any trip open in the period:
   *"₦X van revenue awaiting trip close — profit not yet booked."*

The rollup fields are named so a `deposits_held` column can be added additively
when the crate pass lands.

---

## 9. Edge cases (the list the ACs refer to)

### 9.1 Loading

1. **Load below cost** — a line whose load price is under the current cost shows
   a warning at dispatch. The warning must **not reveal the cost figure** to a
   role behind the cost wall: it says "this price is below what these goods cost
   you", never the number.
2. **Load a product with no cost batch** — allowed; `unit_cost_kobo` is 0 and the
   lot is flagged uncosted. It flows into the same Uncosted transparency bucket
   the rest of the app uses; it does **not** silently become free goods.
3. **Load quantity exceeds warehouse stock** — blocked by the existing stock
   guard (`InsufficientStockException`), same as any transfer.
4. **Two managers load the same van offline** — both write locally; the cloud
   partial-unique index rejects the loser, which lands in the orphan flow. The
   local block means this needs two devices that never saw each other's write.
5. **Dispatch retried after a timeout** — idempotency key makes it a no-op.

### 9.2 Selling

6. **Driver logs in with no open trip** — the terminal shows "no open trip";
   they cannot sell.
7. **Driver sells more than van stock** — the normal stock guard applies; the van
   is single-device so there is no concurrent-till oversell.
8. **A van sale is cancelled** — the order cancels normally (stock returns to the
   van, no payment row existed so there is nothing to compensate), and the trip's
   `sold` recomputes. If the trip is already closed, §9.4 applies.
9. **Driver's street markup** — off-book by design in v1. The receipt prints the
   load price; anything above it is the driver's and is not recorded.

### 9.3 Returns

10. **Return of an item loaded at two prices** — credits at the **oldest lot's
    price first** (FIFO), and re-batches the warehouse at that lot's cost.
11. **Return more than was loaded** — blocked. The forced physical count is what
    makes this a real error rather than a silent over-credit.
12. **Damaged return** — no credit, never re-enters sellable stock, loss booked
    at snapshotted cost through the existing damage-adjustment pattern.
13. **Return after close** — not possible; corrections are compensating entries
    on the driver's cross-trip balance.

### 9.4 Closing and after

14. **Close with a residual** — allowed. The trip is flagged
    `closed_with_balance` and the residual carries forward on the driver's
    cross-trip balance.
15. **A road sale syncs after close** — the system auto-posts the compensating
    pair (shortage-reversal credit + unremitted-cash debit), sets
    `restated_at`/`restated_reason`, and writes **one rolled-up audit row**. This
    is the established "audited, never prompted" correction pattern — the manager
    is informed, not interrogated.
16. **A closed trip is never edited in place.** Every correction is a new signed
    ledger row.
17. **Stale open trip** — after a configurable number of days an open trip nags
    on the Van Sales hub. Revenue is recognised and cost is not booked while a
    trip lingers; the nag is what stops that from being invisible.
18. **Month-straddling trip** — revenue in the ring month, profit in the close
    month, with the open-trip caveat printed in between.

### 9.5 People

19. **Former driver with a balance** — stays visible in the Drivers list,
    **badged** as removed. Offboarding cannot hide a debt.
20. **Offboarding with an open trip or non-zero balance** — blocked, or allowed
    only with an explicit write-off / acknowledgement.
21. **Driver records their own payment** — impossible: no surface, and
    `Gates.vanManage` rejects it.

---

## 10. Permissions and roles

- New seeded default role **Driver** per business (cloud role seeding + backfill
  for existing businesses; the client never mints role rows).
- New permission keys `van.manage` (CEO + Manager) and `van.sell` (Driver),
  seeded **cloud catalogue first** — grants sync against a `role_permissions` FK,
  so the key must exist in the cloud catalogue before any grant reaches a device
  (`[[project_permission_key_cloud_fk_deploy]]`).
- Named gates `Gates.vanManage` and `Gates.vanSell`, cited from the UI, passing
  the membership and static-ban tests. No bare `hasPermission`.
- Role display order stays tier-ordered (CEO → Manager → Cashier → Stock keeper →
  Driver), never alphabetical.

---

## 11. Crate shells — the memo seam (v1)

**What v1 does**: counts. `shells_out` on load lots and the trip, `shells_back`
on return events, surfaced on the reconcile screen before close ("loaded with
100 shells, 65 came back") and on the driver profile's crate-tab seam. The
terminal states the operating rule: **swap-only — no deposit sales on the road.**

**What v1 deliberately does not do**: no deposit money, no `crate_ledger` writes,
no crate-pool balance changes. Counting only, so the later crate pass inherits
history instead of starting blind.

**Why it is in v1 at all**: a 100-crate load carries ~₦180,000 of deposit-value
shells. Without the memo a trip closes "balance 0 = settled" having lost every
shell, and the data to reconstruct it never existed. The memo is cheap and it
preserves history.

The full pass — van crate cargo, deposits on the road, valuing shell loss at the
manufacturer deposit rate inside `computeVanTripPosition` — is **Van Sales v2**,
filed as its own issue and cross-linked from #139. The walk-in same-time-exchange
question (crate audit §B4) must be resolved before that pass, since every van
customer is a walk-in.

---

## 12. Offline and sync

- Fully offline-first through the existing outbox. A van is single-device, so
  there is no concurrent-till oversell on van stock.
- Every new table = **one** `SyncedTable` registry entry + golden-test literals +
  a cloud migration that re-declares `pos_pull_snapshot`'s table array.
- `driver_ledger_entries` is append-only: `scrubCreatedAt: true`, immutable +
  no-delete triggers, void by compensating row.
- Every synced write sets `id` and any DB-defaulted column explicitly
  (`[[project_synced_write_explicit_id]]`).
- RLS uses `current_user_business_ids()`, never an inline `user_businesses`
  subquery (`[[reference_new_synced_table_rls_pattern]]`).
- All `*_kobo` cloud columns are `bigint`.
- Migration numbers are reserved late, per the cross-branch collision convention.

---

## 13. Testing seams

No new seams are invented; these are the plan's own plus existing suite patterns.

1. **`computeVanTripPosition`** — pure, no DB, no widgets. Exhaustive fixtures:
   balance, the three-way breakdown, per-product shortage, lot-cost COGS,
   dual-valued write-offs, shell counts, and the `outstanding == −balance`
   tie-out. Prior art: `test/dashboard/recon_data_test.dart`.
2. **DAO/service + in-memory Drift** (`bootstrapTestDb()`): dispatch (batch
   draw-down + lot snapshot + ledger debit + idempotency), returns (re-batch at
   snapshot cost, forced-count semantics, two-price FIFO), remittance (ledger
   credit + payment row), close (persisted artifact), late-sale restatement.
   Prior art: the costing, wallet and rejected-sale suites.
3. **Reconciliation compute function** — van exclusion predicate, "Cash from
   drivers", closed-trip P&L contribution, open-trip caveat, All-Stores worth
   treatment.
4. **Cloud Transport fake** — trip-tagged sale envelopes, held/release
   behaviour, the close-vs-pending-outbox warning state. Prior art:
   `test/sync/`.

Two claims get explicit tests because they are the ones most likely to rot:

- **Two-van determinism**: interleaved loads and closes over one product yield
  identical per-trip COGS regardless of close order.
- **Backfill/recost fences**: a 0→real cost transition gathers no van lines; the
  recost replay skips van stores.

---

## 14. Naming collision — the dormant legacy tables

`drivers` and `delivery_receipts` already exist in the schema (registered for
sync, in `pos_pull_snapshot`, with **no DAO, no provider and no UI**). They are a
different axis entirely: a van-sales driver is a `users` row with the Driver
role, not a `drivers` row.

**Decision**: leave them untouched and **ignore** them. The prefactor's migration
notes state this explicitly so no future reader assumes `van_trips.driver_user_id`
should have pointed at `drivers`. Retiring them is a separate dead-code sweep,
not van-sales work.

---

## 15. Slice map and dependency order

The original order (`#140 → #141 → #142 → {#143,#144} → #145 → #146 → #147`)
leaves three windows where real money is untracked or misreported. The safe
order, adopted by #161:

```
#140  prefactor — van kind, exclusion predicate, Driver role, gates, spec + ADR
  ↓
#141  load a van — trip, priced lots WITH cost snapshot, ledger debit, shells_out
  ↓
#144  driver payments — ledger credit + van_remittance payment row
  ↓
#142  driver terminal — trip-tagged sales, NO payment row, backfill/recost fences
  ↓
#143  restocks & returns — FIFO credit, re-batch at cost, forced count, shells_back
  ↓
#145 + #147  (ship adjacent) reconcile & close artifact  +  rollup reporting
  ↓
#146  driver profile + Drivers list
```

Why the moves:

- **#144 before #142** — the remittance leg must exist before road sales stop
  writing payment rows, otherwise there is a window where cash enters the books
  nowhere at all.
- **Exclusions in #140/#142, not #147** — otherwise five slices ship with road
  revenue inflating All-Stores figures at zero cost.
- **#145 and #147 adjacent** — the close artifact and the report that reads it
  are one change split across two issues; shipping them apart means a period
  where profit is persisted and invisible.

---

## 16. Out of scope (v1)

- Van crate cargo and deposit settlement → **Van Sales v2** (memo counts only in
  v1, §11).
- Manufacturer deposit settlement (the app-wide deposit outflow leg) — its own
  small PRD, sequenced before or with the van crate pass.
- Registered/credit customers on the van, discounts at the terminal, capturing
  the driver's above-load markup, multi-warehouse trips, iOS.
- Store-side money fixes — PRD #155 owns compensating payment records, the day
  close, and batch coverage for non-van flows; PRD #156 owns the crate pool. Van
  Sales builds on both and duplicates neither.
