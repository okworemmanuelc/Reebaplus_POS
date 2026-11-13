# No PIN: email sign-in only, on every device and in the browser

**Status: accepted** (#812, owner decisions 2026-11-13). Supersedes the PIN
unlock model (device-local 6-digit PIN, lock screen, auto-lock, biometric).

The owner wants the app to open in a web browser, where a user signs in with
their email code (or Google) and goes straight into their shop. Asking a browser
user to create and type a PIN adds a step with no benefit, and keeping the PIN on
phones only would leave two sign-in models to maintain.

## Decision

1. **No PIN anywhere.** Phones, tablets and the browser. A verified sign-in
   (email OTP, Google, Existing Account) ends in `AuthService.completeSignIn`;
   a device with a signed-in user and a Supabase session opens straight into
   `MainLayout` at cold start (`AuthService.restoreSignedInUser`, local SQLite
   only, so invariant #11 holds).
2. **No lock.** The drawer Lock button, auto-lock, the 12-hour background
   logout and biometric unlock are gone. To change staff on a shared till, the
   person logs out (which wipes local data, as before) and the next person signs
   in with their own email code.
3. **Suspended or plan-paused member** sees an "Account on hold" screen with Log
   out, instead of the PIN screen. The user stays bound underneath so a
   reactivation reopens the shop without losing offline work.
4. **Delete Business** is confirmed by typing the business name (trimmed,
   case-insensitive). The PIN step is dropped; the cloud `delete_business` RPC
   never took a PIN.
5. **Schema unchanged.** The Drift `users.pin*` columns and the
   `kSetupRequiredPin` placeholder stay (`pin` is NOT NULL); nothing reads them.

## Consequences

- Invariant #2 ("PINs never leave the device") is retired: there is no PIN.
- On a shared till anyone who picks up a signed-in device can use that account
  until it is logged out. The owner accepted this trade-off for simpler sign-in.
- The browser runs the same Drift + sync engine as a phone (#812 S1); its copy is
  wiped on Log Out and after 30 days without use (#812 S5).
