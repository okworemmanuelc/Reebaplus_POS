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
