# drinkPosApp — Domain Context

A local-first drink-POS app. The on-device Drift database is the source of truth; a
sync engine reconciles it with a Supabase cloud backend so the app works fully
offline and converges when connectivity returns.

## Language

### Permissions

**Gate**:
A named yes/no rule deciding whether the current user may see or perform a
gated action (e.g. *receive stock*, *see profit*). May combine permission keys
and role tier, but is always declared once, by name, in the Gate Registry —
call sites cite the name, never re-derive the rule.
_Avoid_: check, guard condition, inline `hasPermission` expressions.

**Gate Registry**:
The single file declaring every Gate in the app. One gated action = one named
entry; the render layer, the screen guard, and the write boundary all cite the
same entry, so the rule cannot drift between layers.

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

### Orders

**Order**:
The persisted record of a sale — one row in `orders` plus its line items. The
aggregate the Order Module owns. Distinct from a *Sale*: an Order can be in
states that are not recognized sales (cancelled/refunded).
_Avoid_: transaction, receipt; "sale" for the record itself.

**Sale**:
The economic event — revenue changing hands, recognized at **Checkout**, not at
Confirm. "A recognized sale" = any Order in a non-reversed state (`pending` or
`completed`), per `orderCountsAsSale`. A Sale is a property of an Order, not a
separate record.
_Avoid_: using "sale" and "order" interchangeably; "completed sale" (revenue is
not tied to the `completed` status).

**Checkout**:
The lifecycle operation that settles a sale and recognizes revenue: books wallet
legs, deducts inventory, issues crates, writes the Order at status `pending`.
The economic act.
_Avoid_: settle, record-sale (as user-facing verbs), "complete the sale".

**Confirm**:
The ceremonial lifecycle operation flipping an Order `pending`→`completed`,
stamping `completedAt` and recording goods receipt + returned empties. Creates
**no** revenue.
_Avoid_: complete (as a synonym for Checkout), finalize.

**Cancel**:
The lifecycle operation that reverses a settled sale (a.k.a. refund) — undoes
stock, payments, and credit-balance legs. A cancelled/refunded Order is never a
recognized Sale.
_Avoid_: void, delete.

**Cart**:
A pre-checkout draft of a would-be Order — mutable, no revenue, no status, no
invariants. Becomes an Order at **Checkout** (Cart → Checkout → Order). *Not*
part of the Order Module, even though `OrdersDao` currently stores saved carts;
a separate concern.
_Avoid_: treating a Cart as a draft/pending Order; folding cart logic into the
Order Module.

### Scoping

**Current Business Id**:
The id of the tenant bound to the current session — null until a business binds
(login, or the create-business handoff). A device may hold more than one
business's data, so every tenant-scoped read filters to it. Exposed reactively
by `currentBusinessIdProvider`, the single watchable source.
_Avoid_: reading `db.currentBusinessId` at build time (non-reactive → the read
is baked and sticks stale/empty for the session).

**Business-Scoped Stream**:
A live-query provider declared through the `businessScopedStream` factory (or
`businessScopedStreamFamily` for keyed ones, plus `…AutoDispose` twins). It
watches the Current Business Id, emits its required `whenAbsent` value until a
business is bound, hands the closure `(ref, db, businessId)` with the resolved
non-null id, and rebuilds on bind or switch — so a tenant-scoped read cannot be
baked to a missing or stale business at build time.
_Avoid_: raw `StreamProvider` over a DAO `watch*`, inline businessId guards.
