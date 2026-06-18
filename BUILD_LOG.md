# Build Log

---

## 2026-06-18 — Sync Issues: collapse `sessions:upsert` churn (reuse session id per device+user)

**Investigation.** A device's Sync Issues screen showed a pile of pending
`sessions:upsert` (and a couple `user_businesses:upsert`) rows, attempts
climbing to 15, failing with two network-rooted errors: `Failed host lookup …
errno = 7` (DNS down — the URI was `/auth/v1/token?grant_type=refresh_token`,
i.e. the client couldn't even refresh its expired access token) and
`TimeoutException after 0:00:15` (same dead/weak link, hitting the per-attempt
cap in `_pushChunkTimeoutForAttempts`). HEALTH read Pending 5 / **Failed 0 /
Orphaned 0** — the queue was holding and retrying correctly. So the root cause
of the *errors* is a device-side network/DNS outage, not sync logic (matches the
errno-7 rule); they drain on reconnect.

**The real fixable smell.** `SessionsDao.createSession` minted a **new** session
id on every `setCurrentUser` (login, biometric unlock, PIN re-entry, Switch
User). `enqueueUpsert` coalesces by `(action_type, payload.id)`, but a *new id
each time* defeats that — so every re-auth produced a *separate* outbox row, and
offline re-auths accumulated low-value session pushes that burned retries for
sessions that no longer mattered (the screenshots showed 3+ distinct ids ~20 min
apart).

**Fix.** `createSession` (`daos.dart`) now reuses the existing **active**
(non-revoked, non-expired) session for the same `device_id` + `user_id`: bumps
`expires_at` (sliding TTL) and re-enqueues the full row under the **same id**, so
enqueueUpsert collapses every re-auth into the one coalesced pending row. A
revoked (kicked/logged-out) or expired session is not reused — a real re-login
still starts a new session; no `deviceId` falls back to minting (unchanged).
`AuthService._kickOtherDevices` changed its raw cloud session `insert`→`upsert`
so a fresh sign-in that reuses an already-pushed id can't 23505.

**Verification:** `flutter analyze` on both touched files — clean. Behavioural
(queue stops accumulating duplicate session rows) pending on-device check.

---

## 2026-06-18 — Reports hub: drop the duplicate period bar + tap-through to customer detail from Orders

**Two small UX fixes.**

**1. Reports hub period filter was duplicated.** The Reports hub
(`reports_hub_screen.dart`) rendered a 5-chip period bar (Today / This Week /
This Month / This Year / To Date) above the card grid, but it only seeded the
**Profit Report's** initial period — every other card (Approvals, Daily
Reconciliation, Crate Deposits, Supplier Accounts) ignored it, and each inner
report already owns its own period filter (Profit's AppBar dropdown, Daily
Reconciliation's grouping dropdown). So the user saw period chips on the hub,
then again inside each report. Removed the hub-level bar entirely — the hub is
now just the menu of cards; the period filter lives where its data is.
- `reports_hub_screen.dart`: deleted `_selectedPeriod`, `_periods`,
  `_buildPeriodBar`, `_buildPeriodChip`, and the `Column` wrapper (grid is the
  direct body child now). Removed the now-unused `date_period.dart` import.
- `profit_report_screen.dart`: `initialPeriod` is now optional
  (`String?`, defaults to `kDatePeriodLabels.first`); the hub launches it as
  `const ProfitReportScreen()`.

**2. Orders card → customer detail.** Tapping an order card opened the receipt;
there was no way to reach the customer's profile from Orders. Wrapped the order
card's customer profile region (avatar + name/address) in an `InkWell` that
pushes `CustomerDetailScreen(customer: Customer.fromDb(customer))` via
`slideDownRoute`. For a walk-in (`customer == null`) `onTap` is null, so the tap
falls through to the card's existing `onViewReceipt`. The rest of the card still
opens the receipt.
- `orders_screen.dart` (`_OrderCard`): new imports (Customer model,
  CustomerDetailScreen, slide_route); header restructured so the profile is its
  own tap target inside the existing `Expanded`.

**Verification:** `flutter analyze lib` — touched files clean (3 pre-existing
unused-import warnings remain in unrelated settings screens). `flutter test
test/orders` — 7/7 green.

---

## 2026-06-18 — Auth session-loss diagnostics never reached the cloud (tenant-scope fix)

**Goal:** make the `auth.session_lost` / `auth.session_expired_gate` breadcrumbs
(added earlier today to attribute release "session has expired" reports to a
provider) actually release-visible. They weren't.

**Root cause (verified against the live cloud `error_logs` table):** the table
works — 34 rows, including generic crashes from today — but **zero `auth.*`
rows** had ever arrived. Both breadcrumbs fire at the instant the JWT is gone,
and on the remote-kick path `auth.session_lost` fires *after*
`AuthService.value` is nulled by `fullLogout`. With no business bound,
`ErrorLogDao.logError` derived `bid = currentBusinessId == null` and kept the row
**local-only** (the `if (bid != null) enqueueUpsert` guard) — never queued, never
pushed. The diagnostic for "I lost my session" could not be sent using the
session it was reporting the loss of.

**Fix:** thread an explicit tenant through the diagnostic path so the row is
scoped to the in-hand local user (which we still hold at teardown) and durably
enqueued, flushing on the next authenticated push — for the high-value
`session_expired_gate` case, the OTP re-auth that very screen performs.
- `ErrorLogDao.logError` — new optional `businessId` / `userId` params;
  `bid = businessId ?? currentBusinessId` (same fallback for user). Ordinary
  crash captures are unchanged (resolver still used). Enqueue guard + Layer-C
  raw-write scanner contract preserved.
- `CrashReporter.record` — additive `businessId` / `userId` passthrough.
- `main.dart`: `_SessionExpiredScreen` passes `widget.user.businessId/id` (both
  the success and lookup-failed branches); the auth-state listener captures
  `_auth.currentUser` before any teardown and passes its tenant on
  `auth.session_lost`.

**Verification:** `flutter analyze` clean on all touched files (the 3 unused-import
warnings are pre-existing, in unrelated settings screens). `flutter test
test/sync/` — 119/119 green. Cloud check: migration 0108 (`error_logs`) confirmed
deployed; the stale memory note ("0108 NOT pushed yet") was wrong and is corrected.

---

## 2026-06-18 — Supplier Accounts §21: confirmation gate, CEO void, accounts report, crates section

**Goal:** close the remaining gaps in Supplier Accounts against the 130-check
Phase-1 verification list. The core ledger (list, add/edit/delete, per-store
scope §21.11, transaction history, Daily Reconciliation §14, payment
notifications §16) was already built and store-scoped; four functional gaps
remained.

**Changes:**
- **§4 Confirmation gate (user-confirmed).** Both the Invoice Total and Record
  Payment sheets now show a confirmation dialog *before* the entry is written
  (`confirmSupplierActivity` in `record_supplier_activity.dart`). It spells out
  type, supplier, amount, date, payment method (payments), and target store, and
  warns the entry is permanent and reversible only by a CEO void. Cancel returns
  to the form with data intact; Confirm saves.
- **§10 Void / reversal (CEO only).** Ledger rows on Supplier Details are now
  tappable for a CEO (`SupplierLedgerEntryTile.onTap`), opening an action sheet →
  Void confirmation → appends an opposite-sign compensating row carrying the
  original `store_id` (§21.11 / 10.7). `SupplierLedgerDao.voidEntry` now returns
  `bool` (false on missing/already-voided → double-void is a no-op, 10.11); a
  reversal row and an already-voided original are not voidable in the UI.
  `SupplierAccountService.voidEntry` writes an `supplier.void` Activity Log row
  on success (10.12). Write-boundary CEO re-check guards the action.
- **§15 Supplier Accounts Report.** New `SupplierAccountsReportScreen` + Reports
  hub card (gated on `suppliers.manage`: CEO default, Manager when toggled,
  hidden for Cashier/Stock keeper). One row per supplier: outstanding balance,
  total paid, total received — store-scoped via the §12.1 picker. Gross
  paid/received exclude voided entries; balance nets the void's compensating row.
  Folds the existing store-scoped providers — no schema/DAO change.
- **§3.13 Available Empty Crates section.** Display-only placeholder card on
  Supplier Details for crate businesses (`isCrateBusiness`); real per-supplier
  crate wiring stays deferred to a later phase.

**Verification:** `flutter analyze lib` clean for all touched files (3 pre-existing
unused-import warnings in unrelated settings screens remain). New
`test/suppliers/supplier_ledger_test.dart` (4 tests, green): balance netting,
per-store scope, void compensating-row + balance restore, double-void no-op. Full
suite: 442 pass / 58 skipped / 1 pre-existing unrelated failure
(`invite_staff_sheet_test.dart` — setState-during-build in the staff invite
sheet, not touched by this work). No Drift schema change → no build_runner / cloud
migration.

---

## 2026-06-18 — Release "session has expired" sign-out: investigation + diagnostic breadcrumbs

**Report:** on the release build a user was signed out and shown "session has
expired"; asked to confirm whether Google sign-in triggered it.

**Investigation (no behavioural change):** two distinct forced-logout mechanisms
exist and show different messages. The remote *kick* (single-active-device →
`fullLogout`) shows "signed in on another device"; the *session-expired* gate
(`main.dart` `_SessionExpiredScreen`, rendered when a local user is set but
`_supabaseHasSession == false`) is the one the user saw. The gate flips only on a
genuine Supabase `signedOut` event (transient/offline refresh failures surface on
the stream's `onError` and are swallowed, so the gate is *not* a flaky-network
false positive) — i.e. the refresh token was genuinely revoked server-side.

**Google verdict:** the Google handler (`email_entry_screen`) and the OTP handler
(`otp_verification_screen`) call the *identical* `resolvePostVerifyRoute`; the
device-kick (`setCurrentUser(freshSignIn: true)`) fires from a single place
(`biometric_setup_screen.dart:101`) reachable only on a *fresh* sign-up/PIN-create
by **both** providers. `_kickOtherDevices` uses `signOut(scope:
SignOutScope.others)`, which the server authenticates with the current access
token and always preserves the requesting session — so it can **never** revoke the
current device's own session. Conclusion: Google sign-in does not end the
signing-in device's session; it (like email OTP) revokes *other* sessions of the
same identity via the single-active-device policy. A release device "expiring" is
that policy revoking it because the same account signed in elsewhere.

**Instrumentation added (`lib/main.dart`):**
- `auth.session_lost` breadcrumb in the `onAuthStateChange` listener — records the
  `AuthChangeEvent` name + whether a local user was present when the session went
  null, written to the synced `error_logs` table (release-visible in the Supabase
  console; distinguishes a real `signedOut` revocation from a benign restore).
- `auth.session_expired_gate` breadcrumb in `_SessionExpiredScreen.initState` —
  records that the gate rendered, tagged with the stored auth method (google /
  email / unknown) so field reports can be attributed by provider.

**Docs:** added a "Single active session per identity" subsection to
`context/architecture.md` Auth & Access Model (was previously undocumented).
`flutter analyze lib/main.dart` clean. No schema/behaviour change.

---

## 2026-06-18 — Cold-start sync warm-up (false `timeout` on first push after login)

**Symptom:** right after login the Sync Issues screen showed a `Network`
`user_businesses:upsert` row failing with
`timeout: TimeoutException after 0:00:05.000000: Future not completed`
(attempts: 1), which then healed on the automatic backoff retry.

**Root cause:** not a server error — the Dart-side `.timeout()` firing. The first
push of a session gets a deliberately tight 5s budget
(`_pushChunkTimeoutForAttempts(0)`, fail-fast on dead links), but the very first
authenticated PostgREST request after login is never warm: cold DNS resolution +
TLS handshake + idle-radio wake + GoTrue session settling routinely exceed 5s on
mobile. Whatever row drains first absorbs that cold tax — right after login that's
`user_businesses` (enqueued by the login/onboarding membership write). The retry
succeeds because the connection is now warm *and* gets the roomier attempt-1
budget. Payload volume is irrelevant: the timeout is per *chunk* of
`_pushChunkSize` rows (no blobs in the sync path — `products.imagePath` is a local
path string, receipt photos are local-only), so a large catalogue is just more
warm chunks; only the first pays the cold cost.

**Fix:** `lib/core/services/supabase_sync_service.dart` — pay the cold cost once,
up front, with a warm-up + a backstop floor:
- `_warmUpConnection(businessId)` fires a cheap throwaway `businesses` `select id
  … limit 1` (RLS-safe, scoped to the session business) before the **first** drain
  of a session, so the handshake completes on a throwaway request, not a real row.
- `_didWarmUpThisSession` (reset on every sign-in/out and token refresh) gates it
  to one warm-up per session; a non-degraded drain also marks the session warm.
- First-drain backstop: that drain's per-chunk timeout is floored at
  `_firstDrainTimeoutFloor` (10s = the attempt-1 budget) even for fresh rows, in
  case the warm-up itself ate the cold tax. Subsequent drains fail fast (5s) as
  before — dead-link feedback is unchanged.

**Test:** existing sync suite green (119 tests); analyzer clean. The change is
network-timing behaviour (no schema/DAO change), verified by analyzer + suite;
on-device confirmation = no `user_businesses` timeout row in Sync Issues right
after a fresh login.

## 2026-06-18 — Empty Crates tab now per-store (Phase 2, §16.8.1)

**Symptom:** the inventory **Empty Crates** tab showed business-wide empty-crate
counts even when a specific store was active, so per-store empties were
inaccurate. (This was the locked Phase-1 business-wide behaviour; the user asked
for per-store.)

**Change:** the tab is now store-aware. When a store is locked
(`lockedStoreProvider` non-null) both **Full** and **Empty** confine to that
store; in "All Stores" mode it shows the business-wide totals.
- `InventoryDao.watchFullCratesByManufacturer({storeId})` gained an optional
  store filter (adds `inventory.store_id == storeId` to the
  `inventory↔products` join predicate). `fullCratesByManufacturerProvider`
  (new, in `stream_providers.dart`) watches `lockedStoreProvider` and passes it
  through. Empties read from `store_crate_balances` (per store, via
  `storeCrateBalancesProvider`) when locked, else `manufacturers.empty_crate_stock`.
- `_buildCratesTab` refactored to reactive `ref.watch` (store can change while on
  any tab); removed the now-redundant imperative crate stream subscriptions and
  the `_fullCratesByMfr`/`_emptyCratesByMfr` fields.

**Attribution:** a **manual** crate return from Customer Profile is credited to
the store the customer's most recent crate-bearing order was created from, via
new `OrderCrateLinesDao.resolveStoreForCustomerManufacturer(customerId,
manufacturerId)` (most recent store-stamped order carrying that brand), falling
back to the active store. Keeps `emptyCrateStock = Σ store_crate_balances`
accurate regardless of which store is active at return time. Receive-Delivery
already hard-requires a destination store and the pending-order crate-return
modal already passes `order.storeId`, so no other credit site leaks.

**Test:** `test/crates/crate_logic_test.dart` — new group
`per-store crate accuracy (§16.8.1)`: (1) `watchFullCratesByManufacturer(storeId:)`
confines a multi-store brand to one store and the all-stores view sums both;
(2) `resolveStoreForCustomerManufacturer` returns the most-recent order's store;
(3) returns null with no orders. Full suite 15 tests green. No schema migration
(0104 `store_crate_balances` already shipped).

## 2026-06-17 — Crates tab "Full" always showed zero (ID-vs-name lookup)

**Symptom:** in the inventory **Empty Crates** tab, every manufacturer card's
**Full** stat (and the per-card Total) read **0**, even with full bottles in
stock. Empty counts were correct.

**Root cause:** the full/empty watch streams
(`InventoryDao.watchFullCratesByManufacturer` /
`watchEmptyCratesByManufacturer`) emit maps keyed by **manufacturer ID**, so
`_manufacturerCrateStats[].manufacturer` holds an ID. But the per-card lookup in
`_buildCratesTab` matched `s.manufacturer == mfr.name` — comparing an ID against
a name. It never matched, so every card fell to the `orElse` branch with
`totalBottles: 0`. (The top-of-tab "Full (Crate)" total summed the ID-keyed
stats directly and was unaffected — only the per-card value was wrong.)

**Fix:** `lib/features/inventory/screens/inventory_screen.dart` — match the stat
by `mfr.id` (lookup + `orElse`). No data-layer change: the "Full" count already
streams live from `inventory.quantity` joined on `manufacturer_id`, and all
write paths are stream-tracked (`updates: {inventory}` on the sale decrement,
`updates: {manufacturers}` on `addEmptyCrates`), so "Full" now depletes on sale
and empties (returns + pending-order-confirmation deliveries) increment live.

**Test:** `test/crates/crate_logic_test.dart` — added
`watchFullCratesByManufacturer is ID-keyed and depletes on sale` (asserts the
ID key emits the seeded count and re-emits the reduced count after a sale-style
inventory decrement). Full crate suite (12 tests) green.

## 2026-06-17 — Revenue recognized at checkout, not at Confirm

**Decision (locked):** money/revenue is recognized when **checkout** completes —
the order is written with status `pending` (wallet legs booked, inventory
deducted in `OrderService.addOrder`). The later **Confirm** step
(`OrdersDao.markCompleted`, status `completed`) is ceremonial: it records the
customer's receipt of goods and any returned empty crates. It does not create
revenue.

**Symptom:** every money/sales aggregation filtered orders on
`status == 'completed'`, so a checked-out-but-unconfirmed sale showed **zero**
revenue everywhere until someone confirmed it — contradicting the agreed model.

**Fix:** added a canonical predicate `orderCountsAsSale(status)` /
`orderRevenueStatuses = {'pending', 'completed'}` in
`lib/shared/models/order_status.dart` (a "recognized sale" = checked out and not
reversed). Routed every revenue/sales site through it:
- `recon_data.dart` — `buildReconBuckets` (items sold) and `computeReconData`
  (Daily Reconciliation revenue / P&L). The separate `refunded` branch is
  unchanged.
- `home_screen.dart` — dashboard Today's Sales / Business Overview / Net Profit
  (`filteredOrdersWithItems`; Sales Detail inherits it). The `pendingOrdersCount`
  card still counts `pending` orders separately — untouched.
- `profit_report_screen.dart` — Profit Report revenue/COGS.
- `profile_screen.dart` — Sales Volume now counts non-reversed sales; the
  "Completed" stat stays a true lifecycle count.
- `staff_detail_screen.dart` — staff sales SQL → `status IN ('pending',
  'completed')`.
- `daos.dart` — `getSalesSummaryForProduct` → `status IN ('pending',
  'completed')`.

Cancelled/refunded orders remain excluded everywhere (reversed sales). No schema
change. `flutter analyze lib` clean (8 pre-existing warnings in
`app_drawer.dart`/`main_layout.dart` only). `test/orders` + `test/wallet` green;
full suite green except one pre-existing `invite_staff_sheet_test` failure from
the in-progress `app_dropdown.dart` work (unrelated — Form setState-during-build).

---

## 2026-06-17 — Empty crates: crate return not showing in Crates tab + business-wide Phase 1

**Symptom:** Recording a crate return from a Customer Profile → Crates tab "+"
card did not update the per-manufacturer balance rows (neither the customer's
Crates tab nor the Inventory Empty Crates count reflected it live).

**Root cause:** the balance-cache upserts were written with raw
`customStatement(...)`, which Drift's stream-invalidation engine does not
observe. So `watchCrateBalancesWithGroups` (and the inventory streams) never
re-ran — the data was persisted but the UI did not refresh until a fresh open.
A secondary inconsistency came from the Inventory tab reading per-store
`store_crate_balances` when a store was locked while the customer-return write
path is business-wide.

**Fix (business-wide Phase 1, per checklist §8.7):**
- **Unit A** — routed every balance upsert through stream-notifying
  `customInsert(..., updates: {table})`: `recordCrateReturnByCustomer`,
  `recordCrateIssueByCustomer`, `recordCrateReturnByManufacturer`,
  `StoreCrateBalancesDao.applyDelta` / `setBalance`. This fixes the reported bug.
- **Unit B** — Inventory Empty Crates tab now always reads the business-wide
  `manufacturers.empty_crate_stock` (dropped the locked-store branch). Per-store
  `store_crate_balances` rows are still written as Phase-2 scaffolding but no
  Phase-1 UI reads them, so every surface stays consistent.
- **Unit C** — manual crate return now writes an Activity Log row (§7.8);
  a sale that leaves a registered customer owing crates (no-deposit path) fires
  a CEO + Manager notification (`customer_crate_debt`, §12.1/§12.2) via a
  best-effort post-sale hook in `OrderService`.
- **Unit D** — cart "Empty Crates" section is hidden for walk-in customers
  (gated on `_activeCustomer != null`, matching checkout's `_depositApplies`)
  (§3.13).

**Files changed:**
- `lib/core/database/daos.dart` — 5 balance upserts → `customInsert` + `updates`.
- `lib/features/inventory/screens/inventory_screen.dart` — crates tab business-wide.
- `lib/shared/services/order_service.dart` — `_notifyCrateDebt` post-sale hook.
- `lib/features/customers/screens/customer_detail_screen.dart` — activity log on return.
- `lib/features/pos/screens/cart_screen.dart` — hide Empty Crates for walk-in.

**Tests added:** `test/crates/crate_logic_test.dart` (live watch-stream
regression, ×2); `test/crates/crate_debt_notification_test.dart` (×3, §12.1/§12.2
+ walk-in).

**Verification:** `flutter analyze` clean on all five changed files. Crate /
checkout / notification / inventory / wallet suites pass (57 + the new crate
tests). NOTE: full `flutter analyze lib` is currently blocked by an unrelated
in-progress syntax error in `lib/features/customers/screens/customers_screen.dart:150`
(not part of this work) — flagged to the user.

## 2026-06-17 — Stop FK-violation storm: abort push cycle on a degraded link

**Symptom:** On a flaky link, the Sync Issues screen filled with transient 23503
FK violations (`order_items` / `wallet_transactions` "Key is not present in table
orders") plus a network timeout. The rows self-healed on retry but the screen was
alarming and burned retry attempts.

**Root cause:** v1 per-table push sends groups parent→child by FK priority
(`orders` → `order_items` → `wallet_transactions`). When the parent `orders`
chunk timed out, the loop still continued into the child groups, which then all
FK-failed because the parent never landed.

**Fix:** Added a cycle-level `linkDegraded` flag in `pushPending`. A chunk that
fails with a timeout or a transient network/5xx error (NOT a per-row FK-deferred
or permanent constraint) sets it; after that group's chunks finish, the group
loop `break`s, skipping the remaining child groups. Domain envelopes and the
200-row re-drain microtask are also skipped while degraded. The queue is intact —
the next connectivity/periodic trigger retries the whole queue in priority order,
parents first.

**Files changed:**
- `lib/core/services/supabase_sync_service.dart` — `pushPending`: cascade guard
  (flag + break + domain/re-drain skips).

**Verification:** `flutter analyze` → No issues. `flutter test test/sync/` →
119/119 pass.

## 2026-06-17 — Dashboard debt/credit mis-scoped per store (multi-store)

**Symptom:** After opening a second store and selling across both, the Home
dashboard's debt/credit figures were inaccurate. (Reported alongside a
transient FK-violation storm on the Sync Issues screen — see investigation note
below; that storm self-healed and lost no data.)

**Root cause:** A customer has a single business-wide wallet (one balance, not
one per store) but can buy in multiple stores. The dashboard scoped the
customer set by the customer's assigned home store
(`filteredCustomers = _customers.where(storeId == lockedStore)`) and then summed
each customer's *business-wide* balance. So a cross-store customer's full
balance was counted under their home store (overstated) and dropped entirely
under the others (understated debt invisible). Verified on cloud data: customer
"Rhaenys" is assigned to Wuse Store but transacted in both Wuse and Keffi.

**Decision:** debt/credit is always business-wide, never store-scoped (a wallet
isn't per-store). Sales / inventory / expenses remain store-scoped.

**Files changed:**
- `lib/features/dashboard/screens/home_screen.dart` — removed the
  `filteredCustomers` store filter; `totalCredit` / `totalDebt` now fold over
  all `_customers`. Explanatory comment added.

**Verification:** `flutter analyze lib/features/dashboard/screens/home_screen.dart`
→ No issues found.

**Investigation notes (no code change here):**
- The `order_items` / `wallet_transactions` 23503 FK violations were transient:
  on the v1 per-table push path, when the parent `orders` chunk times out on a
  flaky link the push loop continues and sends children that then FK-fail. They
  retry and self-heal (and the new orphan auto-recovery re-drives
  `fk_deferred_cap_reached` orphans once the parent lands). Cloud query
  confirmed the order + all 3 items + all 5 wallet legs are present; nothing
  lost. Suggested follow-up (NOT applied — sync service under concurrent edit):
  abort the push cycle on a parent-group timeout instead of cascading into
  guaranteed-to-fail child pushes.
- `feature.domain_rpcs_v2.record_sale` is unset cloud-side → every device is on
  the v1 per-table path (v2 atomic RPC dormant).

## 2026-06-17 — Sync retry hardening: backoff cap + automatic orphan recovery

**Symptom:** Pending/orphaned sync issues could stay failed for a very long
time. Two distinct gaps: (1) a transient row's exponential backoff
(`(1 << (attempts % 10)) * base`) could reach ~4 h before wrapping, so on a
device that stayed continuously online (no connectivity transition to clear
backoff) a row sat idle long after its transient cause cleared; (2) orphans in
`sync_queue_orphans` were **never** auto-retried — manual-only via the Sync
Issues screen — even though several historical orphan causes are now
self-healing (the `created_at` scrubber S134, the order-number collision fix, an
FK parent that has since arrived).

**Root cause:** No backoff ceiling; no automatic orphan-recovery path. Orphans
were by-design manual to avoid blind-retrying genuinely-permanent failures (dup
order number) and churning the cloud.

**Fix (additive — no sync redesign):**
- **Backoff cap (§6.8):** `SyncDao.markFailed` now clamps the next-attempt delay
  to a ceiling — 5 min normal / 15 min FK-deferred. The 30 s periodic drain tick,
  connectivity recovery, and sign-in all re-evaluate eligibility, so a row
  retries on a bounded cadence.
- **Automatic orphan recovery (§6.8.1, conservative allowlist):**
  `SyncDao.autoRecoverDueOrphans` re-enqueues only orphans whose reason is on a
  self-healing allowlist — `fk_deferred_cap_reached*` and `*created_at is
  immutable*`. Terminal reasons (dup order number 23505, RLS / insufficient
  privilege, invalid_parameter_value) stay manual-only. A per-orphan cap (3)
  parks a still-failing row for manual review. The cap survives re-orphaning via
  a new device-local `auto_retry_count` column carried on the queue row and
  copied onto the orphan by `markFailed`. The sweep runs from the periodic drain
  tick and on connectivity recovery (`_recoverDueOrphans`, gated on `isOnline`).
  Manual `retryOrphan` resets the counter to 0 (operator takes ownership).

**Files changed:**
- `lib/core/database/app_database.dart` — `auto_retry_count` on `SyncQueue` +
  `SyncQueueOrphans`; schemaVersion 51 → **52**; idempotent `from < 52` migration
  (local-only — these are the outbox tables, never pushed, so NO cloud
  migration).
- `lib/core/database/daos.dart` — backoff ceiling in `markFailed` (+ carry
  `autoRetryCount` onto the orphan); `autoRecoverDueOrphans`,
  `_isAutoRecoverableReason`, `autoRecoverCap`, shared `_reenqueueOrphan` core
  (refactored out of `retryOrphan`).
- `lib/core/services/supabase_sync_service.dart` — `_recoverDueOrphans` wired
  into the periodic tick and `_handleConnectivityTransition`.
- `lib/core/database/app_database.g.dart` — regenerated.
- `test/sync/sync_dao_failure_classes_test.dart` — 4 new tests (allowlist
  recover, terminal skip, created_at recover, cap survives re-orphan).
- `context/architecture.md` — documented both rules under the push path.

**Verification:** `dart analyze lib` → No errors. `flutter test`
sync_dao_failure_classes_test.dart (9) + migration_upgrade_test.dart (15, steps
to v52) → all green. **Pending on-device confirmation** that a real stuck orphan
heals on the next tick / reconnect.

## 2026-06-17 — `storeInventoryCountsProvider` compile error (`Variable` undefined)

**Symptom:** Compile/analyze error in
`lib/core/providers/stream_providers.dart:35` — `The function 'Variable' isn't
defined`, plus three `invalid_null_aware_operator` / `unnecessary_null_comparison`
warnings on lines 41/43/44.

**Root cause:** The `storeInventoryCountsProvider` `customSelect` (added with the
new-store stock-count fix) used `Variable(businessId)`, but the file never
imported `package:drift/drift.dart` (Drift's `Variable` lives there, not in the
re-exports this file already pulled in). The reads also used `row.read<String>` /
`row.read<num>` (non-nullable), so the `if (storeId != null)` guard and the `?.`
operators were flagged dead.

**Files changed:**
- `lib/core/providers/stream_providers.dart` — added
  `import 'package:drift/drift.dart' show Variable;` (house pattern, matches
  `sync_diagnostic.dart`); switched the three column reads to
  `readNullable<…>` so the null guards are meaningful.

**Verification:** `dart analyze` on the file → No errors.

## 2026-06-17 — Live (realtime) sync dies on physical device after background

**Symptom:** Live cross-device sync works in debug on the emulator but stops
on a release APK installed on a physical phone — changes made on another device
no longer appear live.

**Root cause:** Not a release/minification issue (R8 is off, anon key is shared,
no `kReleaseMode` branch in the sync path). `startRealtimeSync` is called only
once at sign-in and guards with `if (_tableChannels.isNotEmpty) return;`, so it
never re-subscribes. The OS suspends/kills the realtime websocket on a physical
device (Doze, screen-off, WiFi↔mobile handoff) in ways that don't occur on an
always-on, never-dozing emulator, and the SDK's channel rejoin is not guaranteed
after a long suspension. Neither the connectivity-recovery handler nor the
app-resume handler re-established the channels — they only did a one-shot
catch-up pull (which masks the problem: changes appear after toggling network or
relaunching, but continuous live updates stay dead).

**Files changed:**
- `lib/core/services/supabase_sync_service.dart` — extracted
  `_tearDownRealtimeChannels()` from `stopRealtimeSync`; added
  `restartRealtimeSync(businessId)` (drops stale channels then re-subscribes;
  no-ops when no channels exist / not signed in). Called from
  `_handleConnectivityTransition` on network recovery.
- `lib/shared/widgets/auto_lock_wrapper.dart` — calls
  `_sync.restartRealtimeSync(subBizId)` on app-resume alongside the existing
  `refreshBusinessRow`.

**Verification:** `flutter analyze` on both files → No issues found. Re-subscribe
on resume + connectivity recovery is additive and idempotent. **Needs
physical-device confirmation** (background the app on a phone, make a change on
another device, foreground — the change should now arrive live).

## 2026-06-17 — New store card shows another store's stock

**Symptom:** Creating a new store made it appear on the Stores list with the
"Total Units" / "Products" figures of an existing store; tapping the card opened
the (correctly empty) detail screen.

**Root cause:** `_StoreCard` (a `ConsumerStatefulWidget`) was rendered in a
`ListView.builder` without a key and subscribed to its store's inventory stream
only once in `initState` using `widget.store.id`. Stores are ordered by name
(`watchActiveStores`), so inserting a new store shifts list positions; Flutter
then recycled the position-matched `_StoreCardState`, which kept streaming the
previous store's inventory. The card showed the old store's stock while
navigation used the correct `widget.store`.

**Files changed:**
- `lib/features/stores/screens/stores_screen.dart` — `_buildStoreCard` now
  passes `key: ValueKey(store.id)` so card state matches by store identity, not
  position; `_StoreCard` constructor accepts `super.key`; added
  `didUpdateWidget` + `_subscribeInventory()` to re-target the inventory stream
  and clear stale figures if a card's store id ever changes.

**Verification:** `flutter analyze lib/features/stores/screens/stores_screen.dart`
→ No issues found. A new store now starts at 0 units / 0 products until
inventory is assigned to it.

## 2026-06-16 — Session 148: Owner role protection

**Files changed:**
- `lib/core/database/app_database.dart` — added `ownerId` nullable TEXT column
  to `Businesses` table; schema v49 → v50; `from < 50` migration adds the column
  with try/catch for idempotency.
- `lib/shared/services/auth_service.dart` — `createNewOwner` and
  `completeOnboarding` both set `ownerId: Value(authUserId)` in the local Drift
  business insert so new and onboarding owners have the field populated before
  the first cloud pull.
- `lib/features/staff/screens/staff_detail_screen.dart` — render-gate hides
  "Change role" button when `isTargetOwner` (target's `authUserId` matches
  `business.ownerId`); outer action section guard updated to avoid orphan
  spacer; `_changeRole` re-checks the owner condition at the write boundary and
  shows error "You cannot change the owner's role." on bypass.
- `lib/core/database/app_database.g.dart` — regenerated via `build_runner`.

**Verification:** `flutter analyze` on all three source files → No errors.
The `ownerId` field appears in `BusinessData`, `BusinessesCompanion`, and the
`$BusinessesTable` column list in the generated file.

**Sync notes:** `owner_id` is already in `_pushableColumns['businesses']` and
`_restoreTableData` uses `BusinessData.fromJson(r)` for cloud pulls — the new
column is picked up automatically on the next pull for existing businesses.
Existing local rows get `ownerId = null` after migration and are backfilled from
the cloud on the next sync.
