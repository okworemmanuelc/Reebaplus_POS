# Staff Onboarding — Role Refactor Progress

**Branch:** `feat/staff-onboarding-phase-1` (canonical refactor branch);
follow-up consistency items on `feat/role-refactor-followups`.

**Status (2026-05-20):** v9 role refactor **SHIPPED**. Cloud migration
0030 applied; edge functions deployed; emulator running v9 binary
(deployed on or before 2026-05-18 per `c755c0a`'s post-deploy smoke
test reference). Steps 1–13 done; Step 14 Block 4 + Block 5 (CEO
portion) green; Block 5 wizard E2E ×3 parked behind the non-CEO
invitee profiles/RLS gap (see [DEFERRED.md](DEFERRED.md)). Two
follow-up consistency items (`app_drawer.dart`, `reports_hub_screen.dart`
Customer Ledger card) closed on `feat/role-refactor-followups` on
2026-05-20.

This file was originally uncommitted scratch — it has been committed
durably per `bab70bd`. Convert to a PR description before final merge.

## Completed commits

### Role refactor (7 commits, in order)

```
2bc8395 feat(edge-fns): bump caller-tier gates to manager+ and drop cleaner role
f80030f feat(drift): schema v9 — role vocabulary refactor + v8→v9 migration test
c3b177c feat(sync): harden users + business_members allow-lists with log+skip policy
f114e56 feat(auth): align AuthService fallbacks and CEO seed with v9 role vocabulary
a6077f3 feat(ui): align role constants and label maps with v9 vocabulary
4345c5e feat(ui): apply v9 threshold sweep to 19 client-side tier gates
f143a31 feat(ui): apply v9 thresholds to 6 gates surfaced outside features/ scope
```

### Auto-lock detour (2 commits, predate the role refactor)

```
87e33f5 refactor(auto-lock): capture db/auth at initState to survive await suspension
c6dcaed fix(auto-lock): guard resume against unauthenticated state
```

## Step status

- **Step 9 — RoleGuard implementation.** ✅ **DONE** in `8787845
  feat(ui): implement RoleGuard and apply v9 permission gates`.
  - Stub replaced with a real `ConsumerWidget` watching `authProvider`;
    14 call sites across 10 files.
  - Existing 4 call sites retuned `minTier: 4` → `minTier: 5`
    (staff_details_screen ×2, staff_screen ×2).
  - 8 new wrappers landed (invite_modal send, invite_pending_sheet
    regenerate+revoke, customer_detail_screen Add Funds + Set Limit,
    customers_screen Add Customer FAB, expenses_screen Add Expense
    FAB, warehouse_screen Add Warehouse FAB, inventory_screen Add
    Product FAB).
  - 3 of 4 informal gates migrated to RoleGuard (reports_hub_screen
    Sales / Expense / Stock cards, customers_screen warehouse filter).
    Customer Ledger card was missed in the sweep — closed on
    `feat/role-refactor-followups` 2026-05-20.
