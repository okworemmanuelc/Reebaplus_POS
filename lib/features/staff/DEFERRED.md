# Staff Onboarding — Deferred Work

Improvements identified during the staff onboarding / role refactor work
that are out of scope for the current branch. Each entry describes the
problem, the proposed direction, and the trigger that would unblock work
on it.

This file lives next to the staff feature code (not under `docs/`) so
deferred items stay visible to anyone reading the feature folder.

## Sync-after-login architecture refactor

**Status:** deferred (post role-vocabulary refactor; design exploration).

**Problem.** `syncOnLogin` currently runs a full cloud pull before the
dashboard renders. On returning logins this stalls the UI for several
seconds even though the local Drift state is already authoritative for
everything the dashboard needs. This was the path that exposed the
cashier-invite sync crash that kicked off the role-vocabulary refactor.

**Proposed design.**

- First login on a device: pull cloud → seed local → route to dashboard.
- Subsequent logins: route to dashboard immediately on local state; kick
  off a background pull; reconcile via existing realtime / pull plumbing.
- Local is the source of truth for read paths; cloud sync is
  fire-and-forget (already true for writes via SyncDao — flip reads to
  match).
- Existing-account-screen bug is **already fixed** by migration 0030 +
  Step 5 sync-hardening (log + skip instead of silent coerce); this
  refactor is the next-order ergonomic improvement, not a fix.

**Not in scope yet.** Conflict-resolution UI for stale-local-state edge
cases (extremely rare given LWW + realtime).

**Trigger to unblock.** Once the role refactor is merged and stable on
production for 1–2 weeks, revisit. Earlier if a returning-login UX
complaint surfaces.

## Non-CEO invitee acceptance blocked by missing profiles row

