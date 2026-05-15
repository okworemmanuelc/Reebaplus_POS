# Role-Refactor Branch — Checkpoint (rev 2)

Handoff snapshot for the post-compaction agent. **This revision is
committed** (departing from the prior rev-1 convention of keeping
CHECKPOINT.md untracked) so durable state survives compaction
regardless of working-tree drift.

[PROGRESS.md](PROGRESS.md) and [DEFERRED.md](DEFERRED.md) are both
also now committed. Read this file first, then DEFERRED.md, then
PROGRESS.md if you need the full commit ladder.

## Current branch state

**Branch:** `feat/staff-onboarding-phase-1`

**Last commit:** `<this commit> docs(deferred,checkpoint): close Block 3 issue triage`

Commit ladder added since the previous CHECKPOINT (rev 1):

```
<this>   docs(deferred,checkpoint): close Block 3 issue triage
607c9bb  fix(ui): bucket CEO rows in staff list
fdd2745  chore(auth): swallow auth-stream errors on offline / DNS hiccups
bab70bd  docs(progress): track in-flight refactor state + post-deploy invitee caveat
0dfddef  docs(deferred): catalogue the non-CEO invitee profiles/RLS gap
68d1e8b  chore(signup-wizard): log invite-redeem failures before the toast
8c55dcf  chore: remove sync/dao diagnostic prints from 2026-05-10 triage
```

(See [PROGRESS.md](PROGRESS.md) for the full role-refactor ladder
back to `2bc8395`.)

## Step just finished

**Step 14 Block 4 (sync resilience, CEO-only) and the runnable parts
of Block 5 (PIN ×5 / relogin ×5 / biometric ×5, CEO)** are both green
per user 2026-05-15. Wizard E2E ×3 stays deferred alongside the
profiles/RLS gap.

Adjacent commits since rev 1 of this CHECKPOINT:

- `8c55dcf` — Block 2 cleanup (sync/dao diagnostic prints removed).
- `68d1e8b` — Issue 3 diagnostic improvement (log invite-redeem
  failures before the toast).
- `0dfddef` — DEFERRED.md gets the new profiles/RLS-gap entry from
  Issues 4/5.
- `bab70bd` — PROGRESS.md committed durably with deploy caveats.
- `fdd2745` — Sub-phase D `onError` handlers (auth_service.dart +
  supabase_sync_service.dart) committed via surgical staging; the
  6 v9 regressions that had been entangled in the working tree
  were reverted to match HEAD before staging.
- `607c9bb` — Issue 1 fix at staff_screen.dart:226.
- `<this>` — DEFERRED.md gains "Terminate Access is a stub" entry;
  CHECKPOINT.md reflects all Block 3 issues closed.

## Step about to start

**Cloud + edge function + app deploy.** Per the plan's
"Pre-Deploy Cleanup & Execution" addendum (2026-05-15) and the
deploy sequence later in this file:

1. `flutter analyze` clean + `flutter test` 97+ green re-check.
2. Build new app (`flutter build apk --release` or iOS equivalent,
   per test device).
3. `source ~/.zshrc && supabase db push` — applies only 0030.
4. `source ~/.zshrc && supabase functions deploy send-invite
   revoke-invite check-invite-email accept-invite resend-invite
   redeem-invite` (six functions, one call).
5. Install new app build IMMEDIATELY (do NOT open old build between
   steps 3 and 5).
6. Post-install CEO smoke test (PIN login → dashboard → re-run
   Block 4 sync-resilience matrix → confirm Issue 1 fix renders a
   CEO section).

## Block 3 issue triage

Three issues surfaced during manual testing. Status snapshot:

### Issue 1 — CEO missing from staff list (RESOLVED 2026-05-15)