- **Step 10 — Invite modal runtime inviter-role filtering.** ✅ **DONE**
  in `6bcfbc1 feat(invite): runtime inviter-role filtering in
  InviteModal`. Filter implemented in `_initInviteRoles` at
  [invite_modal.dart:87-107](../invite/widgets/invite_modal.dart#L87-L107).
- **Step 11 — Test fixture sweep.** ✅ **DONE** in `61c1f04 test: sweep
  role string fixtures to v9 vocabulary`.
- **Step 12 — UBIQUITOUS_LANGUAGE.md.** ✅ **DONE** in `917d03c docs:
  populate UBIQUITOUS_LANGUAGE.md with v9 role glossary`.
- **Step 13 — Deferred-work doc.** ✅ **DONE** in `390baea docs:
  commit DEFERRED.md catalogue for the staff feature`.
- **Step 14 — Final verification.** Partial.
  - `flutter analyze` clean ✅
  - `flutter test` 97+ green ✅
  - Block 4 (sync resilience, CEO): GREEN per user 2026-05-15.
  - Block 5 PIN ×5 / relogin ×5 / biometric ×5 (CEO): GREEN per user
    2026-05-15.
  - Block 5 **wizard E2E ×3**: ⛔ **BLOCKED** on the non-CEO invitee
    profiles/RLS gap ([DEFERRED.md](DEFERRED.md) → "Non-CEO invitee
    acceptance blocked by missing profiles row"). Unblock via the
    `fix/invitee-rls-principal` follow-up branch.

## Cloud deploy status

Migration `supabase/migrations/0030_role_vocabulary_expansion.sql` is
**DEPLOYED**. Verified via `supabase migration list` on 2026-05-20 —
0001 through 0030 all show as applied on remote. Deploy window was on
or before 2026-05-18, referenced by the post-v9-deploy smoke test in
commit `c755c0a` on `feat/auth-uid-pinning-l5`.

## Deploy sequence (historical — executed on or before 2026-05-18)

The original timing-window warning is preserved below for posterity.
It no longer applies — the v9 binary is installed on the emulator and
matches the cloud schema.

⚠ **Critical timing window** (historical). Between cloud migration
landing and the new app build being installed on the emulator, the
old app binary would crash on `syncOnLogin` because its v8 Drift
CHECK rejected the now-tier-6 CEO row coming back from cloud. The
emulator workflow that was followed:

1. **Deploy cloud migration:** `supabase db push` (applied 0030).
2. **Deploy edge functions:** `supabase functions deploy send-invite
   revoke-invite check-invite-email accept-invite resend-invite
   redeem-invite`.
3. **`flutter run` against the emulator IMMEDIATELY.** Compiles +
   installs + launches in one step. Any prior `flutter run` process
   had to be stopped first so the install replaced the binary
   (hot-restart on the old process was not enough — the v8 Drift
   CHECK was baked into the installed APK).

**Note for re-runs / fresh emulators:** if a v8 binary is ever
installed on a clean emulator pointing at v9 cloud (e.g. for
regression testing), `syncOnLogin` will fail with `CHECK constraint
failed: role_tier IN (1,4,5)` until `flutter run` replaces it. No
data loss — purely client-side validation.

### ⚠ Known broken flow post-deploy: non-CEO invitee acceptance

Surfaced during Step 14 Block 3 manual testing. Diagnosis chain and
proposed fix paths are documented in
[DEFERRED.md](DEFERRED.md) → "Non-CEO invitee acceptance blocked by
missing profiles row". Pre-existing structural gap (~2 months old);
the role refactor surfaced it but did not cause it.

**Operational impact post-deploy:**

- **CEO accounts: unaffected.** PIN login, logout/relogin, biometric,
  and all CEO-only flows work as before.
- **Manager / Stock Keeper / Cashier / Rider invites: DO NOT ISSUE in
  production** until the deferred profiles/RLS fix lands. The wizard
  completes server-side (cloud creates the user + membership), but the
  invitee gets stranded on the Welcome-back recovery screen with
  "Could not load your account" and cannot reach the PIN screen on
  a fresh device.
- Any non-CEO invite already issued and pending in production should
  be left pending (or revoked) until the fix ships. Revoking is
  preferable so the invitee doesn't accidentally trigger the broken
  path.

The role-vocabulary refactor is independently shippable — this gap
predates it and exists on the current production code today. Shipping
0030 does not introduce this bug; it just makes it reachable for more
role values (cashier / stock_keeper / rider previously failed earlier
in the chain, so the profiles gap was hidden behind the role_tier
NOT NULL wall).

## Follow-ups noted but not actioned

- ~~**app_drawer.dart:211** — `?? 1` fallback~~
  ✅ **CLOSED 2026-05-20** on `feat/role-refactor-followups`. Now
  `?? 0`, aligning with [role_guard.dart:33](../../shared/widgets/role_guard.dart#L33)'s
  fail-closed convention. Line is now at app_drawer.dart:221.

- ~~**reports_hub_screen.dart Customer Ledger card** — `if (!isCeo)`
  informal gate~~ ✅ **CLOSED 2026-05-20** on
  `feat/role-refactor-followups`. Migrated to
  `RoleGuard(minTier: 6)` with mirrored fallback/child cards,
  matching the other three cards on the screen. Removed the
  now-unused `isCeo` / `user` locals and the `app_providers.dart`
  import.

## Pointers

- **Refactor plan (operative source of truth):**
  `~/.claude/plans/major-scope-expansion-before-structured-pumpkin.md`
- **Deferred work catalogue:** [DEFERRED.md](DEFERRED.md) (sibling file)
- **Pre-refactor Sub-phase D handoff:**
  `~/.claude/plans/reebaplus-pos-staff-onboarding-optimized-unicorn.md`
- **Diagnostic prints awaiting revert:**
  `~/.claude/projects/-Users-solomonizu-flutter-projects-drinkPosApp/memory/diagnostic_prints_to_revert.md`
  (includes the v9-probe in `app_database.dart` `beforeOpen` — uncommitted;
  delete the `// TEMP: v9 verification probe` block when ready).
