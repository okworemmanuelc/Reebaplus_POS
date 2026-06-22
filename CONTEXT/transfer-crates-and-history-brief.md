# Hand-off Brief — Empties-on-Transfer + Per-Store Transfer History

You are a junior implementer on the Reebaplus POS Flutter app. Read this brief
fully, then read the context files it points to, then implement the two units
**in order**, one at a time, verifying each before starting the next.

This brief finishes two items that were explicitly deferred when the
requester-initiated stock-transfer flow shipped:

- **Unit A — Empties move with a transfer.** The `transferCrates` data path
  exists and is fully proven on the cloud side, but it is **not wired into the
  new dispatch UI**. Wire it so a holder can send empty crates alongside the
  product when they dispatch a request.
- **Unit B — Per-store transfer history.** `received` / `cancelled` transfers
  are not surfaced anywhere per store. Add a read-only per-store history view.

Do **not** start coding until you have read the files in the next section.

---

## 0. Read first (in this order)

1. `context/project-overview.md` — product definition & scope. Note the
   stock-transfer bullet in **Platform & Reliability**; you will update it.
2. `context/architecture.md` — **re-read the Invariants section in full.** The
   ones that bite here: #1 (Drift is source of truth), #3 (append-only
   ledgers), #4 (every cloud write goes through the outbox), #6 (permissions
   are data, never hard-coded role names).
3. `context/code-standards.md` — tokens, naming, widget rules, import order,
   `ConsumerWidget`-first, hide-don't-block gating.
4. `context/ui-context.md` — design tokens and component conventions.
5. `context/progress-tracker.md` — current state; you will update it.

Then read the existing code you are extending:

- `lib/core/database/daos.dart` → class `StockTransferDao` (≈ line 4925). In
  particular `dispatchTransfer`, `transferCrates`, `requestTransfer`,
  `receiveTransfer`, `watchHistory`, and the `watchPending*` watchers.
- `lib/features/stores/widgets/store_transfer_hub.dart` — the per-store hub and
  its `_TransferActionCard` / `_askQuantity` dialog (this is where the dispatch
  action lives).
- `lib/features/stores/screens/store_details_screen.dart` — the full-access vs
  restricted branch; the hub is embedded here for full-access viewers.
- `lib/core/providers/stream_providers.dart` — the `storeIncoming*` /
  `storeOutgoing*` transfer providers, `allManufacturersProvider`,
  `storeCrateBalancesProvider`, `productsByStoreProvider`,
  `productsWithStockProvider`, `usersByBusinessProvider`, `allStoresProvider`.

### Hard constraints (project memory — do not violate)

- **No `flutter build apk`.** The app runs on an Android emulator via
  `flutter run`. Never propose an APK build.
- **Do not run `dart format`.** House style is the old dartfmt and is not
  enforced; running it will churn the whole file. Match the surrounding style
  by hand.
- **Never `git checkout` a dirty/uncommitted file.** This tree carries large
  uncommitted work. Undo by re-editing or stashing, never by checkout.
- **Tokens only.** No raw hex, pixels, `BorderRadius.circular(n)`, or
  `TextStyle(fontSize:)`. Use `context.getRSize` / `context.getRFontSize`,
  `AppRadius.*`, `Theme.of(context).colorScheme.*` / `textTheme.*`,
  `AppNotification.show*`. The hub already follows this — copy its patterns.
- **Hide-don't-block + 3-layer gating.** Gate on permission *keys*, never role
  names: render-gate (omit the widget), body-guard, and a write-boundary
  re-check (`ref.read(currentUserPermissionsProvider).contains(<key>)`) inside
  the action. The hub's `_run(...)` helper already does the write-boundary
  re-check — reuse it.
- **Every cloud write goes through the outbox.** `transferCrates` already
  enqueues the `domain:pos_transfer_crates` envelope. Do not add a direct
  Supabase call anywhere.
- **Append-only ledgers.** Crate movements are new `crate_ledger` rows; never
  UPDATE/DELETE a ledger row.

### What you must NOT do

- **No Drift schema migration.** Both units reuse existing tables
  (`stock_transfers`, `crate_ledger`, `store_crate_balances`). Do **not** bump
  `schemaVersion` or add an `onUpgrade` block.
- **No cloud migration.** The cloud RPC `pos_transfer_crates` already exists
  (`supabase/migrations/0107_pos_transfer_crates.sql`) and the sync service
  already handles the `domain:pos_transfer_crates` envelope and its
  server-minted `gen_random_uuid` ledger-id reconciliation
  (`lib/core/services/supabase_sync_service.dart`). You are only invoking an
  already-deployed path. Do **not** touch `supabase/` or the sync service.
