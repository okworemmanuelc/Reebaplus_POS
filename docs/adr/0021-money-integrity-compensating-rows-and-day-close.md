# Money corrections are compensating rows; a reviewed day is a persisted snapshot

**Status:** accepted (2026-07-24)

The shop owner cannot follow their money because the app's money records and the
physical reality drift apart during normal use, with no durable trace of when or
why:

- A refund makes cash leave the till **today**, but the app records nothing
  today — it voids the original sale's payment row in place, silently shrinking a
  past day the owner may have already reviewed and banked against. The
  reconciliation's "Refunds" figure reads an order status nothing ever writes, so
  it shows ₦0 forever.
- Rejected and deleted expenses keep draining cash forever because their payment
  records are never reversed; a mistyped customer repayment can only be
  "corrected" by fabricating an offsetting sale.
- Every past day's report is **recomputed live** and mutates under late syncs,
  cancels, and backdated entries, with no record that it changed.

The full evidence trail is `MONEY_FLOW_AUDIT.md` (§8 Alternatives A/B/C, §10) and
its crate companion `CRATE_TRACKING_AUDIT.md`; the parent PRD is #155.

The codebase already proves the fix elsewhere. The customer wallet and supplier
ledgers are **append-only**: a balance is derived by summing signed rows, and a
correction is a **new compensating row**, never an in-place edit (architecture
invariant #3). This makes those balances conflict-free under sync and gives every
figure a durable row to trace to. ADR 0020 extended the same discipline to the
crate pool.

## Decision

**1. Every money correction is a dated compensating `payment_transactions` row —
the payment ledger becomes append-only in practice.** Cancelling a sale, rejecting
or deleting an expense, and voiding a customer top-up each post a NEW reversal row
through one shared seam (`PaymentTransactionsDao.postReversalPayment`) instead of
mutating the original row. The seam:

- leaves the original row **untouched**,
- lands the reversal on its **own `created_at` day** (the correction day),
- copies the original's single typed reference (order / shipment / expense /
  wallet_txn / delivery) so the exactly-one-reference CHECK holds, and
- stamps a nullable `store_id`.

The legacy in-place void columns (`voided_at` / `voided_by` / `void_reason`) are
retained **read-only for rows written before this discipline**. Cash-flow
reporting counts every payment row on its **own `created_at` day** — so a
later-cancelled sale's cash stays on its original day and the cancel's refund row
lands on the cancel day. A day the owner already banked against never changes
behind their back, and the reconciliation's Refunds figure derives from real
refund rows rather than an order status.

This ADR (issue #169) is the **behavior-preserving prefactor**: it introduces the
seam and the schema/flag plumbing without changing any user-visible flow. The
correction paths are wired to call the seam in the follow-on slices.

**2. A reviewed day is a persisted snapshot (deferred to its own slice, decided
here).** The first time a permitted user opens a finished day's detail, the
computed figure set is frozen as a synced `daily_closings` row (one per business ×
calendar day, natural-key first-writer-wins). The report thereafter renders live
figures alongside the snapshot with a per-card delta badge when they diverge —
**silent history mutation becomes visible history mutation.** The snapshot is
purely observational; no money flow changes. This implements the option ADR 0014
deferred. (The table and UI land in a later slice; this ADR records the decision
so the prefactor's schema/sync groundwork is coherent.)

## Schema & sync plumbing landed by the prefactor (#169)

- `payment_transactions` gains a nullable `store_id`, stamped on all new rows
  (sale / expense / crate-refund paths + the reversal seam); legacy rows stay
  null and report business-wide as today. It joins the payment ledger's
  immutable-column set (fixed at insert).
- `orders` gains a nullable `confirmed_by` (unused until #171, which stops
  Confirm overwriting `staff_id` — keeping the sale attributed to the seller).
- The `payment_transactions.type` CHECK is widened (established
  constraint-migration pattern) to add a **deposit-distinct `crate_deposit`**
  type (unused until #175), so a refundable crate deposit can be excluded from
  "Cash sales".
- All `*_kobo` columns remain `bigint` on the cloud.
- `crate_ledger` and `supplier_crate_ledger` get the `scrubCreatedAt` registry
  flag **preemptively**, dropping `created_at` on every push so a future void
  re-push cannot trip the immutable-column trigger (P0001) and orphan the row —
  closing the trap before any crate-void feature ships.

Drift `schemaVersion` 63 → 64; cloud migration
`0153_money_integrity_payments_seam.sql`.

## Day-close snapshot landed by #174

The synced `daily_closings` table implements decision **§2** (the slice that ADR
deferred). One row per `(business_id, business_date)`, written the FIRST time a
permitted user (Manager+ via `Gates.dailyReconciliation`) opens a **finished**
calendar day's reconciliation detail:

- **Figure set (frozen).** The period-scoped figures the report cards headline —
  total sales, discounts, COGS, gross/net profit, expenses, damages, cash
  in/out/net-movement, cash sales, stock COGS, expected stock closing, items
  sold, shortage units (all `*_kobo` **bigint** on the cloud) — plus the
  captured store scope, the reviewer, and the review timestamp. The
  point-in-time "…now" figures (business worth, empties held, on-hand) are
  deliberately **excluded**: they are meant to reflect the present, so badging
  them against a past review would be noise. One mapper (`dailyClosingFiguresFrom`)
  defines *which* figures freeze, so the write and the delta badges cannot drift.
- **First-writer-wins.** The row id is **deterministic** (UUIDv5 of the natural
  key), so two devices mint the same id and converge. `snapshotIfAbsent` writes
  only when no snapshot exists (re-opening never overwrites), and the pull-side
  restore is **insert-or-ignore**, so the first snapshot a device knows about —
  locally written or pulled — is never clobbered by a later, divergent one.
- **Delta badge.** The detail screen renders live figures alongside the snapshot
  and shows a per-card "changed since review" badge on any card whose figure
  moved (`reconClosingComparison`), only when the current store scope matches the
  captured scope. An unchanged reviewed day shows no badge — silent history
  mutation becomes visible history mutation. Purely observational: no money flow
  or existing figure changes.
- **Residual (accepted).** An offline both-write race on the same day resolves
  last-write on the cloud upsert (the row is not a void-able ledger, so no
  immutability trigger — that would jam the outbox); each device still keeps the
  first snapshot it knows locally. Observational-only, so acceptable.

Drift `schemaVersion` → 70 (66–69 reserved for parallel money-integrity
branches; renumbered contiguous at merge); cloud migration
`0160_money_integrity_daily_closings.sql`. One `SyncedTable` registry entry
(`tenantScoped`, append/first-write-only — no `scrubCreatedAt`, no `hardDelete`).

## Consequences

- Money reports read like a ledger: every naira traces to a durable row, and a
  correction is a visible entry rather than a retroactive edit — disputes can be
  settled from the record.
- Reversals sync conflict-free (append-only, id-keyed), exactly like the wallet.
- The prefactor is inert on its own: no correction path calls the seam yet, no
  new type/flow is exercised, and no report reads `store_id` or `confirmed_by` —
  so the recon and payments suites stay green with identical figures.

## Alternatives rejected

- **A single money-events / full double-entry journal.** The long-term direction,
  but a large migration; this decision converges toward it (append-only,
  derived, compensating) without the rewrite. (PRD #155 "Out of scope".)
- **A counted cash drawer / opening float.** Hard Rule #8 stands; the fix makes
  the *recorded* flows complete and immutable instead of introducing a float.
