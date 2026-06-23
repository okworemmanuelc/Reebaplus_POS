# Brief — Persistent session (stay logged in until explicit logout)

> Executor prompt. Read `context/architecture.md` (Invariants + "Auth & Access
> Model" → "Single active session per identity") and `context/code-standards.md`
> before writing code. Update `context/progress-tracker.md` when done.

## Goal (one sentence)

A signed-in user stays signed in across app restarts and time, and is **only**
returned to the auth flow when they explicitly tap **Log Out** (or are removed by
an account-level event) — never by a time-based session expiry.

## Background — why the session currently expires

There are two independent forced-logout paths today. Be precise about which one
this brief touches.

1. **Time-based expiry (THIS BRIEF).** Each login writes a `sessions` row with a
   **30-day TTL** (`AuthService.setCurrentUser` → `SessionsDao.createSession`,
   `ttl: Duration(days: 30)`; `_kickOtherDevices` stamps the same `expires_at`
   in the cloud). `SessionsDao.findActiveSession` only returns a row where
   `expiresAt > now`. `AuthService.verifyLocalSessionStillActive` runs on every
   app **resume** (`auto_lock_wrapper.dart:78`); if the row is missing/expired it
   calls `_handleRemoteKick → fullLogout`. So after 30 days (or any clock skew
   past `expires_at`) the user is logged out even though nothing else changed.
   The `_SessionExpiredScreen` gate in `main.dart` (`_supabaseHasSession`) fires
   when Supabase reports `signedOut`; a revoked/expired refresh token lands here.

2. **Single-active-device kick (DISABLED).** Previously, a *fresh*
   sign-in elsewhere revoked this device via `_kickOtherDevices`
   (`sessions.revoked_at` + `signOut(scope: others)`). This was a deliberate
   security policy ([architecture.md] "Single active session per identity"). 
   This policy has been disabled per product requirements to support concurrent
   multi-device sign-ins. `_kickOtherDevices` was renamed to `_registerCloudSession`
   and now only registers/upserts the current session to the cloud.

> Decision recorded: the session is **non-expiring by time** while
> preserving the explicit-logout path. Multi-device sign-ins are now fully supported, 
> meaning signing in on a new device will not log out other devices.

## Implementation steps

### Step 1 — Make the local session TTL effectively non-expiring
- [ ] In `AuthService.setCurrentUser` (`lib/shared/services/auth_service.dart`,
      ~line 627) replace the `ttl: const Duration(days: 30)` on
      `createSession(...)` with a far-future TTL (e.g.
      `const Duration(days: 36500)` ≈ 100 years). Add a comment explaining the
      session no longer time-expires by product decision; expiry now happens only
      on explicit logout / remote kick / account deletion.
- [ ] In `_kickOtherDevices` (~line 661) change the cloud `expires_at` stamp to
      the same far-future value so the cloud row and `findActiveSession`'s
      `expiresAt > now` check agree. Keep `revoked_at` logic untouched — the kick
      must still work.
- [ ] Do **not** change `findActiveSession`'s predicate. Keeping the
      `expiresAt > now` clause intact (now always-true) means the kick's
      `revoked_at` path still logs the device out correctly.

### Step 2 — Confirm refresh-token persistence keeps the JWT alive
- [ ] Verify `Supabase.initialize` in `main.dart` (~line 84) relies on the
      default `autoRefreshToken: true` and persistent session storage (it does;
      do not disable them). The SDK auto-refreshes the JWT in the foreground, so
      a normally-used device never hits the `signedOut` gate. No code change
      expected here — just confirm and note it in the progress tracker.
- [ ] Confirm `verifyLocalSessionStillActive` (resume hook) now only trips on a
      genuine remote kick (revoked row), not on time — because the row no longer
      expires. No change to the call site; just verify behaviourally.

### Step 3 — Leave explicit logout untouched
- [ ] Confirm `AuthService.logout()` (~line 813) still revokes the local session
      row + `signOut(scope: local)`. This is the ONE intended way the session
      ends on this device. No change.

### Step 4 — Tests
- [ ] Add/extend a unit test (mirror existing `test/` auth/session suites) that
      `createSession` writes a row whose `expiresAt` is far in the future and
      `findActiveSession` returns it (i.e. it does not expire by time).
- [ ] Add a regression test that a `revoked_at`-flipped row is NOT returned by
      `findActiveSession` (kick still works) and that `logout()` revokes the row.

### Step 5 — Docs
- [ ] Update `architecture.md` "Single active session per identity": note the
      session no longer time-expires (TTL is effectively infinite); the only
      terminations are explicit logout, the cross-device kick, and account
      deletion.
- [ ] Log the change in `progress-tracker.md` and a dated `BUILD_LOG` entry.

## Acceptance criteria
- Log in, force-quit, wait/relaunch (and advance device clock past 30 days): the
  user is still signed in and lands on their PIN/Who's-working screen, never the
  auth/email-entry or "session expired" flow.
- Signing in on a second device still kicks the first (unchanged).
- Tapping **Log Out** still ends the session on this device.
- `flutter analyze` clean; `flutter test` green; `dart run build_runner build` if
  any model changed (none expected).

## Out of scope
- The single-active-device kick, account deletion tombstone wipe, suspend-staff
  drop, and the `_SessionExpiredScreen` OTP re-auth path (those are correct as-is
  and only trigger on genuine server-side revocation, which a non-expiring,
  auto-refreshed session avoids in normal use).
