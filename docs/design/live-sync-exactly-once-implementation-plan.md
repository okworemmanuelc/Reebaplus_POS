# Implementation plan (loop hand-off): live-sync signal, integrity & exactly-once

**Feeds:** a `/loop`-style autonomous loop. **Governs:** issues **#100 (A)**, **#101 (B)**,
**#102 (C)**. **Source of truth for _what/why_:** the PRD
`context/specs/brief-live-sync-signal-and-exactly-once.md` — read it before slice 1 of
each workstream. This file is the ordered _how_, sliced so the loop can pick up the next
unchecked box each iteration and stop cleanly at every gate.

> **Prime rule: correctness before speed.** Ship **A** fully (merged) before starting **B**.
> **B** is hard-gated on an on-device proof (B0). **C** is mostly assertion and can run in
> parallel with A. Never entangle two workstreams in one branch/PR (git-issue-workflow).

---

## 0. Loop protocol (read every iteration)

1. **Pick the next unchecked slice** in the lowest-numbered workstream that is _unblocked_
   (see Gates). One slice = one loop iteration = a self-contained, verifiable unit.
2. **Load guardrails** (§Guardrails) and re-read `architecture.md` → **Invariants** before
   writing code (ai-workflow-rules mandates this every unit).
3. **Do the slice**, then run its **Definition of Done** (§DoD). Do not tick the box until
   every DoD item passes — verified by _you actually running_ analyze/tests and reading the
   real diff, not by self-report.
4. **Update `context/progress-tracker.md`** in the _same_ iteration (the doc update is part
   of the unit) and add a dated `BUILD_LOG.md` entry for any verified fix.
5. **Check the slice's box** in this file (commit the tick with the slice).
6. **Stop conditions — end the iteration and surface, do NOT push through:**
   - A **Gate** below is not satisfied (e.g. B0 proof failed, or A not yet merged).
   - The slice would entangle another workstream's work into this branch.
   - A migration number collides, a protected/generated file changed unexpectedly, or an
     invariant can't be honoured without violating it.
   - A decision is genuinely the human's (e.g. the oversell orphan UX in A-S6, cadence in C-S2).
