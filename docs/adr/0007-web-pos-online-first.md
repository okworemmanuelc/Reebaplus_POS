# Web POS is an online-first client, not offline-first

The web version of the app talks to the Supabase database **live** — every read
hits PostgREST/Realtime and every write goes through a server RPC — with no local
source-of-truth and no sync outbox. This deliberately inverts the mobile app's
invariants #1 and #4 (Drift is the source of truth; every cloud write goes through
the outbox) *for the web client only*. The mobile app stays offline-first,
unchanged: the two clients are different runtimes over one shared Supabase backend,
not one codebase. A browser has reliable connectivity and no durable local store we
trust, so replicating the offline-first machinery on web would be cost with no
benefit and would fight the platform.

The consequence recorded here so a future reader does not "fix" it: **the offline
invariants are mobile-scoped, not app-wide.** Web code that reads live from
Supabase or writes without an outbox is correct; it is not a violation.
