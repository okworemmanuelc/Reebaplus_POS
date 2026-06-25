# Brief: Wipe staff device at cold start when its business was deleted

> **RE-INVESTIGATION (2026-06-23): the auth flow was reworked since v1 of this
> brief — read this box before the steps.** Verified: the cold-start deletion
> gate STILL does not exist (`confirmBusinessDeleted` is only wired to the
> session-bound triggers + the post-verify orphan check), so this brief is still
> needed. But four nearby changes shipped today; the steps below are updated for
> them:
>
> 1. **New "device staff" model.** The picker, the LoginScreen "Switch account"
>    affordance, `main.dart`'s multi-staff decision, and EmailEntry now filter on
>    **device-authenticated** staff only — `deviceStaffProvider` /
>    `UserBusinessesDao.countDeviceStaffForBusiness` (active membership AND
>    `users.pinHash != null`), NOT the business-wide `activeStaffProvider`. The
>    picker (`who_is_working_screen.dart`) now uses `deviceStaffProvider`; its
>    0-staff branch routes to `WelcomeScreen`, 1-staff goes straight to that
>    user's PIN, and the old no-PIN OTP shortcut was removed (tap → LoginScreen).
> 2. **`AuthService.logOutCurrentUser` is now a wipe-on-sole-user flow** (new
>    `LogoutWipeException`): if the logging-out user is the only device staff it
>    runs `clearAllData()` + `fullLogout()`, guarded by a pending-sync check
>    (blocks offline logout when `syncDao.countPending() > 0`; pushes first when
>    online). **Do NOT graft that pending-sync guard onto the deletion gate** —
>    a deleted business is already gone from the cloud, there is nothing to push,
>    and `_handleActiveBusinessDeleted` must wipe unconditionally.
> 3. **EmailEntryScreen** added `_checkDeviceAuthenticatedUsers()` (lines ~81-105)
>    which already does the EXACT business-id resolution this brief needs (device
>    user → businessId, single-local-business fallback, then
>    `countDeviceStaffForBusiness`). **Copy that resolution verbatim** for Step 1.
>    EmailEntry's "Login with PIN" now routes to `WhoIsWorkingScreen` (not
>    LoginScreen) and only shows when device staff exist — so gating the picker
>    covers this entry point too.
> 4. **Google sign-in switched to the native SDK** (`signInWithIdToken`, new
>    `googleWebClientId`). Irrelevant to this gate — just don't be surprised by it.
>
> Net effect on the plan: Step 1's resolver should mirror
> `EmailEntryScreen._checkDeviceAuthenticatedUsers`; Steps 2-4 are unchanged in
> intent. The two existing local-wipe flows (deletion gate vs. sole-user logout)
> are independent — reuse `_handleActiveBusinessDeleted` for THIS one.

## Goal (user requirement)
When an owner permanently deletes a business (§10.3), a staff device must **not
linger on the "Who's working?" picker**. The moment that device opens the app
(cold start or resume) while online, it must jump straight to the Welcome screen
and wipe all business + app data — without ever rendering the staff cards or a
PIN screen.

## Required reading first (in this order)
1. `CONTEXT/architecture.md` — esp. "Auth & Access Model" → Danger Zone, and the
   Storage Model table (what `clearAllData` vs secure storage holds).
2. `CONTEXT/code-standards.md` and `CONTEXT/ai-workflow-rules.md`.
3. Memory `project_account_deletion_shipped` — the existing §10.3 staff
   propagation (tombstone `deleted_businesses`, the three current trigger points,
   the false-positive-proof contract).

## Why this is needed (the gap)
The §10.3 staff-wipe already exists but every trigger requires an **active
session**:
- realtime `businesses` DELETE event (needs a live realtime subscription),
- `SupabaseSyncService.syncMinimumLogin` (runs only *after* PIN unlock),
- `_handleConnectivityTransition` reconnect (needs a current session).

`WhoIsWorkingScreen` renders **before** sign-in — see its own doc comment: "Renders
BEFORE sign-in, so the session has no current business." So none of the three
triggers fire there. A device closed/offline at delete time reopens, resolves its
local business, and shows the picker indefinitely. The single-staff cold-start
path (main.dart routes to `LoginScreen`, not the picker) has the same gap.

