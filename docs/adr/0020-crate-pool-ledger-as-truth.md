# The crate pool is ledger-as-truth behind one write seam

**Status:** accepted (2026-07-22)

The empty-crate pool is recorded in **three representations that no single write
path keeps in step**: the append-only `crate_ledger` / `supplier_crate_ledger`,
the four balance caches (`customer_crate_balances`, `manufacturer_crate_balances`,
`store_crate_balances`, `supplier_crate_balances`), and the
`manufacturers.empty_crate_stock` scalar. Worse, the running balances sync
between devices as **absolute "the count is now N" rows** (`isCache` LWW), so a
late-arriving row silently overwrites another device's work. Two offline tills
that both move the same brand's crates permanently lose one till's activity when
they reconnect. The counts drift, never self-correct, and disagree across the
Crates tab, a locked store's view, and the customer/supplier records. The
append-only ledger that *could* be the single truth exists but is treated as
secondary. (Full analysis: `CRATE_TRACKING_AUDIT.md`; PRD #156.)

The customer wallet already solved exactly this problem in this codebase:
`getWalletBalanceKobo` **derives** a balance by summing signed, append-only
ledger rows and cancels voided rows with compensating entries — never storing or
shipping a mutable total, so it is conflict-free under sync (architecture
invariant #3).

## Decision

**The crate ledger is the one source of truth; every balance is derived, never
stored or shipped as an absolute total.** Every crate balance the app shows —
business empties on hand (per manufacturer), per-store empties, a customer's
crate debt, a supplier's crate debt — is `SUM(quantity_delta)` over the relevant
append-only ledger rows. The balance caches and the `empty_crate_stock` scalar
stop being independently authoritative: they are replaced by live sum queries or
demoted to local-only projections rebuilt from the ledger after each pull. The
hard contract is: **no crate balance is ever pushed to the cloud as an
absolute-value row — only append-only ledger rows sync.** This is the change
that removes the last-write-wins data loss by construction (two devices' ledgers
merge; there is no absolute-value row left to overwrite).

**One write seam — the Crate Pool module (`CratePoolDao`, in
`lib/core/database/daos_crates.dart`; it absorbs the former `CrateLedgerDao`).**
Every write that moves a crate routes through it as a domain verb
(issue-to-customer, return-from-customer, receive/return-supplier, record-damage,
transfer-between-stores, reverse-order-issuance, record-manual-count-correction,
add-empties-to-pool). Each appends a correctly-signed, store-stamped, append-only
ledger row in one transaction and enqueues it to the Outbox. A `crate_seam_ban_test`
fails the build if any crate-table write (or an `empty_crate_stock` mutation)
appears outside the seam, so a new surface (a report, a van, a screen) has exactly
one place to call and cannot reintroduce the drift.

## Rejected alternatives

- **Server-authoritative deltas** — keep the cache tables and route crate
  movements through a guarded relative-decrement RPC (mirroring
  `pos_record_sale_v2`). This still ships totals and keeps three representations;
  it narrows the race window but leaves the drift surface. Rejected: it treats the
  symptom (the LWW push) without making the ledger the truth.
- **Minimal fix** — keep the three representations and schedule the existing
  `verifyCrateReconciliation` nightly. Rejected: reconciliation papers over a
  model with three sources of truth; it will drift again between runs, and the
  reconciler has no authority to decide which representation is right.

## Rollout (this is a multi-slice refactor)

- **#157 (this slice) — prefactor, behavior-preserving.** Introduce the seam and
  make the ledger *complete* (every movement, including a manual "set to N" as a
  reconciling delta row and a store-less `addEmptyCrates`, appends a row). The
  caches are still written exactly as before, so nothing the user sees changes. A
  migration seeds one opening-balance ledger delta per existing cache balance so
  `SUM(quantity_delta)` equals today's displayed number at cutover — without it
  the later derive slices would zero out every existing business's counts. Opening
  rows are **local-only** (every device seeds from its own caches; pushing them
  would double-count).
- **#158 (DONE 2026-07-23)** — customer crate debt derived from the ledger. The
  Crates-tab read (`CratePoolDao.watchCustomerCrateDebt`, forwarded from
  `CustomersDao.watchCrateBalancesWithGroups`) is `SUM(quantity_delta)` over the
  customer's `crate_ledger` rows grouped by manufacturer, wallet-style. The
  `customer_crate_balances` cache is demoted to a **local-only projection** (still
  written by the seam, no longer enqueued), so only append-only ledger rows sync
  for customer crates and two offline tills converge instead of clobbering.
- **#159 (DONE 2026-07-23)** — the PHYSICAL empties pool (business-wide +
  per-store) derived from the ledger. New `CratePoolDao.watchEmptiesPoolByManufacturer({storeId})`
  is `SUM(quantity_delta)` over the store-stamped, customer-less physical-pool
  rows (`store_id IS NOT NULL AND customer_id IS NULL`); grouping by store gives
  the per-store figure, so the business total always equals Σ store totals by
  construction. `InventoryDao.watchEmptyCratesByManufacturer` / `watchTotalCrateAssets`,
  `storeCrateBalancesProvider` / `storeEmptiesByManufacturerProvider`, the
  Inventory Crates tab, and the product-detail read all forward to it. The
  `manufacturers.empty_crate_stock` scalar is DEMOTED off the push set (a new
  `manufacturers` push-column whitelist that excludes it), and `store_crate_balances`
  stops enqueuing — both become local-only projections (restore-on-pull retained,
  values unread). This kills the counter-only-grows asymmetry (a `returned`
  store-stamped row now pulls the pool down) and the cross-store clamp drift on a
  damaged-empty. The dead `verifyCrateReconciliation` (no callers, print-only) is
  removed — the ledger IS the truth, nothing left to reconcile.
- **#160** — derive supplier + `manufacturer_crate_balances` from the ledger;
  demote those remaining caches.
- **#162** — Cancel appends compensating rows (no phantom debt; deposit reversed
  with a deposit-family reference type).
- **#163** — `businessNetPositionKobo` subtracts held customer crate deposits and
  supplier crate debt (honest in both directions), which is only trustworthy once
  balances are ledger-derived.

## Invariants that still bind

Kobo columns stay `bigint`; every crate write stays business-scoped; ledger rows
are append-only and go through the Outbox; a new/changed synced table is one
`SyncedTable` entry; migration numbers are reserved late (ADR 0018 push /
0019 van were reserved on unmerged branches, so this is **0020**).
