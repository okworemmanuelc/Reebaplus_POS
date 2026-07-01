# Brief — Sync Data-Safety & Efficiency ("the outbox is sacred")

**Audience:** the developer/agent implementing this work.
**Status:** PRD / handoff brief — converged via a grilling session (2026-06-30). Read top to bottom before writing code.
**Triage:** ready-for-agent.
**Goal in one sentence:** make offline activity **impossible to lose silently** and stop the
app **re-downloading the whole store on every launch**, so sync is safe *and* efficient
even on zero/low internet.

---

## 0. Read these first (non-negotiable)

This is a mature, spec-driven, local-first codebase. Do **not** invent patterns. Read, in order:

1. `context/project-overview.md`
2. `context/architecture.md` — stack, storage model, **Invariants** (this brief adds Invariant #12)
3. `context/ui-context.md` — the design-token system
4. `context/code-standards.md`
5. `context/ai-workflow-rules.md`
6. `context/progress-tracker.md` — update after every unit
7. `CLAUDE.md` at repo root

**House rules that will bite you:**
- Runs on an **emulator / `flutter run`**, never `flutter build apk`.
- **Never `git checkout` a dirty file** — re-edit or stash. Do not run `dart format` globally.
- Styling routes through the token system. No raw colours / radii / pixel sizes.
- New synced behaviour must be wired at **every** per-table apply site (see the memory note
  "New synced table: wire ALL client apply sites").

---

## 1. Problem Statement

Two user-reported symptoms, one shared root:

1. **Slow sync.** On some businesses the app re-downloads and re-writes the *entire* dataset on
   nearly every launch. The slow part is not bandwidth — it is the sequential local restore of
   thousands of rows.
2. **Silent offline data loss.** After activity with little/no internet, "the data disappears
   completely." Confirmed by the owner across **all** data kinds: held/parked carts, completed
   sales, offline edits, and stock.

### Root causes located (file:line)

| # | Vector | Mechanism | Evidence |
|---|---|---|---|
| **A** | Forced full-pull loop (slow) | Any deferred/FK-skipped table **clears the per-business cursor**, so the next pull runs `since==null` and re-restores everything — every launch, for any business with a chronic FK-skip. | `supabase_sync_service.dart` ~L1992–2009 (`prefs.remove(key)`) |
| **B** | Reconcile wipes un-uploaded rows | `_reconcileHardDeletes` runs on **every** full pull and deletes local rows of `{role_permissions, user_permission_overrides, store_role_permissions, user_stores, saved_carts, notifications}` whose id is absent from the cloud snapshot — **including offline-created rows not yet pushed**. Never consults the outbox. | `_reconcileHardDeletes` ~L2472; gate ~L2436 |
| **C** | Stale cloud overwrites offline edit | LWW guard resolves ties **cloud-wins** (`incoming >= local`). An offline edit survives only if its write bumped local `last_updated_at`; tables without a bump (e.g. `businesses`) get **silently clobbered** on the next full pull. | `_filterByLwwGuard` ~L3598 |
| **D** | Pull-before-push ordering | Connectivity-recovery, pull-to-refresh, and login call `pullChanges` directly (not `syncAll`), so a reconcile/restore can run **before** the offline outbox drains, widening the loss window. | `_onOnlineChanged` ~L320; `syncAll` ~L1821 |
| **E** | Wipe with pending writes | The **only** path that destroys a committed `orders` row is `clearAllData`. Four callers; only `logOutCurrentUser` guards pending writes, and it does push-**then**-wipe (a partial/failed push still wipes the remainder). | `auth_service.dart` L780, L833, L1018, L1089 |
| **F** | Uploader silently drops items | An item should leave the outbox only by **uploading** or by moving to the visible orphans list. Past dedup/coalescing/`resetStuckInProgress` collisions show a third, silent path is possible → "fails to sync correctly." | memory: sync-reset-dedup, sync-retry-hardening |

These compound: **A** forces the full pulls that fire **B** and **C**; **D** widens the window;
**E** is the catastrophic full-wipe; **F** loses data before it ever leaves the device.

---

## 2. Solution — the load-bearing invariant

> **Invariant #12 — The outbox is sacred.** A local row that has an unconfirmed `sync_queue`
> **or** `sync_queue_orphans` entry is **inviolable**: no pull, reconcile, restore-overwrite, or
> `clearAllData` may delete or overwrite it until its push is **confirmed by the server**.
> *Sacred means never destroyed silently — not frozen forever.* Un-pushable data must remain
> **visible and exportable**, and may leave the device **only** by a deliberate, confirmed user
> action.

Every fix below is an *enforcement* of this one rule. Add it to `context/architecture.md`.

### The enforcement primitive (settled by the schema — do not redesign)

`sync_queue` encodes the table in `action_type` (`'<table>:upsert'` / `'<table>:delete'`) and the
row id in `payload->>'$.id'`, with a `business_id` column. So a cheap, exact, one-query-per-table
helper gives the set of **un-uploaded ids**:

```sql
SELECT json_extract(payload,'$.id') FROM sync_queue
  WHERE business_id = :biz AND action_type = :table || ':upsert' AND status != 'completed'
UNION
SELECT json_extract(payload,'$.id') FROM sync_queue_orphans
  WHERE business_id = :biz AND action_type = :table || ':upsert';
```

Expose this as `SyncDao.pendingRowIds(table, businessId)` (or a batched `pendingRowIdsFor(tables)`).
Both outbox tables count — an orphan is still un-uploaded local data the invariant protects.

---

## 3. Implementation Decisions

### Bucket 1 — DATA SAFETY (ship first, verify, then Bucket 2)

**3.1 Wipe gate (E).** Gate every `clearAllData` caller on an empty outbox (pending + orphans):

- **Salvageable wipes** (`logOutCurrentUser`, any future switch-user wipe): if the outbox is
  non-empty —
  - *online:* push-and-**confirm the queue is empty** first (E3). If it drains clean, proceed.
  - *still non-empty* (offline, or rows that won't push): **refuse** the wipe (E1). Keep the user
    logged in. Message: *"You have N unsynced sales. Connect to the internet to sync before
    logging out."*
- **Two-tier resolution** (answers the "synced fine for a long time, then the cloud profile
  changed and it won't sync" deadlock):
  - *retryable* rows remain (transient) → **refuse**; resolves itself on reconnect.
  - *un-pushable* rows remain (orphaned — cloud is actively rejecting: 42501 / P0001 / auth-uid
    drift) → **do not trap.** Route to a **"Resolve unsynced data"** flow: **export** the stuck
    sales as a printable / CSV record (money recoverable on paper) → **typed-confirm discard** →
    then allow logout.
- **Business-deleted wipes** (`wipeOrphanedLocalBusiness`, `_handleActiveBusinessDeleted`,
  `deleteBusinessAndAccount`) — the **only** carve-out, because the business no longer exists in
  the cloud and the data is unsalvageable. Proceed with the wipe, but **write an
  `error_logs`/diagnostic breadcrumb recording the lost count** so it is never silent.
- **Proactive sync-blocked detector:** when pushes begin failing with identity/RLS permanent
  errors, flag the business **"sync blocked — this device's access changed"** and surface the
  export action **immediately** (elevate the existing **Sync Issues** screen from operator-only
  to user-visible), instead of looping retries for days.

**3.2 Reconcile exclusion (B).** `_reconcileHardDeletes` deletes a local row only if its id is
**absent from the cloud snapshot AND absent from `pendingRowIds(table, businessId)`**. Additionally,
only reconcile a table whose slice is **known-complete** (came from a full paginated pull / RPC that
fetched all pages) — never from a possibly-truncated slice (a present-but-short slice must not be
read as "the rest were deleted").

**3.3 Clobber prevention (C).** In `_restoreTableData`, before applying a table, load
`pendingRowIds(table)`. **Any local row with a pending entry is never overwritten by an incoming
cloud row, regardless of timestamp.** The existing timestamp-LWW (`incoming >= local`) is demoted to
a **tiebreaker for non-pending rows only**. Same-second cross-device ties stay **cloud-wins**
(unchanged). Separately, add a **`last_updated_at`-bump audit** across DAO write paths as *hygiene*
— but correctness no longer depends on it.

**3.4 Upload-before-download (D).** On reconnect, pull-to-refresh, and login, **push the outbox
first, then pull.** With 3.3 in place this is no longer required for safety; it avoids wasted
back-and-forth. Keep `pullChanges` callable standalone (the guards make it safe either way).

**3.5 Uploader check-up (F).** Enforce the **two-ways-only rule**: a row leaves `sync_queue`
**only** by (a) confirmed upload (`markDone`) or (b) moving to `sync_queue_orphans` (visible) —
**never silently.** Audit every leave-site: coalescing/dedup, `resetStuckInProgress`, `markFailed`,
`_healOrderNumberCollisions`, and any `status` flip. Add a lightweight **self-count check** that
notices unexplained shrinkage of the outbox between drains and records a breadcrumb.

### Bucket 2 — EFFICIENCY (ship after Bucket 1 is verified)

**3.6 Per-table backfill cursors (A1).** Replace the single "clear the whole cursor on any defer"
behaviour: the global cursor advances on clean pulls; **deferred tables are recorded individually**;
the next pull runs `since == null` for **only those tables** and stays incremental for the rest. The
large tables (`orders`, `order_items`, ledgers) are never re-pulled merely because `categories`
deferred. Preserve the catch-up guarantee for exactly the tables that need it (the reason the cursor
was cleared in the first place — see the L1992–2009 comment).

**3.7 Targeted parent fetch (A2).** When a child FK-orphans on `parentId = X`, fetch **just that
parent row by id** within the existing page loop, insert it, and retry the child — no full re-pull.
Opportunistic refinement for the common inline-created supplier/category/manufacturer case; it must
stay inside the page loop and must not add unbounded round-trips on a flaky link.

---

## 4. Testing Decisions

**Automated first, then a scripted manual on-device checklist.** Lead with one
**failing-today / passing-after** automated test per vector, at the sync engine's existing seams
(`restoreTableDataForTesting`, `reconcileHardDeletesForTesting`, `deleteLocalRowByIdForTesting`, plus
a new seam for the wipe-gate and the per-table-cursor logic). Assert behaviour at the seam, not pixels.

- **E (wipe gate):** outbox non-empty + offline ⇒ wipe refused; un-pushable orphans ⇒ export +
  typed-discard path unlocks the wipe; business-deleted ⇒ wipe proceeds **and** a loss breadcrumb is
  written.
- **B (reconcile):** a local row with a pending outbox entry **survives** a full-snapshot reconcile
  that omits it; a genuinely cloud-deleted row (no pending entry) is still removed; a truncated slice
  does **not** trigger deletions.
- **C (clobber):** local row with a pending edit + an older/equal incoming cloud row ⇒ local
  **survives**, regardless of `last_updated_at`; non-pending rows still follow timestamp-LWW.
- **F (uploader):** every leave-site ends in `markDone` **or** an orphan row — never a silent drop;
  the self-count check fires on injected shrinkage.
- **A1/A2:** deferring `categories` re-pulls only `categories` next time (big tables untouched); an
  FK-orphan triggers a targeted parent fetch + child retry within one pull.

Manual checklist (final confidence): go offline → ring sales, edit a price, park a cart, adjust
stock → reconnect → confirm everything survives and uploads; force a sync-blocked state → confirm
export + discard works and logout is never trapped.

---

## 5. Out of Scope

- **Auth identity-drift self-healing.** The sync-blocked detector *detects + exports*; it does **not**
  attempt to re-bind `auth_user_id` / repair membership (a separate auth bug class — see the memory
  notes on `auth_user_id` clobber and the 42501 business-isolation work).
- **Schema/DAO business-logic redesign**, pull ordering, RLS, and the `pos_pull_snapshot` contract —
  unchanged except where 3.x explicitly touches restore/cursor mechanics.
- **The first-load "Loading your store" overlay** (`brief-first-load-store-overlay.md`) — complementary
  and already in flight; this brief is the underlying correctness/efficiency work its §6 flagged as
  out of scope.
- A runtime on/off feature flag — these are corrections, not experiments.

---

## 6. Sequencing & Rollout

One working branch, **staged** commits, each independently verifiable:

1. **Bucket 1 (data safety)** — 3.1 → 3.5, smallest-first, automated tests per unit, then the manual
   checklist. Trust in the field before touching Bucket 2.
2. **Bucket 2 (efficiency)** — 3.6 → 3.7, lower risk, behind the now-hardened safety net.

Update `context/progress-tracker.md` after each unit and add a dated `BUILD_LOG.md` entry once landed
(per the memory note "Log working fixes to BUILD_LOG").

---

## 7. Further Notes

- Confirm the **exact `clearAllData()` call sites** are all routed through the new wipe gate before
  relying on it — a missed caller re-opens vector E (the catastrophic one).
- The reconcile completeness guard (3.2) matters: a server-side cap/timeout that silently returns a
  short slice must never be read as "these rows were deleted."
- Keep the **Sync Issues** screen the single home for un-pushable data — export, retry, and the
  typed-confirm discard all live there.
