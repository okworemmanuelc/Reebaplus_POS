# drinkPosApp — Domain Context

A drink-POS platform with two clients over one Supabase backend. The **mobile app**
is local-first: the on-device Drift database is the source of truth, and a sync
engine reconciles it with the Supabase cloud so it works fully offline and converges
when connectivity returns. The **web app** is online-first: it reads and writes the
cloud live, through PostgREST/Realtime and server-authoritative RPCs, with no local
source of truth (ADRs 0007–0012). The two clients share **one database schema and
one RPC write-contract** — nothing else. The offline invariants (#1 local-source-of-
truth, #4 every-write-through-the-outbox) are mobile-scoped, not app-wide.

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

### Inventory & Costing

**Add Product**:
The act of creating something you sell and recording what's already on your
shelf — writes stock straight to inventory with **no supplier, no invoice, no
payable**. First-run catalogue building and any brand-new SKU. The felt test:
*"new thing I sell / setting up shop" → Add Product.* Under FIFO costing it
creates the opening Cost Batch (costed or Uncosted).
_Avoid_: routing opening stock through Receive Stock; "add stock" (that's
adding quantity to an existing product).

**Receive Stock**:
The act of logging a supplier delivery of things you already sell — increases
stock **and** posts the supplier invoice, payment, and crate returns. Ongoing
operations, not setup. The felt test: *"a delivery arrived" → Receive Stock.*
Under FIFO costing it pushes a new Cost Batch at the delivery's per-line cost.
_Avoid_: treating it as the general "add a product" entry point; renaming it
(the label "Receive Stock" is locked).

**Uncosted**:
A sold line or held unit whose cost is unrecorded (`buyingPriceKobo == 0`).
Reports never guess: uncosted units are excluded from COGS/valuation and
counted transparently ("Excludes N item(s) with no recorded buying price").
Healed by the prompted cost **backfill** (fires once per product/batch on the
0→first-cost transition; fills gaps only, never overwrites a real snapshot).
_Avoid_: silently substituting current cost at report time; treating zero cost
as free goods.

**Cost Batch** *(ships with the FIFO costing epic — ADR 0005)*:
One receipt of units at one cost for one (product, store) —
`{qty, costKobo, receivedAt}` — drawn down oldest-first by sale timestamp as
sales happen. The unit of cost truth; the product's scalar `buyingPriceKobo`
becomes a derived cache of the oldest remaining batch's cost. Selling price
stays a single current value per product, independent of batches.
_Avoid_: per-batch selling prices; treating a product-form buying-price edit
as a batch record (a new batch at a new cost is a Receive Stock act).

**Provisional COGS** *(FIFO — ADR 0005)*:
An offline till's line COGS, computed from its own local batch-queue view at
checkout — honest, but not yet authoritative. On sync the server re-derives the
authoritative consumption (ordered by each sale's own recorded timestamp across
all tills) and corrects the line snapshot as an ordinary LWW row update. Profit
is provisional until synced; the correction drift is bounded by offline
duration × batch-cost spread. Client and server use the same per-unit rounding
so a provisional line and its correction agree when no re-ordering happened.
_Avoid_: presenting provisional profit as final on a long-offline till;
blocking the sale on a server round-trip.

**Batch-Boundary Reconciliation** *(FIFO — ADR 0005)*:
The server-authoritative re-costing that runs when synced sales re-order a
(product, store)'s FIFO queue — e.g. a late **earlier**-timestamped sale claims
a cheaper batch, pushing a later sale onto a pricier one. The server replays
consumption from the timestamp-ordered movement ledger and re-assigns
already-corrected lines (`pos_recost_product_store`, migration 0133); batch
consumption is derived, recomputable state, so the replay is deterministic and
idempotent for a fixed ledger. The correction is audited with one rolled-up
Activity Log row per sync batch ("N sales of X re-costed on sync"), never a
silent rewrite and never a per-sale prompt.
_Avoid_: server-arrival order as the FIFO key; prompting the user per corrected
sale; treating an assignment as permanent (it is stable only until an earlier
sale arrives).

### Industry

**Industry**:
The trade a business operates in (Beverage distributor, Pharmacy, Phone &
Gadgets, Frozen Foods & Grocery, …) — the single input that morphs the app's
words, presets, and optional feature surfaces. Resolved from `businesses.type`
by the total normalizer `industryOf(type)`; unknown/null → the `generic`
Industry, never a crash. Nine ship, all selectable at onboarding and editable
later (ADR 0015).
_Avoid_: reading `businesses.type` string directly to branch behaviour (use the
resolved Industry); a new `industry_id` column (identity is the normalized type).

**Industry Profile**:
The per-Industry configuration record in the one industry registry: display
label, icon, its **Lexicon**, starter categories/units, and its feature flags.
Layered over the *one* shared products/POS/inventory model — an Industry is
configuration, not a separate data model or app (ADR 0015). The registry
supersedes the old duplicated lists (`business_types.dart` +
`_businessTypes` in `ceo_sign_up_screen.dart`).
_Avoid_: per-industry screens/tables/flows forked from the shared model; a
plugin architecture.

**Lexicon**:
The app-shipped, compile-time set of an Industry's domain nouns (item name, unit,
category, …) — only the nouns that read wrong cross-industry; neutral words
(Save/Price/Stock) are left literal. Beverage-only nouns (crate, empties) live
only in the beverage profile so they cannot leak. Missing slots fall back to the
`generic` Lexicon. Not CEO-editable, not synced (ADR 0015).
_Avoid_: translating every string; a synced or owner-editable vocabulary;
hardcoding "crate"/"bottle" in feature code.

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

### Web

**Web POS**:
The online-first browser client (Next.js/React + `supabase-js`) that operates the
app live against Supabase — reads through PostgREST/Realtime, writes through
server-authoritative RPCs — with no Drift, no outbox, and no offline mode. A
separate runtime from the mobile app, sharing only the schema and the RPC
write-contract. Lives in `web-pos/`.
_Avoid_: "the Flutter web build" (that is `web/`, mobile output); implying it is
offline-capable or shares client code with mobile.

**RPC Write API**:
The set of `SECURITY DEFINER` Postgres RPCs that perform the Web POS's money-writes
transactionally server-side (checkout, receive/adjust stock, ledger posting). The
web client's *only* write path; it never writes business rows through PostgREST
directly. The server-side counterpart to the mobile app's Dart DAO writes.
_Avoid_: "the API", direct PostgREST writes from web, Edge Functions (the write
API is RPCs, not functions).

**Golden-Scenario Suite**:
The shared fixtures — input state → expected resulting rows — run in CI against
*both* the Dart DAO path (mobile) and the SQL RPC path (web) to prove the two
implementations of the same money rule stay identical. The mechanism that makes
"full parity" safe despite two implementations (ADR 0009).
_Avoid_: treating each client's own unit tests as sufficient; assuming shared code
prevents drift (there is none — only shared fixtures).

**Operator** *(web)*:
The signed-in web user attributed to a sale. On web the Supabase session is the
operator directly — there is no PIN and no "Who's working?" picker (ADR 0011).
_Avoid_: equating it with the mobile "active user" chosen via PIN.
