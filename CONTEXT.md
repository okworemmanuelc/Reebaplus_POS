# drinkPosApp — Domain Context

A local-first drink-POS app. The on-device Drift database is the source of truth; a
sync engine reconciles it with a Supabase cloud backend so the app works fully
offline and converges when connectivity returns.

## Language

### Sync

**Sync Engine**:
The component that reconciles the local Drift DB with the cloud — draining the outbox
(push), fetching cloud changes (pull), and applying realtime events. Implemented by
`SupabaseSyncService`.
_Avoid_: sync service, syncer, uploader (for the whole role).

**Cloud Transport**:
The seam through which the Sync Engine performs *all* cloud I/O: push
(`upsertRows` / `deleteRowsById` / `callRpc`), pull (`fetchTable`), realtime
(`startRealtime` / `stopRealtime`), and identity (`currentAuthUserId` / `authEvents`).
A deep module with two adapters — `SupabaseCloudTransport` (real) and
`InMemoryCloudTransport` (test fake).
_Avoid_: client, gateway, backend, API.

**Outbox**:
The set of un-uploaded local writes awaiting push — the `sync_queue` and
`sync_queue_orphans` tables together. Governed by Invariant #12, "the outbox is
sacred": a local row with an unconfirmed outbox entry is inviolable — no pull,
reconcile, restore, or wipe may destroy it before the server confirms its push.
_Avoid_: queue (alone — ambiguous), pending writes.

**Orphan**:
An outbox entry the cloud has *permanently* rejected (e.g. `42501` / `P0001` /
identity drift), moved to `sync_queue_orphans`. Still un-uploaded local data the
Outbox invariant protects: visible and exportable, never silently dropped.
_Avoid_: failed row, dead-letter.
