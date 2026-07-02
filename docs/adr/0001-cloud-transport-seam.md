# Cloud-transport seam for the sync engine

**Status:** accepted (2026-07-02)

`SupabaseSyncService` held a `SupabaseClient` directly, so its push/pull/realtime
paths (`pushPending`, `pullChanges`, `startRealtimeSync`) could only run against a
live backend — the sync data-safety brief's A–F vectors were untestable. We
introduce a `CloudTransport` interface (a deep module: ~7 methods hiding PostgREST,
pagination, realtime channels, and identity) with two *real* adapters —
`SupabaseCloudTransport` (production) and `InMemoryCloudTransport` (a fully-featured
in-memory fake, test-only) — injected at the existing constructor seam. This unit
is a **pure behaviour-preserving extraction**; the brief's correctness fixes land on
top of it as a separate unit.

## Considered Options

- **Thin PostgREST mirror** (`from(t) → builder`) — rejected: shallow, forces the
  fake to reimplement query-builder semantics, keeps every caller coupled to
  PostgREST vocabulary.
- **Neutral transport error type** — rejected for the error contract: the engine's
  retry policy is keyed on Postgres codes (`23503` FK-deferred / `P0001` permanent /
  `23505` order-number collision), which *are* the domain. The seam therefore throws
  `PostgrestException` (carrying `.code`) and `TimeoutException` verbatim; the fake
  throws the same for fault injection.

## Key boundary decisions

- **Leak vs neutralize, decided by payload load-bearingness.** The seam *leaks*
  `PostgrestException` (`.code` drives retry classification) and
  `PostgresChangePayload` (`.newRecord`/`.oldRecord` are the row data the dispatch
  consumes) because their payloads are load-bearing and irreducible. It *neutralizes*
  auth to a 4-value `TransportAuthEvent` enum because the engine consumes only the
  event category — so the enum is a complete, not lossy, representation.
- **Asymmetric loop ownership, decided by outbox contact.** The push chunk-loop stays
  in the engine (inseparable from `markDoneBatch` + adaptive chunk sizing + §6.8
  classification — the sacred-outbox logic the tests must observe); the pull page-loop
  (range paging, per-page timeout, halve-on-timeout) moves into the adapter behind
  `fetchTable`, which returns the whole slice. The engine still picks the initial
  `pageSize` from connectivity and passes it in.
- **Identity folded onto the same seam** (`currentAuthUserId` + `authEvents`) rather
  than a separate `AuthGateway` — one seam, one fake. `Connectivity()` and the static
  `inspectJwtClaims()` global read are out of scope.
- **`SupabaseSyncService` not renamed.** A `SyncEngine` rename is more honest but is
  churn orthogonal to the seam; deferred.

## Consequences

- The engine reaches **zero injected-`_supabase` references** on its sync-I/O paths;
  the file still imports Supabase for the two leaked types and the static
  `inspectJwtClaims` diagnostic.
- `pushPending` / `pullChanges` / `startRealtimeSync` become end-to-end testable
  against `InMemoryCloudTransport`, unblocking the brief's A–F vector tests.
- The existing `*ForTesting` local seams stay and coexist — they test pure-local
  restore/reconcile; the transport seam adds end-to-end coverage.
- **One intentional, accepted deviation from strict extraction:** the `users`
  supplementary fetch, previously a single un-paginated `select`, now routes
  through `fetchTable` and so gains pagination + `(last_updated_at, id)` ordering.
  The returned set is identical (restore is set-based) and the path is strictly
  more resilient; judged inside "behaviour-preserving" tolerance in exchange for a
  single fetch method. Every other moved block is byte-identical.