**Status (rev 2, 2026-05-20):** ✅ **RESOLVED on
`fix/invitee-rls-principal`** — migration
[`0031_seed_profiles_for_invitees.sql`](../../../supabase/migrations/0031_seed_profiles_for_invitees.sql)
extends `accept_invite` to seed `public.profiles` for every invitee
(mirroring the CEO owner-creation pattern at [0023:75-81](../../../supabase/migrations/0023_complete_onboarding_seeds_membership.sql#L75-L81))
and backfills the row(s) for existing non-CEO members. Awaiting deploy
(`supabase db push` from `fix/invitee-rls-principal` after merge to
main). The original diagnosis chain + the three candidate fix paths
are preserved below for posterity.

**Audit-driven recommendation flip (rev 2).** The audit on
`fix/invitee-rls-principal` (2026-05-20) found that the rev-1
recommendation — **Path C with the COALESCE in `public.business_id()`**
— would not have been sufficient on its own. Three distinct
profiles-authoritative consumers exist, not one:

1. `public.business_id()` — the RLS principal helper.
2. [`regenerate_invite_code`](../../../supabase/migrations/0030_role_vocabulary_expansion.sql#L395-L398)
   and [`extend_verification`](../../../supabase/migrations/0030_role_vocabulary_expansion.sql#L520-L523)
   — both read `role_tier` directly from `profiles` for their
   manager-tier gate.
3. [`AuthService.upsertLocalUserFromProfile`](../../../lib/shared/services/auth_service.dart#L312-L368)
   — client-side seeder for the local Drift `users` row;
   returns `null` (stranding the orchestrator on
   `ExistingAccountScreen`) if no profiles row exists.

Additionally, the rev-1 Path C SQL had a **circular RLS dependency**:
its proposed `(SELECT id FROM public.users WHERE auth_user_id = …)`
sub-query would trigger `users.tenant_select` which itself calls
`public.business_id()`, recursing back into the same function. The
fix would have required two new self-read RLS policies on `users`
and `business_members` — a permanent dual-source identity model and
a larger attack surface for future RLS bypasses.

Path B (seed `profiles` for everyone) closes all three consumers in
one SQL change, requires zero client changes (the sync layer at
[supabase_sync_service.dart:1807-1816](../../../lib/core/services/supabase_sync_service.dart#L1807-L1816)
already discards bulk `profiles` rows from `pos_pull_snapshot`), and
restores the original design intent that `profiles` is the
authoritative principal record for every authenticated tenant
member — not just the CEO owner.

---

**Original status (rev 1):** deferred (pre-existing structural gap,
~2 months old; surfaced during Step 14 Block 3 manual testing of the
role refactor, **not caused by it**). Blocks non-CEO invitee fresh-device
flow in production; CEO accounts are unaffected.

**Diagnosis chain.** Reproduction was a manager invite redeemed end-to-end
on a fresh emulator. Wizard completed server-side, then punted to the
Welcome-back recovery screen, which then failed to load the account. Trace:

1. Wizard's `_runRedeem` calls `redeem-invite` → cloud's `accept_invite`
   RPC succeeds, creates `public.users` and `public.business_members`
   rows for the invitee. **Does NOT create a `public.profiles` row** —
   no migration in history ever has for non-CEO invitees.
2. Client calls `applyServerResponse('accept_invite', data)` to seed
   local Drift. The user-insert into Drift's `users` table fails with
   `FOREIGN KEY constraint failed` because `users.business_id` references
   `businesses.id` and `users.warehouse_id` references `warehouses.id` —
   neither row exists on a fresh device.
3. Orchestrator's `localUser == null` recovery path pivots to
   `ExistingAccountScreen` (intended for cloud-has-account /
   local-doesn't), which retries `syncOnLogin` behind clean UI.
4. `syncOnLogin` calls `pullChanges` → cloud RLS denies every tenant
   table because `public.business_id()` returns NULL: that function is
   `SELECT business_id FROM public.profiles WHERE id = auth.uid()`, and
   the invitee has no profiles row. Every tenant policy gates on
   `business_id = public.business_id()`, so every SELECT returns zero
   rows. The pull warning log says exactly this: `WARN pull returned 0
   businesses rows — likely RLS denial (missing profiles row for
   auth.uid()=...)`.
5. Local Drift never receives the businesses / warehouses / users rows.
   ExistingAccountScreen's "tap business" retry loops forever on the
   same wall. The user is stuck.

**Why this is pre-existing, not a refactor regression.** Grep across
every migration in the repo:

- `public.profiles` INSERTs exist in exactly 3 places: `0004_onboarding_resume.sql:106`,
  `0018_complete_onboarding_rpc.sql:79`, `0023_complete_onboarding_seeds_membership.sql:75`.
  All three are in the CEO owner-creation path, all three are hardcoded
  `'ceo', 5`.
- `accept_invite` (the canonical invitee-finalisation RPC) has never
  written to `profiles` in any of its versions: `0022_accept_invite_rpc.sql`,
  `0026_accept_invite_v3.sql`, or `0030_role_vocabulary_expansion.sql`.

So the bug is as old as the multi-role system itself (~0020 in March 2026).
It went unnoticed because every prior verification ran against a CEO
test account, which trivially has a profiles row from the owner-onboarding
RPC. The first non-CEO fresh-device wizard run is the first time the
gap surfaces.

**Proposed fix paths.** Audit required before picking.

- **Path B — fix in 0030's `accept_invite` RPC.** Add `INSERT INTO
  public.profiles (id, business_id, name, role, role_tier) VALUES
  (v_auth_uid, v_invite.business_id, v_clean_name, v_invite.role,
  v_role_tier) ON CONFLICT (id) DO UPDATE ...` adjacent to the existing
  users/business_members inserts. Smallest code change, but expands
  0030's scope from "role-vocabulary refactor" to "role-vocabulary
  refactor plus invitee-RLS-principal fix". Also requires the Drift
  side to start seeding a `profiles` table — verify whether Drift even
  has a `profiles` table (almost certainly not, since the client has
  never needed one). Adding a local `profiles` table is a schema bump
  on its own.

- **Path C — fix in `public.business_id()` helper.** Rewrite the
  RLS principal-lookup function to fall back to `business_members` if
  no profiles row exists:

  ```sql
  CREATE OR REPLACE FUNCTION public.business_id()
  RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
      (SELECT business_id FROM public.profiles       WHERE id        = auth.uid()),
      (SELECT business_id FROM public.business_members
       WHERE user_id = (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       LIMIT 1)
    )
  $$;
  ```

  Smaller surface, no schema changes, no client work. **But** it admits
  the semantic truth that `business_members` is the canonical
  per-business state for everyone — which has implications for the
  `profiles` table's role going forward (vestigial for non-CEOs? owner-
  only intentionally? becomes a perma-CEO-flag?). Carries unknown
  blast radius until someone audits every call site of
  `public.business_id()` and every tenant RLS policy that depends on
  it. The audit is the real cost here.

- **Path D — sync-after-login redesign (see earlier entry in this file).**
  If reads go local-first, the cloud-pull RLS denial stops being on the
  critical path. But that work is bigger and explicitly parked. Not a
  near-term option.

**Recommendation (rev 1, superseded).** Path C is technically cleanest
and has the smallest diff. Pick Path C **after** an audit confirming:

1. Every call site of `public.business_id()` is comfortable with the
   COALESCE semantics (no caller assumes profiles-only).
2. Every tenant RLS policy that uses `public.business_id()` still
   produces correct results when the invitee's business_member row is
   the source of truth.
3. The `STABLE` function classification still holds with the COALESCE +
   join (it should — both branches are read-only, deterministic for a
   given `auth.uid()`).

If the audit surfaces a non-trivial blast radius, fall back to Path B
plus a parallel Drift `profiles` table addition.

**Recommendation (rev 2, what actually shipped).** The rev-1 audit
landed on **Path B**, not Path C. See the "Audit-driven recommendation
flip" block at the top of this entry for the full rationale. The
Drift `profiles` table addition called out as the Path-B fallback
turned out to be unnecessary — the sync layer at
[supabase_sync_service.dart:1807-1816](../../../lib/core/services/supabase_sync_service.dart#L1807-L1816)
already discards bulk `profiles` rows from `pos_pull_snapshot`, and
`AuthService.upsertLocalUserFromProfile` already upserts the
caller's own row into Drift `users` directly from the cloud
`profiles` SELECT. Path B was pure SQL.

**Backfill (rev 2).** Bundled into 0031 itself — the migration
INSERTs a profiles row for every existing `public.users` row with
`auth_user_id NOT NULL` and an active membership, using
`ON CONFLICT (id) DO NOTHING` so re-runs are no-ops. The 0030
pre-flight audit recorded 1× manager and 1× CEO; CEO already has a
profile (from 0023's CEO-only seed path), so the backfill effectively
INSERTs the single missing manager profile.

**Trigger to unblock (rev 2).** Done on `fix/invitee-rls-principal`
(commit pending). Deploy with `supabase db push` after the branch
merges to main; verify via the queries at the bottom of 0031. Block 5
wizard E2E ×3 (Step 14 in [PROGRESS.md](PROGRESS.md)) becomes
runnable once 0031 is live.

## Terminate Access is a stub

**Status:** deferred (pre-existing technical debt; not a refactor
regression). Surfaced during Step 14 Block 3 manual testing of the role
refactor.

**Problem.** Tapping "Terminate Access" on a staff profile opens a
"Delete Staff" confirmation dialog, but the dialog's Delete button is a
no-op. No DB write, no sync enqueue, no error toast — the dialog just
dismisses and the staff member stays active.

**Trace.**

- [staff_screen.dart:1290](screens/staff_screen.dart#L1290) — "Terminate
  Access" tile → `onTap: onDelete`.
- [staff_screen.dart:503-506](screens/staff_screen.dart#L503-L506) —
  `onDelete: () { Navigator.pop(ctx); if (item.user != null)
  _confirmDelete(context, item.user!); }`.
- [staff_screen.dart:768-800](screens/staff_screen.dart#L768-L800) —
  `_confirmDelete` shows an `AlertDialog`. The Delete button at
  L789-796 has `onPressed: () async { Navigator.pop(context); // Stub
  — no DB delete in this version }`.

**Origin.** Commit `4122b55` (2026-03-21, "feat: move update product
button & update CLAUDE.md summary"). Predates every v9 refactor commit
(`2bc8395`, `f80030f`, `c3b177c`, `f114e56`, `a6077f3`, `4345c5e`,
`f143a31`). Pre-existing technical debt.

**Proposed fix.** Replace the stub with a soft-delete that respects
CLAUDE.md §5 sync invariants — `is_deleted = true` on the
`business_members` row via a DAO method that calls
`SyncDao.enqueueUpsert`, NOT `enqueueDelete` (cloud needs to retain
the audit trail of who was on the team and when they left).

Suggested touch points:

- New `BusinessMembersDao.terminateMember(memberId)` method that
  flips `is_deleted = true` and updates `terminated_at` (column add
  may be required — audit the cloud schema first).
- Replace the stub `// Stub — no DB delete in this version` block with
  a call to the new DAO and an `AppNotification.showSuccess` toast.
- Verify the staff list provider (Riverpod) filters `is_deleted = true`
  rows out so terminated members disappear from the list immediately
  via realtime / local stream propagation.
- Cloud side: confirm RLS allows CEO/manager to update `is_deleted`
  on subordinate `business_members` rows.

**Trigger to unblock.** No production blocker — the affordance has been
non-functional for months and no support tickets exist. Pick when
either (a) the CEO needs to remove a real terminated staff member, or
(b) the next staff-management cleanup pass happens. Suggested new
branch: `feat/terminate-staff-access` (or fold into the
`fix/invitee-rls-principal` follow-up if both are tackled together).
