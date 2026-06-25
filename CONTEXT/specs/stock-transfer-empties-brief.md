# Brief — Store-scoped Stock Transfer (request → dispatch → receive) + empties-by-manufacturer

You are implementing a feature in the Reebaplus POS Flutter app. Work spec-driven and
incrementally. **Do not start coding until you have done the reading below.**

## 0. Read first (mandatory, in order)

1. `context/project-overview.md`
2. `context/architecture.md` — re-read the **Invariants** section before *every* unit.
3. `context/ui-context.md`
4. `context/code-standards.md`
5. `context/ai-workflow-rules.md` (scoping, "when to split", "handling missing requirements")
6. `context/progress-tracker.md`

Then read these saved-memory facts (they encode hard-won invariants — do not relearn them
by breaking them):

- **`project_permission_key_cloud_fk_deploy`** — a NEW permission key must exist in the
  cloud `permissions` catalogue **before** any `role_permissions` grant referencing it
  syncs, or the grant fails the FK. Seed the key in BOTH `_defaultPermissionRows`
  (`lib/core/database/app_database.dart`) AND a cloud migration, and deploy the catalogue
  migration first.
- **`project_synced_table_client_apply_sites`** — only relevant if you add a table. **You
  are NOT adding a table** (reuse `stock_transfers`); do not.
- **`project_synced_write_explicit_id`** — DAO writes to synced tables must set `id` and
  any DB-defaulted column the cloud needs (e.g. `created_at`) explicitly.
- **`project_crate_tracking_bottle_gate`** — empties are tracked ONLY for
  `unit == 'bottle' && trackEmpties`.
- **`project_crate_value_per_manufacturer`** — crate/deposit value is per-**manufacturer**,
  not per-product. This is the conceptual basis for the empties-by-manufacturer change.
- **`project_store_lock_dual_mechanism`** — `lockedStoreProvider` is THE app-wide active
  store. Do not reintroduce per-screen store dropdowns.
- **`project_stores_manage_permission_unfinished`** — `stores.manage` is wired but was
  flagged for finishing after the multi-store feature. This IS that feature; reconcile it.
- **`project_permission_enforcement_leaks`** — every gated action needs the 3-layer pattern:
  (1) render-gate, (2) body-guard, (3) write-boundary re-check.
- **`feedback_no_apk_build`** — never `flutter build apk`. Use `flutter run` on the emulator.
- **`feedback_never_git_checkout_uncommitted`** — never `git checkout` a dirty file; never
  run `dart format` (house style is old dartfmt, unenforced).
- **`feedback_log_working_fixes`** — after each verified unit, add a dated `BUILD_LOG.md`
  entry, and update `context/progress-tracker.md`.
- **`feedback_supabase_push_authorized`** — you may run `supabase db push` (respect deploy
  ordering); you don't need to ask each time.

## 1. Current state (already mapped — do not re-derive)

**Schema** (`lib/core/database/app_database.dart`):
- `StockTransfers` table (`@DataClassName('StockTransferData')`): `id, businessId,
  fromLocationId (source), toLocationId (dest), productId, quantity, status, initiatedBy,
  receivedBy?, initiatedAt, receivedAt?, createdAt, lastUpdatedAt`.
- `status` CHECK already allows `('pending','in_transit','received','cancelled')`. **The
  `pending` value is currently UNUSED** — exploit it; no CHECK/schema migration needed for status.
- `stock_transfers` is **already a synced table** (registered in
  `lib/core/services/supabase_sync_service.dart` at its push list, pull `_pullOrder`,
  `_restoreTableData`, and hard-delete switch). Reuse it — no new apply sites.

**DAO** (`lib/core/database/daos.dart`, `StockTransferDao` ~line 4924):
- `createTransfer(...)` — TODAY: writes header as `in_transit` AND decrements source
  inventory immediately (`transfer_out`), enqueues, logs, notifies dest + CEO. This is the
  old "dispatcher picks both stores" path. It will be **superseded** (see target flow).
