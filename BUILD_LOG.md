# BUILD_LOG.md — Reebaplus POS Build History

This file is the running memory between Claude Code sessions. Every session ends with a new entry here. Plain English only — no jargon.

---

## How to use this file

**At the start of every session**, Claude reads this file to know what's already been built and what's still open.

**At the end of every session**, Claude (or the user) adds a new entry using the template below.

**When the master plan changes mid-session**, note it under the current session entry so the change isn't lost.

---

## Entry template (copy this for each new session)

```
## Session [number] — [YYYY-MM-DD]

**Built today:**
- (Plain English description of what was built. One bullet per thing.)

**Files touched:**
- (List of new or changed files. Just paths.)

**Database changes:**
- (Any new tables, columns, or migrations. Plain English.)

**Master plan sections covered:**
- Section X.Y — [brief description]

**Plan updates made during session:**
- (If the master plan was changed today, note what changed and why. Otherwise write "None.")

**Tested:**
- (What was tested and confirmed working.)

**Known issues / left open:**
- (Anything broken, half-done, or deferred to a later session.)

**Next session should:**
- (Suggested starting point for the next session.)
```

---

## Build status overview

Keep this section updated at the top so it's easy to see what's done at a glance.

### Phase 1 — In progress

**Foundation:**
- [ ] Database schema rebuild (section 2 of master plan)
- [ ] Role + permission seeding for new businesses

**Auth flow:**
- [ ] Welcome screen (section 4)
- [ ] CEO Sign Up flow (section 5)
- [ ] Staff Sign Up flow (section 6)
- [ ] Login flow + Forgot PIN (section 7)
- [ ] Who Is Working picker (section 8)

**Core screens:**
- [ ] Staff Management (section 9)
- [ ] CEO Settings (section 10)
- [ ] Home / Dashboard (section 11)
- [ ] Point of Sale (section 12)
- [ ] Cart + Edit Quantity modal (section 13)
- [ ] Checkout (section 14)
- [ ] Receipt (section 15)
- [ ] Inventory + Product Details (section 16)
- [ ] Daily Stock Count (section 17)
- [ ] Customers + Customer Profile (section 18)
- [ ] Orders (section 19)
- [ ] Expenses + Pending Approval flow (section 20)
- [ ] Supplier Accounts (section 21)
- [ ] Track Shipments (section 22)
- [ ] Funds Register (section 23)
- [ ] Activity Logs (section 24)
- [ ] Reports (section 25)
- [ ] Notifications (section 26)
- [ ] Sidebar + Bottom Nav final pass (section 27)

**Cross-cutting:**
- [ ] Role-based guards wired everywhere
- [ ] Rename pass: Warehouse → Store *(done in Session 3)*, Dashboard → Home, Cash Register → Funds Register
- [ ] Loading animations replaced with fade-ins
- [ ] All UUIDs replaced with short codes in user-facing text

Mark each item with `[x]` as it's completed. Add notes under any item if needed.

---

## Session entries

(New entries go below this line. Most recent at the top.)

---

## Session 5 — 2026-05-28 — Crate Size Groups (schema v16 + cloud 0047)

**Built today:**
- The deferred crate rename from Step 4 (PIVOT_PLAN decision Q8), as its own focused session. `crate_groups` → `crate_size_groups` everywhere, and the crate "size" stopped being a bottle-count number and became a word category: **Big / Medium / Small**.
- **Scope change (recorded in PIVOT_PLAN before coding, per CLAUDE.md):** Q8 originally said "rename + relax `size IN (12,20,24)` to `size > 0`". The user revised this to "drop the number, make it a Big/Medium/Small category". The master plan needed no change (it never specifies crate size values). PIVOT_PLAN Q8 updated in three places + the §1.3 block.
- **Local (Drift v16).** Renamed table `crate_groups`→`crate_size_groups`, classes `CrateGroups`→`CrateSizeGroups` / `CrateGroupData`→`CrateSizeGroupData`, DAO `CrateGroupsDao`→`CrateSizeGroupsDao` (+ result classes). Cascaded `crateGroupId`→`crateSizeGroupId` / `crate_group_id`→`crate_size_group_id` on the 6 FK tables (suppliers, products, customer_crate_balances + its UNIQUE, manufacturer_crate_balances + its UNIQUE, crate_ledger, pending_crate_returns). Converted the `size` IntColumn → `crateSizeLabel` TextColumn (CHECK `IN ('big','medium','small')`, default `'medium'`). Updated `_syncedTenantTables`, `_softDeletableTables`, the crate_ledger immutability list, and `idx_crate_ledger_owner_group`.
- **v16 migration block** — the codebase's first table-rebuild migration. Renames the table, renames the 6 FK columns, then rebuilds crate_size_groups via `m.alterTable(TableMigration(...))` with a `columnTransformer` mapping `size` → `crate_size_label` (`12→small, 20→medium, 24→big`, else `medium`); recreates the two indexes + bump trigger the rebuild drops. Forwards pending `sync_queue` rows: `crate_groups:*`→`crate_size_groups:*` action types, and `crate_group_id`→`crate_size_group_id` / `p_crate_group_id`→`p_crate_size_group_id` payload keys.
- **The rename was scoped to the DB FK chain only.** A legacy client-side brand enum `CrateGroup { nbPlc, guinness, cocaCola, premium }` (in `crate_group.dart`) is unrelated to the DB table and was left untouched — verified the rename tokens (`CrateGroups`, `crateGroupId`, `crate_group_id`, …) never collide with the brand tokens (`CrateGroup`, `crateGroup`, `crateGroupName`, `CrateGroupLabel`). Applied via scoped `sed` across lib + test (Session-3 precedent), then hand-fixed the two `.size` display sites and the "Crate Group Assets" label.
- **UI:** the two `${grp.size} bottles` sites now show the capitalised category (e.g. "Medium"); "Crate Group Assets" → "Crate Size Group Assets".
- **Cloud `0047_crate_size_groups.sql` (+ rollback)** — written, NOT deployed. Renames table + indexes, renames the 6 FK columns, converts `size int → crate_size_label text` (same CHECK + mapping as local), and rebuilds the 4 affected RPCs from their latest bodies: `pos_pull_snapshot` (array entry), `pos_create_product_v2` (param `p_crate_group_id`→`p_crate_size_group_id`, DROP+recreate), `pos_record_crate_return` (param + columns, DROP+recreate), `pos_approve_crate_return` (column refs, CREATE OR REPLACE).

