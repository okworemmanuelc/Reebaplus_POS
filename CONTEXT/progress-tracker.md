# Progress Tracker

Update this file after every meaningful implementation change.
The agent reads this file at the start of every session to restore full context.
The human updates it when resolving open questions or making architectural decisions.

---

## Current Phase

Phase 1 — In progress. Session 148 complete (2026-06-16).
148 sessions logged. Codebase is live and being verified on-device.

---

## Current Goal

On-device verification of Session 143 pull-side pagination (throttled/cellular
connection), Session 144 onboarding form updates (business type picker,
phone + LGA fields), and verification of the permission gating screen rendering.

---

## Completed

### Foundation
- Database schema rebuild — Drift schema v13 (Session 2). Now at **v49** after
  141 sessions of incremental migrations.
- Role + permission seeding for new businesses (Session 2). 30 permission keys,
  4 default roles (CEO / Manager / Cashier / Stock keeper) seeded on business
  creation.
- Cloud migrations deployed through **0114** (deleted_businesses tombstone).

### Auth flow
- Welcome screen §4 (Session 6).
- CEO sign-up flow §5 — new-email path (Session 7). Existing-email /
  multi-business branch deferred to Phase 2.
- Staff sign-up via invite code §6 (Session 10).
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
- **Supplier Accounts §21** — core ledger built and store-scoped. On-device
  verification pending.
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
- Drift client schema: **v49**.
- Cloud migrations deployed through: **0114** (0115 written, not yet pushed).
- `flutter test test/sync/` — **115 pass** (Session 141 baseline).
- Full suite last confirmed: 429 pass (Session 145).
- `flutter analyze lib` — clean. 18 pre-existing `avoid_print` infos in
  `test/database/roles_v13_report.dart` only; not regressions.
- iOS build enabled; free Apple ID cert expires after 7 days — re-run
  `flutter run` to refresh.

**Three things to check before every unit:**
1. `flutter analyze` clean before and after.
2. No raw Supabase call from `lib/features/` or `lib/data/repositories/`.
3. No UPDATE or DELETE on an append-only ledger table — corrections are
   new rows only.