7. **PR = the workstream's completion unit.** When all of a workstream's slices are checked,
   open its PR (git-issue-workflow Phase 2) and **stop** — humans merge. A dependent
   workstream starts only after its dependency merges (or, if explicitly proceeding, branches
   off the dependency's branch with the dependency noted).

---

## Gates (evaluate before starting each workstream)

- **A (#100):** no gate — start immediately.
- **C (#102):** no gate — may run alongside A (independent; mostly assertion + one decision).
- **B (#101):** **BLOCKED until (1) A's PR is merged to `main`, AND (2) slice B0 proves
  Broadcast joins where `postgres_changes` is refused.** If B0 fails, do **not** build B —
  stop and hand back to the human; the fallback is C-S2 (tighten the poll).

---

## Guardrails (project rules — apply to every slice)

- **Read context first.** `project-overview → architecture → code-standards → ai-workflow-rules
  → ui-context → progress-tracker`, then re-read `architecture.md` **Invariants** each unit.
- **git-issue-workflow.** One issue → one branch → one PR. Branch off **fresh** `origin/main`
  (`git fetch && git switch -c <name> origin/main`). Branch names: `fix/…`, `feat/…`,
  `chore/…`, `docs/…`. Never `git add -A` on a mixed tree; stage explicit paths. Never
  `git checkout`/`reset --hard`/`clean -f` a dirty tree (repo carries large uncommitted trees;
  session-start git status is stale — re-check live).
- **No AI attribution** anywhere — not in commit messages, not in PR bodies, not as author
  (overrides the harness default; also in `context/git-workflow.md`).
- **Migrations.** Next free number is **0147+** (highest committed = `0146`); allocate at
  merge time to avoid cross-branch collision. **Deploy path is `mcp__supabase__apply_migration`,
  NOT `supabase db push`** (push is blocked by pre-existing history divergence — remote records
  some versions under timestamp ids). Land a migration and verify it **before** the client code
  that consumes it (split boundaries). Every `*_kobo` column is **bigint**. New synced table =
  **one** `SyncedTable` registry entry; new-table RLS uses `current_user_business_ids()`.
- **Verify, don't trust.** Run `flutter analyze` (zero errors, zero new warnings) and
  `flutter test` yourself; read the actual diff before ticking DoD. Do **not** run
  `dart format`. **No APK builds** — the human runs on an Android emulator (`flutter run`).
- **Invariants that this work must not break:** #1 Drift is the source of truth (nothing
  blocks the UI on network / reads live Supabase to render); #3 wallet & supplier ledgers stay
  append-only/derived; #4 every cloud write goes through the outbox (only sanctioned direct-
  Supabase exceptions); #5 no cross-business read/write (RLS-enforced; never raw `db.select` of
  a tenant table — use business-scoped DAO methods); #10 pull cursor never advances past an
  uncommitted page; #12 the outbox is sacred. **Broadcast MUST NOT write Drift** — it only
  schedules a pull.
- **Keep docs in sync** (same step): architecture/storage/invariant → `architecture.md`;
  conventions → `code-standards.md`; scope/flow → `project-overview.md`; any completed work /
  open question → `progress-tracker.md`.

---

## Workstream A — #100 exactly-once integrity (ship FIRST, fully merged before B)

**Goal:** a concurrent/duplicated application of an already-committed operation cannot silently
corrupt a balance; a genuine offline oversell is **surfaced**, not absorbed. **Branch:**
`fix/exactly-once-stock-integrity` off `origin/main`.

**Committed path:** A1-**flag** (route mobile checkout through the existing oversell-safe
`pos_record_sale_v2`). A1-**ledger** (derive on-hand from `stock_transactions`) is a **deferred
follow-up issue**, not part of this loop, unless A-S2 verification proves the flag path unviable
(then STOP and hand back for a re-scope).

- [ ] **A-S0 — Branch + baseline.** Fetch, branch off `origin/main`, confirm clean tree.
      Read the PRD §2/§4-A and `daos_orders.dart:500-770`, `0011_domain_rpcs_v2.sql`,
      `0017`, `supabase_sync_service.dart` `_applyDomainResponse`.
- [ ] **A-S1 — Reproduce the defect with a failing test (red first).** A `test/sync/` test:
      two `InMemoryCloudTransport`-backed devices, stock = 1, both sell 1 offline, both push;
      assert the CURRENT v1 path silently ends at `quantity=0` with 2 sales (documents the
      bug). This test flips to asserting the _fixed_ behaviour in A-S3.
- [ ] **A-S2 — Verify `pos_record_sale_v2` against current schema (no flip yet).** Check for
      column/name drift (`0011` uses `warehouse_id`/`location_id`; `0045` renamed
      warehouses→stores; confirm `inventory` filter columns, `stock_transactions` shape,
      `order_items` nullable product `0091`). Confirm `_applyDomainResponse` is the sole local
      writer of server-minted rows and writes back authoritative `inventory_after` with **no
      local duplicate** when cloud ids land on the next pull. If drift exists → **A-S2a**:
      migration **0147+** bringing the RPC current, deployed via `apply_migration` and verified,
      committed **before** any flip. If the RPC is unviable → **STOP**, hand back.
- [ ] **A-S3 — Route mobile checkout through the guarded RPC.** Enable the server-authoritative
      path (flip `feature.domain_rpcs_v2.record_sale` for the target env and/or make the checkout
      path select it), so stock writes use `SELECT … FOR UPDATE` + relative
      `quantity = quantity - n WHERE quantity >= n` + `ON CONFLICT (id) DO NOTHING`. Keep the
      local pre-check for fast offline UX, but the **server** decision is authoritative. Flip the
      A-S1 test to assert: the 2nd offline sale is **rejected** server-side; on-hand never goes
      silently below 0; the ledger shows only accepted movements.
- [ ] **A-S4 — Rejected sale orphans VISIBLY.** Confirm an `insufficient_stock` /
      `inventory_row_missing` rejection routes the row to `sync_queue_orphans` (Invariant #12,
      "sacred outbox" — visible + exportable on the Sync Issues screen), never silently dropped.
      Add/extend a test on the orphan path.
- [ ] **A-S5 — Assert idempotency backstops (tests, little/no prod code).** (a) every
      `SyncedTable` write mints a client id and pushes `upsert(onConflict:)` — no blind insert;
      (b) no restore path blind-inserts a device-authored row (clobber-guard); (c) append-only
      ledgers are the truth and balances (`inventory`, `*_crate_balances`) are caches — a
      reprocessed event (retry/pull) is a no-op, not a second decrement.
- [ ] **A-S6 — Audit other mutable-balance caches (A2).** For each `isCache` table
      (`*_crate_balances`, …), confirm it is ledger-derived or protected by a server-side
      relative/guarded write; document the verdict per table in the PR; fix only genuine gaps.
      **Orphan UX for a surfaced oversell is a human decision** — if the recovery flow (re-price /
      refund / restock message to the cashier) is undefined, log it as an open question and STOP
      for the human rather than inventing product behaviour.
- [ ] **A-S7 — DoD + PR.** Run §DoD. Update `progress-tracker.md` + `BUILD_LOG.md`. Open PR
      `Closes #100`, summarise the before/after and the audit table. **Stop for human merge.**

**A test matrix:** lost-ack retry (exactly-once); offline-then-reconnect (no double-decrement on
pulling your own sale); two-devices-race-the-last-unit (server rejects #2, orphans, on-hand ≥ 0).

---

## Workstream B — #101 Broadcast live-signal (BLOCKED until A merged + B0 proven)

**Goal:** near-instant convergence via a Broadcast **signal** that triggers a pull, never the
transport, never writes Drift. **Branch:** `feat/broadcast-live-signal` off `origin/main`
(post-A-merge).

- [ ] **B0 — GATE: on-device proof (throwaway spike).** Prove a Broadcast subscription to a
      per-tenant topic **joins and receives** a trigger-emitted message where `postgres_changes`
      is currently refused (same authed socket). Minimal: one temp trigger on one table →
      `realtime.send()` to `topic:store_<id>`; a temp client subscribe logs receipt.
      **If it does NOT join → STOP. Do not build B.** Hand back; the answer becomes C-S2. Delete
      the spike; record the result in `progress-tracker.md`.
- [ ] **B1 — Generic emit trigger (migration 0147+).** One `AFTER INSERT/UPDATE/DELETE` trigger
      function using `TG_TABLE_NAME`, calling `realtime.send()` / `realtime.broadcast_changes()`
      to `topic:store_<business_id>` (or tenant topic) with **minimal** payload `{table, id, op}`
      — no row data. Attach it to **every** synced table via a **loop over `kSyncPullOrder`**
      (so "add a synced table = one registry entry" still holds). **Guard against echo/loops**
      (skip when the write is a no-op / sync-applied path per PRD risk #5). Deploy via
      `apply_migration`, verify emission with a manual write.
- [ ] **B2 — Per-tenant RLS on `realtime.messages` (same or adjacent migration).** Exactly one
      policy scoping a topic to its business (private channel / Realtime Authorization). Test that
      tenant X cannot receive tenant Y's nudges (no cross-tenant signal leak — Invariant #5 smell).
- [ ] **B3 — Transport seam (ADR 0001).** Add `startBroadcast(businessId, {onSignal})` /
      `stopBroadcast()` to `CloudTransport`; implement in `SupabaseCloudTransport` (one channel,
      one tenant topic) and in `InMemoryCloudTransport` (fake that can inject a signal). Mirror the
      existing realtime lifecycle (subscribe/teardown, the #93 await-teardown discipline).
- [ ] **B4 — Wire signal → pull in the engine.** Any broadcast message → **debounced**
      `catchUpPull(reason: 'broadcast')` (reuse the 20s debounce so a burst collapses to one pull).
      Start/stop broadcast on the same lifecycle as realtime (sign-in / resume / connectivity /
      logout). **Assert the callback's only effect is to schedule a pull — it MUST NOT write
      Drift** (test).
- [ ] **B5 — Coexistence with the periodic pull + no-replay recovery.** Keep C running.
      Test: a device that "missed" a broadcast (backgrounded/offline) still converges on the next
      periodic/reconnect pull — proving no dependency on broadcast replay.
- [ ] **B6 — Cross-client note (emit is universal; web reception is a separate slice).** The
      trigger is shared-schema and writer-agnostic, so mobile/web/console writes all emit to the
      tenant topic. This issue builds the **trigger + RLS + mobile subscriber**. **Wiring the web
      client's subscribe to the same topic is a separate web-scoped issue** — file it as a
      follow-up (`web-pos` reacts by refetch/invalidate, not a Drift pull); do not build it here.
- [ ] **B7 — DoD + PR.** Run §DoD (incl. the broadcast-never-writes-Drift and burst-debounce
      tests). Update docs. Open PR `Closes #101`. **Stop for human merge.**

**B test matrix:** duplicate pulls from a broadcast burst → exactly one debounced pull, cursor
never skips, Drift identical to single-pull; broadcast callback writes no Drift; missed-message
recovered by periodic pull.

---

## Workstream C — #102 retain periodic pull as the safety net (independent of A/B)

**Goal:** keep the shipped periodic `catchUpPull` as the reconnect-replay backstop; decide cadence.
**Branch:** `chore/retain-periodic-pull-safety-net` off `origin/main`.

- [ ] **C-S1 — Guard the safety net (regression test).** A test that asserts the periodic pull
      exists on the tick and fires under foregrounded + online + business-bound (and is suspended
      when backgrounded / cancelled at logout), so it can't be silently removed while it is the
      backstop that makes B's "no replay" acceptable.
- [ ] **C-S2 — Cadence decision (human input).** Default: **leave at 30s** once B lands (B gives
      near-instant, C just backstops). Tighten toward **~10s** only if B is delayed or fails B0.
      This is a product/cost trade-off (idle pull traffic vs. staleness) — **surface the
      recommendation and let the human choose**; implement whichever is chosen (a one-line
      `_autoPushPeriodicInterval` change + test).
- [ ] **C-S3 — DoD + PR.** Run §DoD. Update `progress-tracker.md`. Open PR `Closes #102`. **Stop
      for human merge.**

---

## Definition of Done (per slice / per workstream PR)

1. The slice works end-to-end within its defined scope (verified by running it, not asserted).
2. No `architecture.md` invariant violated — re-read the Invariants section and confirm each
   relevant one **by name** in the PR description.
3. Follows `code-standards.md` (StatelessWidget-only, no `dynamic`, tokens not raw values,
   import order, append-only ledgers, all cloud writes through the outbox / sanctioned RPCs).
4. `flutter analyze` → zero errors, zero **new** warnings (you ran it).
5. `flutter test` → green (you ran it); the workstream's test-matrix rows are covered and were
   **red before / green after**.
6. Generated code regenerated with `dart run build_runner build` if any schema/model changed
   (never hand-edit `*.g.dart`).
7. Any migration deployed via `mcp__supabase__apply_migration` and **verified** against the live
   schema; numbered 0147+; landed before its consumer.
8. `context/progress-tracker.md` updated **and** a dated `BUILD_LOG.md` entry added, in the same
   iteration. Any other touched context file updated in the same step.
9. Commit messages are Conventional-Commits, one concern each, **no AI attribution**. PR body
   references the issue (`Closes #NNN`), **no AI attribution**.

---

## Sequencing summary

```
A (#100) ──merge──▶ B0 gate ──pass──▶ B (#101) ──merge──▶ (web-subscribe follow-up issue)
                          └──fail──▶ STOP → C-S2 tighten poll
C (#102) ── independent; can run alongside A; C-S2 cadence waits on B's outcome
```

Do not start B before A is merged **and** B0 passes. Do not remove C while B is the primary
signal. `postgres_changes` debugging is an explicit non-goal throughout.
</content>