- **No new permission key.** Sending empties is part of dispatch — it stays
  gated on the existing `stores.dispatch_transfer`. History is read-only and
  rides on the existing full-access branch. No catalogue change, no
  `app_database.dart` permission edit.

If any of the above turns out to be wrong (e.g. a guard you need does not
exist), **stop and surface it in `progress-tracker.md` as an open question** —
do not invent behaviour or widen scope.

---

## Unit A — Empties move with a transfer

### Goal (one sentence)

When a holder accepts & dispatches a pending request for a crate-eligible
product, let them optionally send N empty crates of that product's manufacturer
along with the stock, moving them from the holder store's empty-crate pool to
the requesting store's pool.

### Domain facts you must honour

- **Crate eligibility gates on the bottle, not the manufacturer.** Empties are
  tracked **only** when `product.unit` is `bottle` (compare **case-insensitively**
  — the stored default is `'Bottle'`) **AND** `product.trackEmpties == true`. A
  product that is PET, or a bottle with `trackEmpties == false`, must **not**
  offer the empties field and must **not** move any crates.
- **Empties are per-manufacturer.** The crate pool is keyed by `manufacturerId`
  (from `product.manufacturerId`), never per product. `transferCrates` already
  takes `manufacturerId`.
- **The holder store is the source.** In a `pending`/`in_transit` row,
  `fromLocationId` is the holder (source, where the empties leave from) and
  `toLocationId` is the requester (destination, where empties arrive). This
  matches the product direction at dispatch.
- The holder store's available empties for a manufacturer come from
  `store_crate_balances` for `fromLocationId` + that `manufacturerId`. Sending
  more than available would drive the pool negative — **the UI must cap the
  input at the available balance.**

### A1 — DAO: let dispatch carry empties

Extend `StockTransferDao.dispatchTransfer` (in `lib/core/database/daos.dart`)
with an optional parameter so the product dispatch and the crate move are one
user action, correctly ordered:

```dart
Future<void> dispatchTransfer({
  required String transferId,
  required String dispatchedBy,
  int? quantity,
  int emptyCratesToSend = 0, // NEW — 0 means "send no empties" (current behaviour)
}) async { ... }
```

Implementation contract:

1. Keep the existing behaviour exactly when `emptyCratesToSend == 0` (the
   common, non-crate case). Do not regress the current tested path.
2. Validate: if `emptyCratesToSend < 0` throw `ArgumentError`.
3. After the existing inventory `transfer_out` leg flips the header to
   `in_transit` and the dispatch succeeds, **if `emptyCratesToSend > 0`**:
   - Resolve the product row for `transfer.productId` (it carries
     `manufacturerId`, `unit`, `trackEmpties`). Use a business-scoped read —
     **never a raw `db.select` of a business-owned table** (see the
     business-scoping invariant); use the existing products DAO method that
     fetches a product by id within the business. If none exists, add a small
     business-scoped getter rather than reaching past the scope.
   - Compute eligibility: `unit.toLowerCase() == 'bottle' && trackEmpties`. If
     **not** eligible, throw `StateError` (the UI should never have offered the
     field; failing loud surfaces a programming error rather than silently
     dropping crates). Do **not** silently no-op.
   - Move the empties from `fromLocationId` → `toLocationId` for that
     `manufacturerId`, quantity `emptyCratesToSend`, performed by
     `dispatchedBy`, using the **same crate-ledger + `store_crate_balances` +
     `domain:pos_transfer_crates` envelope** that `transferCrates` already
     implements.

   **Reuse, don't duplicate.** Factor the body of the existing `transferCrates`
   (the two `crate_ledger` inserts, the two `store_crate_balances` upserts, and
   the `domain:pos_transfer_crates` enqueue) into a private,
   transaction-agnostic helper, e.g.:

   ```dart
   Future<void> _writeCrateTransferLegs({
     required String transferId,
     required String fromStoreId,
     required String toStoreId,
     required String manufacturerId,
     required int quantity,
     required String performedBy,
   }) async { /* the current transferCrates body, WITHOUT its own transaction() */ }
   ```

   Then:
   - `transferCrates(...)` wraps `_writeCrateTransferLegs(...)` in
     `transaction(() => ...)` (its public contract is unchanged).
   - `dispatchTransfer(...)` calls `_writeCrateTransferLegs(...)` **inside its
     existing `transaction`**, after the inventory leg, so the product dispatch
     and the crate move commit together locally.

   Keep `transferCrates` public — it remains a reusable building block; just
   don't leave its logic duplicated.

4. Notifications/activity log: the existing dispatch notification is fine.
   Optionally append the empties count to the activity-log description (e.g.
   `… + N empty crate(s)`); keep it to the existing `activityLogDao.log` call,
   do not add a second notification.