**IMPORTANT correction made this session (cloud schema reality):**
- The task brief AND a prior memory note both claimed the cloud `crate_groups` "already had `crate_size_label` text and lacked `size`/`empty_crate_stock`/`deposit_amount_kobo`." **This was false.** Reading the cloud migration history directly: `0001_initial.sql` created crate_groups with `size int CHECK (size IN (12,20,24))` + `empty_crate_stock` + `deposit_amount_kobo`, and **no migration ever altered it** — `crate_size_label` exists nowhere cloud-side. So cloud was identical to local pre-v16, there was **no divergence**, and 0047 must convert `size→crate_size_label` cloud-side too (not just rename). Surfaced this to the user before writing 0047; the user confirmed the cloud crate table has **zero rows** and wants it stored as words. The stale `project_crate_cloud_divergence.md` memory was corrected.
- Mapping direction (`12→small` vs the 0001 comment's `12=big`): user said "just save as words" (no records to migrate), so kept the brief's `12→small, 20→medium, 24→big` consistently on both sides.

**Files touched:**
- lib/core/database/app_database.dart (schemaVersion 15→16, v16 migration block, CrateSizeGroups table + crateSizeLabel + CHECK, 6 FK column renames, @DriftDatabase tables/daos lists, _syncedTenantTables, _softDeletableTables, crate_ledger immutability list, idx_crate_ledger_owner_group)
- lib/core/database/app_database.g.dart, daos.g.dart (regenerated — build_runner, 268 outputs)
- lib/core/database/daos.dart + ~11 other lib files (sed rename: providers, sync service, sync_diagnostic, supplier_service, inventory_screen, crate_return_modal, receive_delivery_sheet, cart_service, crate_return_approval_service, receipt_widget)
- lib/features/inventory/screens/inventory_screen.dart (label + category display), lib/features/deliveries/widgets/receive_delivery_sheet.dart (category display)
- test/ (sed rename across crate-touching tests + hand-fixed `size: 12`→`crateSizeLabel: Value('small')` in 3 local tests and `'size': 12`→`'crate_size_label': 'small'` in 3 cloud integration tests)
- test/database/crate_size_groups_v16_payload_rewrite_test.dart (new, 8 tests)
- test/database/crate_size_groups_v16_migration_test.dart (new, 5 tests — target shape + size→label mapping)
- supabase/migrations/0047_crate_size_groups.sql (new, write-only)
- supabase/scripts/rollback/0047_rollback.sql (new)
- PIVOT_PLAN.md (Q8 revision in 3 places + §1.3 block + cloud-reality correction + step-4 deferral marked done)
- BUILD_LOG.md (this entry)

**Database changes:**
- Drift v16: `crate_groups`→`crate_size_groups`; `crate_group_id`→`crate_size_group_id` on 6 tables; `size int`→`crate_size_label text` (CHECK big/medium/small, default medium).
- Cloud 0047 WRITTEN, NOT deployed. 0045+0046 are already deployed (0046 pushed this session), so 0047 only waits on the v16 client shipping — deploy right after.

**Master plan sections covered:**
- §2 rename (Crate Size Groups). Decision Q8 (revised). No master plan edit needed (never specified crate size values; empty-crate flow in §13.4/§16.10 unaffected — `emptyCrateStock`/`depositAmountKobo` untouched).

**Plan updates made during session:**
- Q8 revised: numeric `size` dropped in favour of a Big/Medium/Small `crate_size_label`. Recorded in PIVOT_PLAN before coding.
- Corrected the false "cloud has crate_size_label / lacks the two columns" premise (see the IMPORTANT correction above).

**Tested:**
- `flutter analyze lib/ test/` — 0 errors (only the 18 pre-existing `avoid_print` infos).
- `flutter test` — **135 pass** (122 prior + 8 payload-rewrite + 5 migration), 0 failures.
- Grep checkpoint: zero DB-identifier stragglers in lib (outside the v16 migration block, which intentionally holds the old strings for the ALTERs); the legacy `CrateGroup` brand enum remains intact (1 enum). The only old-token hits are the intentional pre-migration keys inside the two new rewrite/migration tests.

**Known issues / left open:**
- **Cloud 0047 not deployed.** 0045+0046 are deployed (0046 pushed this session), so 0047 only waits on the v16 client — deploy with/right after it ships. Until then, v16 clients pushing `crate_size_group_id` / `crate_size_groups:*` / `p_crate_size_group_id` to the un-migrated cloud will 42703 and queue (no data loss; the v16 block also forwards pre-v16 queued rows).
- **NOT verified on the emulator.** The two `.size`→category display sites and the inventory label change were not exercised on a running app this session — recommend a `flutter run` smoke (fresh install + a v15→v16 upgrade) to confirm the inventory crate cards show the category label and nothing crashes.
- **v15→v16 onUpgrade not driven end-to-end by an automated test.** Consistent with the standing v11→v15 schema-fixture gap (still deferred). The new migration test mirrors the rebuild's `size→label` CASE mapping + asserts the v16 target shape, but the real `TableMigration` rebuild path on a populated v15 DB is covered only by reasoning (FK enforcement OFF during onUpgrade; column set otherwise unchanged). Build the schema-fixture harness before a real-device release — now doubly worth it given v16 is the first table-rebuild migration.

**Next session should:**
- Deploy cloud 0047 once the v16 client ships (0046 was already deployed this session), then resume PIVOT_PLAN at step 5 (Welcome + CEO Sign Up flow).

---

## Session 4 — 2026-05-28 — Pivot step 4 (small renames, partial) + cloud 0042–0045 deploy

**Built today:**
- Deployed cloud migrations 0042–0045 to the linked Supabase project (`supabase db push`). All four applied cleanly and now show as remote in `supabase migration list`. This closes the v14 cut-over window — v14 clients' queued writes drain on next push.
- Started PIVOT_PLAN step 4 ("small renames"). Step 4 turned out to be four independent schema mutations, not one, so it was done as vertical slices (schema → codegen → references → analyzer-green per slice), smallest first. Two slices landed; two were deferred (see Plan updates).
- **Slice (a) Customer Group → Price Tier.** Drift column `customers.customer_group` → `price_tier`. Dart enum `CustomerGroup` → `PriceTier`, field `customerGroup` → `priceTier`. DAO `getPriceForCustomerGroup` → `getPriceForTier`. `pos_create_customer` domain envelope key `p_customer_group` → `p_price_tier`. UI label "Customer Group" → "Price Tier".
- **Slice (a) close-out — CHECK tighten + data migration (the part that was incomplete).** Master plan §16/§21 says Price Tier is Retailer / Wholesaler only, so the CHECK was narrowed from the 4-value legacy set (`retailer,wholesaler,distributor,walk_in`) to `('retailer','wholesaler')`. Local v15 block now: migrates data (`distributor`→`wholesaler`, `walk_in`→`retailer`) then rebuilds the customers table via `m.alterTable(TableMigration(customers))` (SQLite can't ALTER a CHECK) and recreates its three indexes (`idx_customers_business_lua`, `_business_deleted`, `_business_phone`) + `bump_customers_last_updated_at` trigger. Cloud 0046 does the data `UPDATE` then `DROP CONSTRAINT customers_customer_group_check` / `ADD CONSTRAINT customers_price_tier_check`. 0046_rollback reverses (restores the 4-value CHECK; the data migration itself is one-way). Fresh-install CHECK enforcement covered by new `test/database/price_tier_check_test.dart` (5/5).
- **Slice (b) Purchases → Shipments.** Drift table `purchases` → `shipments`, class `Purchases` → `Shipments`, data class `DeliveryData` → `ShipmentData`, `DeliveriesDao` → `ShipmentsDao` (+ `getLastDeliveryForProduct` → `getLastShipmentForProduct`, `LastDeliveryInfo` → `LastShipmentInfo`). The permanent ledger FK columns `stock_transactions.purchase_id` and `payment_transactions.purchase_id` → `shipment_id` (their exactly-one-FK CHECK constraints and the `_ledgerTables` immutability lists updated to match). `purchase_items` KEEPS its `purchase_id` column (table is deferred-for-drop). Synced-table lists + sync restore case updated.
- **Dashboard → Home (Option A, settled at close-out).** Drawer label "Dashboard" → "Home". Class `DashboardScreen` → `HomeScreen`, file `dashboard_screen.dart` → `home_screen.dart` (git mv; `main_layout` import + usage updated). Internal nav route key kept at the original stable `'dashboard'` (an earlier pass had flipped it to `'home'`; reverted across all 7 usages — navigation_service index map, drawer, home/reports_hub/approvals screens). Net: user-facing = Home, code class = HomeScreen, internal route key = 'dashboard'. `lib/features/dashboard/` folder kept.
- **Settings → CEO Settings.** Drawer label + the two SettingsScreen AppBar titles. (Role-based hiding deferred — see Plan updates.)
- Drift schema bumped 14 → 15. Single `if (from < 15)` migration block covers slices (a) + (b): the column/table renames plus pending-`sync_queue` payload rewrites (`customer_group`→`price_tier`, `p_customer_group`→`p_price_tier`, and `purchase_id`→`shipment_id` scoped to `stock_transactions`/`payment_transactions` upserts only, plus `purchases:*`→`shipments:*` action-type forwarding).
- Cloud migration `supabase/migrations/0046_pivot_small_renames.sql` (write-only, NOT deployed). Renames the two cloud columns + the table, and rewrites every live function that referenced the old names — authoritative list pulled from `pg_proc` on the live DB: `pos_create_customer` (→ `p_price_tier`/`price_tier`), `pos_inventory_delta_v2` (→ `shipment_id`), `pos_pull_snapshot` (array `'purchases'`→`'shipments'`), and DROP of the dead v1 `pos_inventory_delta` (already broken since 0045 renamed `inventory.warehouse_id`; client only calls `_v2`). Rollback `supabase/scripts/rollback/0046_rollback.sql` mirrors the reverse (restores all four functions incl. v1, reverses the renames).

**Files touched:**
- lib/core/database/app_database.dart (schemaVersion 14→15, v15 migration block, Customers/StockTransactions/PaymentTransactions/PurchaseItems table defs, Shipments class + DataClassName, ledger CHECK + immutability lists, @DriftDatabase tables/daos lists, `_syncedTenantTables`)
- lib/core/database/app_database.g.dart, daos.g.dart (regenerated)
- lib/core/database/daos.dart (ShipmentsDao, getPriceForTier, pos_create_customer envelope key, stock-transaction referenceId)
- lib/core/services/supabase_sync_service.dart (synced list + restore case `purchases`→`shipments`/`ShipmentData`)
- lib/features/customers/data/models/customer.dart, data/services/customer_service.dart, screens/customers_screen.dart, screens/customer_detail_screen.dart, widgets/add_customer_sheet.dart (PriceTier)
- lib/features/pos/controllers/pos_controller.dart, screens/pos_home_screen.dart, widgets/product_grid.dart (PriceTier)
- lib/features/inventory/screens/product_detail_screen.dart (ShipmentsDao / LastShipmentInfo)
- lib/shared/widgets/app_drawer.dart (Home + CEO Settings labels, route key), lib/shared/services/navigation_service.dart (route key), lib/features/dashboard/screens/{dashboard,reports_hub,approvals}_screen.dart (route key)
- lib/core/settings/settings_screen.dart (AppBar titles)
- test/integration/rpcs/pos_create_customer_test.dart (p_price_tier contract — skipped integration test)
- supabase/migrations/0046_pivot_small_renames.sql (new, write-only; + CHECK tighten at close-out)
- supabase/scripts/rollback/0046_rollback.sql (new; + CHECK restore)
- lib/features/dashboard/screens/home_screen.dart (renamed from dashboard_screen.dart, class HomeScreen)
- lib/shared/widgets/main_layout.dart (HomeScreen import + usage)
- test/database/price_tier_check_test.dart (new, fresh-install CHECK enforcement, 5/5)
- test/database/renames_v15_payload_rewrite_test.dart (new, payload rewrites, 9/9 — written alongside this work)
- PIVOT_PLAN.md (step 4 status + deferrals)

**Database changes:**
- Drift v15: `customers.customer_group`→`price_tier`; `purchases`→`shipments`; `stock_transactions.purchase_id`/`payment_transactions.purchase_id`→`shipment_id`. `purchase_items` unchanged.
- Cloud 0042–0045 DEPLOYED. Cloud 0046 WRITTEN but NOT deployed (gated).

**Master plan sections covered:**
- §2 renames (Price Tier, Home, Shipments, CEO Settings). Decisions Q5/Q8/Q9 touched (see deferrals).

**Plan updates made during session (recorded in PIVOT_PLAN.md step 4):**
- **Drop `purchase_items` (Q5) deferred to step 25** — it still backs the product-detail "Last Delivery" card via `ShipmentsDao.getLastShipmentForProduct`; dropping now orphans the feature with no replacement.
- **Crate Groups → Crate Size Groups (Q8) deferred to its own session** — ≈196 refs / 22 files + cloud RPC rewrites; v14-scale, not "small". (User chose "its own focused session".)
- **Hide CEO Settings for non-CEO (Q9) deferred to step 10** ("Sidebar role guards") — no role-resolution infra exists yet (only a hardcoded `isCEO=true` placeholder in inventory). Step 4 did the label only.

**Tested:**
- `flutter analyze` clean (only pre-existing `avoid_print` infos in `test/database/roles_v13_report.dart`). `flutter test` → **all 122 pass** (108 prior + 9 `renames_v15_payload_rewrite_test` + 5 `price_tier_check_test`), 0 failures.
- One bootstrap failure surfaced mid-slice-(b) and was fixed: the two ledger tables' CHECK constraints and `_ledgerTables` immutability lists still referenced `purchase_id` after the getter rename; updated to `shipment_id` + regenerated.

**Known issues / left open:**
- Cloud 0046 not deployed — deploy after this lands, right after the v15 client ships (re-read 0046 header's deploy-ordering note). Until then, v15 clients pushing `price_tier`/`shipment_id` keys to the un-migrated cloud will 42703 and queue (no data loss).
- "Zero stragglers" checkpoint only partial: `purchase_items`/`PurchaseItems` and `crate_group(s)` deliberately remain pending their deferred steps.
- The v11→v14 (now v15) upgrade schema-fixture test gap from Session 3 still stands. Specifically untested: the v15 customers table-rebuild path (`m.alterTable(TableMigration(customers))` + index/trigger recreation). Reasoning gives confidence (FK enforcement is OFF during onUpgrade — proven by the v12 incident where `DROP TABLE` reached the copy stage; column set is unchanged post-rename so the copy is 1:1; indexes/trigger recreated to match onCreate exactly) and fresh-install CHECK is tested, but the actual 14→15 upgrade is not exercised. Build the schema-fixture before any real-device release.

**Next session should:**
- Deploy cloud 0046 (after confirming the deploy-ordering note), then do slice (d): Crate Groups → Crate Size Groups as a dedicated v14-scale rename session (schema v16 + cloud 0047). Then resume the plan at step 5 (Welcome + CEO Sign Up flow).

---

## Session 3 — 2026-05-27 — Schema v14 (warehouses → stores rename pass)

**Built today:**
- Schema v14 bump. The `warehouses` table is now `stores`. Every `warehouse_id` foreign-key column on the ten dependent tables (users, customers, inventory, stock_adjustments, orders, order_items, expenses, activity_logs, plus the two v13 placeholders invite_codes and user_stores) is now `store_id`. `stock_transfers.from_location_id` / `to_location_id` and `stock_transactions.location_id` kept their generic names — only their FK target changed.
- Drift v14 migration block in `app_database.dart` that runs the rename in place using SQLite's `ALTER TABLE ... RENAME TO` and `ALTER TABLE ... RENAME COLUMN` (auto-updates FK references, trigger bodies, and index column refs on SQLite ≥ 3.25). Index names that embedded "warehouse" (`idx_warehouses_business_lua`, `idx_warehouses_business_deleted`, `idx_inventory_business_pw`) and the `bump_warehouses_last_updated_at` trigger were dropped + recreated with `stores` / `store_id` in the new names. Pending `sync_queue` rows with `action_type = 'warehouses:upsert'` or `'warehouses:delete'` are forwarded to `stores:upsert` / `stores:delete`.
- All Drift Dart classes renamed: `Warehouses` → `Stores`, `WarehouseData` → `StoreData`, `WarehousesDao` → `StoresDao`. The `_syncedTenantTables` and `_softDeletableTables` lists updated. The `activity_logs` immutability trigger's column list updated from `warehouse_id` → `store_id`.
- Codegen regenerated (`build_runner build --delete-conflicting-outputs`).
- Stream providers renamed: `allWarehousesProvider` → `allStoresProvider`, `warehouseByIdProvider` → `storeByIdProvider`, `productsByWarehouseProvider` → `productsByStoreProvider`.
- `NavigationService` renames: `warehouseLocked`/`lockedWarehouseId`/`selectedWarehouseId`/`customersInitialWarehouseId` → `store*` equivalents; `applyUserWarehouseLock`/`clearWarehouseLock`/`setLockedWarehouse` → `*Store*`; route map `7: 'warehouse'` → `7: 'stores'`. `app_providers.lockedWarehouseProvider` → `lockedStoreProvider`.
- Folder move: `lib/features/warehouse/` → `lib/features/stores/`. `warehouse_screen.dart` → `stores_screen.dart` (plural to match sidebar label). `warehouse_details_screen.dart` → `store_details_screen.dart`. `data/models/warehouse.dart` → `data/models/store.dart`. The list-screen class became `StoresScreen` for plural/file alignment.
- Auth onboarding file `warehouse_assignment_screen.dart` → `store_assignment_screen.dart`. `onboarding_draft.warehouseId/Name` → `storeId/Name`.
- Sidebar label `'Warehouse'` → `'Stores'` (master plan §27.2 plural). Active-route key updated to `'stores'`.
- Bulk sed pass across 62 remaining Dart files (excluding `app_database.dart` and `*.g.dart`) for identifier/string consistency, plus a follow-up pass for uppercase `WAREHOUSE` in inventory and delivery sheet section labels. Broken import paths after sed (sed produced `features/store/...`; real folder is `features/stores/...`) were corrected.
- Cloud migration `supabase/migrations/0045_rename_warehouses_to_stores.sql` (1376 lines) — single transaction: table rename, ten column renames, three constraint renames (one explicit FK, two anonymous UNIQUEs), two v13 FK constraint renames (`invite_codes_warehouse_id_fkey`, `user_stores_warehouse_id_fkey`), three index renames, then CREATE OR REPLACE for seven RPCs with surgical `warehouse_id` → `store_id` and `warehouses` → `stores` substitutions (`pos_pull_snapshot`, `pos_record_sale_v2`, `pos_inventory_delta_v2`, `pos_create_product_v2`, `pos_cancel_order`, `pos_record_expense`, `pos_create_customer`), plus a signature change on `complete_onboarding` (parameter renamed `p_warehouse_id` → `p_store_id` via DROP + recreate). Three RPCs that had `p_warehouse_id` in their parameter list (`pos_record_sale_v2`, `pos_record_expense`, `pos_create_customer`) also got DROP + parameter-rename treatment to match the Dart client's `p_store_id` payload key. Four RPCs whose bodies don't reference warehouses (`pos_approve_crate_return`, `pos_wallet_topup`, `pos_void_wallet_txn`, `pos_record_crate_return`) were left alone — Postgres auto-updates their references to the renamed table. Trailing verification queries appended.
- Rollback `supabase/scripts/rollback/0045_rollback.sql` (1324 lines) — mirror reverse: `complete_onboarding` restored first (verbatim from 0044 to keep mid-rollback clients working), then all seven RPCs restored from their pre-rename source bodies (0020 / 0017 / 0011), then indexes / constraints / columns / table reversed in opposite order.
- Master plan updates: §1.1 now explicitly says "One business is owned by one CEO, and one CEO can own multiple businesses" and adds "so a single CEO email can map to many businesses" to the database-multi-membership paragraph. §2.2 now explicitly says "Every business has at least one store, and one business can have many stores." Both restatements requested by the user to make the architecture's direction explicit; the data model already supported both.

**Files touched:**
- reebaplus_master_plan.md (§1.1, §2.2 directionality)
- lib/core/database/app_database.dart (schema rename, schemaVersion 13 → 14, v14 migration block, _syncedTenantTables, _softDeletableTables, ledger immutability list, _postCreateStatements index)
- lib/core/database/app_database.g.dart (regenerated)
- lib/core/database/daos.dart (DAO + method renames + SQL strings)
- lib/core/database/daos.g.dart (regenerated)
- lib/core/providers/stream_providers.dart (3 provider renames)
- lib/core/providers/app_providers.dart (lockedWarehouseProvider → lockedStoreProvider)
- lib/shared/services/navigation_service.dart (six identifier renames + route map)
- lib/features/stores/ (new, from git mv of lib/features/warehouse/; 4 screens/models with internal sed)
- lib/features/auth/screens/store_assignment_screen.dart (renamed from warehouse_assignment_screen.dart, sed)
- lib/features/auth/onboarding/onboarding_draft.dart (field rename)
- lib/shared/widgets/app_drawer.dart (sidebar label "Stores", route "stores")
- lib/shared/widgets/main_layout.dart (StoresScreen class binding + import path)
- lib/shared/widgets/receipt_widget.dart, activity_log_screen.dart (sed)
- lib/shared/services/auth_service.dart, order_service.dart, cart_service.dart, activity_log_service.dart (sed)
- lib/shared/models/activity_log.dart (sed)
- lib/features/customers/{screens,widgets,data}/ (sed across 5 files)
- lib/features/auth/screens/{login_screen,access_granted_screen,create_pin_screen}.dart (sed)
- lib/features/pos/{screens,widgets,controllers}/ (sed across 5 files)
- lib/features/inventory/{screens,widgets,data}/ (sed across 9 files; uppercase WAREHOUSE labels fixed)
- lib/features/expenses/widgets/add_expense_sheet.dart (sed)
- lib/features/dashboard/screens/{dashboard_screen,stock_audit_screen}.dart (sed)
- lib/features/orders/screens/orders_screen.dart (sed)
- lib/features/profile/screens/profile_screen.dart (sed)
- lib/features/deliveries/widgets/receive_delivery_sheet.dart (sed; uppercase fix)
- lib/features/sync/screens/first_sync_screen.dart (sed)
- lib/core/widgets/app_fab.dart, lib/core/diagnostics/sync_diagnostic.dart, lib/core/services/supabase_sync_service.dart (sed)
- lib/main.dart (sed; import path corrected)
- supabase/migrations/0045_rename_warehouses_to_stores.sql (new, 1376 lines)
- supabase/scripts/rollback/0045_rollback.sql (new, 1324 lines)
- BUILD_LOG.md (this entry; checklist row updated)

**Database changes:**
- Drift schema bumped to v14.
- Table `warehouses` renamed to `stores` locally.
- Ten `warehouse_id` columns renamed to `store_id`.
- Indexes `idx_warehouses_business_lua`, `idx_warehouses_business_deleted`, `idx_inventory_business_pw` renamed to their `_stores_` / `_ps` equivalents.
- Trigger `bump_warehouses_last_updated_at` renamed to `bump_stores_last_updated_at`.
- `_syncedTenantTables`: `'warehouses'` → `'stores'`.
- `_softDeletableTables`: `'warehouses'` → `'stores'`.
- `_LedgerImmutability('activity_logs', ...)`: `'warehouse_id'` → `'store_id'` (the column rename auto-updates the trigger body; the list mirrors the new shape for fresh installs).
- Pending `sync_queue` rows with table-level `warehouses:*` action_types are forwarded to `stores:*`.
- Cloud side: migration 0045 + rollback ready; deploy as one commit with the Dart client to avoid a `p_warehouse_id`/`p_store_id` parameter-name mismatch on `complete_onboarding` and the three v2 RPCs whose parameter names also changed.

**Master plan sections covered:**
- §1.1 (multi-membership directionality made explicit).
- §2.2 (multi-store directionality made explicit; Warehouse → Store rename source-of-truth).
- §27.2 (sidebar item is "Stores", plural).
- §27.5 (Warehouse sidebar item replaced).
- Touches every section that mentions the renamed word, but they were already correct in the plan (the doc never said "Warehouse" outside §27.5).

**Plan updates made during session:**
- Two restatements in §1.1 and §2.2 making "one CEO → many businesses" and "one business → many stores" directionality explicit. Requested by the user; no architectural change.

**Tested:**
- `flutter analyze lib/ test/` — clean of errors. 18 pre-existing `avoid_print` infos remain in `test/database/roles_v13_report.dart` (intentional debug output from Session 2; out of scope).
- `flutter test test/database/roles_v13_seed_test.dart` — 7/7 passing. Asserts row counts (30 / 63 / 8 / 1 / 1 — the trailing `user_stores` count survives the v13 → v14 column rename invisibly because the test queries via Drift's typed API).
- `flutter test` (full suite) — 101 passed, 58 skipped, zero failures.
- `flutter pub run build_runner build --delete-conflicting-outputs` — succeeded; 238 outputs. Only the pre-existing `manager` API duplicate-orderings warnings (Session 2) remain.
- Final grep: zero `warehouse` references in `lib/` or `test/` Dart files outside the v14 migration block in `app_database.dart` (the migration block intentionally contains the old strings to execute the rename).

**Known issues / left open:**
- Cloud migration 0045 + rollback 0045 are written but NOT yet deployed. The user will handle deploy timing. **Deploy the SQL and ship the new Dart build in the same commit / rollout** — the `complete_onboarding` signature changes parameter name `p_warehouse_id` → `p_store_id`, and `pos_record_sale_v2` / `pos_record_expense` / `pos_create_customer` similarly. Any client + server mismatch on parameter names will fail the RPC.
- `pos_pull_snapshot` (last in 0020) still references the dropped `business_members` and `invites` tables in its `v_tenant_tables` array. 0045 only substitutes `'warehouses'` → `'stores'` — it does NOT fix the stale references because that's a separate concern noted in `project_role_refactor.md`. The snapshot has presumably been broken since 0041; if so, that needs its own session.
- No upgrade-path test asserts v13 → v14 migration runs without errors on a real device. Session 2's test suite uses `onCreate` (fresh v14 schema) only. The migration was reasoned about against SQLite's documented behavior (≥ 3.25 auto-updates FK refs / trigger bodies on RENAME); a real v12/v13 device upgrading should be smoke-tested before relying on it in production.
- v11 → v14 cumulative upgrade path is not exercised by automated tests. The v12 raw DROP COLUMN fix (commit `b9ae0b8`) is reasoned about — SQLite 3.35+ semantics, bundled SQLite is recent enough via `sqlite3_flutter_libs ^0.5.15` — but not directly verified. Before any release goes to a real device that was last installed at v11 or earlier, add a Drift schema-fixture test: `drift_dev schema dump` for v11/v12/v13, then a `verifySelf()` walk through each upgrade block. Roughly a one-session investment; worth doing once because it pays for itself on every subsequent schema change.

**Next session should:**
- Begin step 4 of PIVOT_PLAN.md §8: the small renames pass (Customer Group → Price Tier, Dashboard → Home, Purchases → Shipments, Crate Groups → Crate Size Groups, Settings → CEO Settings; drop `purchase_items`). This is another schema bump (v15) plus cloud-side rename mirror.

**Code-review fixes applied 2026-05-27 (same session, after the initial pass):**

User reviewed the Step 3 output and surfaced three findings. All fixed before closing out the session.

- **P0 — sync_queue payload rewrite.** v14 originally rewrote only the `action_type` for `warehouses:*` rows; payloads of writes to tables that reference the renamed table (users, customers, inventory, orders, …) still carried `'warehouse_id': '...'` keys. After cloud 0045 deploys, those keys would either get silently stripped by the push-time column whitelist (users) or hard-fail with PostgREST 42703 (every other table). Same problem on domain envelopes with top-level `p_warehouse_id`. Fix: two extra `customStatement` UPDATEs at the bottom of the v14 block that use `json_set` + `json_remove` to rewrite top-level `$.warehouse_id` → `$.store_id` and `$.p_warehouse_id` → `$.p_store_id` on every pending sync_queue row. Documented in-block that nested keys (e.g. `warehouse_id` inside `p_movements` arrays for `pos_record_sale_v2`) are NOT rewritten — SQLite's `json_set` can't recurse and the nested shape is RPC-specific. Practical risk is low because domain envelopes drain quickly. New test file `test/database/stores_v14_payload_rewrite_test.dart` (7 cases) asserts: top-level rewrite on `users:upsert`; cross-table rewrite on 9 affected tables; domain `p_warehouse_id` rewrite; payloads without the key are untouched; non-pending rows skipped; idempotent on repeat runs; mixed (both keys present) payloads handled.
- **P1 — `pos_pull_snapshot` had a stale array.** The original rewrite in 0045 propagated `'business_members'` and `'invites'` from 0020 into the new array, but those tables were dropped by 0041 and the function has been broken since. Removed both strings from the array in 0045 and in the rollback (the rollback intentionally does NOT restore the broken 0020 shape — it restores a 0020-shape with the fix preserved, so a rollback does not re-introduce the snapshot bug). Added explanatory comments. The function should now actually work after 0045 deploys.
- **P2 — CLAUDE.md §5 exception #6.** One-word fix: "writes to `users` / `businesses` / `warehouses`" → "writes to `users` / `businesses` / `stores`". Hard rule #15 and coding rule #2 were already correct from the earlier sweep.

**Re-verification:**
- `flutter analyze lib/ test/` → still 0 errors; only the 18 pre-existing `avoid_print` infos.
- `flutter test` → 108 passing (was 101), 58 skipped, 0 failures. The 7-case payload-rewrite test passes.

---

## Session 2 — 2026-05-26 — Schema v13 (roles, permissions, membership)

**Built today:**
- Schema v13 bump. Seven new tables: `permissions` (global static config), `roles`, `role_permissions`, `role_settings`, `user_businesses`, `invite_codes`, `user_stores`. Six are synced tenant tables; `permissions` is global.
- Drift v13 migration that creates the new tables, adds the matching `(business_id, last_updated_at)` and soft-delete indexes, adds bump triggers, and seeds the 30-row global `permissions` table from a hardcoded list.
- `_postCreateStatements` updated to do the same for fresh installs (v13 schema on a brand-new device).
- Seven new DAOs in `daos.dart`: `PermissionsDao` (read-only), `RolesDao`, `RolePermissionsDao`, `RoleSettingsDao`, `UserBusinessesDao`, `InviteCodesDao`, `UserStoresDao`. All tenant DAOs route writes through `enqueueUpsert` / `enqueueDelete` per CLAUDE.md §5.
- Seven new stream providers in `stream_providers.dart`: `allRolesProvider`, `allPermissionsProvider`, `rolePermissionsProvider`, `roleSettingsProvider`, `userBusinessesProvider`, `myUserStoresProvider`, `activeInviteCodesProvider`.
- Three Supabase migrations: `0042` (schema + RLS + realtime + bump triggers), `0043` (permissions seed + per-business backfill via `seed_default_roles_for_business` helper function), `0044` (extends `complete_onboarding` RPC to seed roles + bind CEO).
- Verification test `test/database/roles_v13_seed_test.dart` — 7 tests, all green. Companion report at `test/database/roles_v13_report.dart` that prints actual DB contents for spot-check.

**Files touched:**
- lib/core/database/app_database.dart
- lib/core/database/app_database.g.dart (regenerated)
- lib/core/database/daos.dart
- lib/core/database/daos.g.dart (regenerated)
- lib/core/providers/stream_providers.dart
- supabase/migrations/0042_create_roles_permissions_tables.sql (new)
- supabase/migrations/0043_seed_permissions_and_backfill_businesses.sql (new)
- supabase/migrations/0044_complete_onboarding_seeds_roles.sql (new)
- test/database/roles_v13_seed_test.dart (new)
- test/database/roles_v13_report.dart (new)
- BUILD_LOG.md (this entry)

**Database changes:**
- Drift schema bumped to v13.
- Seven new tables added (see "Built today").
- `_syncedTenantTables` extended with: roles, role_permissions, role_settings, user_businesses, invite_codes, user_stores.
- `_softDeletableTables` extended with: roles, invite_codes.
- `_LedgerImmutability` and existing ledger tables unchanged.
- Cloud side: three new migrations 0042/0043/0044, plus a new SQL helper `seed_default_roles_for_business(uuid)`. Not yet deployed — user to deploy when convenient.

**Master plan sections covered:**
- §2.1 (Data-driven roles) — schema scaffolded; runtime use in later sessions.
- §2.4 (Database tables) — six of the listed tables built; `stores` and `activity_logs` extensions deferred to later steps per PIVOT_PLAN.md.
- §2.5 (Permission keys) — all 30 starter keys seeded.

**Plan updates made during session:**
- None. (All plan changes from this session were captured in Session 1 ahead of code work.)

**Tested:**
- `flutter test test/database/roles_v13_seed_test.dart` — 7 / 7 passing. Asserts row counts (30/63/8/1/1), slugs (ceo/manager/cashier/stock_keeper), per-role permission counts (30/24/6/3), default setting values, and the corrected Stock-keeper-no-products.add invariant.
- `flutter analyze` on the three changed lib files — no issues.
- `flutter pub run build_runner build` — succeeded; warnings about duplicate `manager` API reference names are pre-existing and don't affect runtime.

**Known issues / left open:**
- Cloud migrations 0042/0043/0044 have been written but not deployed (no local Supabase instance was configured for this session). When deployed, run the verification queries at the bottom of each migration file against a real Supabase instance to confirm the row counts match.
- The `manager` API duplicate-orderings warnings from build_runner are pre-existing; the master plan rebuild has no `manager`-API usage, so they're cosmetic. Add `@ReferenceName()` annotations as a cleanup pass later if needed.
- Local backfill for v12 → v13 upgraders is intentionally NOT done in the Drift migration — the cloud is authoritative and the next sync pull populates the tenant tables. This means a v12 device upgrading offline will have empty role tables until it reconnects. Document this in the upgrade notes when shipping.

**Next session should:**
- Begin step 3 of PIVOT_PLAN.md §8: rename pass for warehouses → stores (Drift v14 + cloud-side migration). Touches the new `invite_codes.warehouse_id` and `user_stores.warehouse_id` columns along with everything else.

---

## Session 1 — 2026-05-26 — Pivot Planning

**Built today:**
- No code written. Read-only investigation session to produce PIVOT_PLAN.md.
- Read all planning docs and inventoried the existing codebase end-to-end.
- Surfaced 10 open questions; user answered all 10.
- Wrote PIVOT_PLAN.md in the repo root.

**Files touched:**
- PIVOT_PLAN.md (created, then revised after user decisions)
- reebaplus_master_plan.md (updated — see "Plan updates" below)
- BUILD_LOG.md (this entry)

**Database changes:**
- None.

**Master plan sections covered:**
- Full read of reebaplus_master_plan.md to map gaps against the current codebase.

**Plan updates made during session:**

The user reviewed PIVOT_PLAN.md's 10 open questions and approved the following changes to reebaplus_master_plan.md:

- **§2.3 rewritten.** Was: "drop users_role_tier_check constraint". Now: "Starting from a clean schema — the old staff/role system was wiped in commit 38ea06b / migration 0041; all §2.4 tables build fresh."
- **§1.1 rewritten.** Was: "one email can belong to more than one business" (no caveat). Now: "Phase 1: each user belongs to one business at a time. The database supports multi-membership from day one; the switch-business picker UI is Phase 2."
- **§7.1 updated.** Removed the "If user belongs to multiple businesses, show business picker" line. Replaced with: "Straight to Home for the user's single business. Multi-business picker is Phase 2."
- **§16.5 updated.** Added explicit note that the four legacy product price columns (retail / bulk breaker / distributor / selling) are dropped during the pivot. Products now hold exactly three prices: Buying Price, Retailer Price, Wholesaler Price.
- **§16.5 + new §16.11 added.** Barcode scanning is in scope for Phase 1, but only for Pharmacy and Supermarket business types. Hidden for Bar, Beer Distributor, Restaurant, Boutique. The `barcode_widget` package stays in pubspec.yaml. The QR code on the receipt remains removed (§15.3).

Other decisions that did not change the master plan but are recorded in PIVOT_PLAN.md:
- Funds Register movements live as a new `funds_account_id` column on `payment_transactions` (no new `funds_movements` table).
- `users.businessId` stays as a "primary business" pointer; `user_businesses` is built alongside it.
- `purchase_items` is dropped along with the `purchases` → `shipments` rename.
- `activity_logs` migrates to the generic `entity_type` / `entity_id` / `before` / `after` shape; old per-entity FK columns dropped after data copy.
- "Pro Tips" sidebar item removed (moves to Settings > Help in Phase 2).
- `crate_groups` → `crate_size_groups`; relaxed to allow any positive integer.
- "Settings" sidebar item renamed to "CEO Settings", hidden for non-CEO.

**Tested:**
- N/A — planning only.

**Known issues / left open:**
- The Q4 product price column drop will lose existing price data on test devices. User confirmed: "no data migration from the old columns — fresh start. User will manually re-enter prices after the migration." Confirm again before running the migration.

**CLAUDE.md updates made this session:**
- §5 (Sync invariants) expanded from 2 documented exceptions to 6. The four additions: `_compensateRejectedSale` (order_service.dart), `setUserPin` (auth_service.dart, PIN columns local-only by schema), `upsertLocalUserFromProfile` (auth_service.dart, mirrors a cloud read), and `createNewOwner` / `completeOnboarding` (auth_service.dart, cloud RPC already wrote canonical state and resolver isn't bound). All four were already justified in code with explicit comments; the documentation was just out of date. Update done out-of-band ahead of the main pivot order so future sessions don't accidentally "fix" legitimate code.

**Additional plan updates made this session (during step 2 blueprint review):**
- Master plan §16.7 updated: "Add product" for Stock keeper changed from "Yes" to "No". User clarified the planning decision: only CEO and Manager can add new products. Stock keepers can add stock and adjust quantities on existing products only. This drops `products.add` from the Stock keeper default permission set.
- Default `role_settings.max_expense_approval_kobo` for Manager set to 0 (was tentatively ₦50,000 in the first blueprint). CEO must set this explicitly in CEO Settings before any Manager can approve expenses without escalation. Safer opening default for fresh businesses. (Master plan §10.2 was already non-prescriptive; no master plan edit needed.)
- `roles` table gains a `slug` column (lowercase identifier: `ceo`, `manager`, `cashier`, `stock_keeper`). All code that branches on role identity uses the slug, never the name. `name` stays for display + future localisation. UNIQUE (business_id, slug). The four default seeds carry these slugs.

**Notes for later sessions (not actioned this session):**
- The Cashier `reports.see_sales` permission grants the bare ability to see a sales report, but the "own sales only" scope is NOT enforced by the permission itself — it must be enforced at the query layer. Make sure step 11 (Home role-aware cards) and step 26 (Reports) both apply this scope filter when the current user is a Cashier. The same scoping discipline applies anywhere a role has "own store only" or "own sales only" access per master plan tables — permissions answer "can they see the report?", queries answer "what data is in it?".

**Next session should:**
- Begin with step 1 of PIVOT_PLAN.md section 8: master plan reconciliation review with the user (already done in this session — can skip to step 2).
- Then step 2: build the schema v13 migration with the new tables (`roles`, `permissions`, `role_permissions`, `role_settings`, `user_businesses`, `invite_codes`, `user_stores`). Their DAOs and stream providers. Mirror cloud-side. Add to `_syncedTenantTables`. Seed 4 default roles + permission rows on business creation.

---

## Session 0 — Setup (template entry — replace with first real session)

**Built today:**
- This is a placeholder entry. Delete it after the first real session is logged.

**Files touched:**
- MASTER_PLAN.md
- CLAUDE.md
- BUILD_LOG.md

**Database changes:**
- None.

**Master plan sections covered:**
- All sections (initial setup of planning files).

**Plan updates made during session:**
- None.

**Tested:**
- N/A — setup only.

**Known issues / left open:**
- Everything in the build status overview is still open.

**Next session should:**
- Begin with Phase 1 foundation work — the database schema rebuild (section 2 of master plan). Drop the brittle role check constraint on the users table. Set up the new tables: roles, permissions, role_permissions, role_settings, stores, user_stores, user_businesses, invite_codes, activity_logs.
