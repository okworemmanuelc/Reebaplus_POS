# Web client stack — Next.js/React + supabase-js

The web app is built in TypeScript with Next.js/React and `supabase-js`, not in
Flutter Web. Realtime subscriptions, RLS-scoped PostgREST reads, and `rpc()` calls
are first-class in `supabase-js`, which matches the online-first model (ADR 0007)
directly. Reusing the Flutter app on web was rejected because the entire mobile
codebase is wired to Drift-backed DAOs and offline-first providers (invariant #1):
"reusing" it would mean ripping out its data layer behind hundreds of call sites and
still shipping a heavy web runtime for a data-grid app.

Because the shared contract is the schema + RPCs (ADR 0008), *no* client code is
shared with Flutter — so the client language is free to be whatever suits the web,
and TypeScript + React is the idiomatic live-Supabase choice.