When logged in as CEO, the CEO's own profile did not appear in the
staff management list. **Root cause:** the per-tier render-order list
at [staff_screen.dart:226](../../../lib/features/staff/screens/staff_screen.dart#L226)
predated the v9 tier bump and never included tier 6, so CEO rows fell
off the render loop entirely. **Fix:** single-line change in commit
`607c9bb` — `[5, 4, 3, 2, 1]` → `[6, 5, 4, 3, 2, 1]`. CEO now renders
in its own section above Managers. Verify on device post-deploy.

### Issue 2 — "Terminate Access" does nothing (DEFERRED — pre-existing stub)

Tapping "Terminate Access" opens a "Delete Staff" confirmation dialog
whose Delete button is a literal stub
([staff_screen.dart:768-800](../../../lib/features/staff/screens/staff_screen.dart#L768-L800),
specifically the `// Stub — no DB delete in this version` comment at
line 794). Pre-existing since commit `4122b55` (2026-03-21,
"feat: move update product button & update CLAUDE.md summary") — predates
every v9 refactor commit.

**Out of scope for this branch.** Catalogued in
[DEFERRED.md](DEFERRED.md) → "Terminate Access is a stub" with full
fix proposal (soft-delete via DAO + sync-queue enqueue, per CLAUDE.md
§5 sync invariants). No production blocker — the affordance has been
non-functional for months and no support tickets exist.

### Issue 3 — Cashier invite half-success (CLOSED)

**Symptom:** invitee filled NOK in the signup wizard, hit Continue,
saw "Something went wrong. Please try again." But the invite shows as
pending in the CEO's staff view — cloud accepted the create-invite
side, then redeem failed.

**Root cause:** the deployed (v8) `accept_invite` RPC's role→tier
CASE statement has no `WHEN 'cashier'` branch (see
[0026_accept_invite_v3.sql:115-120](../../../supabase/migrations/0026_accept_invite_v3.sql#L115-L120)),
so `v_role_tier := NULL`, then `INSERT INTO public.users (..., role_tier)
VALUES (..., NULL)` violates `users.role_tier NOT NULL`. RPC rolls
back atomically; invite stays pending. Confirmed via Supabase
edge-function logs:
`[redeem-invite] accept_invite RPC failed: null value in column
"role_tier" of relation "users" violates not-null constraint`.

**Structural fix:** migration 0030 (already written + committed in
`f80030f`, deploy pending) rewrites the CASE to include
`cashier → 3, stock_keeper → 4, rider → 2` and widens the tier CHECK
to `(2,3,4,5,6)`. Existing pending invite will redeem cleanly on
retry post-deploy without intervention.

**Diagnostic improvement landed:** commit `68d1e8b` adds client-side
`[SignupOrchestrator]` debugPrints before both early-return toasts in
`_runRedeem` (the `InviteApiErr` branch at L124-L127 and the
unexpected-response fallback at L132-L138). Future silent failures of
this shape will now leave a Debug Console trail without needing to
dig through Supabase dashboard logs.

**Recovery path for the existing orphan pending invite:** either
revoke it (clean restart) or leave it pending (auto-redeems on retry
post-deploy of 0030).

### Issues 4/5 — Manager redeem failure, profiles/RLS gap (DEFERRED)

**What user observed:** logged in as new manager, completed wizard,
got punted to Welcome-back screen, "Could not load your account"
toast on attempting to tap the business.

**Full diagnosis chain** (catalogued in [DEFERRED.md](DEFERRED.md) →
"Non-CEO invitee acceptance blocked by missing profiles row"):

1. Cloud `accept_invite` RPC succeeds for manager (CASE has a manager
   branch). `public.users` + `public.business_members` rows created.
   `public.profiles` row is NOT created (never has been for non-CEO).
2. Client's `applyServerResponse('accept_invite', data)` tries to
   seed local Drift `users` row → fails on FOREIGN KEY constraint
   because Drift `users.business_id` references `businesses.id` and
   the fresh-device local DB has no businesses row yet.
3. Orchestrator's `localUser == null` recovery branch pivots to
   `ExistingAccountScreen`.
4. That screen calls `syncOnLogin` → `pullChanges` → cloud RLS denies
   every tenant table because `public.business_id()` returns NULL
   (the function reads from `public.profiles` and the invitee has no
   profiles row).
5. Local Drift never gets the businesses / users rows. Welcome-back
   screen's "tap business" retry loops on the same wall.

**Why this is pre-existing, not a refactor regression:** grep across
all migrations confirms no migration in history ever creates a
profiles row for non-CEO invitees. The bug has existed since the
multi-role system in 0020_business_members (March 2026). It went
unnoticed because every prior verification used a CEO test account
which trivially has a profiles row from owner-onboarding. The role
refactor surfaced it but did not cause it.

**Scope decision (Path A approved by user):** ship the role refactor
as-is; defer the profiles/RLS fix to a follow-up branch. Trade-off
captured in operational warning: do NOT issue non-CEO invites in
production until the fix lands; CEO accounts are unaffected.

**Next session, when picking up the profiles/RLS fix:** read
DEFERRED.md's three candidate fix paths (B: extend `accept_invite`,
C: COALESCE in `public.business_id()`, D: sync-after-login redesign).
Recommendation is **Path C after a call-site audit** of every site
that uses `public.business_id()` and every tenant RLS policy that
depends on it. Fall back to Path B + a parallel Drift `profiles`
table if the audit surfaces non-trivial blast radius. Suggested
branch name: `fix/invitee-rls-principal`.

## Open follow-ups (out of scope for this branch — carried forward)

These are captured for visibility but should NOT be addressed inside
the role-refactor branch — they're noise that obscures the diff. New
branches or post-merge cleanups.

1. **`app_drawer.dart:211` `?? 1` fallback.** Tier 1 is no longer in
   the canonical set `{2,3,4,5,6}`. Functionally harmless (the
   fallback only fires when `currentUser` is null, and the drawer
   isn't rendered pre-login). Also documented in
   [PROGRESS.md](PROGRESS.md) §Follow-ups.

2. **`reports_hub_screen.dart` Customer Ledger card.** Still uses the
   `if (!isCeo)` informal gate pattern that the other three cards
   (Sales Report / Expense Tracker / Stock Audit) migrated to
   `RoleGuard` in Step 9. Out of scope for the Step-9 sweep because
   it was not in the plan's gap-analysis table. Documented in
   [PROGRESS.md](PROGRESS.md) §Follow-ups.

3. ~~**Uncommitted onError hunks in two service files**~~
   **RESOLVED 2026-05-15** — committed in `fdd2745`. The 6 v9
   regressions that had been entangled in the working tree (auth
   service defaults / docstring / CEO seed) were reverted to HEAD
   before staging; `git diff --staged` confirmed only the onError
   hunks at `auth_service.dart:993-1006` and
   `supabase_sync_service.dart:1391-1413` made it into the commit.

4. ~~**`PROGRESS.md` itself.** Uncommitted scratch state.~~
   **RESOLVED 2026-05-15** — PROGRESS.md was committed in `bab70bd`
   to make the deploy-sequence caveat durable for the post-compaction
   agent. The file's original "delete or convert to a PR description
   before merge" instruction still applies before final merge.

5. **NEW: Non-CEO invitee profiles/RLS gap.** Pre-existing structural
   issue (~2 months old). Full diagnosis chain, three candidate fix
   paths, and recommendation in
   [DEFERRED.md](DEFERRED.md) §"Non-CEO invitee acceptance blocked by
   missing profiles row". Blocks Block 5 wizard E2E ×3 and any
   non-CEO invitee acceptance in production. Suggested follow-up
   branch: `fix/invitee-rls-principal`. Pick after auditing
   `public.business_id()` call sites and every tenant RLS policy.

## Reminder — cloud migration 0030 is written, NOT deployed

`supabase/migrations/0030_role_vocabulary_expansion.sql` has been
committed to git (in commit `f80030f` per PROGRESS.md) but **NOT
pushed to cloud**. The cloud `profiles` / `users` / `business_members`
/ `invites` tables still carry the v8 vocabulary and the v8
`(1, 4, 5)` tier set. The whole refactor's correctness on production
depends on 0030 being applied with the deploy sequence below.

The `supabase_migrations.schema_migrations` table on the remote was
empty when this branch's Step 14 prep began (historical migrations
were applied via dashboard SQL editor, not via CLI). `supabase
migration repair --status applied` was run for versions 0001–0029
(skipping the absent 0012). Verified via `supabase migration list`:
0001–0029 now show in both Local and Remote columns; 0030 is the
only Local-only row. So `supabase db push` at deploy time will push
exactly one migration.

`SUPABASE_DB_PASSWORD` is exported in `~/.zshrc:9` (plaintext —
acceptable for the short deploy window; rotate + remove after deploy).

## Reminder — deploy sequence (per PROGRESS.md, with Issues-4/5 caveat)

⚠ **There is a critical timing window** between cloud migration 0030
landing and the new app build being installed on the user's device.
During that window the old app binary will crash on `syncOnLogin`
because its pre-Step-4 Drift CHECK (`role_tier IN (1,4,5)`) rejects
the now-tier-6 CEO row coming back from cloud.

Strict order, no skipping:

1. **Build the new app first.** Have APK / IPA staged and ready
   *before* touching cloud.
2. **Deploy cloud migration:** `source ~/.zshrc && supabase db push`
   (will apply only 0030).
3. **Deploy edge functions:** `supabase functions deploy send-invite
   revoke-invite check-invite-email accept-invite resend-invite
   redeem-invite`.
4. **Install the new app build IMMEDIATELY.** Do NOT open the
   existing app build between steps 2 and 4.

User instruction: do not use the app between cloud deploy and app
rebuild. If you accidentally open the old build, `syncOnLogin` will
fail with `CHECK constraint failed: role_tier IN (1,4,5)` — recovery
is to close the app and install the new build. No data loss because
the failure is purely client-side validation; cloud state is already
consistent.

### Post-deploy operational caveat — Issues 4/5

**CEO accounts: unaffected.** All CEO-only flows (PIN login,
logout/relogin, biometric, etc.) continue to work.

**Non-CEO invitee acceptance on a fresh device: KNOWN BROKEN until
the deferred profiles/RLS fix lands.** Do NOT issue Manager /
Stock Keeper / Cashier / Rider invites in production until the
follow-up branch ships. Existing pending non-CEO invites should be
left pending or revoked (revocation preferred, so the invitee doesn't
trigger the broken path accidentally).

## Pointers

- **Refactor plan (operative source of truth):**
  `~/.claude/plans/major-scope-expansion-before-structured-pumpkin.md`
  (also copied to [PLAN.md](PLAN.md) for in-repo access)
- **Per-step progress / commit ladder:** [PROGRESS.md](PROGRESS.md)
- **Deferred-work catalogue:** [DEFERRED.md](DEFERRED.md)
- **Glossary for v9 vocabulary:** [UBIQUITOUS_LANGUAGE.md](../../../UBIQUITOUS_LANGUAGE.md)
- **Diagnostic prints tracker (all entries now marked removed):**
  `~/.claude/projects/-Users-solomonizu-flutter-projects-drinkPosApp/memory/diagnostic_prints_to_revert.md`