## Key existing pieces to reuse (do NOT reinvent)
- `SupabaseSyncService.confirmBusinessDeleted(businessId)` — public, false-positive
  -proof tombstone check. Returns true ONLY on a confirmed `deleted_businesses`
  row; ANY error/offline returns false (never a false-positive wipe). USE THIS.
- `AuthService._handleActiveBusinessDeleted()` — already does
  `clearAllData()` + `fullLogout()` + sets `businessDeletedRemotely = true`
  (one-shot snackbar consumed on `EmailEntryScreen`). It is re-entry guarded via
  `_handlingBusinessDeleted`. `fullLogout()` calls `_secure.clearAll()` +
  `deviceUserIdNotifier.value = null`, which makes `main.dart`'s home builder
  rebuild to `WelcomeScreen` automatically (`_hasDeviceUser` → false).
- `AuthService.getDeviceUserId()` + `db.storesDao.getUserById(id)` → `businessId`,
  with the single-local-business fallback already implemented in
  `WhoIsWorkingScreen._resolveBusiness()` (lines ~48-68). Mirror that resolution.

## Implementation steps

### Step 1 — Add a public pre-sign-in gate on AuthService
File: `lib/shared/services/auth_service.dart`

Add a method (place it near `wipeOrphanedLocalBusiness` / `_handleActiveBusinessDeleted`):

```dart
/// Cold-start / pre-sign-in gate (§10.3). Before the Who's-working picker or the
/// single-staff PIN screen renders for a KNOWN device, confirm the device's local
/// business hasn't been permanently deleted by its owner. If the cloud tombstone
/// confirms deletion, wipe + full-logout (→ WelcomeScreen) exactly like the
/// session-bound triggers, and return true so the caller suppresses the picker.
///
/// Resolves the business id from the device user (single-local-business
/// fallback). Returns false on any ambiguity (offline, no tombstone, no
/// business) — never a false-positive wipe (same contract as confirmBusinessDeleted).
Future<bool> wipeIfActiveBusinessDeleted() async {
  String? businessId;
  final userId = await getDeviceUserId();
  if (userId != null) {
    final u = await _db.storesDao.getUserById(userId);
    businessId = u?.businessId;
  }
  if (businessId == null) {
    final businesses = await _db.select(_db.businesses).get();
    if (businesses.length == 1) businessId = businesses.first.id;
  }
  if (businessId == null) return false;

  if (!await _sync.confirmBusinessDeleted(businessId)) return false;

  // Confirmed: reuse the exact same wipe + logout the session-bound triggers use.
  await _handleActiveBusinessDeleted();
  return true;
}
```

Notes:
- Confirm the field/getter names against the file: the DB is `_db`, sync is
  `_sync`, secure storage helpers already exist. `getUserById` is on `storesDao`
  (see WhoIsWorkingScreen). Use the SAME unscoped query the picker uses; do NOT
  introduce a raw business-scoped read that violates the business-scoping
  invariant — `getUserById`/`select(businesses)` here are the same calls the
  picker already makes pre-sign-in, so they are acceptable.
- `_handleActiveBusinessDeleted` is private but in the same class — call it
  directly. Do not duplicate the wipe logic.

### Step 2 — Gate the Who's-working picker
File: `lib/features/auth/screens/who_is_working_screen.dart`, in `_resolveBusiness()`.

After resolving `businessId` (BEFORE the `setState` that reveals the cards), call
the gate. If it wipes, do not setState into the picker — `main.dart` will rebuild
to `WelcomeScreen` because the device user is now null. Pattern:

```dart
// §10.3: a staff device whose business was deleted while it was closed/offline
// must never see the picker — confirm via the cloud tombstone and bounce to
// Welcome (wipe happens inside). Online-only & false-positive-proof.
if (businessId != null &&
    await ref.read(authProvider).wipeIfActiveBusinessDeleted()) {
  if (!mounted) return;
  Navigator.of(context).pushReplacement(
    MaterialPageRoute(builder: (_) => const WelcomeScreen()),
  );
  return; // do not fall through to setState(_resolving = false)
}
```