> Ordering note: write the crate legs **after** the inventory `transfer_out`
> leg inside the same transaction, so an `InsufficientStockException` on the
> product aborts the whole thing (no orphaned crate movement).

### A2 — Provider: holder-store empties by manufacturer

In `lib/core/providers/stream_providers.dart`, add a `.family` provider keyed by
`storeId` that exposes the store's current empty-crate balance per manufacturer
as a `Map<String, int>` (`manufacturerId → balance`), e.g.
`storeEmptiesByManufacturerProvider`. Source it from the existing
`storeCrateBalancesDao.watchForStore(storeId)` (the same DAO method
`storeCrateBalancesProvider` uses), mapping rows to
`{ row.manufacturerId: row.balance }`. Follow the file's existing provider
style and doc-comment conventions.

### A3 — UI: offer empties in the dispatch dialog

In `lib/features/stores/widgets/store_transfer_hub.dart`:

- The `_TransferActionCard` for `_CardMode.fulfil` is the only place that
  dispatches. Pass it the data it needs to decide whether to offer empties:
  - `manufacturerId` (from the product),
  - `isCrateEligible` (`unit.toLowerCase() == 'bottle' && trackEmpties`),
  - `availableEmpties` for the **holder** store (`transfer.fromLocationId`,
    which equals the hub's `storeId`) and this `manufacturerId`, read from the
    new `storeEmptiesByManufacturerProvider(storeId)`.

  Resolve `unit` / `trackEmpties` / `manufacturerId` from the product. The hub
  already builds `products` from `productsWithStockProvider(null)`; each
  `ProductDataWithStock` exposes `.product.manufacturerId`, `.product.unit`,
  `.product.trackEmpties`. Build the lookups alongside the existing
  `productNames` map.

- Extend `_askQuantity()` so that **when `isCrateEligible && availableEmpties > 0`**
  it shows a **second** numeric field — "Empty crates to send (optional)",
  default `0`, with a hint line like `Available here: <availableEmpties>`. Cap
  the value at `availableEmpties` (clamp on submit; show
  `AppNotification.showError` if they exceed it, or silently clamp — pick one
  and be consistent). When the product is not eligible, the dialog is unchanged
  (quantity only). Return both values (e.g. a small record
  `({int quantity, int empties})` or extend the return type) so `_accept` can
  pass them through.

- `_accept()` passes `emptyCratesToSend:` into `dispatchTransfer`. Keep the
  existing write-boundary re-check via `_run('stores.dispatch_transfer', …)`.
  Update the success message to mention the empties when `> 0`
  (e.g. `Dispatched N unit(s) + M empty crate(s) to <store>.`).

- Use only tokens and the hub's existing `AppInput` / button helpers. Dispose
  any new `TextEditingController` you create.

### A4 — Tests (Unit A)

Extend `test/transfer/stock_transfer_dao_test.dart`:

- `dispatchTransfer` with `emptyCratesToSend > 0` on a crate-eligible product:
  flips header → `in_transit`, decrements source product stock (existing
  assertion), **and** writes two `crate_ledger` rows
  (`transferred_out` at `fromLocationId` = `-M`, `transferred_in` at
  `toLocationId` = `+M`), updates `store_crate_balances` both sides, and
  enqueues a `domain:pos_transfer_crates` outbox row.
- `dispatchTransfer` with `emptyCratesToSend == 0` (default): **no** crate rows,
  **no** `domain:pos_transfer_crates` enqueue — proves the non-crate path is
  untouched.
- `dispatchTransfer` with `emptyCratesToSend > 0` on a **non-eligible** product
  (PET, or bottle with `trackEmpties == false`): throws `StateError`, and the
  transaction rolls back (no header flip, no crate rows). Pick whichever is
  simplest to assert given the existing test harness.
- Insufficient **product** stock with empties requested: the existing
  `InsufficientStockException` still aborts everything — assert no crate rows
  are written.

Match the existing test file's setup helpers and assertion style.

### A5 — Verify Unit A before moving on

- `flutter analyze` → zero errors, zero new warnings.
- `flutter test test/transfer` → green.
- Confirm by reading the diff that no schema/migration/sync-service file was
  touched and no new permission key was added.

---

## Unit B — Per-store transfer history

### Goal (one sentence)

Give a full-access viewer of a store a read-only list of that store's completed
transfers (`received` and `cancelled`), covering both directions
(sent-from and arrived-at this store).

### B1 — DAO: per-store history watcher

In `StockTransferDao` add:

```dart
/// Completed transfers touching [storeId] — `received` or `cancelled`, in
/// either direction (fromLocationId == storeId OR toLocationId == storeId),
/// newest first. Read-only history for the store-details hub.
Stream<List<StockTransferData>> watchHistoryForStore(String storeId) { ... }
```

Filter: `whereBusiness(t) & (t.fromLocationId.equals(storeId) |
t.toLocationId.equals(storeId)) & t.status.isIn(['received', 'cancelled'])`,
ordered by `initiatedAt` desc. Mirror the style of the existing `watchHistory`
/ `watchPendingForHolderStore` methods. Leave the business-wide `watchHistory`
in place.

### B2 — Provider

In `lib/core/providers/stream_providers.dart` add a `.family` provider:
`storeTransferHistoryProvider` →
`StreamProvider.family<List<StockTransferData>, String>` watching
`watchHistoryForStore(storeId)`. Follow the existing `storeIncoming*` /
`storeOutgoing*` provider conventions in that file.

### B3 — UI: a read-only history section

Add the history to the per-store full-access view. Two acceptable placements —
pick the one that fits the existing layout best and keep it read-only:

- a collapsed/expandable **"Transfer history"** section at the bottom of
  `store_transfer_hub.dart` (preferred — keeps all transfer UI in one widget), or
- a **"View transfer history"** button in `store_details_screen.dart`'s
  full-access branch that opens a simple list.

Requirements for the list:

- Show, per row: product name, quantity, the **direction** relative to this
  store (e.g. an "Out" chip when `fromLocationId == storeId`, an "In" chip when
  `toLocationId == storeId`), the counterparty store name, the status
  (`received` / `cancelled`), and the date (`initiatedAt` or `receivedAt`).
- Resolve product names from `productsWithStockProvider(null)` and store names
  from `allStoresProvider`, exactly as the hub already does.
- Cap the list to a sensible recent window (e.g. the most recent ~20–30) to
  avoid an unbounded list; the full ledger is not needed here.
- **Read-only. No actions, no buttons that mutate.** Empty state: a single
  muted "No past transfers for this store." line, consistent with the hub's
  existing empty-state styling.
- Tokens only; reuse the hub's card/section styling so it looks native.

> Do **not** try to show crate counts in history — `stock_transfers` has no
> crate column, and the crate legs live in `crate_ledger`. History is about the
> product transfer rows only. If a crates-in-history view is ever wanted it is a
> separate unit; note it as an open question rather than building it.

### B4 — Tests (Unit B)

Extend `test/transfer/stock_transfer_dao_test.dart`:

- `watchHistoryForStore(storeId)` returns `received` + `cancelled` rows where
  the store is either source or destination, newest first.
- It **excludes** `pending` and `in_transit` rows.
- It **excludes** rows that touch only other stores.

### B5 — Verify Unit B

- `flutter analyze` → clean.
- `flutter test test/transfer` → green.

---

## Docs to update (part of the work, not a follow-up)

Per `ai-workflow-rules.md`, a unit is not done while a doc still describes the
old behaviour:

- `context/project-overview.md` — the stock-transfer bullet in **Platform &
  Reliability** currently says moving empty crates alongside a transfer "exists
  in the data layer but is not yet wired into the new request/dispatch UI
  (deferred follow-up)." Rewrite it to state empties now move with a dispatch
  (per-manufacturer, holder→requester, capped at the holder's available pool)
  and that per-store transfer history is now surfaced. Remove the "deferred
  follow-up" caveat for these two items.
- `context/progress-tracker.md` — record both units as completed; note any open
  questions you raised.
- `BUILD_LOG.md` — add a dated entry per the project convention (log working
  fixes/features after verification). **Re-read the file immediately before
  editing** — it is edited in parallel; anchor your insert on a stable heading
  and do not clobber other entries.

---

## Definition of done (verify each explicitly — do not assume)

1. A holder dispatching a crate-eligible product can send empties along; they
   move holder→requester per-manufacturer through the existing
   `domain:pos_transfer_crates` envelope; the non-crate dispatch path is
   unchanged.
2. The empties field appears **only** for `bottle` + `trackEmpties` products and
   is capped at the holder store's available balance.
3. A full-access viewer of a store sees a read-only history of that store's
   `received` / `cancelled` transfers, both directions.
4. No Drift migration, no cloud migration, no sync-service change, no new
   permission key (confirm by reading the diff).
5. No invariant in `architecture.md` violated — re-confirm #3 (append-only),
   #4 (outbox), #6 (permissions are data) by name.
6. `code-standards.md` honoured: `ConsumerWidget`-first, tokens not raw values,
   hide-don't-block gating with write-boundary re-checks, business-scoped DAO
   reads only.
7. `flutter analyze` → zero errors / zero new warnings.
8. `flutter test test/transfer` → green (and any other suite you touched).
9. All three docs above updated in the same change.

**Manual step left to the user (cannot be done headless):** an on-emulator
walkthrough via `flutter run` of accept-with-empties → confirm receipt, and the
history list. Note this in your hand-back; do not attempt an APK build.
</content>
</invoke>
