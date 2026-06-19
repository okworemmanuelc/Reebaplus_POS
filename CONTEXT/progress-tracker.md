# Progress Tracker

Update this file after every meaningful implementation change.
The agent reads this file at the start of every session to restore full context.
The human updates it when resolving open questions or making architectural decisions.

---

## Current Phase

149 sessions logged. Codebase is live and being verified on-device.

### Daily Reconciliation Report engine enhancements (Part 1, 2, & 3)
- **ReconData updates (Part 1):** Added `supplierPayableKobo`, `inventoryOnHandKobo`, `uncostedInventoryItems`, `surplusCostKobo`, `topItems`, and `manufacturerEmpties`.
- **Invariants maintained:** `orderCountsAsSale(status)` remains unchanged; ledger filtering for voided entries is strictly followed; money math is exclusively in kobo (`int`).
- **Design decisions explicitly noted:**
  - `productsWithStockProvider(null)` returns aggregated stock since `ProductDataWithStock` does not expose `storeId` on the individual items; as a result, the `inventoryOnHandKobo` property aggregates all available `totalStock` returned by the provider without additional `storeId` filtering.
  - For `businessNetPositionKobo`, customer debt (`totalOwedKobo`) was treated as a positive value (to be flagged as "at risk" in UI later), and empty crates held (`crateDepositKobo`) was updated to be a recoverable asset (`+ crateDepositKobo`) as directed in Part 2.
- **Statement UI Rebuild (Part 2):**
  - Rebuilt `_statementCard` in `daily_reconciliation_detail_screen.dart` into three clear semantic sections: "Net result for this period", "Business worth right now", and "Other context flows".
  - Used `AppSemanticColors.success` and `theme.colorScheme.error` for profitability metrics.
  - Added new fields to CSV export for CEO roles only.
- **Sales & Empty Crates UI (Part 3):**
  - Expanded `_salesCard` to list the top 3 selling items dynamically.
  - Rebuilt `_cratesCard` to show a detailed per-manufacturer breakdown of crates held along with their respective deposit values.
- **Verification:** Ran `flutter analyze` locally, no issues found.

---

## Crate Flow Mapping (Confirmed)
- **Crates TAKEN (at checkout)**: `checkout_page.dart` receives `crateLines` from `cart_screen.dart` (gated by `unit=='bottle' && trackEmpties`). 
  - `_buildCrateDepositSection()` handles per-brand deposit capture when `_depositApplies` is true (registered customer + Cash/Transfer + crate business).
  - A new `_buildReadOnlyCratesSection()` displays a read-only confirmation of empties taken for walk-ins, wallet, or credit sale payment modes.
  - On confirm, `addOrder` logs crates taken + deposit snapshot + deposit paid into `order_crate_lines`, ensuring dual-write symmetry locally and on the cloud.
- **Crates RETURNED**: `crate_return_modal.dart` correctly recognizes crate returns exclusively through the pending-order confirm modal (`CrateReturnModal.show`). The checkout path correctly isolates sale creation without invoking any return or settlement writes.

---

