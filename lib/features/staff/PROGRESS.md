# Staff Onboarding — Role Refactor Progress

**Branch:** `feat/staff-onboarding-phase-1`

This file is uncommitted scratch state for the role-vocabulary refactor
in flight. Delete or convert to a PR description before merge.

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

## Steps remaining

- **Step 9 — RoleGuard implementation.**
  - Replace the stub in `lib/shared/widgets/role_guard.dart` with a real
    `ConsumerWidget` that gates on `currentUser.roleTier >= minTier`.
  - Retune the 4 existing call sites (all `minTier: 4` → `minTier: 5`):
    staff_details_screen.dart ×2, staff_screen.dart ×2.
  - Add 8 new wrappers from the gap-analysis:
    invite_modal send button, invite_pending_sheet regenerate+revoke,
    customer_detail_screen Add Funds + Set Limit, customers_screen Add
    Customer FAB, expenses_screen Add Expense FAB, warehouse_screen Add
    Warehouse FAB, inventory_screen Add Product FAB.
  - Migrate 4 informal gates to RoleGuard:
    reports_hub_screen Sales Report / Expense Tracker / Stock Audit
    cards (`if (!isCeo)`), customers_screen warehouse filter
    (`if (isManagerOrAbove)`).
- **Step 10 — Invite modal runtime inviter-role filtering.**
  In `lib/features/invite/widgets/invite_modal.dart`: load current user's
  role in `initState`, filter the role dropdown accordingly (CEO sees
  manager+stock_keeper+cashier+rider; Manager sees stock_keeper+cashier+rider;
  everyone else gets a "no permission" early-return).
- **Step 11 — Test fixture sweep.**
  16 role-string literals across 18 test files (`role: 'admin'` → `'ceo'`,
  `role: 'staff'` → `'cashier'`). Triage each match — `admin`/`staff` may
  appear in non-role contexts (customer_group names, route keys, comments)
  that should NOT be changed. Document false positives in the commit body.
- **Step 12 — UBIQUITOUS_LANGUAGE.md.**
  Populate the (currently empty) repo-root file with the 5-role × tier
  glossary, removed/renamed log, and gate vocabulary cheat-sheet.
- **Step 13 — Deferred-work doc.**
  Commit `lib/features/staff/DEFERRED.md` (created untracked alongside
  this PROGRESS.md) with the sync-after-login architecture refactor as
  the first entry.
- **Step 14 — Final verification.**
  `flutter analyze` clean, `flutter test` 97+ green (after Step 11 sweep),
  manual matrix on real device (invite-modal filtering CEO/manager/cashier
  matrix, existing-account-screen flow, sync-with-bad-row tolerance), plus
  the rev-3 appendix 5/5 protocol (PIN login ×5, logout-relogin ×5,
  biometric ×5, wizard E2E ×3).

## Cloud deploy status

Migration `supabase/migrations/0030_role_vocabulary_expansion.sql` is
**WRITTEN AND COMMITTED but NOT DEPLOYED**. Waiting until Steps 9–14 land
so the app build and cloud changes ship in one tight window.

## Deploy sequence (when ready)

⚠ **Critical timing window.** Between cloud migration landing and the new
app build being installed on the device, the old app binary will crash
on `syncOnLogin` because its v8 Drift CHECK rejects the now-tier-6 CEO
row coming back from cloud. Minimize the window:

1. **Build the new app first.** Have APK/IPA staged and ready before
   touching cloud.
2. **Deploy cloud migration:** `supabase db push` (applies 0030).
3. **Deploy edge functions:** `supabase functions deploy send-invite
   revoke-invite check-invite-email accept-invite resend-invite
   redeem-invite`.
4. **Install the new app build IMMEDIATELY.** Do NOT open the existing
   app build between steps 2 and 4.

**User instruction:** do not use the app between cloud deploy and app
rebuild. If you accidentally open the old build, `syncOnLogin` will
fail with a `CHECK constraint failed: role_tier IN (1,4,5)` error —
recovery is to close the app and install the new build. No data loss
because the failure is purely client-side validation; cloud state is
already consistent.

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

- **app_drawer.dart:211** — `final roleTier = ref.read(authProvider).currentUser?.roleTier ?? 1;`
  uses tier 1 as fallback. Tier 1 is no longer in the canonical set
  `{2,3,4,5,6}`. Functionally harmless because the fallback only fires
  when `currentUser` is null (pre-login state, drawer isn't rendered).
  Surface for follow-up if a strict-vocabulary pass is wanted.

- **reports_hub_screen.dart Customer Ledger card** — still uses the
  `if (!isCeo)` informal gate (same pattern as the Sales Report /
  Expense Tracker / Stock Audit cards migrated to RoleGuard in
  Step 9). Out of scope for the Step 9 sweep because it was not in
  the plan's gap-analysis table; revisit if a follow-up consistency
  pass is wanted.

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