Place it after the businessId resolution block and the existing `if (!mounted)
return;`. Keep the existing `_resolving` flow for the non-deleted case. The
`pushReplacement` is belt-and-suspenders: `fullLogout` already nulls the user so
`main.dart` re-routes, but navigating explicitly avoids a one-frame flash of the
picker.

### Step 3 — Gate the single-staff cold-start PIN screen
File: `lib/features/auth/screens/login_screen.dart`.

A single-staff device skips the picker and renders `LoginScreen` directly
(main.dart#L394). Add the same gate so this path is covered:
- In `initState` (and/or the existing `didChangeAppLifecycleState` resumed
  branch — this screen already has `WidgetsBindingObserver`), call
  `wipeIfActiveBusinessDeleted()`; on true, `pushReplacement` to `WelcomeScreen`.
- Guard against running it on a `presetUser` flow that came from the picker if it
  would double-fire; a simple `bool _checkedDeletion` latch is fine. Don't block
  the PIN UI on the network call — let the screen render, run the check async,
  and bounce if it returns true.

### Step 4 — Resume-while-on-picker (nice-to-have, include it)
If the device is sitting on the picker and the delete happens while displayed,
add a re-check on resume. `WhoIsWorkingScreen` is currently `ConsumerStatefulWidget`
without a lifecycle observer — add `WidgetsBindingObserver`, register in
`initState` / remove in `dispose`, and on `AppLifecycleState.resumed` re-run the
Step-2 gate. Keep it cheap (single tombstone HEAD-style select already capped at
`.limit(1)`).

## Invariants & guardrails (do not violate)
- **False-positive-proof:** never wipe on an ambiguous result. Offline / network
  error / no tombstone → `confirmBusinessDeleted` returns false → no wipe. A
  suspended or removed (not deleted) staff member has NO tombstone, so they are
  unaffected — verify you did not add any other wipe condition.
- **No raw business-scoped reads** beyond the picker's own existing pre-sign-in
  resolution. Don't add new `db.select` of tenant tables.
- **Reuse** `_handleActiveBusinessDeleted` for the wipe; do not call
  `clearAllData`/`fullLogout` ad hoc (keeps the snackbar + re-entry guard
  behavior identical to the existing triggers).
- This is **client-only** — no migration, no schema bump. The cloud tombstone &
  RPC already exist and are deployed. Do NOT touch `delete_business` /
  `deleted_businesses` / migrations.
- Snackbar: `businessDeletedRemotely` is consumed on `EmailEntryScreen`
  (email_entry_screen.dart:60). After wipe the user lands on `WelcomeScreen`; the
  message will surface when they proceed to email entry — this matches existing
  behavior. (Optional: also surface it on `WelcomeScreen` if the user wants it
  earlier; confirm before adding.)

## Verification (NO apk builds — emulator + `flutter run` only)
1. `dart analyze` (or the MCP `analyze_files`) must be clean for the touched files.
2. Manual emulator test, two devices / two emulators:
   - Sign in CEO on device A, staff on device B; let B sync.
   - Background/close B (so it has no live realtime).
   - On A: CEO → Settings → Danger Zone → Delete Business (PIN confirm).
   - Reopen B **online**: it must jump straight to Welcome (no picker, no cards),
     and local data must be gone (relaunch shows Welcome/Email, not the picker).
   - Repeat with B as a **single-staff** device (LoginScreen path) — Step 3.
   - Offline reopen of B: it must NOT wipe (no false positive) — stays on picker;
     wipes later when it reconnects (existing `_handleConnectivityTransition` /
     `syncMinimumLogin` paths) or on the next online cold start.
3. Add a dated entry to `BUILD_LOG.md` describing the fix (per house rule).
4. Update `CONTEXT/progress-tracker.md`.

## Files expected to change
- `lib/shared/services/auth_service.dart` (new `wipeIfActiveBusinessDeleted`).
- `lib/features/auth/screens/who_is_working_screen.dart` (gate + optional resume).
- `lib/features/auth/screens/login_screen.dart` (single-staff cold-start gate).
- `BUILD_LOG.md`, `CONTEXT/progress-tracker.md` (docs).