## Call-Site Audit for Receipt Construction
1. **`lib/features/orders/screens/orders_screen.dart:852`** (`_viewReceipt`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param.
2. **`lib/features/orders/screens/orders_screen.dart:997`** (`_printReceipt`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param (for `ThermalReceiptService`).
3. **`lib/features/customers/screens/customer_detail_screen.dart:987`** (`_showReceipt`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param.
4. **`lib/features/customers/screens/customer_detail_screen.dart:1088`** (`_printReceiptFromDetail`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param (for `ThermalReceiptService`).
5. **`lib/features/pos/screens/checkout_page.dart:1436`** (`_printReceipt`): Cart map is intact, but `buildReceipt` doesn't currently accept `manufacturerNames`. Will be updated.

**Decisions Recorded:**
- `cratesOwed` and `cratesCredit` will be completely removed from `receipt_widget.dart` and `buildReceipt` params as they are replaced by the new "Empty Crates" section.
- Extract the per-manufacturer grouping into a shared helper in `receipt_widget.dart` to avoid duplicating the manufacturer list. The new always-on "Empty Crates" section owns the manufacturer + count breakdown, and the "Crate Deposit" block will be collapsed to a single financial line.

---

## Current Goal

On-device verification of Session 143 pull-side pagination (throttled/cellular
connection), Session 144 onboarding form updates (business type picker,
phone + LGA fields), and verification of the permission gating screen rendering.

---

## Completed

### Daily Reconciliation UI Modernization & Custom Range (2026-06-19)
- Redesigned `DailyReconciliationListScreen` to follow the glassy UI standard (`AppDecorations.glassyBackground`, `SharedScaffold`).
- Extracted the period dropdown from the title bar into a dedicated, wider row above the list.
- Added a "Custom range" option to the dropdown via `showDateRangePicker`. Selecting a custom range queries the daily aggregation (`ReconGrouping.day`) bounded by the selected start and exclusive end dates.
- Export to CSV reflects the custom period naming and date range in the subject.
- Replaced the simple card container with a glassy `ClipRRect` + `BackdropFilter` card wrapper.
- Uses `NotificationListener<ScrollUpdateNotification>` for scroll-reactive AppBar background transition.

### Empty Crates "Full" counted non-bottle stock — PET tracked (2026-06-19)
- Bug: a Coca-Cola PET product was tracked in the inventory Empty Crates tab —
  `InventoryDao.watchFullCratesByManufacturer` summed ALL of a manufacturer's
  inventory as "Full" crates (only filtered `manufacturerId != null` + not-deleted),
  while the cart and `createOrder` gate crate issuance on
  `unit == 'bottle' && trackEmpties`.
- Fix: added `unit.lower() == 'bottle'` + `trackEmpties = true` to the query so
  Full matches createOrder's basis. A bottle+PET manufacturer counts only the
  bottle stock; empties were already bottle-only. Updated 2 fixtures + new
  regression test (PET not counted). 16/16 crate tests green. See BUILD_LOG.

### Glassy transition ghosting fixed — opaque page backgrounds + tab warm-up (2026-06-19)
- Root cause of "leftover previous screen": the Glassy page background set both
  `BoxDecoration.color` and `gradient`, but `color` is ignored when `gradient`
  is set — and the gradient's tint stops (primary @0.05/0.12) were ~90% transparent,
  so pages were see-through and the screen beneath bled through during route pushes.
- New central helper `AppDecorations.glassyBackground(context)` — same look, every
  stop made opaque via `Color.alphaBlend(tint, scaffoldBg)`. Applied to
  glassy_scaffold, customers, customer_detail, home, supplier_transactions,
  supplier_accounts_report, supplier_detail.
- `MainLayout._warmNextTab()`: mounts tabs offstage one-per-frame after first frame
  so the first bottom-nav tap isn't a cold synchronous build (lag). 200ms tab
  cross-fade kept; route `FadeTransition` removal from slide_route.dart stays.

### Cart + cart/orders badges store-gated to side-bar store §12.1 (2026-06-19)
- Cart storage re-keyed `userId` → `"userId|storeId"`; `CartService` now takes
  `NavigationService` and swaps the live cart/customer on `lockedStoreId` change.
  Switching stores shows that store's own cart; "All Stores" is its own bucket.
- Cart-tab badge follows automatically (ValueListenableBuilder on `cartProvider`).
- Orders-tab badge now filters pending orders by the active store: switched the
  `main_layout` sub to `ordersDao.watchPendingOrders()` (`OrderData` w/ storeId)
  and counts by `lockedStoreProvider` at build. Cart tests + analyze green.
- **Saved carts store-tagged** (§13.5 follow-up): nullable `saved_carts.store_id`
  (Drift v54 → **v55**, cloud `0119_saved_carts_store_id.sql` — pushed). Save
  stamps the active store; the Recall list (`watchSavedCarts(.., storeId:)`) is
  confined to it (null-store legacy rows stay visible everywhere); `loadCart`
  switches the side-bar store to the cart's origin store and restores into that
  bucket so a store-A cart can't leak into B. New
  `test/pos/saved_cart_store_gating_test.dart`.

### Custom price on a cart item §13.4 + `sales.set_custom_price` (2026-06-19)
- New feature: a permitted user can sell a cart line at a price other than its
  designated selling price; the CEO toggles who may do so per role.
- **Permission:** new catalogue key `sales.set_custom_price` ("Set a custom
  price on a cart item", Sales). CEO-only by default; shows as a normal toggle
  on Roles & Permissions (NOT hidden), so it inherits the business/store/user
  override layers. Local: added to `_defaultPermissionRows`; Drift schema
  **v53 → v54** with an idempotent `if (from < 54)` `INSERT OR IGNORE INTO
  permissions` (v48 pattern; no table change). Cloud:
  `0118_add_sales_custom_price_permission.sql` (catalogue + CEO backfill; new
  businesses auto-grant via the CEO dynamic SELECT) — **pushed 2026-06-19**;
  verified 6/6 CEO roles granted, 0 non-CEO grants.
- **Cart model (`cart_service.dart`):** lines gain immutable `catalogPriceKobo`
  + `customPriceKobo` (null = none). `setCustomPrice` overwrites the effective
  `unitPriceKobo`/`price` (so order line + totals + profit math are unchanged)
  and reverts to catalog when cleared; re-clamps any discount. `refreshProduct`
  keeps the custom price but tracks the new catalog ref; `acceptStaleness` bumps
  the catalog ref too.
- **UI (`edit_item_modal.dart`):** permission-gated "Custom Price" section above
  discount; discount cap computes off the effective line total; save applies the
  custom price before the discount in both add and edit modes.
- **Checkout/cart:** `_detectCartStaleness` skips custom-priced lines (a hand-set
  price is never reverted); cart screen shows a "Custom price" badge.
- New `test/pos/cart_custom_price_test.dart` (5 green). `roles_v13_seed_test`
  35 → 36. `flutter analyze lib` clean (3 pre-existing settings warnings);
  pos/sync/database suites green. See BUILD_LOG 2026-06-19.

### Login routing changed to POS (2026-06-19)
- Changed the default post-login landing screen from Home (Dashboard, index 0) to Point of Sale (index 1) for all roles, including CEO and Manager, matching the user's intent to land them on POS directly after sign in.
- Updated `auth_service.dart`, `navigation_service.dart`, and UI strings in `ceo_sign_up_screen.dart` and `success_dashboard_entry_screen.dart` to refer to "Point of Sale" instead of "dashboard".
- Updated `CONTEXT/project-overview.md` to reflect this change in the core flow and success criteria.

### UI Consistency & Layout fixes (2026-06-19)
- Standardized responsive grid and card layout patterns in `ui-context.md` to prevent text overflow when system font scaling and layout scaling differ.
- Fixed a bottom text overflow issue in `product_grid.dart` by refactoring text blocks to use intrinsic height (via standard containers without flex properties) while keeping the visual area flexible.

### Supplier empty-crate tracking §3.13 — full build (2026-06-19)
- Replaced the §3.13 "coming soon" placeholder on Supplier Details with real
  per-supplier empty-crate tracking — the supplier-side mirror of the customer
  crate subsystem. A customer owes US empties; here WE owe the SUPPLIER empties
  for the full crates they deliver, and the deposit value is the outstanding
  crates × the per-manufacturer rate.
- **Schema (Drift v52 → v53):** two new tables, mirroring the customer side.
  `supplier_crate_ledger` (append-only movement log: `received` +, `returned` −,
  `adjusted`; carries `deposit_paid_kobo`, `store_id`) registered in
  `_syncedTenantTables` + `_ledgerTables` (immutable + no-delete triggers).
  `supplier_crate_balances` (per-(supplier, manufacturer) cache, balance =
  SUM(delta); positive = we owe) registered in `kSyncCacheTables` +
  `_naturalKeyPushConflictTargets`. onUpgrade v53 + `_postCreateStatements`
  index/trigger parity so onCreate == upgrade. Cloud migration
  `0117_supplier_crate_tracking.sql` (table+RLS via `current_user_business_ids()`
  +realtime+bump trigger+`pos_pull_snapshot`) — **written, NOT yet pushed**.
- **DAOs:** `SupplierCrateLedgerDao` (recordCrateReceiptFromSupplier /
  recordCrateReturnToSupplier / watchHistory / watchDepositHeldKobo) +
  `SupplierCrateBalancesDao` (watchBySupplier / watchTotalOwed). Mirrors
  `CrateLedgerDao`. Service `SupplierCrateService` adds Activity-Log writes.
- **Sync:** both tables wired into `_pullOrder`, `_restoreTableData`
  (supplier_crate_ledger via `_restoreLedgerTable`, the cache via natural-key
  resilient upsert), `_tablePushPriority`, `_deferrableTables`. The sync
  registration-completeness test passes.
- **UI:** Supplier Details → **Empty Crates** tab now shows the net crate
  balance (owed / credit), the refundable deposit value, per-manufacturer rows,
  and a "Record crate activity" sheet (Received / Returned + manufacturer + count
  + optional deposit), gated on `suppliers.manage` with a write-boundary re-check.
  **Receive Delivery** now records a supplier crate receipt per tracked line
  (the supplier-side analogue of crate-issue-at-sale) so the invoice tracks how
  many crates arrived.
- **Deposit model decision:** the headline "Deposit value (refundable)" is
  COMPUTED as Σ(positive balance × `Manufacturers.depositAmountKobo`) so it stays
  consistent with the crate balance automatically; the record sheet still stores
  the actual `deposit_paid_kobo` per row for the audit trail (and
  `watchDepositHeldKobo` nets paid − refunded for tests/future detail).
- New `test/suppliers/supplier_crate_test.dart` (5 green: receipt/return netting,
  crate credit, per-(supplier,manufacturer) scope, deposit-held netting,
  append-only delete rejection). `flutter analyze lib` clean (only the 3
  pre-existing settings unused-import warnings). Full suite 452 pass / 58 skipped
  / 1 pre-existing unrelated failure (`invite_staff_sheet_test`). build_runner
  regenerated. See BUILD_LOG 2026-06-19.

### Sync Issues — collapse `sessions:upsert` churn (2026-06-18)
- Diagnosed a Sync Issues queue full of pending `sessions:upsert` / a couple
  `user_businesses:upsert` rows (attempts → 15). Errors were network-rooted:
  errno-7 `Failed host lookup` (DNS down, on the auth token-refresh URI) and
  15s `TimeoutException` — device-side outage, not sync logic; Failed/Orphaned
  were 0, so the queue was retrying correctly and drains on reconnect.
- Real fix: `SessionsDao.createSession` minted a fresh id on every re-auth,
  defeating `enqueueUpsert`'s coalescing (keyed on `payload.id`) → one outbox
  row per login. Now it reuses the existing active session for the same
  `device_id`+`user_id` (bumps `expires_at`, re-enqueues same id), so re-auth
  pushes collapse into one coalesced row. Revoked/expired sessions still mint
  fresh. `AuthService._kickOtherDevices` cloud session `insert`→`upsert` so a
  reused id can't 23505. `flutter analyze` clean; on-device pass pending.
  See BUILD_LOG.

### Supplier Accounts §21 — verification-list gaps closed (2026-06-18)
- Closed the four remaining gaps against the 130-check Phase-1 verification list
  (the core ledger was already built & store-scoped):
  - **§4 confirmation gate** (user-confirmed): Invoice Total and Payment now
    confirm (type/supplier/amount/date/method/store + permanence warning) before
    writing — `confirmSupplierActivity` in `record_supplier_activity.dart`.
  - **§10 CEO void/reversal**: ledger rows tappable on Supplier Details
    (`SupplierLedgerEntryTile.onTap`) → action sheet → confirm → compensating
    row keeps original `store_id`. `SupplierLedgerDao.voidEntry` returns `bool`
    (double-void no-op, 10.11); `SupplierAccountService.voidEntry` logs a
    `supplier.void` Activity row (10.12). CEO-only render-gate + write-boundary.
  - **§15 Supplier Accounts Report**: new `SupplierAccountsReportScreen` + Reports
    hub card gated on `suppliers.manage` (CEO default / Manager toggle / hidden
    for Cashier+Stock keeper). Per-supplier balance/paid/received, store-scoped;
    gross excludes voids, balance nets them. No schema/DAO change.
  - **§3.13 Available Empty Crates**: display-only placeholder on Supplier
    Details for crate businesses (real wiring deferred).
- `test/suppliers/supplier_ledger_test.dart` added (4 green). `flutter analyze
  lib` clean for touched files. On-device pass still pending. See BUILD_LOG.

### Release "session has expired" — investigation + diagnostic breadcrumbs (2026-06-18)
- Investigated a release-build report of being signed out with "session has
  expired". Identified two distinct forced-logout paths: the remote *kick*
  (single-active-device → `fullLogout`, "signed in on another device") vs. the
  *session-expired* gate (`main.dart` `_SessionExpiredScreen`, shown when a local
  user is set but `_supabaseHasSession == false`). The latter flips only on a real
  Supabase `signedOut` event (transient refresh failures are swallowed on
  `onError`), so it means the refresh token was genuinely revoked server-side.
- **Google verdict:** Google sign-in cannot end the signing-in device's own
  session — `_kickOtherDevices` uses `signOut(scope: SignOutScope.others)`, which
  always preserves the requesting session. Google and email/OTP funnel through the
  identical `resolvePostVerifyRoute`; the kick fires from one place
  (`biometric_setup_screen.dart:101`) on a *fresh* sign-up by both providers. A
  release device expiring = the single-active-device policy revoking it because
  the same account signed in elsewhere.
- **Added (no behaviour change):** `auth.session_lost` and
  `auth.session_expired_gate` breadcrumbs to the synced `error_logs` table
  (release-visible in the Supabase console; the latter tags the stored auth method
  so reports can be attributed by provider). Documented the previously-undocumented
  "Single active session per identity" policy in `architecture.md`. `flutter
  analyze lib/main.dart` clean. See BUILD_LOG 2026-06-18.
- **Follow-up fix (same day):** the breadcrumbs weren't actually reaching the
  cloud — verified the live `error_logs` table had 34 rows (generic crashes,
  incl. today) but **zero `auth.*`**. Cause: they fire when the JWT is gone, and
  on the kick path *after* `AuthService.value` is nulled, so `ErrorLogDao.logError`
  resolved `bid == null` and kept the row local-only (never enqueued). Fixed by
  threading an explicit `businessId`/`userId` through `CrashReporter.record` →
  `logError` and scoping each breadcrumb to the in-hand local user, so it's
  durably enqueued and flushes on the next authenticated push (the gate's own OTP
  re-auth). Migration 0108 (`error_logs`) confirmed deployed. `flutter test
  test/sync/` 119/119 green. See BUILD_LOG 2026-06-18.

### Cold-start sync warm-up — false `timeout` on first push after login (2026-06-18)
- Symptom: a `user_businesses:upsert` row failed with a 5s `TimeoutException`
  in Sync Issues right after login, then healed on retry.
- Cause: the first push of a session gets a fail-fast 5s budget, but the first
  authenticated request is cold (DNS+TLS+radio wake+session settling) and
  exceeds it; the first-enqueued row (`user_businesses` after login) eats it.
- Fix (`supabase_sync_service.dart`): `_warmUpConnection` fires one cheap
  `businesses` select before the first drain (pays the cold cost on a throwaway
  request), gated by `_didWarmUpThisSession` (reset on sign-in/out); first-drain
  per-chunk timeout floored at 10s as a backstop. Later drains fail fast as
  before. Sync suite green (119); analyzer clean. See BUILD_LOG 2026-06-18.

### Empty Crates tab — per-store accuracy (Phase 2 active, §16.8.1) (2026-06-18)
- **Reverses the locked Phase-1 business-wide decision below.** The inventory
  Empty Crates tab now shows **per-store** empties when a store is locked, and
  the business-wide total only in "All Stores" mode (`lockedStoreId == null`).
- Data layer: `watchFullCratesByManufacturer({storeId})` gained an optional
  store filter (joins `inventory↔products` on `manufacturer_id`, filters
  `inventory.store_id`); `fullCratesByManufacturerProvider` is store-scoped via
  `lockedStoreProvider`. Empties read from `store_crate_balances` (per store) or
  `manufacturers.empty_crate_stock` (All Stores) — the
  `emptyCrateStock = Σ store_crate_balances` invariant holds.
- Attribution: a **manual** crate return from Customer Profile is credited to
  the store the customer's most recent crate-bearing order was created from
  (`OrderCrateLinesDao.resolveStoreForCustomerManufacturer`), falling back to
  the active store. Receive-Delivery already hard-requires a store;
  crate-return modal already passes `order.storeId` — no leak there.
- UI: Crates tab refactored to reactive `ref.watch` (store can change on any
  tab); removed the redundant imperative crate stream subscriptions.
- Tests: per-store filter + resolver coverage added to
  `test/crates/crate_logic_test.dart` (15 tests green). No schema migration
  (0104 `store_crate_balances` already shipped). See BUILD_LOG 2026-06-18.

### Crates tab "Full" always showed zero — ID-vs-name lookup (2026-06-17)
- Bug: in the inventory Empty Crates tab, every manufacturer card's **Full**
  stat read 0. `_manufacturerCrateStats` is keyed by manufacturer **ID** (the
  watch streams emit ID-keyed maps), but `_buildCratesTab` matched
  `s.manufacturer == mfr.name`, so it never matched and fell to `orElse`
  (`totalBottles: 0`).
- Fix: match by `mfr.id` in `inventory_screen.dart`. No data-layer change — Full
  already streams live from `inventory.quantity` joined on `manufacturer_id`, and
  all writes are stream-tracked (`updates:{inventory}` on the sale decrement,
  `updates:{manufacturers}` on `addEmptyCrates`), so Full depletes on sale and
  empties (returns + pending-order-confirmation deliveries) increment live.
- Test: `watchFullCratesByManufacturer is ID-keyed and depletes on sale` added
  to `test/crates/crate_logic_test.dart` (12 tests green). See BUILD_LOG.

### Revenue recognized at checkout, not at Confirm (2026-06-17)
- Locked model: revenue is recognized when **checkout** completes (order written
  `pending` — wallet legs booked, inventory deducted). **Confirm**
  (`markCompleted` → `completed`) is ceremonial: it records receipt of goods and
  returned empty crates; it creates no revenue.
- Bug: every money/sales aggregation filtered on `status == 'completed'`, hiding
  checked-out-but-unconfirmed sales from all revenue figures until confirmation.
- Fix: canonical `orderCountsAsSale` / `orderRevenueStatuses = {'pending',
  'completed'}` in `lib/shared/models/order_status.dart`; routed Daily
  Reconciliation (`recon_data.dart`), dashboard (`home_screen.dart`), Profit
  Report, Profile Sales Volume, staff sales (`staff_detail_screen.dart`), and
  `getSalesSummaryForProduct` through it. Cancelled/refunded stay excluded. No
  schema change. Analyzer clean; order/wallet tests green. See BUILD_LOG.

### Empty crates — live-refresh fix + business-wide Phase 1 (2026-06-17)
- **Bug fixed:** crate return from Customer Profile didn't update the Crates tab.
  Root cause: balance caches were upserted via raw `customStatement`, invisible
  to Drift's stream tracker. Routed all 5 upserts through `customInsert(...,
  updates: {table})` (`recordCrateReturnByCustomer`, `recordCrateIssueByCustomer`,
  `recordCrateReturnByManufacturer`, `StoreCrateBalancesDao.applyDelta`/`setBalance`).
- **Phase scope decision (SUPERSEDED 2026-06-18 — see Phase 2 entry above):**
  ~~Phase 1 empty-crate counts are BUSINESS-WIDE (checklist §8.7), NOT per-store.
  `store_crate_balances` / `storeCrateBalancesProvider` stay as Phase-2
  scaffolding (rows still written) but no Phase-1 UI reads them. Inventory Empty
  Crates tab now always reads `manufacturers.empty_crate_stock`.~~ The tab now
  reads per-store balances when a store is locked.
- Manual crate return writes an Activity Log row (§7.8); an owed-crate sale
  fires a CEO+Manager `customer_crate_debt` notification (§12.1/§12.2) via a
  best-effort post-sale hook in `OrderService._notifyCrateDebt`.
- Cart "Empty Crates" section hidden for walk-in customers (§3.13).
- Tests: 2 watch-stream regression tests + 3 crate-debt notification tests.
  No schema migration needed (existing tables). See BUILD_LOG 2026-06-17.

### Dashboard debt/credit now business-wide, not store-scoped (2026-06-17)
- Fixed multi-store dashboard inaccuracy: a customer's single business-wide
  wallet balance was being attributed to their assigned home store
  (over/under-counting cross-store customers). `totalCredit`/`totalDebt` now
  fold over all customers regardless of the active store; sales/inventory/
  expenses stay store-scoped. Product decision: a wallet is business-wide.
  Analyzer clean. See BUILD_LOG 2026-06-17.
- Investigation: the accompanying `order_items`/`wallet_transactions` 23503 FK
  violations were transient on the v1 per-table push path (parent `orders`
  chunk times out → loop cascades into child pushes that FK-fail → retry +
  orphan auto-recovery self-heal). Cloud verified: no data lost.

### Push cascade guard — abort cycle on degraded link (2026-06-17)
- Fixed the FK-violation storm at the source: `pushPending` now stops the push
  cycle when a group hits a timeout / transient network error (parents likely
  didn't land) instead of cascading into child groups that are guaranteed to
  23503. Per-row FK-deferred / permanent errors keep their own backoff. Domain
  envelopes + the 200-row re-drain are also skipped while degraded. Analyzer
  clean; 119/119 sync tests pass. See BUILD_LOG 2026-06-17.

### Sync retry hardening — backoff cap + auto orphan recovery (2026-06-17)
- §6.8: capped the transient-retry backoff ceiling in `SyncDao.markFailed`
  (5 min normal / 15 min FK-deferred) so a many-times-failed row can no longer
  drift ~4 h into the future and stay stuck on a continuously-online device.
- §6.8.1: automatic orphan recovery. A periodic (30 s drain tick) +
  connectivity-recovery sweep (`autoRecoverDueOrphans`) re-enqueues orphans whose
  cause now self-heals — `fk_deferred_cap_reached*` (parent may have landed) and
  `*created_at is immutable*` (ledger scrub at push, S134). New device-local
  `auto_retry_count` on `sync_queue` + `sync_queue_orphans` (Drift v52) survives
  re-orphaning so the per-orphan cap (3) holds; then the row is parked for manual
  review. Terminal reasons (dup order number, RLS, bad-parameter) stay
  manual-only. Conservative allowlist chosen by product decision. Manual
  `retryOrphan` resets the counter. 4 new tests; full suite + migration test
  green. Local-only schema change — no cloud migration. See BUILD_LOG 2026-06-17.

### Realtime resubscribe on resume / reconnect (2026-06-17)
- Fixed: live (realtime) sync silently dying on a physical device after the app
  is backgrounded or the network switches — `startRealtimeSync` only ran once at
  sign-in and never re-subscribed dead channels. Added
  `SupabaseSyncService.restartRealtimeSync`, called on app-resume
  (`auto_lock_wrapper`) and connectivity recovery. Analyzer clean; awaiting
  on-device confirmation. See BUILD_LOG 2026-06-17.

### Foundation
- Database schema rebuild — Drift schema v13 (Session 2). Now at **v51** after
  142 sessions of incremental migrations.
- Role + permission seeding for new businesses (Session 2). 30 permission keys,
  4 default roles (CEO / Manager / Cashier / Stock keeper) seeded on business
  creation.
- Cloud migrations deployed through **0114** (deleted_businesses tombstone).

### Auth flow
- Welcome screen §4 (Session 6).
- CEO sign-up flow §5 — new-email path (Session 7). Existing-email /
  multi-business branch deferred to Phase 2.
- Staff sign-up via invite code §6 (Session 10).
  - Session 149: 9-step flow with phone (step 4) and address (step 5)
    matching CEO store-details. `AutocompleteField` extracted to
    `auth_form_kit.dart` (shared). Drift schema v51 adds `phone`/`address`
    to `users`; SQL migration 0116 adds cloud columns + recreates
    `redeem_invite_code` with `p_phone`/`p_address`. Sync whitelist updated.
- Login + Forgot PIN §7.1–7.4 (Session 8). Multi-business confirm-PIN
  deferred to Phase 2.
- Who Is Working picker §8.1–8.5 (Session 11). "Active now" dot deferred.

### Core screens
- Staff Management §9 (Session 10).
- CEO Settings §10.1 menu + Business Info / Stores / Security / Activity Logs
  access (Session 14). Roles & Permissions §10.2 (Session 15). Appearance
  (Session 17). §10.3 Phase 2.
- Delete Business & Account §10.3 — staff wipe on owner delete, tombstone,
  three-angle trigger (online / app-open / reconnect) (Session 140).
- Home / Dashboard §11 — role-aware cards, subtitle, store lock, Total SKUs.
- Point of Sale §12 — role guards (Session 19). On-device verified 2026-05-30.
- Cart + Edit Quantity modal §13 — discount + role caps, fractional toggle,
  per-cashier saved carts, Undo (Session 20). On-device verified 2026-05-30.
- Checkout §14 — two-step payment + receiving account (Session 26), wallet-info
  checkbox (Session 30). §14 complete.
- Daily Stock Count §17 — count persistence, shortages snapshot, Record Damages
  form, store-name header, CEO/Manager notifications, Cashier blocked (Session 58).
  Ring 3 Daily Reconciliation integration still open (see In Progress).
- Supplier Accounts §21 — DB-backed per-supplier ledger, Invoice Total /
  Payment via "Record Activity", absorbs former Track Shipments (Session 110).
  Per-store ledger entries §21.11 (Session 127).
- Expenses — per-store scope gating via active-store picker §20.8 (Session 133).
- Daily Reconciliation §25.9 — store-scoped, Day/Week/Month/Year grouping,
  CEO P&L + statement of account, Manager retail shrinkage, drill-down
  (Session 135).
- Business Reports hub §25.1–25.3 — removed Sales Report / Expense Tracker /
  Customer Ledger cards, redesigned period filter to chip row (Session 136).

### Infrastructure / cross-cutting
- Rename pass: Warehouse → Store (Session 3), Dashboard → Home (with §11).
- Realtime two-device sync confirmed on-device (Session 27).
- Per-table push error classification — FK-deferred vs permanent vs transient,
  §6.8 parity (Session 128).
- Legacy order-number collision self-heal — pull-side and push-side (Session 129).
- Voided ledger row `created_at` scrub — never send `created_at` on void
  re-pushes for append-only ledgers (Session 134).
- Sync push chunking — adaptive chunk sizing (Wi-Fi 25 rows, cellular 10,
  floor 5), 15s timeout per chunk, halve on timeout / double after 3 clean
  chunks, skip on no-network (Session 141).
- Pull-side pagination (Session 143): `_fetchOneTable` now fetches in pages
  ordered by `last_updated_at` + `id` asc; page size is connectivity-driven
  (Wi-Fi 500 / cellular 100 / poor 50, floor 10). On cellular/poor the
  monolithic `pos_pull_snapshot` RPC is bypassed entirely; `_pullViaPostgRest`
  fetches tables sequentially (in `_pullOrder` FK-safe order) instead of
  parallel `Future.wait`. Adaptive timeout: a page-level TimeoutException
  halves the page size and retries the same offset; propagates when already
  at the floor. `syncMinimumLogin` also passes connectivity-based page size.
  LWW guard, hard-delete reconciliation, and the deferred-table cursor logic
  are all preserved. `flutter analyze` clean; 115/115 sync tests pass.
- Theme colour system — 5 palettes × light/dark; POS filter chips,
  cart/checkout totals, notifications, activity logs now theme-aware
  (Session 140).
- App icon — Reebaplus logo as launcher icon across all platforms (Session 137).
- iOS build enabled — runs on Simulator and physical iPhone (Session 138).
- Funds Register §23 — **removed entirely** at user request (Session 96).
  §23 is a tombstone. Hard Rule #8. No reintroduction.
- Track Shipments §22 — **removed entirely**, folded into Supplier Accounts
  (Session 110). §22 is a tombstone.
- Onboarding + registration form alignment (Session 144): all 7 business types
  now rendered in CEO sign-up picker (Restaurant/Supermarket/Bar/Pharmacy/
  Building Materials/Boutique greyed-out with "Coming soon" badge; only Beverage
  distributor selectable). Store Details step now collects Store Phone Number
  (digits-only, min 8 digits) and LGA/District (searchable autocomplete,
  populated from kNigerianLgas[state] when country is Nigeria; resets when state
  changes via ValueKey). `OnboardingDraft.lgaDistrict` added; `locationCombined`
  now emits Street → LGA → State → Country. `_submitBusinessType` maps
  'Beverage distributor' → 'Beer distributor' before writing to draft (DB
  canonical preserved). `BusinessInfoScreen._load` maps 'Beer distributor' →
  'Beverage distributor' for dropdown; `_save` maps back. New file:
  `lib/core/data/nigerian_lgas.dart` (36 states + FCT with full LGA lists).
  `kBusinessTypes` updated to 7 entries using 'Beverage distributor' display
  label; `isCrateBusiness` now accepts all three spellings. `flutter analyze`
  clean; 22/22 auth tests pass.
- Codebase cleanup — deleted 7 dead/unused files (CustomerLedgerScreen, ApprovalsScreen, WelcomeVerificationModal, sync_service.dart stub, guarded.dart helper, products_data.dart, filter_bar.dart) and resolved compile error in supabase_sync_service.dart (Session 142).
- Removed dead `last_notification_sent_at` schema + backend remnants (Session 142):
  the "Waiting for Assignment" screen, its main.dart routing guard, and the
  `_handleOnboardingAlerts` escalation system were deleted in a prior session;
  this drops the leftover column. Drift schema **v48 → v49** — `users` column
  removed from the table class, raw `ALTER TABLE users DROP COLUMN
  last_notification_sent_at` onUpgrade step (try/catch idempotent, NOT
  TableMigration — same decoupling rationale as the v12 users rebuild), pull
  restore + push whitelist refs stripped from `supabase_sync_service.dart`,
  Drift code regenerated. Cloud migration
  `0115_drop_last_notification_sent_at.sql` written (NOT yet pushed). `storeId`
  untouched (still used for store-locking). `flutter analyze lib` clean;
  migration/sync/auth/database suites pass.
- Fixed orphaned-tenant re-registration bug (§10.3 follow-up, Session 142):
  re-registering with the same email after "Delete Business & Account" left a
  stale local `users` row (old `businessId`) when the device's wipe never
  ran/completed. `resolvePostVerifyRoute` was routing this case to
  `LoginRoute` with the dead `businessId`, causing `tenant_mismatch` on pull
  and RLS `42501` on push (stale `sync_queue` rows). Now: when the cloud
  confirms no business for the auth identity (`fetchSupabaseAccount() ==
  null`) and a confirmed `deleted_businesses` tombstone matches the stale
  row's `businessId`, `AuthService.wipeOrphanedLocalBusiness` (new —
  `SupabaseSyncService.confirmBusinessDeleted`, a public wrapper of
  `_confirmBusinessDeleted`) wipes the device via `clearAllData()` and the
  email is routed as brand-new (`NoAccountFoundRoute`). Ambiguous results (no
  tombstone / offline) preserve the existing offline PIN-login path —
  never a false-positive wipe. New test:
  `test/auth/post_verify_route_orphan_business_test.dart`.
- Fixed ListTile debug assertion crashes in tests and UI (Session 145): SwitchListTile widgets wrapped inside decorated containers (such as AppDecorations.glassCard) triggered a debug assertion failure on newer Flutter versions ("ListTile background color or ink splashes may be invisible"). Wrapped the inner columns/list-tiles in transparent Material widgets: in `_permissionGroupCard` and `_viewAllStoresCard` in `role_permissions_detail_screen.dart`, and `_permissionGroupCard` in `staff_permissions_screen.dart`. Ran `dart format lib/` to clean formatting, verified `flutter analyze lib` is 100% clean, and ran the entire test suite ensuring 429/429 tests pass.
- New-store stock-figure leak fixed (2026-06-17): a newly created store showed
  another store's "Total Units" / "Products" on the Stores list while its detail
  screen was correctly empty. Cause: `_StoreCard` in `stores_screen.dart` was a
  keyless `ListView.builder` child that subscribed to its store's inventory
  stream only in `initState`; stores order by name, so inserting one shifts
  positions and Flutter recycled the position-matched state, which kept
  streaming the previous store's inventory. Fix: `ValueKey(store.id)` on each
  card + `didUpdateWidget`/`_subscribeInventory()` re-targeting. A new store now
  starts at 0 until inventory is assigned. `flutter analyze` clean.
- Declarative back interception + tab history traversal (Session 146): Migrated `MainLayout` from `WidgetsBindingObserver.didPopRoute` to `PopScope(canPop: false, onPopInvokedWithResult: ...)` — the modern Flutter back-interception API. Removed `WidgetsBindingObserver` mixin, `addObserver`/`removeObserver` calls, and the `didPopRoute` override. Updated `NavigationService.handleBackPress` Step 3: tries `popIndex()` first (returns the user to the previous tab in history), then falls back to navigating to the home tab (Step 3.5). Both files analyze clean.
- Owner role protection (Session 148): Drift schema **v49 → v50** — added
  `ownerId` (nullable TEXT) column to `Businesses` table, mirroring the cloud's
  existing `owner_id` column. Raw `ALTER TABLE businesses ADD COLUMN owner_id
  TEXT` onUpgrade step (try/catch idempotent). `createNewOwner` and
  `completeOnboarding` in `auth_service.dart` now write `ownerId` explicitly in
  the local mirror inserts. `staff_detail_screen.dart`: computes `isTargetOwner`
  (`user.authUserId == business.ownerId`) after the membership null-guard; the
  "Change role" button is hidden (render-gate + outer section guard updated) when
  the target is the owner; `_changeRole` has a defense-in-depth re-check that
  returns early with an error notification ("You cannot change the owner's role.")
  if the gate is somehow bypassed. `currentBusinessProvider` (already in tree)
  supplies the live `ownerId`. `build_runner` regenerated; `flutter analyze`
  clean (no errors).
- Debug-mode audit + Stock Count review sheet (Session 147): Audited all `kDebugMode` and `assert` gates across the codebase. Found two intentional `kDebugMode` uses: `logger.dart` (debug logging only) and `sync_issues_screen.dart:1124` (service-role-key + project-URL fields hidden in release — developer tool, correct by design). Two `assert`-only constructor guards in `create_pin_screen.dart` and `pin_keypad.dart` are silently bypassed in release mode (noted, not changed — valid Flutter pattern). `build.gradle.kts` release build uses debug signing key (TODO comment present; no functional divergence for biometric/secure-storage since both modes share the same keystore). Replaced the simple `AlertDialog` in `StockCountScreen._confirmAndSave()` with a `DraggableScrollableSheet` review panel: summary chips (counted / adjusted / short / over), full itemised list of every product with a diff (product name, system → actual, coloured diff badge), "all matched" empty state with a green check icon, and "Back" + "Confirm & Save Count" action buttons. `flutter analyze` clean — 18 pre-existing `avoid_print` infos in test file only.

---

## In Progress

- **Receipt §15** — QR code removed, wallet-info display wired (Session 30).
  Still open: refund button, Completed-tab specifics.
- **Customers + Customer Profile §18** — soft-delete, Crates-tab gate, required
  phone, `customers.set_debt_limit` permission (Session 31). Still open: Edit
  flow, GPS capture, Add-Funds payment method.
- **Daily Stock Count §17** — Ring 3 Daily Reconciliation data wiring still
  pending. On-device pass also pending.
- **Supplier Accounts §21** — full feature built: ledger, store scope §21.11,
  §4 confirmation gate, §10 CEO void, §14 reconciliation, §15 accounts report,
  §16 payment notifications, §3.13 crates placeholder. On-device verification
  against the 130-check list still pending.
- **Theme consistency** — only four areas swept in Session 140. Other screens
  may carry hardcoded `blueMain` / `blueLight` / raw `Colors.*` values.

---

## Next Up

1. On-device verify Session 143 pull pagination under a throttled / flaky /
   cellular connection.
2. Decide: app-wide colour sweep vs next feature unit.
3. **Inventory + Product Details §16** — not started.
4. **Orders §19** — not started.
5. **Expenses + Pending Approval flow §20** — store-scope wired (Session 133);
   full §20 feature pass not started.
6. **Activity Logs §24** — not started.
7. **Notifications §26** — not started.
8. **Sidebar + Bottom Nav final pass §27** — not started.
9. **Cross-cutting cleanup** — role-based guards wired everywhere; loading
   animations replaced with fade-ins; all UUIDs replaced with short codes in
   user-facing text; Cash Register → Funds Register label cleanup (§23 removed,
   label pass only).

---

## Open Questions

- **Empty crates — walk-in crate semantics (§3.14–3.16).** The checklist says a
  walk-in sale should still adjust empty-crate inventory automatically and that
  walk-ins must return crates equal to receipt at the same time (no deferred
  balance). Current `createOrder` gates the entire crate block on
  `customerId != null`, so walk-ins accrue no crate rows at all. Define the
  intended walk-in crate-inventory behaviour before implementing — do NOT invent.

- **Empty crates — §5/§9/§10/§11/§13 on-device verification pending.** The
  pending-order Crate Return modal, refund flow (`crate_refund`), order
  cancellation reversal, reconciliation crate section, and role-access gating
  are all built; they need on-device (emulator) confirmation against the
  checklist rather than further code changes.

- **Supplier empty crates §3.13 — cloud push + on-device verification pending.**
  The full feature is built and unit-tested (2026-06-19). Outstanding: (1) push
  `0117_supplier_crate_tracking.sql` BEFORE distributing a v53 build; (2) on-device
  confirm receipt/return nets the per-supplier balance, the deposit value tracks,
  and Receive Delivery increments the supplier crate debt; (3) confirm the
  computed-deposit model (balance × manufacturer rate) matches the operator's
  expectation vs. tracking literal deposit cash — revisit if they want the entered
  `deposit_paid_kobo` surfaced as the headline instead.

- **Receipt §15 refund button** — deferred multiple times. Confirm the exact
  UX (who triggers it, from which screen, what it writes to the ledger) before
  picking up §15.

- **Customers §18 GPS capture** — deferred from Session 31. Confirm: still in
  Phase 1 scope or moved to Phase 2, before implementing the Edit flow.

- **`onPrimary` in dark colour schemes** — only the Black & White palette sets
  it explicitly. Dark-mode coloured themes may show black chip text on a medium
  primary. Confirm whether an explicit `onPrimary` pass across all
  `ColorScheme.dark(...)` blocks in `app_theme.dart` is wanted.

- **`CustomerLedgerScreen` dead code** — deleted (Session 142).

- **Free Apple ID provisioning** — real-device cert expires after 7 days.
  Re-run `flutter run` to refresh. Confirm before any iOS release testing.

- **Cloud migrations 0042–0044 row-count verification** — written in Session 2,
  deployed in Session 4. The verification queries in each migration file should
  be run against a real Supabase instance. Status unknown — confirm if done.

---

## Architecture Decisions

Locked decisions. Do not revisit without updating `architecture.md` and logging
the reason here.

- **One email, one business (Phase 1).** Database supports multi-membership from
  day one; the switch-business picker UI is Phase 2. (Session 1 / §1.1.)

- **Funds Register removed entirely (2026-06-04).** §23 is a tombstone. No cash
  account, no Open Day / Close Day, no per-store money accounts. Money tracked
  as recorded sales, expenses, refunds, and supplier payments. Hard Rule #8.
  (Session 96.)

- **Track Shipments folded into Supplier Accounts (2026-06-06).** §22 is a
  tombstone. Supplier Accounts absorbs shipment tracking via "Record Activity"
  ledger. (Session 110.)

- **Append-only ledgers.** The five append-only tables are `payment_transactions`,
  `wallet_transactions`, `supplier_ledger_entries`, `crate_ledger`, and
  `stock_transactions`. The cloud enforces this with append-only triggers.
  Voids are new rows; `created_at` is never sent on void re-pushes.
  (Session 134 / §5 sync contract.)

- **Role identity uses the slug, never the name.** The `roles` table has a
  `slug` column (`ceo`, `manager`, `cashier`, `stock_keeper`). All code that
  branches on role identity uses the slug. `name` is display-only. (Session 1.)

- **`products.add` removed from Stock keeper defaults.** Only CEO and Manager
  can add new products. Stock keepers adjust quantities on existing products
  only. (Session 1 / §16.7.)

- **Default `role_settings.max_expense_approval_kobo` for Manager set to 0.**
  CEO must set this explicitly before a Manager can approve expenses without
  escalation. Safer opening default for fresh businesses. (Session 1.)

- **Three product prices only: Buying, Retailer, Wholesaler.** Four legacy price
  columns dropped in the pivot. (Session 1 / §16.5.)

- **Barcode scanning scoped to Pharmacy and Supermarket only.** Hidden for all
  other business types. `barcode_widget` package stays in pubspec.yaml.
  (Session 1 / §16.11.)

- **Per-store scoping pattern.** Expenses (§20.8), Supplier Accounts (§21.11),
  and Daily Reconciliation (§25.9) all follow the §12.1 active-store picker.
  Concrete store → that store's data; All Stores (CEO / all-stores Manager) →
  aggregate. Recording stamps: `lockedStoreId ?? first-selectable`. (Sessions
  127, 133, 135.)

- **Sales Report, Expense Tracker, Customer Ledger removed from Reports hub.**
  Data lives on individual screens. Hub cards are tombstones. (Session 136 /
  §25.2.)

- **§25.10 merged into Daily Reconciliation §25.9.** One store-scoped report,
  groupable by Day/Week/Month/Year with drill-down. Cash tracking rejected by
  user. §25.10 is a tombstone. (Session 135.)

- **Cashier `reports.see_sales` scope is query-layer only.** The permission
  grants access; "own sales only" is enforced at the query, not the permission.
  Home (§11) and Reports (§25) must both apply this scope filter. (Session 1.)

- **Sync push chunking.** Wi-Fi/ethernet ceiling: 25 rows. Cellular ceiling: 10
  rows. Floor: 5 rows. Timeout: 15s per chunk. Adaptive: halve on timeout,
  double after 3 consecutive clean chunks. Skip if `Connectivity` returns `none`.
  (Session 141.)

- **`deleted_businesses` tombstone (cloud-only).** No FK to `businesses`;
  survives cascade. RLS: any signed-in device may read it; writes are owner-only
  via `delete_business` RPC. Staff devices wipe via three triggers: realtime,
  on next app open, on reconnect. Migration 0114. (Session 140.)

---

## Session Notes

**To resume in a new session:**
Read this file first, then `CLAUDE.md`, then the master plan section relevant
to the unit being picked up.

**Repository state:**
- Drift client schema: **v54** (v54 = `sales.set_custom_price` permission seed;
  v53 = §3.13 supplier_crate_ledger + supplier_crate_balances).
- Cloud migrations deployed through: **0118** (0117 supplier crate tracking +
  0118 `sales.set_custom_price` pushed 2026-06-19; verified: catalogue row
  present, granted to all CEO roles, 0 non-CEO grants).
- `flutter test test/sync/` — **115 pass** (Session 141 baseline).
- Full suite last confirmed: 452 pass / 58 skipped / 1 pre-existing unrelated
  failure (`invite_staff_sheet_test`) (2026-06-19).
- `flutter analyze lib` — clean. 18 pre-existing `avoid_print` infos in
  `test/database/roles_v13_report.dart` only; not regressions.
- iOS build enabled; free Apple ID cert expires after 7 days — re-run
  `flutter run` to refresh.

**Three things to check before every unit:**
1. `flutter analyze` clean before and after.
2. No raw Supabase call from `lib/features/` or `lib/data/repositories/`.
3. No UPDATE or DELETE on an append-only ledger table — corrections are
   new rows only.
