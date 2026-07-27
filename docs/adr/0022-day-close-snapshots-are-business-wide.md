# A day close is one business-wide record, not one per store scope

**Status:** accepted (2026-07-27) — supersedes the store-scope half of ADR 0021 §2
("Day-close snapshot landed by #174": *"plus the captured store scope"* and
*"only when the current store scope matches the captured scope"*). Everything
else in that section still stands.

#174 froze a reviewed day as a synced `daily_closings` row, keyed
`(business_id, business_date)` and **first-writer-wins**. But the figures it froze
were computed in whatever **§12.1 active store scope the first opener happened to
be locked to**, the opener's lock was stamped into `store_scope_id`, and the delta
badges + reviewed banner rendered **only while the viewer's scope still matched
that captured scope**.

Those three facts contradict each other. The key has no store in it, so a day can
hold exactly ONE snapshot — and whichever scope opened the day first therefore
decided, permanently, what that day's baseline meant. Every other scope got no
baseline at all: no banner, no badges, the day reading as never reviewed. A
business-wide baseline could never be captured afterwards, because first-writer-wins
refuses to overwrite.

This had already happened in production: the single existing `daily_closings` row
carries a non-null `store_scope_id`, so for that business a CEO viewing **All
Stores** saw nothing for that day, forever — the exact silent-history-mutation
blindness #174 existed to remove (US 17/18/19 held only inside the accidental
capture scope). Found by the #155 close-out audit; filed as #191.

## Decision

**The frozen figures are always BUSINESS-WIDE, and the comparison is business-wide
on both sides.** A persisted day close is one durable record of what the whole
business's day looked like. Concretely:

1. **Capture ignores the viewer's scope.** `computeReconData(businessWide: true)`
   ignores both the active store lock and a confined Manager's store set (via
   `reconStoreFilter(businessWide: true)`), and reads the **unscoped** stock
   totals. Whoever opens the finished day first freezes the same figures, so
   first-writer-wins is no longer a lottery. Vans stay excluded — business-wide is
   not "vans too" (van-sales spec §8.1).
2. **The comparison is ungated.** `reconClosingComparisonOrNull` compares the
   snapshot against the **business-wide** live figures at every viewing scope, so
   the reviewed banner and the delta badges show whatever store is locked. The
   store-scoped card figures are unchanged (§12.1): a locked store still reads its
   own day; the badge discloses that the **day** moved after it was banked
   against.
3. **`store_scope_id` is legacy: always written NULL, never read.** The column
   stays on both schemas (no Drift `schemaVersion` bump, no cloud migration): a
   non-null value is a pre-#191 row and is read as business-wide too. That is what
   makes the fix retroactive — the existing production row starts showing its
   banner and badges at All Stores with **no data change**.

The rejected alternative was adding `store_scope_id` to the natural key (one
snapshot per business × day × scope, with the scope in the deterministic id and a
widened cloud unique index). It is more faithful to per-store review, but it
multiplies the record, needs a cloud migration, and still leaves "which scopes
were ever opened?" deciding what history exists. "One durable record of what the
day looked like" is the property #174 was for.

## Consequences

- **Accepted residual:** the one pre-#191 production row froze a single store's
  figures, so its badge now discloses the difference against the business-wide day
  — a "look again" nudge rather than silence. It cannot be re-frozen
  (first-writer-wins), and it is not worth a destructive production write to
  repair; every subsequent day is business-wide from the start.
- A finished Day bucket runs the reconciliation aggregate **twice** (viewer-scoped
  for the cards, business-wide for the day close). Week/month/year buckets and the
  current day are untouched, and both passes are over already-in-memory rows.
- A confined Manager who opens a finished day first now freezes figures covering
  stores they cannot see, and their banner reflects business-wide movement. That
  is the price of a single comparable baseline; no per-store figure is exposed on
  screen.
- **Known cousin, not fixed here (#192's neighbourhood):** the capture still
  passes the viewer's `isCeo`, which gates the supplier-ledger flows, so a
  Manager-captured snapshot freezes a different `netCashMovement` /
  `stockExpectedClosing` basis than a CEO-captured one. The frozen record should
  be opener-independent in role terms too.

## Invariants that still bind

Purely observational — no money flow or existing figure changes. Natural-key
first-writer-wins and the deterministic id are untouched, so offline devices still
converge on one row; the push stays a complete-payload upsert with an explicit
`id` and every DB-defaulted column. Kobo columns stay `bigint` on the cloud. One
`SyncedTable` entry, unchanged. Migration numbers are reserved late — this ADR
needs no migration at all (ADR 0018 push / 0019 van were reserved on unmerged
branches, so this is **0022**).