- `receiveTransfer({transferId, receivedBy})` — `in_transit → received`, increments dest
  inventory (`transfer_in`), notifies sender. **Keep, unchanged.**
- `cancelTransfer({transferId, cancelledBy})` — `in_transit → cancelled`, restores source
  inventory via compensating `transfer_in`. **Keep.**
- `transferCrates({transferId, fromStoreId, toStoreId, manufacturerId, quantity,
  performedBy})` — moves empty crates per-manufacturer between stores (two `crate_ledger`
  rows + `store_crate_balances`, single `domain:pos_transfer_crates` cloud envelope).
  **Keep; call it at DISPATCH time, per manufacturer.**

**UI** (`lib/features/stores/screens/`):
- `stores_screen.dart` — the all-stores list. App-bar holds the "Stock Transfer" (dispatch)
  icon → `StockTransferScreen`, and "Transfer Queue" → `IncomingTransfersScreen`. The whole
  screen currently HARD-BLOCKS anyone without `stores.manage` ("You don't have access to
  Stores"). FAB = Add Store; cards have Edit/Delete.
- `store_details_screen.dart` — per-store view: metric overview, stats grid, inventory list,
  a single "View Inventory" quick action. No transfer entry points today.
- `stock_transfer_screen.dart` — standalone dispatch form: Source + Destination dropdowns,
  product autocomplete, qty, optional single crate field tied to the selected product's
  manufacturer. Gated on CEO-only `stores.manage`. **To be replaced by the request flow.**
- `incoming_transfers_screen.dart` — tabs Incoming / Outgoing / History over in-transit
  transfers; Confirm Receipt (`stores.receive_transfer`) + Cancel (`stores.manage`).

**Providers** (`lib/core/providers/stream_providers.dart`):
- `canViewAllStoresProvider` (CEO, or Manager with the all-stores toggle), `selectableStoresProvider`
  (assigned stores for confined users), `myUserStoresProvider(userId)` (assignment set),
  `lockedStoreProvider`, `productsByStoreProvider(storeId)`.
- `viewerScopedIncomingTransfersProvider` / `viewerScopedOutgoingTransfersProvider` filter
  in-transit transfers by `toLocationId` / `fromLocationId` ∈ the viewer's assigned stores.

**Permissions** (`_defaultPermissionRows` in `app_database.dart`, category `'Stores'`):
- `stores.manage` — "Add, edit, and remove stores" — CEO-only by default.
- `stores.receive_transfer` — "Confirm receipt of incoming stock transfers".

**Empties collection (the receive flow)** — `lib/features/receiving/screens/receive_checkout_screen.dart`:
- Collects empties PER PRODUCT: `_emptiesReturned` (`Map<String,int>` keyed by `productId`),
  `_emptiesControllers` keyed by `productId`, one `_emptiesRow` per cart line where
  `trackEmpties && manufacturerId != null`. Passes `emptiesReturnedByProduct` to the service.
- **Downstream is ALREADY per-manufacturer**: `lib/shared/services/receive_stock_service.dart`
  `confirmReceipt(...)` loops lines and calls
  `crateLedgerDao.recordCrateReturnByManufacturer(manufacturerId: ..., quantity: returned, ...)`.
  So a business that sells two SKUs of the same manufacturer currently shows TWO empties
  inputs that both write to the same manufacturer pool — confusing and double-entry-prone.

## 2. What to build

### Decisions you MUST confirm with the requester before writing the permission migration

These change role capabilities and add DB migrations; confirm names/defaults, then proceed.

- New key **`stores.request_transfer`** — "Request stock from another store". Default-granted
  to **CEO + Manager**.
- New key **`stores.dispatch_transfer`** — "Approve and dispatch stock requests from your
  store". Default-granted to **CEO + Manager**.
- `stores.receive_transfer` stays the receive gate (ensure **Manager** has it by default).
- `stores.manage` narrows to **store CRUD only** (Add/Edit/Delete store). It NO LONGER gates
  dispatch/cancel/receive.

If the requester prefers a single combined `stores.transfer` key instead of two, adjust —
but keep request vs dispatch independently grantable unless told otherwise.

### Target transfer flow (requester-initiated; everything inside a store)

Field meaning is unchanged: `fromLocationId` = the store that HOLDS the goods (source),
`toLocationId` = the store that NEEDS them (requester). The only change is who initiates.

1. **Request** (raised from inside the requesting store's details, by a user with
   `stores.request_transfer` whose assigned/active store is the requester):
   browse another store's inventory read-only, pick product + quantity (+ optional empties
   per manufacturer), submit. → new header row `status='pending'`, `fromLocationId=sourceStore`,
   `toLocationId=requesterStore`, `initiatedBy=requester`. **No inventory or crate movement yet.**
   Enqueue the header; notify the source store's assigned users + CEO.
