# ADR 0028: Count-Based Crate Shortage Warning

**Status:** accepted (2026-09-23)  
**Context:** Issue #293, PRD #284 (§6 & §7)  
**Amends:** ADR 0023 (§4 & §5)

---

## Context

Prior to this decision, crate tracking lacked a mechanism to verify physical empties against the running derived ledger except by trust. When counts were performed, a gap between expected empties and counted empties was ambiguously characterized in early docs (e.g. ADR 0023) as "crates owed minus empties on hand", conflating supplier settlement balances with warehouse physical inventory gaps.

PRD #284 (§6 & §7) establishes the canonical lifecycle for manufacturer empty crates, making physical counting a first-class operation directly from the `ManufacturerScreen` and defining precisely how count discrepancies translate into a **Crate Shortage** warning.

---

## Decision

### 1. Shortage is Strictly Count-Based

A **Crate Shortage** is derived solely from physical count corrections (`recordManualCountCorrection`). It reflects missing physical empties discovered during a warehouse count relative to the derived expected balance (`expectedEmptiesAt`).

### 2. Chronological Per-(Manufacturer, Store) Shortage Fold

Shortage is tracked per `(manufacturer, store)` by folding crate count movements chronologically:
1. **Opening Count sets the baseline:** The first count at a store is recorded as an `opening_count`. It sets the initial baseline balance and raises **zero** shortage (`shortage = 0`).
2. **Count below expected opens shortage:** Any subsequent count where `counted < expected` (`quantityDelta < 0`) increases the open shortage by the gap (`-quantityDelta`).
3. **Count above expected closes shortage first (Unbanked Surplus):** Any count where `counted > expected` (`quantityDelta > 0`) reduces any open shortage. If the surplus exceeds the open shortage, the excess surplus is **not banked** — it clamps to 0 and cannot offset future shortages.
4. **All Stores is the sum of open store shortages:** For an All Stores view, the business-wide shortage is the sum of open shortages across all stores (`Σ store shortages`). Surplus in Store B never nets out or conceals a shortage in Store A.

### 3. Shortage is a Warning, Not a Financial Loss

A Crate Shortage is a warning of missing physical inventory valued at:
$$\text{warning value} = \text{short crate count} \times \text{manufacturer crate value}$$
It is not an immediate financial debit, loss, or expense. It moves no cash, alters no supplier balances, and leaves customer held deposits untouched. Writing off missing crates is a separate, deliberate management action.

### 4. Shortage Applies to Arrangement-Off (Swap-Only) Brands

Shortage tracking applies equally to manufacturers with `crateMoneyArrangement == 'none'` (swap only) as well as deposit-bearing brands. Even when no monetary deposit is traded with suppliers, missing crates represent physical asset losses and operational risk that must be surfaced to the business.

### 5. Count Sheet UI & Store Scoping Invariants

The `CountManufacturerEmptiesSheet` on `ManufacturerScreen`:
- Displays expected empties derived from the ledger (`expectedEmptiesAt`).
- Prompts for what was counted (never the difference).
- Displays the live difference and its warning naira value before saving:
  - Short: *"This is what will be recorded: N crates short (₦X warning value)"*
  - Surplus: *"This is what will be recorded: N crates surplus"*
  - Match: *"This is what will be recorded: No difference"*
- Employs `crateCountStoreWithoutAsking`:
  - On single-store businesses or store-locked sessions, the store is preselected with no store picker prompt.
  - In All Stores on multi-store businesses, the user must explicitly pick a store before recording.
- Rejects negative or non-numeric counts and prevents saving when invalid.
- Cancel dismisses the sheet and writes nothing.

### 6. Named Gate Access Control

Counting crates is protected by `Gates.countCrates`, keyed to the permission `stock.view`. This permits Cashiers and Stock keepers to perform physical counts, while revoking `stock.view` hides the count action.

### 7. Write-off and Reverse write-off (amended 2026-09-30, #296)

- **Write off** reduces a store's open shortage and books a loss on the day it is taken, at the crate value **snapshotted** on the `crate_shortfall_writeoffs` row (source `count_shortage`, store-stamped). It is capped at the open shortage, re-read inside the write's transaction, so the same crates can't be written off twice from two screens. It books for every brand, whatever its Crate Money Arrangement. It moves no cash and no crates.
- The write-off joins the time-ordered fold: it lowers open shortage (floored at 0) and becomes an outstanding write-off.
- **Reverse write-off** is for written-off crates that a later count found. That count's surplus beyond the open shortage becomes *reversible*, up to the crates still written off; a later short count takes it back out of reach. A reversal writes compensating **negative** `count_shortage` rows, newest write-offs first, each at the rate that write-off was snapshotted at — so the gain equals the loss it gives back. The gain is booked on the day of the reversal, never on the write-off's day. A reversal never reopens a shortage.
- Rows from the two tables that share a `created_at` second are ordered by their UUIDv7 id (millisecond).
- **Daily Reconciliation's "Crates missing"** shows this same figure, read through the same per-brand fold, in the same store scope as the manufacturer screen, and uses the same write-off sheet. The depot-gap Crate Shortfall (owed − on hand) is retired: it is no longer shown or write-off-able anywhere (ADR 0023 rule 5 amended).
- The older `manual` (depot-gap) and `customer_forfeit` (#217) write-offs are not events in the fold and never net against the shortage. They stay booked on their own days.
- Gate: write-off and reversal use `Gates.confirmCrateDeposit` (CEO, Manager), hidden for everyone else.

---

## Consequences

- Business owners and managers receive immediate, accurate visibility into empty crate discrepancies on the `ManufacturerScreen` Short status card and the `InventoryScreen` brand cards (`⚠ N short` badge).
- Physical counting is decoupled from financial settlement; unbanked surplus guarantees historical discrepancies are never masked by subsequent inventory inflows.
- Multi-store isolation is strictly preserved.
