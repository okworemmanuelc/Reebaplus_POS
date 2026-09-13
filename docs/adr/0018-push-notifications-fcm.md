---
status: accepted
---

# Push notifications for console broadcasts via Firebase Cloud Messaging

Console broadcasts (operator announcements — Notifications of `type = 'console_broadcast'`)
must alert staff at the OS level even when the app is closed; the existing in-app bell only
surfaces them when opened. We add **Firebase Cloud Messaging** (`firebase_messaging` +
`flutter_local_notifications`) as the push transport: an `AFTER INSERT` trigger on
`notifications` (filtered to `console_broadcast`) fans out through `pg_net` to a `send-push`
Edge Function that resolves the targeted business's Device Tokens and calls the FCM HTTP v1
API — mirroring the existing `send-invite-email` trigger→`pg_net`→function pattern (0126). The
per-install FCM token lives on the existing cloud-only `devices` table (0129); no console
change is needed, because the console already inserts the `console_broadcast` rows.

## Considered Options

- **OneSignal / a managed push vendor** — far less backend to build, but adds a third-party
  that holds device/user identifiers and a second SDK, inconsistent with this app's deliberate
  no-third-party posture (crash handling also avoided third-party). Rejected.
- **Realtime-only (no OS push)** — the status quo; cannot alert a backgrounded or killed app,
  which is the entire requirement. Rejected.
- **FCM data-only messages** — full render control, but unreliable delivery to killed apps
  (Android deprioritizes, iOS rate-limits). Rejected in favour of a hybrid notification+data
  message.

## Consequences

- **A second background pathway and the first third-party SDK.** Until now "sync is the only
  background work" and there was no third-party SDK; FCM adds both. Recorded here so a future
  reader does not read it as an accident.
- **Push is an alert only — it never writes Drift.** The Notification row of record still
  arrives via the normal realtime-pull sync path, so the FCM background isolate stays trivial
  and a push failure never loses data (the broadcast still appears in the bell on the next
  pull). This mirrors "Realtime is a signal, never the transport."
- **Tenant isolation (invariant #5) is preserved by Device Token uniqueness.** A given FCM
  token maps to exactly one `devices` row — the most recent login — enforced by a
  `SECURITY DEFINER` trigger that nulls the token on every other row, plus a client
  clear-on-logout, so a broadcast to one business can never reach a phone now serving a
  different tenant.
- **iOS is code-ready but deferred.** The client code is cross-platform; iOS activation (APNs
  auth key, Apple Developer push capability, physical-device testing) is a tracked prerequisite,
  not built in this slice.