2. **Accept & dispatch** (by a user with `stores.dispatch_transfer` assigned to the SOURCE
   store, from incoming-requests inside the source store's details): may **alter the quantity
   to match availability**, then dispatch. → decrement source inventory (`transfer_out`,
   reuse the existing adjustStock path; guards negative stock), set `status='in_transit'`,
   update `quantity` if altered, enqueue, log, notify requester. If empties accompany the
   shipment, call `transferCrates(...)` here, **per manufacturer**. **Reject** instead →
   `status='cancelled'`, notify requester, no inventory change.
3. **Receive** (by a user with `stores.receive_transfer` assigned to the requesting store):
   Confirm Receipt → existing `receiveTransfer(...)` (`in_transit → received`, increment dest).
4. **Cancel** an in-transit dispatch → existing `cancelTransfer(...)` (restores source).
   A requester may cancel their own still-`pending` request → `cancelled`, no inventory change.

### Store visibility model

- **Stores drawer entry**: show to CEO, and to any Manager (i.e. also when the user has
  `stores.request_transfer` / `stores.receive_transfer` / `stores.dispatch_transfer`, not
  only `stores.manage`). Update the gate in `lib/shared/widgets/app_drawer.dart`.
- **`stores_screen.dart` (all stores list)**: stop hard-blocking non-`stores.manage` users.
  Render the store list to all Manager+ viewers. Keep Add Store (FAB) and per-card
  Edit/Delete gated on `stores.manage` (3-layer). **Remove the app-bar "Stock Transfer"
  dispatch icon and the "Transfer Queue" icon from this screen** — those move into store
  details (below). The standalone source→dest `StockTransferScreen` is retired (delete it
  and its route/import once nothing references it).
- **`store_details_screen.dart`**: branch on whether the viewer is assigned to (or can view
  all) THIS store:
  - **Assigned / all-stores viewer (full view)**: current metrics + inventory + actions, PLUS
    a transfer hub for this store: **Incoming Requests** (pending where `fromLocationId ==
    thisStore` — others asking this store to send; Accept-with-qty / Reject, gated
    `stores.dispatch_transfer`), **Incoming Transfers** (in-transit where `toLocationId ==
    thisStore`; Confirm Receipt gated `stores.receive_transfer`), **My Requests/Outgoing**
    (pending/in-transit this store raised or dispatched; cancel as applicable), and a
    **Request Stock** action (gated `stores.request_transfer`).
  - **Not assigned (restricted view)**: show the **inventory list read-only** plus a single
    **Request Stock from this store** action (gated `stores.request_transfer`). Hide store
    value/metric management affordances that imply ownership. No Edit/Delete, no accept/receive.

### Empties by manufacturer (two screens)

A. **Receive checkout** (`receive_checkout_screen.dart`): replace the per-product empties
   collection with **per-manufacturer**. Group `cart.where((l) => l.trackEmpties &&
   l.manufacturerId != null)` by `manufacturerId`; render ONE input row per manufacturer
   (label by manufacturer name; show the summed full-crates received across that
   manufacturer's lines as the secondary text). Change the service boundary to
   `emptiesReturnedByManufacturer: Map<String,int>` (manufacturerId → qty) and update
   `receive_stock_service.confirmReceipt(...)` to iterate manufacturers and call
   `recordCrateReturnByManufacturer` once per manufacturer. Net cloud/ledger effect is
   identical (downstream already aggregates by manufacturer) — this removes the double-entry
   surface. You'll need a manufacturer-name lookup (manufacturers are already in Drift; find
   the existing provider/DAO rather than adding one).

B. **The new Request Stock flow**: when empties travel with a transfer, collect/show them
   **per manufacturer**, and move them at dispatch via `transferCrates(...)` per manufacturer.
   Do not reintroduce a per-product crate field.

## 3. Units (one at a time; verify each before the next)

Split per `ai-workflow-rules.md`. Suggested order:

1. **Empties-by-manufacturer in receive checkout** (UI + service-boundary; independent,
   smallest, ships value immediately). No migration.
2. **Permission catalogue**: seed `stores.request_transfer` + `stores.dispatch_transfer` in
   `_defaultPermissionRows` and a Drift migration that inserts them into `permissions`;
   write the matching cloud migration under `supabase/migrations/` and **deploy the cloud
   catalogue migration first** (FK ordering). Grant defaults to CEO + Manager (and ensure
   Manager has `stores.receive_transfer`). Land + verify before any UI references the keys.
3. **DAO**: add `requestTransfer(...)`, `dispatchTransfer({transferId, quantity?,
   dispatchedBy, empties?})`, `rejectRequest(...)`; adjust/retire `createTransfer`. Each
   synced write sets `id` + `created_at` explicitly and `enqueueUpsert`s the full row.
   Add providers: `viewerScopedIncomingRequestsProvider` (pending, `fromLocationId` ∈ my
   stores), `viewerScopedOutgoingRequestsProvider` (pending, `toLocationId` ∈ my stores).
4. **Store visibility + relocation**: drawer gate, `stores_screen.dart` de-block + remove
   transfer icons, retire `StockTransferScreen`.
5. **Store-details transfer hub**: full vs restricted branch, Request Stock flow (browse
   source inventory read-only, pick product/qty, optional empties-by-manufacturer), Incoming
   Requests (accept-with-qty / reject), Incoming Transfers (confirm receipt), outgoing
   tracking/cancel. Reuse `incoming_transfers_screen.dart` building blocks where sensible.

## 4. Standards & exit criteria (every unit)

- StatelessWidget/ConsumerWidget-first; `ConsumerStatefulWidget` only for ephemeral UI state.
- Tokens ONLY: `context.getRSize` / `context.getRFontSize` (or the `rSize`/`rFontSize` helpers
  used in these files), `AppRadius.*`, `Theme.of(context).colorScheme.* / textTheme.*` /
  `extension<AppSemanticColors>()`, `FontAwesomeIcons.*`. No raw hex / px / palette constants.
- Notifications via `AppNotification.showInfo/showError/showSuccess` — never raw `SnackBar`.
- Permissions: hide-don't-block + the 3-layer pattern (render-gate, body-guard, write-boundary
  re-check) on every gated action. Never branch on a role slug for gating (CEO short-circuit
  in the existing providers is the only sanctioned slug use).
- Every cloud write goes through Drift + the outbox (`enqueueUpsert`); no direct Supabase
  calls from features. Ledgers stay append-only.
- Re-verify file state before editing (the user edits these files in parallel).
- Update `context/progress-tracker.md` in the SAME step; add a dated `BUILD_LOG.md` entry
  after each verified unit. Update `architecture.md`/`project-overview.md` if scope or the
  storage/permission model changes (the permission-model change DOES warrant a doc note).
- Per unit: `flutter analyze` zero errors / zero new warnings; `flutter test` passes; if you
  changed Drift schema/seed, regenerate with `dart run build_runner build`. Run on the
  emulator with `flutter run` — never `flutter build apk`.
- If anything here is ambiguous or conflicts with a context file, STOP and surface it in
  `progress-tracker.md` as an open question rather than guessing (esp. the permission-key
  decision in §2).
