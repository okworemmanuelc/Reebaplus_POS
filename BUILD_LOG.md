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

> **On-device verification (2026-05-30):** the features built through Session 26 —
> POS (§12), Cart (§13), Inventory + Product Details (§16), and Funds Register Phase 1
> (§23) — have been verified on-device by the user, clearing the standing emulator-pass
> backlog noted across Sessions 19–26. Two-device realtime sync also confirmed
> (Session 27). The per-session "on-device pass pending" notes below are superseded.

**Foundation:**
- [x] Database schema rebuild (section 2 of master plan) *(done in Session 2 — schema v13)*
- [x] Role + permission seeding for new businesses *(done in Session 2)*

**Auth flow:**
- [x] Welcome screen (section 4) *(done in Session 6)*
- [x] CEO Sign Up flow (section 5) *(done in Session 7 — new-email path; §5.2 existing-email branch deferred)*
- [x] Staff Sign Up flow (section 6) *(done in Session 10)*
- [x] Login flow + Forgot PIN (section 7) *(done in Session 8 — §7.1–7.4; §5.2/§7.2 multi-business confirm-PIN deferred to Phase 2)*
- [x] Who Is Working picker (section 8) *(done in Session 11 — §8.1–8.5; "active now" dot deferred)*

**Core screens:**
- [x] Staff Management (section 9) *(done in Session 10)*
- [x] CEO Settings (section 10) *(§10.1 menu + Business Info / Stores / Security / Activity Logs access done in Session 14; §10.2 Roles & Permissions done in Session 15; Appearance added to §10.1 in Session 17; §10.3 is Phase 2)*
- [x] Home / Dashboard (section 11) *(role-aware cards, subtitle, store lock, Total SKUs — commit 8307314)*
- [x] Point of Sale (section 12) *(role guards — Session 19)*
- [x] Cart + Edit Quantity modal (section 13) *(discount + role caps, fractional toggle, per-cashier saved carts, Undo — Session 20)*
- [x] Checkout (section 14) *(two-step payment + receiving account done with Funds Register Session 26; "Add wallet info to receipt" checkbox added Session 30 — §14 now complete)*
- [~] Receipt (section 15) *(QR code removed — §15.3 / hard rule #8 — and §15.1 wallet-info display wired in Session 30; full §15 pass (refund button, Completed-tab specifics) still pending)*
- [ ] Inventory + Product Details (section 16)
- [~] Daily Stock Count (section 17) *(Session 58: count persistence + shortages snapshot, Record Damages form, store-name header, CEO/Manager notifications, Cashier blocked. Open: the Ring 3 Daily Reconciliation Report that consumes this data; on-device pass)*
- [~] Customers + Customer Profile (section 18) *(Session 31: soft-delete, Crates-tab gate, required phone, customers.set_debt_limit permission. Open: Edit flow, GPS capture, Add-Funds payment method)*
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
- [~] Rename pass: Warehouse → Store *(done in Session 3)*, Dashboard → Home *(done with §11)*; Cash Register → Funds Register pending (section 23)
- [ ] Loading animations replaced with fade-ins
- [ ] All UUIDs replaced with short codes in user-facing text

Mark each item with `[x]` as it's completed. Add notes under any item if needed.

---

## Session entries

(New entries go below this line. Most recent at the top.)

---

## Session 73 — 2026-06-04 — Cart: "Select Customer" picker rebuilt as a smooth fixed-height sheet

**What the user asked for:**
- In the cart, the pick-customer modal closed too easily when scrolling and opened too small; then, after a first pass, the scrolling / height-resize / disappearance still felt glitchy. Make it smooth.

**Built today:**
- Root cause of both the dismiss-on-scroll and the jank: the picker (`_showChangeCustomerModal`) stacked three drag mechanisms — `showModalBottomSheet`'s own drag-to-dismiss, an inner `DraggableScrollableSheet` (with 75%↔95% snap), and a tap-to-dismiss barrier. Scrolling had to hand off to "expand the sheet" before the list actually moved, and the snap jumped — that's the glitchy feel.
- Fix: removed the `DraggableScrollableSheet` and the custom `GestureDetector` barrier entirely. The sheet is now a plain **fixed-height** `showModalBottomSheet` — `SizedBox(height: 85% of screen)` + a normal `Column` with the grip / header / store filter / search / `ListView`. Gave the sheet a real `backgroundColor` + rounded `shape` so its native open/close animation shows; kept `enableDrag: false` so a downward scroll never doubles as drag-to-dismiss. Closing is the native barrier (tap-outside → smooth slide-down) or the X. The list is a plain `ListView` (no shared scroll controller), so scrolling is clean.

**Files touched:**
- `lib/features/pos/screens/cart_screen.dart`

**Database changes:**
- None.

**Status:** `flutter analyze` clean on the file. On-device confirmation pending (scroll should be smooth, no accidental dismiss, opens at ~85%, closes with a clean slide-down).

**Known issues / left open:**
- The two sibling sheets in the same file (`_viewSavedCarts`, `_showEditCrateDeposit`) still use the `DraggableScrollableSheet` + default-drag pattern and may feel the same way. Not touched this session — apply the same fixed-height treatment if they misbehave.

---

## Session 72 — 2026-06-03 — Permissions/nav cleanup + stock-adjustment notifications

**What the user asked for:**
- Remove the "Give a discount" toggle (the per-role discount slider already governs it).
- Hide POS and Cart from the bottom nav for a stock keeper (any role without the sales permission).
- Rename permission labels: "Edit product buying price" → "View buying price", "Edit product prices" → "Edit product", "View stock levels" → "View Inventory".
- Notify the CEO and managers whenever a stock keeper adds or removes stock (with the reason on a removal).

**Built today:**
- The "Give a discount on a sale" toggle no longer shows in Roles & Permissions; the per-role Max discount % slider remains the single control (0% = no discount). The role-card "X of N permissions" count now ignores the hidden key. The underlying permission key stays in the catalogue, unenforced.
- POS and Cart tabs now disappear from the bottom nav for any role lacking the "Make a sale" permission (the stock keeper by default), instead of showing but being blocked at the screen. CEO/Manager/Cashier are unchanged.
- Three permission labels renamed (display text only — what each permission controls is unchanged).
- When a stock keeper adds or removes stock from the Update Stock screen, the CEO and all managers now get an in-app notification (blue for an add, yellow for a removal, with the reason). A manager/CEO adjusting stock themselves does not trigger it.
- Moved the Max discount % slider out of the bottom "Role limits" section up into the Sales section at the top of the role's settings (it's the sole discount control now). Max expense approval stays in Role limits.
- Moved the Manager-only "Stores" settings section (Allow viewing other stores) to the very top of the role settings screen — it's now first on the list. Everything else keeps its order.
- Pulled the `Stores`-category permission group ("Add, edit, and remove stores") out of the generic bottom-of-list rendering and into that same top Stores section, directly below the "Allow viewing other stores" toggle, so the two store settings sit together. Extracted a shared `_permissionGroupCard` helper to render category toggle cards in both the Stores section and the main loop (no behaviour change to the toggles themselves).
- Moved the Max expense approval input out of the bottom "Role limits" section up into the Expenses section (parallels the discount-to-Sales move). The "Role limits" section is now empty and removed.

**Files touched:**
- lib/core/settings/role_permissions_detail_screen.dart
- lib/core/settings/roles_permissions_screen.dart
- lib/core/permissions/permission_dependencies.dart
- lib/shared/widgets/main_layout.dart
- lib/core/database/app_database.dart
- lib/features/inventory/screens/product_detail_screen.dart
- supabase/migrations/0087_rename_permission_labels.sql (new)
- reebaplus_master_plan.md (§10.2, §12, §16.7, §26.4)

**Database changes:**
- Local schema bumped to v32: a migration updates the three permission labels in the local `permissions` catalogue (existing devices get the new labels; the catalogue is seeded once and not re-synced).
- Cloud migration 0087 updates the same three labels in the cloud `permissions` catalogue. Pushed to remote.

**Master plan sections covered:**
- §10.2 — Roles & Permissions (give-discount toggle now hidden, governed by the slider).
- §12 — POS/Cart gated on the sales permission, hidden in nav when absent.
- §16.7 — permission label wording (View Inventory / Edit product / View buying price).
- §26.4 — new "stock keeper added/removed stock" notification to CEO + Manager.

**Plan updates made during session:**
- §10.2: noted the give-discount toggle is hidden (the Max discount % limit governs discounts).
- §12: noted POS + Cart are hidden in the bottom nav for any role without the sales permission.
- §16.7: "See buying price" reworded to "View buying price" to match the new label.
- §26.4: added the stock-keeper add/remove notification (info for add, warning for removal, with reason; fires to CEO + Manager).

**Tested:**
- `flutter analyze` on all six touched Dart files — no issues.
- Cloud migration 0087 applied successfully via `supabase db push`.
- On-device emulator verification of the four behaviours still to be run by the user (no APK build per workflow).

**Known issues / left open:**
- None.

**Next session should:**
- On the emulator, confirm: no give-discount toggle (slider still works); stock keeper has no POS/Cart tabs; the three renamed labels show on an upgraded install; a stock-keeper add/remove notifies a CEO/manager account.

---

## Session 71 — 2026-06-03 — Checkout: price-change guard fix + Pay-from-Wallet default

**What the user asked for:**
- Review the price-change guard for when goods prices change mid-sale (and other events not accounted for during checkout).
- Make the checkout payment default to "Pay from Wallet".

**Built today:**
- Price-change guard fix. The guard (`_detectCartStaleness` → "Prices changed" dialog) correctly catches a product whose price/version changed since it was added to the cart. But on "Accept new prices" it updated the cart provider and then told the cashier to "confirm again" while staying on the checkout page — and that page's totals are an immutable snapshot taken when it opened (`widget.cart` / `widget.total`). `acceptStaleness` rebuilds the cart with fresh map instances, so this page never saw the new prices and re-confirming would re-flag the same lines forever (stuck loop). Now, after accepting, it flashes "Prices updated. Review the cart and check out again." and pops back to the cart, whose totals are live — the cashier reviews the new prices and checks out again cleanly.
- Pay-from-Wallet default. On opening Checkout, a registered customer now defaults to the "Pay from Wallet" sub-option (set in `initState` via `_isWalletPayment = !_isWalkIn`). Walk-ins stay on Cash / Card (no wallet, hard rule 14). If the customer has no wallet credit, the existing "no credit available" hint still shows and the cashier switches to Cash / Card — the default is just the starting selection.

**Audit notes (events checked, no change needed):**
- Stock running out mid-sale: handled server-side. When online, `flushSale` surfaces `insufficient_stock` from the cloud RPC, `_compensateRejectedSale` reverses the local writes, and the checkout catch flashes "Checkout failed: …". Offline, the sale posts optimistically and reconciles on the next push (offline-first by design).
- Product deleted mid-sale: `checkCartStaleness` skips a soft-deleted/missing product (the row still resolves for the FK), so the sale completes against the cart snapshot. Left as-is — selling the last of a just-discontinued line is acceptable under the offline model; not in scope to change.

**Files touched:**
- `lib/features/pos/screens/checkout_page.dart`
- `reebaplus_master_plan.md` (§14.2 — Pay-from-Wallet default note)

**Database changes:**
- None.

**Plan updates made during session:**
- §14.2 — added the "Default selection (2026-06-03, user)" note: registered customers default to Pay from Wallet, walk-ins to Cash / Card.

**Status:** `flutter analyze` clean on the file. On-device confirmation pending.

---

## Session 70 — 2026-06-03 — Checkout: no more silent action failures

**What the user asked for:**
- When an action on the checkout page fails, flash the appropriate error message instead of doing nothing silently.

**Built today:**
- Wrapped the cart-staleness pre-flight in `_confirmPayment`: it runs before the main try block, so a thrown DB error there used to kill the Confirm button with no feedback. It now flashes "Could not verify cart prices: …" and aborts cleanly.
- Wrapped the printer-picker's `onSelected` connect/print path (`_showPrinterPicker`): `connect()` / `printBytesDirectly()` throwing previously went unhandled and silent. It now flashes "Print error: …".
- Verified the rest of the page already surfaces failures (the main checkout catch, Print, Share, and every validation `return` flash). The only untouched `catch` is the cosmetic item-colour parse fallback, which is intentional.

**Files touched:**
- `lib/features/pos/screens/checkout_page.dart`

**Database changes:**
- None.

**Status:** `flutter analyze` clean on the file. On-device confirmation pending.

---

## Session 69 — 2026-06-03 — Apply-credit: leave the outstanding unticked → book it as debt

**What the user asked for:**
- In the apply-credit checkout flow (Pay from Wallet where the credit only partly covers the order), when the "Outstanding paid" box is left unticked, don't block — instead register the outstanding as debt on the customer's wallet (credit they owe the business), as long as it stays within their debt limit. It must sync live.

**Built today:**
- The "Outstanding paid" checkbox is now optional. Ticked → the shortfall is collected as cash into the chosen Funds account (unchanged). Unticked → the full total debits the wallet (sub-type 'wallet', nothing paid now), so the wallet goes negative by the outstanding — that's the new debt. It posts through the wallet ledger and syncs live like any credit/wallet sale.
- Gated the debt path on the debt limit: if the resulting debt would breach the customer's limit (or they have no limit set), checkout is blocked with a message telling the cashier to tick the box and collect the cash instead. Reuses the live debt-limit value from Session 67.
- UI: the apply-credit breakdown now reflects the unticked state — "Wallet after sale" shows the negative balance, the outstanding row reads "Outstanding (added as debt)", and a hint explains that leaving the box unticked adds the amount to the customer's debt. The receiving-account picker now only appears when the box is ticked (no cash is collected otherwise).

**Files touched:**
- `lib/features/pos/screens/checkout_page.dart`
- `reebaplus_master_plan.md` (§14.2 — documented the "leave unticked → debt" option)

**Database changes:**
- None.

**Plan updates made during session:**
- §14.2 apply-credit note updated: the "Outstanding paid" checkbox is optional; unticked books the outstanding as wallet debt within the debt limit.

**Status:** `flutter analyze` clean on the file; order money-math + checkout tests pass. On-device confirmation pending.

---

## Session 68 — 2026-06-03 — Fix: Print Receipt did nothing (silently blocked by a location-permission gate)

**What the user reported:**
- Tapping **Print Receipt** on any device, for any user, did nothing — no "Preparing receipt…" message and no printer-picker popup. Same on the checkout receipt screen and on reprint from the Orders screen and a customer's orders.

**Root cause:**
- All three print paths call `PrinterService.requestPermissions()` as the first gate. It required **bluetoothScan + bluetoothConnect + location** to *all* be granted (`.every(isGranted)`). A POS app asking for **location** is unusual, so staff routinely deny it — and location isn't needed at all, because we connect to *already-paired* printers (we read the OS bonded list, we never run a classic Bluetooth scan). The moment location was denied, the method returned `false` and the whole flow stopped before "Preparing receipt…" and before the picker.
- Secondary gap vs. the intended behaviour: checkout and Orders only checked `isConnected` then `printBytesDirectly`. They never called `autoConnect()`, so a previously-paired printer was never reused unless it happened to still be live — it should auto-connect to the last-used printer first.

**Built today:**
- `requestPermissions()` now requests only `bluetoothConnect` + `bluetoothScan` (no location) and returns success based on `bluetoothConnect` (the one actually needed to connect/print on Android 12+). Wrapped in try/catch with logging so a failure surfaces instead of silently killing the flow.
- Checkout and Orders now call `printBytes()` (reuse live connection → else auto-connect to the saved/last-used printer → print). Only when that fails do they pull up the picker — matching "auto-print to the paired printer, fall back to the picker."
- `PrinterPicker` now ensures Bluetooth permission before reading the bonded list (so device names are accurate on Android 12+) and no longer spins forever if the adapter read throws (e.g. no Bluetooth hardware) — it falls through to the empty state.
- `AndroidManifest.xml`: capped legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` + location at `maxSdkVersion=30`, flagged `BLUETOOTH_SCAN` `neverForLocation`. Printing no longer depends on location at the manifest level either.

**Files touched:**
- `lib/shared/services/printer_service.dart`
- `lib/features/pos/screens/checkout_page.dart` (print path only — the Session 67 debt-limit change is separate)
- `lib/features/orders/screens/orders_screen.dart`
- `lib/shared/widgets/printer_picker.dart`
- `android/app/src/main/AndroidManifest.xml`

**Database changes:**
- None.

**Status:** `flutter analyze` clean on all touched Dart files. On-device confirmation pending — needs a real device with a paired thermal printer (the emulator has no Bluetooth, so the picker will show "No paired printers found" there, which is expected).

---

## Session 67 — 2026-06-03 — Fix: checkout used a stale debt limit (couldn't complete a sale after raising the limit)

**What the user reported:**
- After increasing a customer's debt limit, checkout still failed for a customer whose debt was NOT above the new limit — when there was an outstanding amount left on the account (a partial / credit sale).

**Root cause:**
- In `checkout_page.dart`, the debt-limit check compared a **live** wallet balance against a **stale** debt limit. The balance came from the live ledger (`walletBalancesKoboProvider`), but the limit was read from `_initialCustomer.walletLimitKobo` — a snapshot of the Customer object captured when the page (and the cart's active customer) was set up. Raising the limit afterward updated the database but never that snapshot, so the check kept using the old, lower limit and wrongly blocked the sale with "exceeds debt limit".

**Built today:**
- Added a `_currentCustomerWalletLimitKobo` getter that reads the customer's current debt limit live from `customerServiceProvider` (kept in sync via `watchAllCustomers()`), falling back to the `_initialCustomer` snapshot if the customer isn't in the live list yet. The debt-limit validation now uses it, so the limit and the balance are both read live and stay consistent.

**Files touched:**
- `lib/features/pos/screens/checkout_page.dart`

**Database changes:**
- None.

**Status:** `flutter analyze lib/features/pos/screens/checkout_page.dart` clean. On-device confirmation pending.

---

## Session 66 — 2026-06-03 — Removed the top SyncBanner

**What the user asked for:**
- Initially: when sync runs/finishes, the top banner ("Syncing your store…" / "Caught up.") should overlay the screen instead of pushing it down. Then: remove that top banner entirely — there's already a green sync banner at the bottom.

**Built today:**
- Deleted `lib/shared/widgets/sync_banner.dart` (the top `SyncBanner` widget) and removed it from `MainLayout`. `MainLayout`'s body is now just the tab `Stack` — no more `Column(SyncBanner, Expanded(...))`, so nothing shifts the screen for sync state. Dropped the now-unused `sync_banner.dart` import.
- Generalized a stale comment in `staff_management_screen.dart` that named the "always-mounted SyncBanner" as the `pullStatusProvider` watcher; the post-frame deferral reasoning stays.
- `pullStatusProvider` is left in place (unwatched now) — it's still written by `pullChanges`; not part of this change.

**Status:** `flutter analyze` clean (remaining 18 issues are pre-existing `avoid_print` infos in `test/database/roles_v13_report.dart`). On-device confirmation pending.

---

## Session 65 — 2026-06-03 — Roles & Permissions: dependency gating (§10.2)

**What the user asked for:**
- Some permissions are gated by others. When a permission that relies on another is toggled on/off, the rest should respond — e.g. when "Make a sale" is off, "Give a discount" should be off; when Inventory (stock view) is off, adding/updating stock is off. Make this 100% accurate and properly gated.

**How the dependency map was decided (not invented):**
- Ran a read-only multi-agent workflow (one analyzer per permission category + an adversarial verifier) to derive dependencies from how each permission *actually* gates the app — a true dependency = the child screen/button is unreachable, or the action is meaningless, without the parent.
- Confirmed each link against the seeded default roles so no default grant is a child without its parent. This caught a conflict: the user-picked `reports.see_cost_prices → reports.see_profit` clashes with the Manager default (Manager is granted cost-prices *without* profit by design), so that one link was dropped after checking with the user.
- A notable finding: `sales.discount.give` is defined but never enforced anywhere — discounts are gated only by each role's `max_discount_percent` setting. By the user's call it's still included in the dependency map now; actually wiring the permission to gate the discount UI is a deferred follow-up (see Known issues).

**Built today:**
- New single-source-of-truth dependency map (child → parent) with transitive `descendantsOf` / `ancestorsOf` / `parentOf` helpers.
- In the CEO's Roles & Permissions detail screen: revoking a parent now cascade-revokes every currently-granted dependent (each enqueues its own sync delete; one activity-log entry records the cascade). A dependent's toggle is disabled with a `Requires "<parent>"` hint while its parent is off, so it can't be granted alone. CEO stays locked all-on.

**The 18 dependency links:**
- `sales.make` ← `sales.discount.give`, `sales.cancel`
- `stock.view` (the Inventory gate) ← `products.add`, `products.edit_price`, `products.edit_buying_price`, `products.delete`, `stock.add`, `stock.adjust`
- `customers.add` (the Customers gate) ← `customers.update`, `customers.delete`, `customers.wallet.update`, `customers.set_debt_limit`, `customers.wallet.totals.view`
- `staff.invite` ← `staff.suspend`, `staff.change_role`
- `suppliers.manage` ← `shipments.manage`
- `funds.view` ← `funds.open_day`, `funds.close_day`

**Follow-up in same session:** the user asked that disabling `customers.add` disable every other customer permission. Added the 5 `customers.* → customers.add` links above (checked safe against the seeded defaults — Manager/Cashier/CEO all hold `customers.add` alongside their customer children). `customers.update` is, like `sales.discount.give`, a defined-but-unenforced permission — the config gating still works. +2 tests (customer cascade + customer lock); suite now 14.

**Files touched:**
- lib/core/permissions/permission_dependencies.dart (new)
- lib/core/settings/role_permissions_detail_screen.dart
- test/settings/role_permissions_detail_test.dart

**Database changes:**
- None. Pure Dart/UI; no schema, migration, or new package. Revokes use the existing `RolePermissionsDao.revoke` path, so the §5 sync contract is unchanged.

**Master plan sections covered:**
- §10.2 — Roles & Permissions sub-page (per-role permission toggles).

**Plan updates made during session:**
- None. The master plan doesn't specify a dependency map; this is config-screen gating layered on the existing toggles, no behavioural change to seeded roles.

**Tested:**
- `flutter analyze` clean on the three touched files.
- 12 tests in role_permissions_detail_test (3 new): parent revoke cascades to granted dependents and enqueues their deletes; a child toggle is disabled with the "Requires" hint while its parent is off; the child is interactive once the parent is on. Full settings + role suites green (42 tests).

**Known issues / left open:**
- `sales.discount.give` is still unenforced at runtime (discounts gated only by `max_discount_percent`). The dependency is in the map but cascading it is cosmetic until the permission is wired into the discount UI — a deferred follow-up the user chose.
- Runtime "effective permission" resolution (auto-dropping a child whose parent isn't held) was deliberately NOT added — it would silently break legitimately-seeded grants (e.g. Manager cost-prices). Gating stays at the config screen; structural deps make runtime resolution moot anyway.
- On-device pass pending.

**Next session should:**
- Optionally wire `sales.discount.give` enforcement into the discount UI (alongside `max_discount_percent`), if the user wants that toggle to do something at runtime.

---

## Session 64 — 2026-06-03 — Business details: name/currency propagation, sync RLS fix, editable setup info

**What the user reported:**
1. Changing the business name in Settings doesn't show on receipts (and "verify currency too") — and should reflect on the onboarding welcome screen and everywhere the name appears.
2. The CEO should be able to edit all the setup/onboarding info (store address, phone) and their own CEO details.
3. A Sync Issues screenshot: `businesses:upsert` rejected with `42501` (RLS), 24 attempts — the rename never reaches the cloud.

**Root causes found:**
- **Sync (the real blocker).** Business edits push as a PostgREST `.upsert()` = `INSERT ... ON CONFLICT DO UPDATE`. Postgres checks the **INSERT** policy's `WITH CHECK` on the candidate row even when the row already exists. The cloud `businesses_insert` policy (0004) requires `onboarding_complete = false` AND `owner_id = auth.uid()` — but an established business pushes `onboarding_complete = true`, and the local `businesses` table has no `owner_id` column so it's never pushed (candidate is NULL). Either way → 42501, retried forever. Migration 0062 (Session 32) only widened the UPDATE branch; its header wrongly assumed the INSERT branch is never evaluated for an edit.
- **Receipts hardcoded the name.** Both the on-screen receipt and the thermal builder printed `'Coldcrate Ltd'` / `'Wholesale Drinks & POS'`, ignoring the real business.
- **Currency was hardcoded to ₦** everywhere — `formatCurrency()` ignored the saved `default_currency`; the Business Info dropdown wrote the setting but nothing read it.
- **Stores + CEO profile were read-only.** No edit path existed; the POS header even showed the app name instead of the business name (§12.1).

**Built today:**
- **Cloud migration 0086** (`0086_businesses_insert_edit_upsert_fix.sql`) — relaxes `businesses_insert` to `WITH CHECK (owner_id = auth.uid() OR id = public.business_id())`, mirroring the 0062 UPDATE policy, so an owner editing their active business passes. **Deployed 2026-06-03.** The push was first blocked because the remote had 0076–0085 applied (parallel work the user deployed then lost in a `git reset --hard`; files unrecoverable — 0076–0080 partially survive in dangling commit `cd1ec9d` with a duplicate-0080, 0081–0085 gone). Reconciled with `supabase migration repair --status reverted 0076..0085` (untracks them on remote — does NOT drop their schema; the supplier-accounts / stores-address / stock-transfer tables stay live but untracked-by-migrations), then `supabase db push` applied 0086. Confirmed `0086 | 0086 | 0086` in `migration list`.
- **App-wide currency.** New `kCurrencySymbols` map + `currencySymbolForCode()` (currencies.dart); a global `activeCurrencySymbol` + currency-aware `formatCurrency()` (number_format.dart); `currencyCodeProvider` / `currencySymbolProvider` (stream_providers.dart); the app root (`main.dart`) watches the synced currency and updates the global, so every money display (29 `formatCurrency` call sites + both receipts) follows the CEO-chosen currency live. Hardcoded `₦` labels/prefixes/strings across 12 files swapped to the dynamic symbol.
  - **Follow-up (symbol-only):** the user reported Home cards showed `"NGN (₦)197,640"`. Cause: older onboarding stored `default_currency` as the **label** `"NGN (₦)"` (not the ISO code `"NGN"`); the old hardcoded formatter ignored the setting, so it surfaced only once `formatCurrency` started reading it. Fix: `currencySymbolForCode` now returns **only the glyph**, tolerant of label-style values via a new `normalizeCurrencyCode()` (extracts the embedded ISO code → `"NGN (₦)"` → `"NGN"` → `₦`). Business Info `_load` normalises too, so the picker shows a clean code and saving repairs the stored value. `test/currency_format_test.dart` (8 tests) guards it.
  - **Follow-up (live reactivity):** the user reported a currency change didn't update other users live. Root cause was NOT sync (the `settings` row pushes — it carries `business_id` so RLS passes — is in the realtime publication, and the restore fires the local watch) but **reactivity**: each tab lives behind its own nested `TabNavigator` (MainLayout), so a preserved route never re-ran `formatCurrency` when the global symbol changed. Fix: every money-displaying SCREEN (21 of them) now `ref.watch(currencySymbolProvider)` at the top of `build`, so they rebuild the instant currency changes — same-device and cross-device. Two non-Consumer detail screens (supplier_detail, sales_detail) were converted to `ConsumerStatefulWidget`.
- **Settings-save flashes (user request).** Added success/error toasts to the CEO Settings sub-pages that saved silently: Appearance ("Appearance updated."), Security auto-lock ("Auto-lock updated."), Activity-Logs-access + Sync-Issues-access toggles ("Access updated."). Business Info and Stores already flashed. Drained the new toast's auto-dismiss timer in the 3 affected widget tests (appearance + activity-logs toggle) — full suite back to green (323 pass).
- **Business name on receipts + POS header.** `ReceiptWidget` and `ThermalReceiptService.buildReceipt` gained a `businessName` param; the 3 call sites (checkout, customer-detail, orders) pass it from a new live `currentBusinessProvider` / `currentBusinessNameProvider`. POS header (§12.1) and the staff onboarding "Welcome to {business}" now read the live name too.
- **Editable setup info.** Business Info gains a **Phone** field (`BusinessesDao.updateInfo` + cloud). New enqueuing DAO writes `StoresDao.updateStore` (name/address) and `StoresDao.updateUserProfile` (name/avatar), plus `AuthService.refreshCurrentUser()`. Stores settings + the profile screen made editable (CEO/own-profile). Email editing deliberately deferred (login identity → needs OTP).

**Database changes:**
- One new cloud migration (0086) — RLS only, no schema change. Pending deploy (see above). No local Drift schema/version bump (used existing columns: `businesses.phone`, `stores.location`, `users.name`/`avatarColor`).

**Master plan updates:**
- §10.1 — Business Info gains phone; currency made real + receipt/header name noted. Stores: editing the existing store's name/address is Phase 1.
- §27.1 — profile edit (own name + avatar) note added; email edit out of scope.

**Tested:**
- `flutter analyze lib` → clean (whole tree). Full suite `flutter test` → **315 passing**. Receipt widget tests still green (wallet-info gate + QR-removal). Editable Stores/Profile screens reviewed against the diff (permission-gated, enqueue via the new DAOs, `deviceBottomInset` correct). Emulator walk-through to confirm the queued rename flushes is the one manual step left.

**Known issues / left open:**
- The cloud retains the orphaned 0076–0085 schema (supplier accounts, stores address columns, stock-transfer RPCs, renamed permission labels) now untracked-by-migrations after the repair-reverted reconciliation. Harmless to this app (it never references those tables), but a fresh `db reset`/rebuild won't reproduce them — re-baseline with `supabase db pull` if that matters. **Note 0077 added cloud `stores` address columns**; this app still writes the single fused `stores.location` — verify the cloud columns are nullable/defaulted so store upserts don't 23502 (not observed, but flagged).
- Avatar colour does not propagate cross-device (existing per-device pull behaviour, unchanged).
- After deploy, the stuck `businesses:upsert` flushes on its next retry (or tap **Retry now** in Sync Issues).

---

## Session 63 — 2026-06-02 — Daily Reconciliation Report (§25.2 / §25.9, Ring 3)

The last big §25 report. The Reports hub now has 6 cards.

**Plan change (user) — §25.9 drill-down model:** §25.9 was written for Day / Week /
Month / Year period cards, but §30.11 (same date) had already replaced those chips
with rolling windows and made the daily reconciliation calendar-bound. **User chose:
one card per calendar day within the selected rolling window** (no span aggregation).
Updated §25.9 to match, with a dated note.

**Built today:**
- **Daily Reconciliation card** on the Reports hub (CEO + Manager, §25.3) → a
  **day-card list** (`daily_reconciliation_list_screen.dart`). The rolling period
  chip picks the span; the screen lists one card per **calendar day** in it that has
  a Close Day and/or a saved stock count. Each card headlines items-sold + net cash
  variance and flags a **Mismatch** when that day had a cash shortage or a stock
  shortage. CSV export of the day summary. Tapping → that day's detail.
- **Per-day detail** (`daily_reconciliation_detail_screen.dart`) — the full §25.2
  roll-up for one business date: **sales summary** (items sold, SKUs, total sales,
  best staff, top item), **Close Day cash audit** per account (expected / counted /
  variance, shortage flagged), **stock audit** (products counted, short / surplus +
  itemised shortages), **outstanding customer debt** and **approved expenses
  recorded that day**, and **empty-crate holdings** (Bar / Beer Distributor only).
  CSV export. Read-only.
- **Two new providers** (`stream_providers.dart`): `businessTimezoneProvider` (to
  bucket order / expense timestamps into the business calendar day) and
  `emptyCratesByManufacturerProvider`. No new DAO methods — sales/expenses/debts are
  summarised from existing providers (`allOrdersProvider`, `allExpensesProvider`
  approved-only, `walletBalancesKoboProvider`), matching the spec's "summary, not a
  duplicate".

**Bug found & fixed during review (audit-accuracy).** A Save Count inserts a fresh
session row, so re-counting a store the same day yields several rows for one
(store, date). The first cut **summed** the stock figures across all sessions →
double-counted products-counted / short / surplus and listed shortages twice. Fixed:
both screens now collapse to the **latest session per store** (newest createdAt)
before rolling up — genuinely distinct stores still aggregate, a re-save replaces
rather than doubles. Re-verified PASS.

**Files touched:**
- lib/features/dashboard/screens/daily_reconciliation_list_screen.dart (new)
- lib/features/dashboard/screens/daily_reconciliation_detail_screen.dart (new)
- lib/features/dashboard/screens/reports_hub_screen.dart (Daily Reconciliation card)
- lib/core/providers/stream_providers.dart (businessTimezone + emptyCrates providers)
- reebaplus_master_plan.md (§25.9 rolling-window reconciliation)

**Master plan sections covered:** §25.2 (Daily Reconciliation content), §25.9
(per-day drill-down, reconciled to rolling windows), §25.6/§25.7 (period + CSV),
§25.8 (empty state).

**Tested:** `flutter analyze` clean on all touched files (project-wide only the
pre-existing `avoid_print` infos remain). CSV tests pass. The feature was reviewed by
an adversarial multi-agent pass (caught the double-count above) and re-verified after
the fix. On-device pass pending.

**Known issues / left open:**
- Per-store report scoping / multi-store breakdown is **Phase 2** (master plan §2);
  the detail aggregates a day across stores (correct for one-store Phase 1).
- Empty crates + outstanding debt are **current** point-in-time figures (not
  day-scoped) — they summarise the live subsystems per §25.2.
- **Supplier Accounts Report** is the only §25.2 card still unbuilt — blocked on the
  Ring 1 supplier subsystem (in-memory stub). **Expense Tracker** CSV still pending
  (routes to the §20 feature screen).

---

## Session 62 — 2026-06-02 — Daily Stock Count: role-based store visibility (CEO all-stores filter) (§17)

Follow-up to Session 58. The user asked for stock counts to stay **per store**, but with a CEO **"All stores" filter** while roles below CEO are confined to their **own assigned store**.

**Built today (all in [stock_count_screen.dart](lib/features/inventory/screens/stock_count_screen.dart)):**
- **Role-based store scope.** Reused the app's existing "view all stores" rule verbatim — `isCeo || (isManager && managerCanViewAllStoresProvider)` — so Stock Count doesn't invent a second, conflicting definition. CEO (and a Manager the CEO granted) may view every store; everyone else is scoped to their `user_stores` assignments (falling back to their primary `users.storeId`).
- **"All stores" overview (read-only).** When an all-stores viewer opens unscoped, the Store picker gains an **All stores** option (the default) that lists every store's stock — product, store, quantity — with **no Actual input, no Save Count, no Record Damages**. Counting is per store, so the CEO picks a store from the picker to actually take a count. A small hint banner says so.
- **Roles below CEO see only their store.** The picker shows only their assigned store(s) (no "All" option); a single assigned store means no picker at all. The Count **History** is now filtered to their store(s) too — a Stock keeper no longer sees other stores' counts.
- **Scope resolves after the role does.** Moved `_init()` out of `initState` and behind a `build()` gate that only fires once the role provider is non-null, so a CEO is never briefly mis-scoped to "no store" on first open.
- A non-all-stores viewer with a null scope (no assigned store) now loads **nothing** instead of every store's products (closes a would-be cross-store leak), and shows a "No store assigned to you" empty state.

**Plan:** §17.1 updated with the role-based store-visibility rule (read-only All-stores overview; sub-CEO roles confined to their store for both counting and History).

**Verify:** `flutter analyze` clean; full suite **315 passed**. Not yet walked on-device.

---

## Session 61 — 2026-06-02 — Reports: CSV export on Sales/Funds + remove Stock Audit report (§25)

Phase B finishing touches on the §25 Reports hub.

**Built today:**
- **CSV export (§25.7) wired into the Sales Report and the Funds Register Report.**
  Each report-detail screen now has an "Export CSV" button in its app bar
  (disabled when there's no data) using the shared `csv_export.dart` helper. Sales
  CSV columns mirror the on-screen table (Profit column only in profit mode). Funds
  CSV is one row per closed day/account: Date, Store, Account, Expected, Counted,
  Variance. With Profit and Customer Ledger (built earlier), all remaining report
  detail screens now export CSV.

**Plan change (user request) — Stock Audit report removed:**
- The user asked to remove the **Stock Audit** report entirely. Deleted the hub
  card and the whole `stock_audit_screen.dart`. Updated `reebaplus_master_plan.md`:
  removed the §25.2 list item, the §25.3 matrix row, and the §30.11 scope mention,
  with a dated removal note. Stock health stays visible in **Inventory**, and the
  **stock-reconciliation summary** still lives inside the Daily Reconciliation
  Report (§25.2/§25.9) — only the standalone report is gone. Verified nothing else
  referenced `StockAuditScreen` before deleting.
- The Reports hub is now 5 cards: Sales, Expense Tracker, Customer Ledger, Funds
  Register, Profit (CEO-only).

**Files touched:**
- lib/features/dashboard/screens/sales_detail_screen.dart (CSV export)
- lib/features/funds/screens/funds_register_report_screen.dart (CSV export)
- lib/features/dashboard/screens/reports_hub_screen.dart (remove Stock Audit card +
  import)
- lib/features/dashboard/screens/stock_audit_screen.dart (DELETED)
- reebaplus_master_plan.md (§25.2 / §25.3 / §30.11 Stock Audit removal + note)

**Master plan sections covered:** §25.7 (CSV), §25.2/§25.3/§30.11 (Stock Audit
removal).

**Tested:** `flutter analyze` clean on all touched files (project-wide only the
pre-existing `avoid_print` infos remain). No test referenced the deleted screen.
On-device pass pending.

**Known issues / left open:**
- **Expense Tracker** card still routes to the §20 Expenses *feature* screen (owned
  by Session 59), which has no CSV export yet — small follow-up there, not added to
  avoid touching that feature mid-flight.
- **Daily Reconciliation Report** (§25.9) is now buildable (Daily Stock Count
  landed in Session 58) — next big §25 item. **Supplier Accounts Report** still
  blocked on the Ring 1 supplier subsystem.

---

## Session 60 — 2026-06-02 — Reports hub: Phase A (cleanup + role-gating) + Profit Report (§25, Ring 3)

Continues the §25 planning in **Session 57** (which fixed the §11.3-vs-§25.3
plan conflict). This is the first implementation pass.

**Built today:**
- **Hub cleanup + role-gating (§25.2/§25.3).** Removed the **Pending Approvals**
  card the plan forbids (§25.2) — it opened a dead placeholder screen
  (`approvals_screen.dart`); real expense approvals live on the Expenses screen.
  Each remaining card is now **hidden, never greyed** (rule #7) for any role
  lacking it: Sales→`reports.see_sales`, Expense Tracker→`reports.see_expenses`,
  Stock Audit→`stock.view`, Funds Register→`funds.view`, Customer Ledger→role
  (no dedicated key), all under an `isManagerOrAbove` base so the hub stays
  CEO+Manager only (§11.3).
- **Profit Report (§25.2, CEO only) — new screen.** Revenue, cost of goods, gross
  profit, margin over the selected period (§30.11 chips), with a per-product
  breakdown sorted by profit and CSV export. Gated behind `reports.see_profit`
  (CEO-only by default seed). Profit per line uses the buying price snapshotted
  on the order line at sale time.
- **Customer Ledger Report (§25.2) — new screen.** Replaces the card that routed to
  the customers LIST. Live wallet balances across registered customers: headline
  Owed-to-you / Customer-credit / Debtors-count tiles, a Top-debtors section and an
  In-credit section, plus CSV export. Negative balance = owes, positive = credit;
  walk-ins excluded (rule #14). No period filter — balances are point-in-time, so
  the rolling §30.11 windows don't apply.
- **Shared CSV export helper** (`lib/core/utils/csv_export.dart`, §25.7 "CSV from
  day one") — RFC-4180 builder + share-sheet, reusing the existing
  `share_plus`+`path_provider` (no new dependency). Unit-tested.

**Bug found & fixed during review (money-math).** The first cut of the Profit
Report booked order lines whose captured buying price was **0** as **zero cost =
100% profit**, overstating gross profit/margin and diverging from the trusted
Net-Profit (home_screen) and Sales-breakdown screens, which treat a 0 buying
price as **unknown cost** and exclude it. A 0 cost is reachable in-spec (a product
created by a role without `products.edit_buying_price` persists 0). Fixed:
zero/negative-cost lines are excluded from the profit math everywhere (headline,
per-product, CSV), their quantity surfaced as a transparency note ("Profit
excludes N item(s) sold with no recorded buying price"); if every sold line is
uncosted, only the note shows (no misleading ₦0 headline). Revenue − COGS now
always equals Gross Profit.

**Files touched:**
- lib/features/dashboard/screens/reports_hub_screen.dart (remove forbidden card +
  dead import, role-gate all cards, add Profit card, route Customer Ledger to the
  new report)
- lib/features/dashboard/screens/profit_report_screen.dart (new)
- lib/features/dashboard/screens/customer_ledger_screen.dart (new)
- lib/core/utils/csv_export.dart (new)
- test/utils/csv_export_test.dart (new — 6 tests)

**Master plan sections covered:** §25.2 (Profit Report; Pending-Approvals removal),
§25.3 (role gating), §25.6 (detail-screen shape), §25.7 (CSV), §25.8 (empty state).

**Tested:** `flutter analyze` clean on all touched files (project-wide only the
pre-existing `avoid_print` infos in test/database/roles_v13_report.dart remain).
CSV helper unit tests pass (6/6). Profit math + gating reviewed by an adversarial
multi-agent pass (the zero-cost bug above was caught there) and re-verified after
the fix. On-device pass pending.

**Process note (no data lost, but flagged):** while undoing an over-eager
`dart format`, a `git checkout` discarded Session 56's **uncommitted** Funds
Register card in `reports_hub_screen.dart`; it was rebuilt verbatim from the
session-start read. The session-start git status is stale and the working tree
carries large uncommitted work (Sessions 56–60, migrations 0071–0073) — **commit
recommended.** See memory `feedback_never_git_checkout_uncommitted`.

**Known issues / left open (Phase B/C):**
- **Customer Ledger** report is now built. Per-store report scoping (§25.6 store
  filter, §25.3 Manager "Own store") is **Phase 2** (master plan §2: per-store
  reports ship in Phase 2) and absent from every report screen — a known deferral,
  not a Phase-1 gap.
- Wire CSV export into the other report detail screens (Sales/Stock Audit/Funds/
  Expenses) — Phase B.
- **Daily Reconciliation Report** (§25.9) is now **unblockable** — its dependency,
  Daily Stock Count, landed in **Session 58** (§17). Re-scope in Phase C.
- **Supplier Accounts Report** still blocked on the Ring 1 Supplier Accounts +
  Track Shipments subsystem (payment_service.dart is still an in-memory stub).

---

## Session 60 — 2026-06-02 — Expenses fixes: budget-bar crash, always-on budget, Add Expense as a screen (§20)

**Built today:**
- **Fixed the Expense Tracker crash (§20.1).** Opening Expense Tracker from
  Business Reports threw a layout error ("infinite width"). Cause: the **Set
  budget** button used the shared button's default full-width mode while sitting
  inline in a row, which has no width to fill. Told that one button to size to
  its label. No other button was affected (the rest sit in full-width slots or
  dialogs).
- **Budget bar is now always visible (§20.1).** It used to appear **only** when
  the period selector was on "Last 30 days". Since the budget is a **monthly**
  goal, the bar now shows on **every** period. Its Spent/pending figures always
  reflect the **last-30-days** window regardless of the selected period (which
  still filters the list and the "Total Expenses" headline). No misleading
  "2% of monthly budget" when you switch the list to "Today".
- **Add Expense opens as a full screen (§20.2).** The Record/Edit Expense form
  was a bottom-sheet modal; it's now a pushed **screen** with a normal app bar
  and back button. Same fields, same rules — only the presentation changed.
  Renamed `AddExpenseSheet` → `AddExpenseScreen` and moved it into `screens/`.
  Set `resizeToAvoidBottomInset: false` on it so the keyboard inset isn't
  double-counted (the footer already pads by `deviceBottomInset`, which includes
  the keyboard) — without it, focusing a field threw the Save button up the page.
- **Fixed "Set budget" not syncing to the cloud (§20.1, 42501).** Saving a
  monthly budget showed an RLS rejection in Sync Issues (`expense_budgets:upsert`,
  code 42501). Cause: migration 0073 created the `expense_budgets` cloud policy
  with the old inline `user_businesses` membership subquery — the same broken
  pattern 0071/0074 already had to rewrite (it returns empty when a user's
  `auth_user_id` has drifted, so the push is silently forbidden while reads still
  work). New migration **0075** redefines the policy to use the profiles-based
  `public.current_user_business_ids()`, the canonical path every other tenant
  table uses. Deployed. The stuck budget upsert flushes on Retry / next tick.

**Files touched:**
- lib/features/expenses/screens/expenses_screen.dart
- lib/features/expenses/screens/add_expense_screen.dart (new — moved/renamed from widgets/add_expense_sheet.dart)
- lib/features/expenses/widgets/add_expense_sheet.dart (deleted)
- supabase/migrations/0075_expense_budgets_rls_via_profiles.sql (new)
- reebaplus_master_plan.md (§20.1 always-visible note, §20.2 screen-presentation note)

**Database changes:**
- Cloud migration **0075** — redefines `expense_budgets_tenant_rw` RLS to use
  `public.current_user_business_ids()` (fixes the 42501 push rejection). No
  schema change. Deployed via `supabase db push`.

**Master plan sections covered:**
- §20.1 — budget bar always visible; §20.2 — Record Expense as a screen.

**Plan updates made during session:**
- §20.1: noted the monthly budget bar is shown on every period and reflects the
  last-30-days window (user request, 2026-06-02).
- §20.2: noted the form opens as a full screen, not a modal (user request).

**Tested:**
- `flutter analyze lib/features/expenses/` — no issues. On-device pass pending
  (user to hot-reload and confirm the three changes).

**Known issues / left open:**
- None.

**Next session should:**
- Continue Ring-1/Ring-3 reporting work per the master plan.

---

## Session 59 — 2026-06-02 — Expenses: full implementation (approval flow + funds debit + budget) (§20, Ring 1)

**Built today:**
- The Expenses feature went from a fake in-memory stub to a real, persisted,
  cloud-synced feature. (The screen already read the real database; the gaps
  were the §20 behaviours below.)
- **Approval flow (§20.4).** Every expense now has a status — Approved, Pending
  CEO approval, or Rejected. A Manager recording an expense **over their
  approval limit** lands as Pending; a CEO (or a Manager within limit) is
  auto-approved. The Expenses screen shows a **Pending Approvals** section at
  the top (only for whoever can approve), each with **Approve** / **Reject**
  (reject asks for a reason). Cards carry a status badge; rejected cards show
  the CEO's reason. Approving/rejecting notifies the staff who recorded it.
- **Money actually moves now (§20.5).** Recording a Cash / Bank / POS expense
  **reduces that Funds Register account**. The debit posts **when the expense is
  approved** — immediately for an auto-approved one, or at CEO approval for a
  Pending one; a Rejected one never moves money. Like a refund, it's dated to
  **today's open funds day**, so recording/approving such an expense needs the
  day to be open (blocked with a clear message otherwise). "Other"-method
  expenses don't touch any account. Deleting an approved expense **gives the
  money back** (a reversing entry on today's till).
- **Record Expense form upgrades (§20.2):** category is now a **searchable field
  that creates new categories on the fly**; the payment method maps to a real
  account, with an **account picker** (which Cash Till / Bank / POS machine) for
  tracked methods; the **date** and a **receipt photo (local file)** are now
  saved; payment-method options fixed to Cash / Bank Transfer / POS card / Other.
- **Edit / Delete (§20.3):** edit your own within 24h (CEO + Manager), edit any
  (CEO), soft-delete (CEO only) — each gated and hidden when not allowed.
  Editing changes descriptive fields only; amount/method are fixed after
  creation (delete + re-record to change them), which keeps the money ledger
  consistent.
- **Monthly budget (§20.1/§20.3):** the budget bar now uses a **real, CEO-set
  monthly goal** (replacing hardcoded numbers), countable **per business and per
  store**. The bar counts **approved** spend only and shows "₦X pending
  approval" underneath. CEO gets a **Set budget** action.
- **Stats tab (§20.6):** category breakdown, this-month-vs-budget comparison,
  and top staff by spend — all over approved expenses.
- **Home Total Expenses** now counts approved expenses only.
- Removed the dead in-memory `ExpenseService` / `Expense` model / provider.

**Files touched:**
- reebaplus_master_plan.md (§20.1/§20.5 amendments)
- lib/core/database/app_database.dart (expenses columns, expense_budgets table,
  fund_transactions reference_type CHECK widen, schema v31 + migration step,
  synced/soft-delete lists, partial unique indexes)
- lib/core/database/daos.dart (ExpensesDao: approval-aware addExpense + funds
  debit, approveExpense / rejectExpense / updateExpense / softDeleteExpense,
  watchPendingCount; new ExpenseBudgetsDao)
- lib/core/database/daos.g.dart, app_database.g.dart (regenerated)
- lib/core/providers/stream_providers.dart (pendingExpensesCountProvider,
  expenseBudgetsProvider + resolveMonthlyBudgetKobo,
  currentUserMaxExpenseApprovalKoboProvider)
- lib/features/expenses/screens/expenses_screen.dart (full rewrite: badges,
  pending section, approve/reject, budget bar + set-budget, edit/delete, stats)
- lib/features/expenses/widgets/add_expense_sheet.dart (searchable category,
  account picker, open-day gate, date/receipt persistence, status-from-limit)
- lib/features/dashboard/screens/home_screen.dart (Total Expenses = approved only)
- lib/core/providers/app_providers.dart (removed dead expenseServiceProvider)
- supabase/migrations/0073_expenses_full.sql (new — NOT yet deployed)
- test/expenses/expense_approval_funds_test.dart (new — 6 tests)
- Deleted: lib/features/expenses/data/services/expense_service.dart,
  lib/features/expenses/data/models/expense.dart

**Database changes:**
- Schema bumped to **v31**. `expenses` gains `funds_account_id`, `status`
  (CHECK approved/pending/rejected, default approved), `rejection_reason`,
  `approved_by`, `approved_at`, `expense_date`, `receipt_path`.
- `fund_transactions.reference_type` CHECK widened to allow `'expense'` (the
  expense debit / its reversal). Append-only ledger rebuild (same dance as the
  v29 crate_ledger change).
- New synced tenant table **`expense_budgets`** (`business_id`, nullable
  `store_id`, `amount_kobo`) with two partial unique indexes (one live goal per
  business / per store). Added to `_syncedTenantTables` + `_softDeletableTables`.
- Cloud migration **0073** mirrors all of the above + adds `p_status` /
  `p_funds_account_id` / `p_expense_date` / `p_receipt_path` to the
  `pos_record_expense` RPC and `expense_budgets` to the snapshot pull.
  **NOT yet pushed** — see Known issues (deploy ordering).

**Plan updates made during session:**
- §20.1 (Budget Activity bar): recorded that the monthly budget goal is set
  **overall for the business and optionally per store**, stored in a new
  `expense_budgets` table (`business_id`, nullable `store_id`, `amount_kobo`);
  the bar resolves the goal by the viewer's store scope, falling back to the
  business-wide goal. (User request, 2026-06-02 — §20 previously said only
  "monthly budget".)
- §20.5 (Cash and account rules): recorded that the Funds Register debit posts
  **when the expense becomes approved** (auto-approved → immediately; Pending →
  on CEO approval; Rejected → never), dated to the open funds day it posts on
  (refund-day rule, §19.7), and that recording/approving a tracked-account
  expense **requires an open funds day** (§23.8). Also: receipt photo is a
  **local file path** in Phase 1 (cloud upload deferred). (User decisions,
  2026-06-02.)

**Post-build adversarial review + fixes (same session):**
Ran a multi-agent bug review (7 finder dimensions × diverse-lens verifiers);
15 candidate findings, 5 confirmed (4 distinct bugs). All fixed — Dart-only, no
schema/migration/redeploy:
- **(HIGH) Budgets never synced DOWN.** `expense_budgets` was in the push list
  but missing from the inbound `_pullOrder` + `_restoreTableData` switch in
  `supabase_sync_service.dart`, so a budget set on one device never reached
  others (and a 2nd device setting the same scope would hit a cloud unique-index
  23505). Added it to both. **The Session-58 `stock_counts` table had the
  identical omission — fixed it too** (saved counts likewise weren't reaching
  other devices). Regression test: `test/sync/expense_budgets_restore_test.dart`.
- **(HIGH) Manager saw all stores' expenses.** The screen read the unscoped
  `allExpensesProvider`; §20.3 says Manager = own store. Added
  `viewerScopedExpensesProvider` (CEO → all; others → own store) so the list,
  totals, stats, and budget spend are all store-scoped and match the goal scope.
- **(MED) Double-tap approve could double-debit** (TOCTOU: status read outside
  the txn). Moved the status guard inside the transaction with a conditional
  `status='pending'` UPDATE + affected-row check in `approveExpense` /
  `rejectExpense` / `softDeleteExpense` (the latter so a double delete can't
  double-reverse). Regression tests added (double-approve → one debit; double-
  delete → one reversal).
- **(MED) No CEO alert on pending submit.** `addExpense` now fires an
  `expense.pending_approval` notification to CEO users when a Manager's
  over-limit expense escalates (§20.4/§26.4 bell badge).
- Hardening (latent, from refuted-but-cheap findings): `_methodLabel` no longer
  crashes on a legacy `'card'` method; the Add-Expense FAB is gated by
  `expenses.create`.

**Tested:**
- `flutter analyze` clean (only pre-existing `avoid_print` infos in
  test/database/roles_v13_report.dart).
- Full suite after fixes: **309 passed, 58 skipped, 0 failures.**
- Migration chain upgrades cleanly to **v31** (migration_upgrade_test covers
  v17/v21/v24/v26/v27/v28 → v31).
- `test/expenses/expense_approval_funds_test.dart` (8 tests) + new
  `test/sync/expense_budgets_restore_test.dart` (2 tests).

**Known issues / left open:**
- **Cloud migration 0073 deployed** (2026-06-02, `supabase db push`) — remote is
  in sync with the v31 build. The review fixes are Dart-only, so no further
  cloud deploy is needed.
- **Per-store budget setting is single-store in Phase 1.** The data model +
  sync support per-store goals, but the CEO Set-Budget action always writes the
  business-wide (null-store) goal because the UI shows one store (§2.2). A
  store picker for budgets lands with the Phase-2 multi-store UI.
- **Receipt photo is local-only** (Phase 1 decision): the file path syncs but
  the image itself does not upload, so a receipt won't appear on other devices.
  Cloud upload (Supabase Storage + compression) is deferred.
- **Edit is descriptive-only**: amount / payment method / account are immutable
  after creation (delete + re-record to change them). Deliberate, to keep the
  append-only funds ledger consistent.
- The `pos_record_expense` **domain-RPC path** is behind a feature flag (likely
  off); the live path is the table-upsert path. Both were updated.
- Not yet verified on-device (emulator) — pending a run.

**Next session should:**
- Deploy cloud 0073, then verify on the emulator: record (auto-approved + over-
  limit Pending), approve/reject, the open-day gate, the funds debit/reversal in
  Funds Register, and the per-store budget bar.

---

## Session 58 — 2026-06-02 — Daily Stock Count: persistence + Record Damages + notifications (§17, Ring 2)

**Built today:**
- Saving a stock count now **records the count** (not just the stock adjustment).
  Each Save Count writes one session row holding how many products were counted,
  the shortage/surplus totals, and the itemised list of products that didn't
  match — the data the Daily Reconciliation Report (a later, Ring 3 feature)
  will read. A count is recorded even when everything matched, so the history is
  complete.
- Added the **Record Damages** button (top of the Daily Stock Count screen). It
  opens a small form — pick a product, type a quantity, choose a reason
  (Broken / Expired / Spilled / Theft / Other) — and submitting reduces that
  product's stock and logs it to history. It blocks if the quantity is more than
  what's in stock.
- The stock count and the damage each now **notify the CEO and Manager**
  ("stock count saved — reconciliation report ready" / "damage recorded"), per
  the master plan's notification list.
- Saving now records **who** did the count/adjustment (it previously saved a
  blank staff id).
- **Fixed the header**: the subtitle showed a raw store id ("Store #" + a long
  id) — it now shows the store **name** (or "All Stores"), with a store icon. The raw
  id was also a hard-rule #4 violation (no UUIDs in user-facing text).
- **Access control**: the Stock Take icon in the Inventory header is now hidden
  for Cashiers (master plan §17.4: only Stock keeper, Manager, CEO). The screen
  itself also refuses access if somehow reached by a Cashier.

**Files touched:**
- supabase/migrations/0072_stock_counts.sql (new — pushed to remote)
- lib/core/database/app_database.dart (StockCounts table, schema v30, migration step, synced-tables list, index)
- lib/core/database/daos.dart (StockCountsDao)
- lib/core/database/daos.g.dart, app_database.g.dart (regenerated)
- lib/core/providers/stream_providers.dart (allStockCountsProvider)
- lib/features/inventory/screens/stock_count_screen.dart (Save Count persistence + notify, Record Damages form, store-name header, access guard)
- lib/features/inventory/screens/inventory_screen.dart (hide Stock Take icon for Cashier)
- test/inventory/stock_count_dao_test.dart (new)

**Database changes:**
- New synced table `stock_counts` — one row per saved count session: store, date,
  who counted, products-counted, shortage/surplus roll-up, and a JSON list of the
  changed products. Schema bumped to v30. Cloud migration 0072 (table + RLS +
  realtime + snapshot pull) was pushed to remote **before** the v30 app — the
  required deploy order.
- Damages are NOT a new table — they reuse the existing stock-adjustment ledger
  with a `damage:<reason>` note, so the cloud already syncs them.

**Master plan sections covered:**
- §17.1 (header — store name + store icon), §17.2 (Record Damages form), §17.3
  (save records the count + shortages; fires the reconciliation-ready event),
  §17.4 (access: Cashier blocked), §26.4 (stock-count-saved + damage-recorded
  notifications).

**Plan updates made during session:**
- None. This implements the existing plan; no scope change.

**Tested:**
- `flutter analyze` — clean (only pre-existing `avoid_print` infos in an unrelated test).
- New `test/inventory/stock_count_dao_test.dart` (5 tests) — a short count adjusts
  inventory AND records the itemised shortages payload; a matched count still
  records a zero-shortage session; mixed shortage/surplus roll-ups are correct;
  the write enqueues for sync; a damage reduces stock via the `damage:<reason>`
  ledger.
- Full non-integration suite: **299 passed, 2 skipped, 0 failed** (migration +
  sync tests unaffected by the schema bump).

**Post-build review + fixes (same session):** ran an extensive multi-agent
adversarial review of the above. It found **5 real bugs** (and correctly dismissed
6 test-coverage nits). All five fixed:
- **(critical) Cloud sync would silently fail.** The `stock_counts` RLS policy in
  0072 copied the *old, broken* membership-subquery pattern from 0068 — the exact
  thing migration 0071 had to fix for the funds table. Saved counts would have been
  rejected by the cloud (error 42501) and stuck in the sync queue, while reads kept
  working (so it would have looked fine until you checked another device). Fixed by
  **new migration `0074_stock_counts_rls_via_profiles.sql`** (mirrors 0071, uses the
  profiles-based `current_user_business_ids()` helper), pushed to remote.
- **(high) Saving could freeze the screen.** If another till sold an item mid-count,
  Save Count could throw partway and leave the Save button permanently stuck/hidden
  with no message. Wrapped the save in error handling that shows a message, refreshes
  the figures, and re-enables the button so the user can retry.
- **(medium) A blank count box zeroed stock.** An empty "Actual" box was read as 0,
  which would zero that product's stock and fire a false shortage alert. Now a blank
  box means "not counted" and is skipped (a typed 0 is still a real count).
- **(low) Access guard hardened** to fail closed while the role is still loading.
- **(nit) Header label** no longer says "All Stores" for a single-store count whose
  name hasn't synced yet (shows "This store").
- Re-ran: `flutter analyze` clean; stock-count tests pass; full suite **305 passed,
  2 skipped, 0 failed**.

**Follow-up — per-store + history + confirm (same session, user request):**
- **Counts are now per store.** A daily stock count is taken for one store at a
  time; the combined all-stores view is gone. When opened with a store lock it's
  fixed to that store; when opened unscoped a **Store picker** chooses which store
  (hidden if the business has a single store). Switching stores reloads that
  store's count. (Plan updated — §17.1.)
- **Fixed: a saved count now shows in history.** The Stock Count History sheet was
  reading the partial activity-log trail, which missed no-change counts. It now
  reads the authoritative `stock_counts` table, so **every saved count appears**
  (per store, newest first) with each session's store, time, products counted,
  and the itemised shortages/surpluses.
- **Confirm dialog on Save Count.** Tapping Save Count now shows a confirmation
  summarising how many products will be adjusted (and any shortages) before it
  commits — since saving changes live stock. (Plan updated — §17.2.)
- Cleanup: removed the now-dead all-stores grouping (`_DisplayItem`,
  `_buildStoreHeader`); the product list is a flat per-store table.
- Re-ran: `flutter analyze` clean; full suite **315 passed, 2 skipped, 0 failed**.

**Known issues / left open:**
- Not yet verified on-device (emulator pass pending).
- `ActivityLogDao.getStockCountLogs()` is now unused (the history switched to
  `stock_counts`) — left in place, not deleted.
- The **Daily Reconciliation Report** (§25.9) that consumes this data is still a
  **Ring 3** item — not built here. This session only produces its stock-audit
  half (the cash-audit half already exists from Close Day).

**Next session should:**
- Either continue Ring 2 (Customers Edit / GPS), or pick up the Ring 3 Daily
  Reconciliation Report now that both halves (Close Day cash + stock count) of
  its data exist.

---

## Session 57 — 2026-06-02 — Planning: full Business Reports hub (§25) + plan-conflict fix

**Planning session — no feature code yet.** Mapped the §25 Reports hub against the
current code and the data layer, and resolved a master-plan contradiction before
building.

**Plan conflict resolved (master plan edited):** §11.3 said the Reports hub is
"CEO and Manager only," but the §25.3 visibility matrix and the §27.3 sidebar row
gave Cashier an "Own sales" Sales report and Stock keeper a no-money Stock Audit.
The three can't all stand. **User chose: keep CEO + Manager only.** Edited
`reebaplus_master_plan.md` — §25.3 now reads "Hidden" for Cashier and Stock keeper
on every report (including Stock Audit), the §27.3 Reports row is `Yes | Yes |
Hidden | Hidden`, and a dated reconciliation note records the decision. A cashier's
own-sales summary stays on Home / Orders; a stock keeper's stock view stays in
Inventory.

**State found (drift vs §25.2):**
- `reports_hub_screen.dart` shows 6 cards with **no per-card role gating**.
- A **"Pending Approvals" card** is present — **forbidden by §25.2** ("there is no
  Pending Approvals card on Reports"). Must be removed.
- **Customer Ledger** card routes to the Customers **list**, not a §25.6
  wallet-balances / top-debtors report. **Expense Tracker** routes to the Expenses
  feature screen. **Sales / Stock Audit / Funds Register** have real detail screens.
- Missing cards: Daily Reconciliation, Supplier Accounts, Profit. No CSV export
  (§25.7) on any report yet.

**Buildability (verified against daos.dart / app_database.dart):**
- Ready now: Sales, Expense Tracker, Stock Audit, Customer Ledger, Funds Register,
  **Profit** (COGS available — `OrderItems.buyingPriceKobo` is stored per line).
- **Blocked** (depend on earlier-Ring subsystems not yet built): **Supplier
  Accounts** (Ring 1 Supplier Accounts + Track Shipments — `PaymentService` is still
  an in-memory stub, no `supplier_payments` table); **Daily Reconciliation** (Ring 2
  Daily Stock Count snapshot — only the Close-Day cash half exists).
- CSV (§25.7) needs **no new dependency** — `share_plus` + `path_provider` already
  in `pubspec.yaml`.

**Agreed scope (user):** Hub + ready reports now; defer the two blocked cards until
their subsystems land (rule #7 — absent, not greyed). Build plan: (A) remove the
forbidden card + add §25.3 role-gating via `hasPermission` / role slug; (B) build
Profit (CEO-only) + a real Customer Ledger report screen + a shared CSV-export
helper wired into each report detail.

**Next session should:** start Phase A (hub cleanup + role-gating), then Phase B.

---

## Session 56 — 2026-06-02 — Close Day: RLS fix + Funds Register Report + stock-count gate + same-day Reopen

### Part D — Reopen Day (same day only) (§23.5/§23.6, plan change)

**Plan updates made during session:**
- §23.6 — added **Reopen Day**: a closed day can be reopened **while it is still
  the same business day** (e.g. closed too early). Gated by `funds.close_day`.
  Once the day rolls over it stays closed (the closed-day summary, hence the
  button, only shows for today). §23.5 clarified: "never reopened" means never
  *automatically* by a back-dated refund — the manual same-day reopen is a
  separate explicit action. User decision 2026-06-02.

**Built today:**
- `FundDaysDao.reopenDay(store, date, performedBy)` — inside one transaction:
  deletes that day's `fund_day_closings` snapshots (hard delete + enqueueDelete;
  it's a normal synced table, and enqueueDelete also cancels any still-pending
  close upsert — so the UNIQUE (fund_day_id, funds_account_id) constraint won't
  block a later re-close), flips `fund_days` back to `open`, clears
  closedBy/closedAt, logs `funds.reopen_day`. The ledger (`fund_transactions`) is
  untouched, so the expected balance is preserved.
- "Reopen Day" button (outline) on the closed-day summary with a confirm dialog;
  only renders for today's closed day → inherently same-day.

**Files touched:**
- reebaplus_master_plan.md (§23.6 Reopen Day, §23.5 clarifier)
- lib/core/database/daos.dart (FundDaysDao.reopenDay)
- lib/features/funds/screens/funds_register_screen.dart (Reopen button + handler)

**Tested:**
- `flutter analyze` on touched files: no issues. On-device pass pending.

**Notes:**
- Reopen is gated on `funds.close_day` (no new permission key → no cloud
  permissions-catalogue deploy needed). Reopen logs to Activity Logs but does NOT
  fire a bell notification — can add a `funds_day_reopened` §26.4 notification as a
  follow-up if the CEO should be alerted when a Manager reopens.

### Part C — Stock-count gate on Close Day (§23.6, plan change) + report empty-state fix

**Plan updates made during session:**
- §23.6 — added the **stock-count gate**: closing the *current* business day is
  blocked until a Daily Stock Count (§17) is saved for that store that day. The
  reconciliation needs the stock audit. Back-dated closes (the §23.8 stale-prev-day
  path) are **exempt** — that day can't be re-counted, and blocking it would
  deadlock the next day from opening. User decision 2026-06-02 ("hard-block today,
  allow back-dated"). Cross-ref line added to §17.3.

**Built today:**
- Close Day now checks `StockCountsDao.wasStockCounted(store, date)` before opening
  the close sheet (only when the day being closed is today). No count → a "Take
  stock first" dialog with a shortcut to the Stock Count screen; the day does not
  close. Back-dated/previous-day closes skip the check.
- **Bug fix:** the Funds Register Report was empty because its default "Last 24
  hours" rolling window clipped out a day closed for *yesterday's* business date
  (the common previous-day-close path). The period filter is now business-day
  aware — a day counts as in-period if it *ended* within the window (anchored on
  the day's end, not its midnight start).

**Files touched:**
- reebaplus_master_plan.md (§23.6 stock-count gate, §17.3 cross-ref)
- lib/core/database/daos.dart (StockCountsDao.wasStockCounted)
- lib/features/funds/screens/funds_register_screen.dart (gate + Take-stock prompt)
- lib/features/funds/screens/funds_register_report_screen.dart (business-day filter)

**Question answered for the user:**
- "What happens when a day is closed before the day ends?" → Per §23.5 a closed
  day is never reopened; closing removes the open-day gate so POS is blocked for
  the rest of that day. No reopen feature in Phase 1. The stock-count gate now
  reduces accidental premature closes.

**Tested:**
- `flutter analyze` on all touched Dart files: no issues. On-device pass pending.

**Known issues / left open:**
- No "reopen day" feature (by §23.5 design). If premature closes become a real
  problem in use, revisit with the user — would be a separate plan change.

### Part B — Funds Register Report (§25.2)

**Built today:**
- Added the **Funds Register Report** card to the Business Reports hub
  (§25.2). Opens a read-only detail screen showing, across the selected period,
  each closed day's per-account reconciliation: account, Expected, Counted, and
  Variance — with mismatches flagged (red, plus a per-day "Mismatch" badge).
  Headline tiles up top: Days closed, Mismatches, Net variance. Period dropdown
  overrides the hub's global filter (§25.5/§25.6). Empty state "No data for this
  period." (§25.8). This is the close-day data surfacing the user asked for.

**Files touched:**
- lib/features/funds/screens/funds_register_report_screen.dart (new)
- lib/features/dashboard/screens/reports_hub_screen.dart (new card + import)
- lib/core/database/daos.dart (FundDayClosingsDao.watchAllForBusiness,
  FundsAccountsDao.watchAllForBusiness — both business-scoped)
- lib/core/providers/stream_providers.dart (allFundDayClosingsProvider,
  allFundsAccountsProvider)

**Master plan sections covered:**
- §25.2 Funds Register Report, §25.5/§25.6 period filter, §25.8 empty state.

**Plan updates made during session:**
- None. Built exactly as §25.2 already specifies (a report card in the grid, not
  a new "Audit" tab — user confirmed "build per plan").

**Tested:**
- `flutter analyze` on all four touched files: no issues. On-device pass pending.

**Known issues / left open:**
- CSV export (§25.7 "CSV from day one") not added — no sibling report screen has
  it yet; deferred to the full §25 pass so all reports get it together.
- Daily Reconciliation Report (§25.2/§25.9) still deferred — it's Ring 3 and needs
  Daily Stock Count (§17), which isn't built.
- Manager "own store" scoping (§25.3) not yet enforced on report detail screens —
  matches the current behaviour of the other report cards; for the §25 pass.

### Part A — Fix: Close Day 42501 RLS rejection on fund_day_closings

**The bug:** Closing the day surfaced repeated "RLS rejection" errors on the Sync
Issues screen — `fund_day_closings:upsert` failing with Postgres code 42501 ("new
row violates row-level security policy"). One stuck row per account (Cash Till, POS
machine, Bank). The per-account reconciliation snapshots never reached the cloud,
so the day's reconciliation looked incomplete / "didn't close."

**What actually happened:** The day *did* close. `closeDay()` does all its work in
local SQLite (no row-level security there) and only enqueues the cloud pushes, so it
never threw — "Day closed" was shown and the `fund_days` header flipped to closed and
synced fine (it was NOT in the failure list). Only the `fund_day_closings` snapshots
were stuck in the push queue.

**Root cause:** When `fund_day_closings` was added (migration 0068), its RLS policy
copied the *original* `fund_days` policy from 0057 — the pre-0051 pattern that
resolves the caller's business through an inline `auth.uid() → users.auth_user_id →
user_businesses` subquery. That subquery runs as the logged-in user (so it's itself
filtered by row-level security) and comes back empty whenever a user's stored
`auth_user_id` has drifted from their current login — which fails the check and
returns 42501. The three sibling funds tables had already been fixed for exactly this
in migration 0058 (they resolve the business via the profiles-based helper
`current_user_business_ids()`), but `fund_day_closings` was created later and missed
that fix.

**The fix:** New migration `0071_fund_day_closings_rls_via_profiles.sql` — drops and
recreates the `fund_day_closings_tenant_rw` policy to use
`public.current_user_business_ids()`, identical to the 0058 funds policies. Pushed to
the cloud (only pending migration; 0050–0070 already applied). No app/schema change —
the local Drift table was already correct.

**Files touched:**
- supabase/migrations/0071_fund_day_closings_rls_via_profiles.sql (new)

**Database changes:**
- Cloud only: swapped the `fund_day_closings` RLS policy from the user_businesses
  inline subquery to the profiles-based `current_user_business_ids()` helper.

**Master plan sections covered:**
- §23.6 — Close Day / per-account reconciliation snapshot (bug fix, no plan change).

**Tested:**
- `supabase db push` applied 0071; `supabase migration list` confirms 0071 is now on
  remote. The already-queued `fund_day_closings` upserts will flush on Retry / next
  backoff tick now that the policy passes.

**Known issues / left open:**
- The stuck queue items need a Retry (or the next auto-retry) to actually push — the
  fix unblocks them but does not replay them itself.
- Reports surfacing of close-day data (Funds Register Report / Daily Reconciliation
  Report, §25.2) is still unbuilt — see note to user; §25 Reports is not started.

**Next session should:**
- Confirm on-device that the pending `fund_day_closings` items cleared after Retry.

---

## Session 55 — 2026-06-01 — Fix: "confirm empty crates" crash (FormatException) + empty-crate tab not updating

**The bug:** Confirming a crate return threw `FormatException: Invalid radix-10
number`. Root cause: this app stores every `last_updated_at` / `created_at` as an
**integer** (Unix epoch seconds), but four raw-SQL writes in the crate flow set
`last_updated_at = CURRENT_TIMESTAMP`. SQLite's `CURRENT_TIMESTAMP` is the *text*
"2026-06-01 20:06:53", which lands in the integer column as text. The next time
drift reads that row it runs `int.parse` on the text and blows up.

Because `addEmptyCrates` always does that UPDATE then immediately re-reads the
manufacturer row, every confirm crashed — and since the crash rolled the whole
transaction back, the manufacturer's empty-crate count never went up. That's why
the Empty Crates tab in Inventory never reflected the return. Fixing the crash
fixes both symptoms at once (the tab reads the manufacturer's stock via a live
stream, so it now updates the moment a return is confirmed).

**The fix:** Replaced `CURRENT_TIMESTAMP` with the same integer expression the
columns already use as their default — `CAST(strftime('%s', CURRENT_TIMESTAMP)
AS INTEGER)` — in the four crate writes (manufacturer empty-crate counter, the
customer-balance upsert, the manufacturer-balance upsert, and the approve flow).
No schema change, no data repair needed: both connected devices were checked and
held clean integer timestamps (the failed confirms had always rolled back).

**Files touched:**
- lib/core/database/daos.dart
- lib/shared/services/crate_return_approval_service.dart
- test/crates/crate_logic_test.dart

**Database changes:**
- None. (Behaviour-only fix to how existing columns are written.)

**Master plan sections covered:**
- §13.4 — crate tracking by manufacturer (no plan change).

**Plan updates made during session:**
- None.

**Tested:**
- Added three regression tests in test/crates/crate_logic_test.dart covering
  `addEmptyCrates`, a second customer return (ON CONFLICT path), and a second
  approve (ON CONFLICT path). Confirmed they fail against the old code with the
  exact `int.parse` crash, and pass after the fix. Full crate suite green;
  analyze clean on the touched files.

**Known issues / left open:**
- Note for future raw-SQL writes: never assign `CURRENT_TIMESTAMP` (or any text
  datetime) to a drift datetime column — it's stored as integer epoch. Use
  `CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)` or a bound `DateTime`.

---

## Session 54 — 2026-06-01 — Date-filter chips unified onto one rolling helper

The user asked to review every filter chip so the date windows (24 hours, last
7 days, last 30 days, last year, to date) calculate correctly, and confirmed my
recommendation: standardise to **rolling windows** with those labels, across all
Phase-1 screens.

Builds on the concurrent Session 53 Orders work (which made the Orders period
filter a dropdown, default Day, capped for lower roles). My change relabels that
dropdown to the canonical rolling set and preserves the lower-role cap as the
**three shortest windows** (Last 24 hours / Last 7 days / Last 30 days).

**The problem found (a real mess, not just a tweak):** every period filter rolled
its own date math, and the same chip meant different things on different screens.
Two incompatible styles were live at once — rolling ("last N days") on Home /
Reports / Orders / Expenses / Payments, but calendar boundaries ("since the 1st /
since Monday") on the Customer wallet and Supplier detail. Stock Audit was even
inconsistent with itself ("This Week" = last 7 days but "This Month" = since the
1st). Plus an off-by-up-to-a-day bug (`diff.inDays <= 7` counts a record 7d23h
old as "within 7 days"), a fragile `'Day'` check, and three vocabularies for the
same idea (Day/Today, To Date/All Time/All).

**Built today:**
- **One shared helper, `lib/core/utils/date_period.dart`** — the single source of
  truth. A `DatePeriod` enum (last 24 hours / 7 days / 30 days / year / to date),
  the canonical chip labels, a tolerant label parser (still understands every old
  label so nothing breaks), an `includes(date)` test, and a `(start, end)` range
  for the screens that query the DB by date. UTC-normalised so local/UTC
  timestamps compare cleanly.
- **Routed all 8 Phase-1 filter screens + 2 services through it:** Home, Reports
  Hub, Orders (completed + cancelled tabs), Expenses (list + budget tracker),
  Supplier-Accounts Payments + Supplier detail, Customer wallet, Stock Audit, and
  the payment/expense services. Every chip now reads the same canonical set, and
  the date math is identical everywhere.
- Removed the dead business-timezone plumbing the refactor orphaned (Customer
  detail + Stock Audit): rolling windows are timezone-independent, so the
  `_businessTz` fetch / `localDateUtc` calendar math went away.
- **Left alone on purpose:** Inventory History (§16.8 keeps its own
  Today/7 Days/30 Days/All labels) and the Phase-3 Deliveries screen — matches the
  scope the user chose.

**Files touched:**
- lib/core/utils/date_period.dart (NEW)
- lib/features/dashboard/screens/home_screen.dart, reports_hub_screen.dart, stock_audit_screen.dart
- lib/features/orders/screens/orders_screen.dart
- lib/features/expenses/screens/expenses_screen.dart + data/services/expense_service.dart
- lib/features/payments/screens/payments_screen.dart + data/services/payment_service.dart
- lib/features/customers/screens/customer_detail_screen.dart
- lib/features/inventory/screens/supplier_detail_screen.dart
- test/utils/date_period_test.dart (NEW — 18 tests)
- reebaplus_master_plan.md (new §30.11 canonical chip spec; §30.6/§19.1/§20.1/§25.1/§11.2 defaults)

**Database changes:** None.

**Master plan sections covered:** §30.11 (new), §30.6, §11.2, §19.1, §20.1, §25.1.

**Plan updates made during session:** Added §30.11 documenting the canonical
rolling chip set + that Funds/Close Day stay calendar-day-bound and Inventory
History keeps its own labels; updated the per-screen default-period mentions.
Reviewed with the user (the user picked the rolling approach + all-Phase-1 scope)
before coding.

**Tested:** New `test/utils/date_period_test.dart` — **18/18 pass**, covering the
boundary cases that were previously wrong (exactly-7-days inclusive, 7d+1s
excluded, etc.) and UTC/local zone handling. `flutter analyze lib`: my 10 files
are clean. A read-only adversarial review (one agent per changed file) returned
**all 10 all-clear** — no leftover hand-rolled date math, no legacy-label
comparisons, all dropdown defaults valid, no orphaned imports. No on-device pass
yet.

**Known issues / left open:**
- **Pre-existing, NOT this work:** the working tree carries a half-finished
  crate-by-manufacturer migration (Session 52's deferred Bug #2) —
  `app_database.dart`/`.g.dart` dropped `crateSizeGroupId` but `daos.dart` and the
  sync/crate services still reference it, so `flutter analyze` reports 19
  `crateSizeGroupId` errors and the full `flutter test` suite can't compile. None
  of those files were touched here. The date-filter helper was verified in
  isolation because its test imports only `date_period.dart` (zero app deps).
  Finishing that crate migration is the prerequisite for a clean full-suite run.

**Next session should:** finish the deferred crate-by-manufacturer migration so
the app compiles + the full test suite runs, then on-device check the filter
chips on Home / Orders / Expenses / Customer wallet.

---

## Session 53 — 2026-06-01 — Orders money hidden below Manager + filter dropdown + wallet-totals permission

Continues on `feat/orders-pending-refund`. The user asked that roles **below
Manager** (Cashier, Stock keeper) stop seeing monetary values in Orders, that the
period filter chips become a **dropdown** sitting inline with the search bar, that
the dropdown be **capped at Month** for those roles, that it **default to Day**,
and that the **Total In / Total Out** tiles on a customer's Wallet tab be hidden
for those roles unless the CEO turns them on.

**Built today:**
- Orders screen: the per-tab money stat cards (Total Value / Revenue / Collected /
  Crate Deposits / Value Forfeited), the per-line item prices, and each order
  card's Total / Paid / discount / wallet-debt amounts are now **hidden for roles
  below Manager**. The printed/shared receipt is unchanged (it's the customer's
  document).
- Orders screen: the old row of filter chips is replaced by a **dropdown** that
  sits next to the search bar (Completed + Cancelled tabs). It **defaults to Day**.
  Roles below Manager only get Day / Week / Month; Manager + CEO also get Year /
  To Date / All Time.
- Customer Wallet tab: the **Total In / Total Out** tiles are hidden for roles
  below Manager unless the CEO grants the new `customers.wallet.totals.view`
  permission (CEO Settings → Roles & Permissions → that role). Manager + CEO
  always see them.
- Added a shared `isManagerOrAbove(ref)` helper (fails closed while the role is
  still loading) used by both screens.

**Files touched:**
- lib/features/orders/screens/orders_screen.dart
- lib/features/customers/screens/customer_detail_screen.dart
- lib/core/providers/stream_providers.dart
- lib/core/database/app_database.dart
- supabase/migrations/0069_customers_wallet_totals_view_permission.sql (new)
- test/database/migration_upgrade_test.dart
- reebaplus_master_plan.md, BUILD_LOG.md

**Database changes:**
- New permission key `customers.wallet.totals.view` ("Customers" category). Added
  to the local catalogue + a new local schema bump (v27 → v28, `INSERT OR IGNORE`
  in onUpgrade) and to the cloud catalogue via migration 0069, which also grants
  it to CEO + Manager by default (new-business seed + backfill of existing
  businesses). Cashier / Stock keeper are intentionally NOT granted it.

**Master plan sections covered:**
- §19.1 (filter dropdown + Month cap + Day default), §19.3 (Cashier money rule),
  §27.3 (Orders → Cashier "Items only"), §2.5 (new permission key), §18.4 (wallet
  totals gating).

**Plan updates made during session:**
- §19.3 conflicted with the request: it previously let the **Cashier** see their
  own sales' money ("Own sales only") and restricted only the Stock keeper. The
  user confirmed the new rule, so §19.3 / §27.3 were updated so **both** roles
  below Manager are money-blind in Orders, §19.1 documents the dropdown/cap/default,
  §2.5 lists the new permission, and §18.4 documents the wallet-totals gating.

**Tested:**
- `flutter analyze` — clean for all changed files (only pre-existing `avoid_print`
  infos in the unrelated `roles_v13_report.dart`).
- Added a v27 → v28 onUpgrade test (re-seeds the new key); it + the existing
  migration tests pass.
- Updated the catalogue-count assertions that the new key bumped 32 → 33
  (`roles_v13_seed_test`, `role_permissions_detail_test`, `roles_permissions_screen_test`)
  — these also confirm the new key auto-appears as a CEO Settings toggle.
- Full suite green: **271 passed, 0 failed**.

**Known issues / left open:**
- Cloud migration 0069 must be `supabase db push`-ed for the new permission to be
  grantable on real devices (FK on `role_permissions.permission_key`).
- The customer detail **Orders tab** order cards still show totals to a Cashier
  (out of scope per the user's answer — they scoped the customer screen to the
  Total In/Out tiles only). Flag if that should also be hidden.

**Next session should:**
- Deploy 0069, verify on-device that a Cashier sees no money in Orders and no
  Total In/Out, and that the CEO toggle re-enables the tiles.

---

## Session 52 — 2026-06-01 — Bug sweep (wallet/receipt/funds/notifications) + Close Day UI

Continues on `feat/orders-pending-refund`. The user reported 7 bugs; a read-only
multi-agent investigation (6 finders + an adversarial verifier per finding)
root-caused each against the §14.3 dual-leg wallet model. The verifier caught
real mistakes in three of the first-pass fixes (a non-monotonic-UUID tiebreaker,
a wrong "settle old debt" reading of bug #4, and unsafe notification re-insert),
which changed the final approach. Six bugs + a Close Day UI landed and were
tested; the seventh (crate tracking) is a schema+cloud migration left as the
focused next step.

**Built today:**
- **Bug #7 — silent notifications fixed app-wide.** `AppNotification` held its
  top-overlay entry in a static that was orphaned when the navigator key
  regenerates on an auth-state change, so every notification after that silently
  painted nothing (the debt-limit block was one victim). It now self-heals —
  re-inserts a fresh overlay entry when the old one is unmounted. Also made the
  checkout debt-limit check read the wallet balance synchronously (from the live
  provider, no awaited DB read) so the "exceeds debt limit" / "no limit set"
  error always flashes instead of dropping behind an `if (mounted)` guard.
- **Bug #3 — credit shows before debit in wallet history.** The display query
  (`WalletTransactionsDao.watchHistory`) sorted only by `created_at DESC`; the
  two sale legs share the same second, so the tie order was undefined (and wrong
  on-device). Added a deterministic secondary sort — credit sorts above debit —
  so the wallet reads "money in, then money out" (the order charge shows last).
  No reliance on insertion order or the random-tailed UuidV7 id.
- **Bug #5/#6 — receipt wallet balance.** The receipt was fed a PRE-sale
  projection (`old − total + cash`) read AFTER the legs posted, so it
  double-counted (partial and credit sales showed double the debt). It now shows
  a snapshot of the true post-sale net (`old + paid − total`) captured at
  confirm; correct for full / partial / credit / wallet / apply-credit.
- **Bug #4 — apply wallet credit on a full payment (new flow, §14.2/§14.3).**
  When a registered customer with wallet credit pays in full and the credit only
  partly covers the order, "Pay from Wallet" now applies the credit (wallet → ₦0),
  shows the outstanding, requires an "Outstanding paid" confirmation + receiving
  account, and collects the rest. The cash flows through the wallet (credit leg)
  and credits the chosen Funds account — implemented purely by passing
  `amountPaid = outstanding` + a cash sub-type to the existing dual-leg
  `createOrder` (no DAO change).
- **Bug #1 — Funds Register blank on open.** The screen returned an empty widget
  while its async providers loaded (blank then pop-in), and was permanently blank
  for a lone-owner CEO (no store auto-selected). Now shows a fade-in loading
  placeholder (§30.7) and falls back to the business's first store.
- **Close Day UI (§23.6) — the data layer existed (Session 49); the UI did not.**
  Added a **Close Day** button at the bottom of the Funds Register (gated by
  `funds.close_day`), a Close Day sheet (per-account counted cash / withdrawn vs
  the live expected balance), a "Day closed" reconciliation summary (expected /
  counted / variance, variance flagged red), and the §23.8 unclosed-previous-day
  banner with a Close action. On close it now fires a §26.4 notification to
  **CEO + Manager** ("day closed — reconciliation ready"); the existing
  funds-mismatch alert to the CEO still fires on a variance.

**Files touched:**
- reebaplus_master_plan.md (§14.2/§14.3 apply-credit + credit-before-debit; §13.4
  crate-by-manufacturer note; §23.6 Close Day button + CEO/Manager notification)
- lib/core/utils/notifications.dart (overlay self-heal)
- lib/core/database/daos.dart (watchHistory deterministic sort; createOrder leg
  comment; FundDaysDao.watchDay/watchUnclosedDayBefore; closeDay day-closed
  notification; UserBusinessesDao.getUserIdsForRoleSlugs)
- lib/core/providers/stream_providers.dart (fundDayProvider, unclosedDayBeforeProvider)
- lib/features/pos/screens/checkout_page.dart (apply-credit flow, snapshot receipt
  balance, synchronous debt-limit error)
- lib/features/funds/screens/funds_register_screen.dart (loading + store fallback,
  Close Day button/sheet/summary/banner)
- test/orders/order_service_money_math_test.dart (+1: credit-before-debit ordering)

**Database changes:** None this batch — no schema/migration. (The crate re-key,
below, IS a schema change and was deferred.)

**Master plan sections covered:** §14.2, §14.3, §13.4, §23.6, §26.4, §30.7.

**Plan updates made during session:** §14.2 documents the apply-credit
full-payment flow; §14.3 documents credit-before-debit ledger ordering; §13.4
notes empty crates are tracked by manufacturer (not crate size group); §23.6
adds the Close Day button + CEO/Manager close notification. All reviewed with the
user (3-question decision) before coding.

**Tested:** `flutter analyze lib` clean. `flutter test`: **270 passed, 58
skipped, 0 failed** (+1 over the Session 51 baseline = the new ordering test). No
on-device pass yet — recommend verifying: a partial/credit registered sale
receipt + wallet ordering, the apply-credit full payment, a debt-limit-exceeding
sale flashes the top error, the Funds Register opens without a blank flash, and a
full Close Day (button → sheet → summary, + the CEO/Manager notification).

**Bug #2 (crate confirmation modal empty) — DONE + DEPLOYED (schema v29 + cloud
0070).** Re-keyed empty-crate CUSTOMER tracking from crate size group to
MANUFACTURER (§13.4). Root cause: the customer/manufacturer crate ledger keyed by
a "crate size group" (Big/Medium/Small) that products are never assigned, so the
§19.5 modal skipped every line (`crate_return_modal.dart` `if (cgId.isEmpty)
continue;`). What changed:
- **Schema v29** (slotted at v29 because a concurrent feature took v28/cloud 0069):
  `customer_crate_balances` → `manufacturer_id` + UNIQUE(business, customer,
  manufacturer); `manufacturer_crate_balances` → drop the size dim, UNIQUE(business,
  manufacturer); `pending_crate_returns` → `manufacturer_id`; `crate_ledger` →
  `crate_size_group_id` nullable + the owner CHECK relaxed from customer⊕manufacturer
  to "at least one set" so a customer crate row can ALSO name the manufacturer whose
  crates it holds. The two balance CACHES are dropped+recreated (they rehydrate);
  `crate_ledger` rebuilds preserving history (v25 ledger-trigger pattern). The
  `crate_size_groups` TABLE stays — it still powers the Empty Crates inventory tab,
  deliveries, and supplier crate-group mapping (products/suppliers keep a vestigial
  nullable `crate_size_group_id`).
- **DAOs/UI/sync:** `recordCrateReturnByCustomer/Manufacturer`, `createPendingReturn`,
  `verifyCrateReconciliation`, the two balance-display joins, the crate-return modal
  (now lists by manufacturer — the actual modal-empty fix), the approval service,
  `pendingReturnsWithDetailsProvider`, the approval + customer-Crates screens, and
  the `_applyDomainResponse` balance_row handler — all keyed by manufacturer.
- **Cloud 0070** (deployed) mirrors the table re-key (additive: new cols nullable,
  caches/pending cleared) and rewrites `pos_record_crate_return` (param
  `p_crate_size_group_id` → `p_manufacturer_id`) + `pos_approve_crate_return`
  (reads `manufacturer_id`). Rollback at `scripts/rollback/0070_rollback.sql`.
- **Tests:** crate_logic + the two dispatch tests re-keyed; the two skipped
  integration tests re-keyed to compile/run; a new v28→v29 onUpgrade test; the
  fixture helpers re-keyed. `flutter analyze` clean; `flutter test`: **291 passed,
  58 skipped, 0 failed**.

**Deploy (user said "apply and deploy", 69 confirmed ready):** `supabase db push`
applied the whole pending set in order — **0068** (fund_day_closings, Session 49),
**0069** (customers.wallet.totals.view, a concurrent feature), **0070** (this crate
re-key). All three now show Local|Remote in `supabase migration list`.

**Concurrent-work note:** this branch had heavy parallel editing during the
session — a `customers.wallet.totals.view` feature (v28 / cloud 0069, logged as
Sessions 53–54) landed in the same files. The crate re-key was slotted at v29 /
0070 to avoid the version/migration collision and left that feature untouched;
the green full-suite run confirms the two bodies of work coexist.

**On-device migration fix (same session):** the first device run of the v29
upgrade crashed — `CREATE INDEX idx_crate_ledger_business_lua already exists` —
because drift's `alterTable` re-applies the rebuilt table's existing indexes, so
the block's bare `CREATE INDEX` was a duplicate. Fixed by `DROP INDEX/TRIGGER IF
EXISTS` before each recreate in the crate_ledger rebuild (also swaps
`idx_crate_ledger_owner_group` to its new no-`crate_size_group_id` shape). The
v28→v29 test now recreates those indexes first so it actually exercises the
rebuild branch (it had skipped it). No cloud change. No uninstall needed — the
failed onUpgrade rolled back, so a re-run on the fixed build upgrades cleanly.

**On-device wallet-ordering fix (bug #3, real root cause + final direction):**
two parts. (1) Root cause of the flakiness: `created_at` is second-resolution
(no `storeDateTimeAsText`), so a sale's two wallet legs TIE on `created_at`, and
the original tiebreak `OrderingTerm(type.equals('credit'), desc)` is a no-op in
`ORDER BY` → the tie fell back to SQLite rowid order, which differs in-memory
(test) vs the on-device file DB — a false-passing test. Fixed by tie-breaking on
a real numeric column (`signed_amount_kobo`), deterministic across backends, and
by stamping BOTH legs the same `created_at` in `createOrder` so they always tie.
(2) Final direction (user clarified): the wallet history is **newest-first**, and
the order charge is the LAST step of a sale, so it belongs at the **TOP** with
the payment below it → tiebreak is `signed_amount_kobo ASC` (negative DEBIT above
positive CREDIT). §14.3 plan note updated to match. Pure Dart change
(`watchHistory` + the leg timestamps) — no schema/migration/cloud; just
hot-restart.

**Known issues / left open:**
- No on-device pass yet for either the 6-bug/Close-Day batch or the crate re-key.
- The v2 crate RPC flag (`feature.domain_rpcs_v2.record_crate_return`) is OFF by
  default; the re-keyed cloud RPCs are deployed and ready for when it's enabled.

**Next session should:** on-device verify — a Bar/Beer order's crate-return modal
now lists drinks by manufacturer and records the customer's per-manufacturer crate
balance; plus the 6-bug/Close-Day batch checks noted above.

---

## Session 51 — 2026-06-01 — Orders re-plan: full wallet ledger + Pending-first lifecycle + refund-day-dated reversal

New branch: **`feat/orders-pending-refund`** (off `main` @ 979a512). An earlier
draft of the Orders UI work this session was discarded at the user's request
(`git reset --hard`) and the whole thing re-planned from the four decisions
below, then rebuilt.

**The four decisions (user, 2026-06-01):**
1. Checkout → **Pending**; **revenue is recognized at checkout**. Confirming →
   Completed is operational only (refund-locked + picked-up/delivered + crates
   received), never a financial event.
2. **Refund**: Pending tab only, Manager/CEO only, order → Cancelled. The
   reversal is dated to the **refund day** (the day the cash leaves the till),
   **not** the original sale day.
3. An order **can** owe — but only a credit sale the wallet can't cover. "Owes"
   **equals the wallet balance** and shows **only when that balance is below
   zero**, because **every** registered sale runs through the wallet (rule #4).
4. Close Day is strictly day-bounded — each day reconciles only its own activity.

**Built today:**
- **Full wallet ledger (§14.3, rule #4).** `OrdersDao.createOrder` now posts
  **two** wallet legs for every registered sale — a **debit of the order total**
  and a **credit of the amount paid** (reusing `topup_cash`/`topup_transfer` by
  method, so no CHECK-widening migration). Net = paid − total (0 when fully
  paid, negative = owes). This closes the old gap where fully-paid cash sales
  skipped the wallet entirely. Walk-ins still bypass the wallet (rule #14). The
  Funds Register credit is unchanged and independent — separate ledgers, no
  double-count.
- **Pending-first lifecycle (§19.5).** `OrderService.addOrder` creates orders as
  `'pending'` and no longer stamps `completedAt`; Confirm (`markCompleted`) owns
  that. Money is booked at checkout regardless of status.
- **Refund-day-dated reversal (§19.7 / §23.5).** `markCancelled` now takes a
  `businessDate` (the refund day) and (a) **reverses both wallet legs** so the
  customer's wallet returns to its pre-sale balance, and (b) dates the Funds
  Register **void-debit to that refund day**, not the sale's original day — so a
  closed day is never reopened and today's till matches the cash that left it.
- **Orders UI.** Pending populates; a real **Refund** button (Manager/CEO via
  `sales.cancel`) replaces the old Cancel — it **gates on an open funds day**
  for the order's store (§23.8, same as the POS gate), requires a reason, uses
  the `ORD-` number, and calls `markAsCancelled` with today's business date.
  Removed the no-op refund stub, the receipt-modal refund, the Pending
  **Outstanding** stat card, and the per-order net-paid **Owes** badge. Owing
  now shows only via the live **wallet-debt badge** (balance < 0).

**Files touched:**
- reebaplus_master_plan.md (§14.3, §19.2, §19.5, §19.7, §23.5, §23.8)
- lib/core/database/daos.dart (createOrder dual legs; markCancelled rework)
- lib/shared/services/order_service.dart (addOrder pending; markAsCancelled businessDate)
- lib/features/orders/screens/orders_screen.dart (Refund flow + gate; removals)
- test/orders/order_service_money_math_test.dart (dual-leg + refund-day + lifecycle)
- test/orders/pr_4c_test.dart, test/wallet/wallet_logic_test.dart,
  test/sync/dispatch/orders_dao_cancel_dispatch_test.dart (businessDate arg; one
  obsolete "skips wallet write" test updated to assert the two legs)

**Database changes:** None — reused existing `topup_cash`/`topup_transfer` and
`refund`/`void` wallet reference types; no schema or migration.

**Master plan sections covered:** §14.3, §19.2, §19.5, §19.7, §23.5, §23.8.

**Plan updates made during session:** §14.3 made the dual-leg rule explicit;
§19.2 dropped "Outstanding"; §19.5 documented revenue-at-checkout + operational
Completed; §19.7 added refund-day dating + open-day requirement; §23.5/§23.8
matched the refund rules. (All reviewed by the user before coding.)

**Tested:** analyze clean (only the 18 pre-existing `avoid_print` infos in a
test helper). `flutter test`: **269 passed, 58 skipped, 0 failed** — incl. new
tests for the four sale-type wallet legs, refund reversing both legs, the
Funds void landing on the refund day (sale day untouched), and the lifecycle.

**Known issues / left open:**
- **v2 RPCs (flag OFF):** `pos_record_sale_v2` still mints only the wallet
  debit, and `pos_cancel_order` doesn't yet honour `p_business_date` or reverse
  the payment leg — documented inline as "don't enable until updated" (R2).
- Cloud migration **0068** (`fund_day_closings`, Session 49) is still **unpushed**
  — must precede the v27 app schema reaching any device.

**Next session should:** on-device check of a registered-customer sale's wallet
history (two legs), the Pending → Confirm flow, and a Manager/CEO refund (incl.
the open-day block); then resume the Ring 0 backlog.

---

## Session 50 — 2026-06-01 — Ring 0 #5: Orders refund — Funds Register reversal (data layer) + §19 plan change

**Built today (data layer + plan; Orders UI is the next step):**
- **Funds Register reversal on cancel/refund (Ring 0 #5, §19.7).** `markCancelled`
  already restored inventory, voided the payment, and refunded the wallet — but
  never took the money back out of the Funds Register account the sale credited.
  Added a compensating **`fund_transactions` 'void' debit** per original 'sale'
  credit (same account + business_date; the ledger is append-only, so we append
  rather than mutate). The account's expected balance returns to pre-sale, so
  Close Day (§23.6) no longer reports a phantom surplus. v1 path only — noted
  that the v2 `pos_cancel_order` RPC must mint this server-side if that flag is
  ever enabled (mirror of createOrder's R2).
- `OrdersDao` gained `FundTransactions` in its accessor (for the void append).

**Plan change (user, 2026-06-01) — §19 Orders:**
- §19.7: the Pending order's reversal action is a single **Refund** button that
  **replaces** the former Cancel. Reason required; inventory restored; full
  refund (wallet auto / cash logged); reverses the funds credit; order → Cancelled.
- §19.8: **Refund removed from the Completed tab** — Completed is read-only; all
  refunds happen from Pending before confirm. Post-completion return = new order.
- Rider (per user): Phase 1 = name shown on the receipt only; logistics Phase 3
  (already what §19.5 said — no change needed).

**Findings while scoping the Orders screen (for the UI step):**
- The **Confirm flow + Empty Crates modal already exist** — Pending's
  "mark delivered" opens `CrateReturnModal` then `markAsCompleted` (§19.5 built).
- The current **Refund button on the Cancelled tab is a no-op stub**
  (`_processRefund` just shows a toast — no DAO write). The *real* reversal is
  `markCancelled`, fired by the Pending **Cancel** button.
- **`addOrder` creates orders as `'completed'`**, so the Pending tab is currently
  never populated — diverges from §14.4/§19.5 ("order lands in Pending"). The
  checkout→Pending lifecycle fix is the prerequisite for the Pending-tab UI to
  matter. `markCompleted` already owns `completedAt`, so the fix is: addOrder →
  `'pending'` + no completedAt; Confirm sets it.

**Open (next focused step — Orders UI + lifecycle):** swap Pending's Cancel
button for a Refund button (reason + wallet/cash, calling the now-complete
`markCancelled`; fix the raw-UUID/empty-staffId/hardcoded-reason bugs the PIVOT
flagged); delete the no-op Cancelled-tab refund stub; flip `addOrder` to create
`'pending'`. Flagged for review before the lifecycle change lands.

**Tested:** analyze clean (lib/ clean; 18 pre-existing test-helper infos).
`flutter test`: **266 passed, 58 skipped, 0 failed** (+3 = the new cancel/refund
funds-reversal tests in order_service_money_math_test.dart).

**NOT committed** per the standing instruction.

---

## Session 49 — 2026-06-01 — Ring 0 #4: Funds Register Close Day + reconciliation

**Built today:**
- **Close Day (§23.6) — the day-close + per-account cash reconciliation.** When a
  Manager/CEO closes a day, for each active account the app records a
  reconciliation snapshot: **expected** (the account's running balance =
  SUM(signed_amount_kobo) at close), **counted** (what they entered — cash
  counted for the Cash Till, amount withdrawn for POS/bank), and **variance**
  (counted − expected; non-zero = shortage/surplus). The day header flips to
  `status='closed'` with `closedBy`/`closedAt`. All in one transaction.
- **New synced table `fund_day_closings`** (schema **v27**) holds those
  per-account snapshots — the cash-audit half the Daily Reconciliation Report
  (§25.9, Ring 3) will read. One row per (day, account), `UNIQUE(fund_day_id,
  funds_account_id)`. Wired into `_syncedTenantTables`, `_pullOrder`, a hot-path
  index, the bump trigger, and a `fundDayClosingsProvider` stream.
- **New-day-blocked guard (§23.8).** `openDay` now throws if a previous day for
  the store is still unclosed (`getUnclosedDayBefore`) — the Open-Day twin of
  the existing already-open guard. A closed prior day unblocks the next.
- **Mismatch notification (§26.4).** When any account's variance is non-zero,
  closeDay fires a `funds_mismatch` alert (severity `alert`) to the CEO (new
  `UserBusinessesDao.getCeoUserId`); falls back to the closer if no CEO resolves
  locally, so the alert is never broadcast to roles that can't see Funds.
- **Activity log.** closeDay writes a `funds.close_day` log (the permission was
  previously seeded-but-dead) — "Closed the day", or "… — funds mismatch
  flagged" when off.

**Files touched:**
- lib/core/database/app_database.dart (new `FundDayClosings` table; @DriftDatabase
  table + dao registration; `_syncedTenantTables`; hot-path index; schemaVersion
  26→27; v27 onUpgrade block, idempotent like v21)
- lib/core/database/daos.dart (`FundDaysDao.closeDay` + `getUnclosedDayBefore` +
  openDay guard; new `FundDayClosingsDao`; `UserBusinessesDao.getCeoUserId`)
- lib/core/providers/stream_providers.dart (`fundDayClosingsProvider`)
- lib/core/services/supabase_sync_service.dart (`_pullOrder` += fund_day_closings)
- app_database.g.dart / daos.g.dart (drift codegen)
- supabase/migrations/0068_fund_day_closings.sql (NEW — see below)
- test/funds/funds_register_dao_test.dart (+8: closeDay math, shortage→mismatch
  notification, sync enqueue, the §23.8 block/unblock guards, error guards)
- test/database/migration_upgrade_test.dart (+1: v26→v27 table creation)

**Database changes:**
- Local: schema **v27** adds `fund_day_closings` (additive; no rebuild of
  existing tables). `FundDays` comment corrected — it IS mutable on close in
  Phase 1 now (not Phase 2).
- Cloud: **0068_fund_day_closings.sql written but NOT pushed** — additive table +
  RLS + realtime + appends the table to `pos_pull_snapshot`. **DEPLOY ORDER: it
  must be pushed before the v27 app reaches a device**, or the fund_day_closings
  upserts would 42P01 cloud-side (the same class as the v25/0066 issue). Left for
  review.

**No UI yet.** This is the data layer + reconciliation math + guards (the Ring
0/1 "funds-debit/close primitive"). The Close Day *screen* and the Daily
Reconciliation Report (§25.9) are later items.

**Tested:** `flutter analyze` clean (18 pre-existing `avoid_print` infos in a test
helper). `flutter test`: **263 passed, 58 skipped, 0 failed** (+8 = the new Close
Day + migration tests).

**NOT committed** per the standing instruction — left in the working tree for
review. Cloud 0068 is NOT pushed (deploy-order note above).

---

## Session 48 — 2026-06-01 — Ring 0 #3: money-math regression net + sync.view real-time fix

**Built today:**
- **Fixed: the Sync Issues access toggle didn't sync in real time across devices.**
  Granting `sync.view` to a non-CEO role worked locally but never reached other
  devices. Root cause was cloud-side, not UI: `role_permissions.permission_key`
  has a FK to `permissions(key)` (migration 0042), and `sync.view` was in the
  LOCAL catalogue (v26) but NOT the cloud — migration 0067 had been left unpushed
  as "optional." So the grant's enqueued upsert was rejected on the FK and sat
  erroring in the queue. Confirmed by diffing the local default permission keys
  against the live cloud table: `sync.view` was the ONLY local-only key. Fix:
  **pushed 0067** (additive, idempotent); verified present. The errored grant now
  lands on the next queue retry. No Dart change — the local catalogue, grant/
  revoke enqueue, and the reactive provider chain were all already correct.
- **Money-math consistency regression net (Ring 0 #3).** `OrderService.addOrder`
  — the production cart entry point — had zero test coverage. Added
  service-layer tests that drive `addOrder` and assert the real persisted rows
  (orders, payment_transactions, wallet_transactions, fund_transactions):
  - **cash / mixed / credit / wallet** classification via `_resolvePaymentType`.
  - **partial payment → wallet debit == total − paid** (the `_resolveWalletDebit`
    residual), with the cash portion crediting the Funds account.
  - **fully-paid registered cash sale writes ZERO wallet rows** (net-zero).
  - credit & wallet sales credit NO Funds account and write NO payment row.
  - money-invariant guards: a paid sale with no Funds account / no businessDate
    throws; a wallet/credit sale with no customer throws (hard rules #5 / #14).
  - **funds expected balance:** open day (opening credit) + a sale credit →
    `getBalanceFor == 700,000 == SUM(signed_amount_kobo)` over the account/day.

**Files touched:**
- test/orders/order_service_money_math_test.dart (new — 8 tests, all green)
- test/checkout_page_test.dart (the 2 render smoke-tests stay skipped — see below)
- supabase/migrations/0067_sync_view_permission.sql (comment corrected: REQUIRED,
  not optional, because of the FK — and pushed)
- BUILD_LOG.md, Session 44 notes corrected (0067 is now pushed)

**Database changes:**
- Cloud only: pushed 0067 → `public.permissions` now has the `sync.view` row.
  No local schema change (still v26).

**Tested:**
- `flutter analyze` clean (18 pre-existing `avoid_print` infos in a test report
  helper — untouched).
- `flutter test`: **255 passed, 58 skipped, 0 failed** — the +8 over the prior
  baseline are exactly the new money-math tests. (The "2 skip" noted in an
  earlier summary undercounted; the whole-suite skip total is and was 58.)

**Decision — the 2 `checkout_page_test` widget tests stay skipped.** PIVOT line
554 cited them as evidence of the OrderService coverage gap. I attempted to
un-skip them (disposed the ProviderContainer before `db.close` to cancel the
`walletBalancesKoboProvider` stream), but the current — much larger — CheckoutPage
still deadlocks in a bare harness: other DB-backed streams need full data
scaffolding (seeded business/store/funds + a populated cartProvider) to settle.
These are render smoke-tests with zero money-math value, so resurrecting them is
a widget-harness chore, not part of the regression net. The coverage they stood
in for now lives in order_service_money_math_test.dart. Re-skipped with an honest
updated comment (the old "unblocks after PR 5" note was stale).

**Still open:** Ring 0 #4 — Funds Register Close Day + expected-vs-actual
reconciliation (the next Ring 0 item; needs closing-amount columns + a `closeDay`
DAO + the "new day blocked until previous Close Day" guard).

**Plan update (mid-session, no code):** at the user's request, expanded master
plan §25 — the **Daily Reconciliation Report** now spells out the daily roll-up
(SKUs sold, Close Day cash audit with fund-shortage/misappropriation flags,
empty crates, debts, expenses) and a new **§25.9 period-card drill-down** (tap a
Day/Week/Month/Year card to open that span's reconciliation). The **Sales Report
card is kept** (the user initially suggested removing it — flagged that it's a
distinct planned report; they agreed to keep). Build order unchanged: this stays
a **Ring 3** item, after Close Day (in progress) and Daily Stock Count produce
its data — so no feature code was written, only the plan was updated.

**NOT committed** per the standing instruction — left in the working tree for
review. Cloud-side, 0067 IS pushed (it fixed the live real-time bug).

---

## Session 47 — 2026-06-01 — Empty Crates tab hidden by a business-type casing mismatch

**Built today:**
- Fixed a bug where the Empty Crates tab (and the "Total Crates" summary card) never showed for a Beer-distributor business — first noticed because a Manager couldn't see it.
- Real root cause (found with an on-device diagnostic, NOT roles or sync): the business's stored type was `Beer Distributor` (capital D), but the tab's gate compared exactly against `Beer distributor` (lowercase d, the canonical value in `business_types.dart`). Capital-D ≠ lowercase-d, so the gate was false for everyone in that business, regardless of role. The value came from an older onboarding build — current builds store the canonical lowercase, so no live code path still produces it; it's legacy data.
- Fix: added one shared helper `isCrateBusiness(String? type)` in `business_types.dart` that compares case-insensitively (trimmed), and routed both crate gates through it (Inventory Empty Crates tab + Customer detail Crates tab). Resilient to the legacy casing without a risky data migration of synced `businesses` rows.
- Non-Bar/Beer businesses still never see crate features (§13 preserved) — the helper only matches Bar / Beer distributor.
- Note: an earlier guess this session (a membership-aware business-id provider for a stale-`businessId`-pointer theory) was REVERTED — the diagnostic showed the pointer resolved correctly, so that change was unrelated and not kept.

**Files touched:**
- lib/core/data/business_types.dart (new `isCrateBusiness` helper)
- lib/features/inventory/screens/inventory_screen.dart (gate uses the helper)
- lib/features/customers/screens/customer_detail_screen.dart (gate uses the helper)

**Database changes:**
- None. (The drifted `Beer Distributor` row was left as-is; the gate is now casing-tolerant.)

**Tested:**
- `flutter analyze` on all changed files — no issues.
- On-device (user, 2026-06-01): Empty Crates tab now appears in the Beer-distributor business. Confirmed working.

**Known issues / left open:**
- Latent data-casing issue: that business's stored type is `Beer Distributor`, which is NOT in `kBusinessTypes`, so CEO Settings > Business Info may not pre-select it correctly. Not fixed here (would need a normalisation of the synced row). Flag for a later session if it bites.

**Next session should:**
- Confirm the fix on-device, then continue Funds Register Phase 1 work.

---

## Session 46 — 2026-06-01 — System-nav overflow sweep (edge-to-edge safe areas)

**Built today:**
- Fixed widgets that were painting *underneath* the phone's bottom system-navigation
  area on real devices. The app runs edge-to-edge on Android 15 (targetSdk 35), which
  no longer reserves space for the nav bar, so anything pinned to the bottom that didn't
  account for the safe-area inset slid under it.
- The fix keys off the device's actual bottom inset (`MediaQuery.padding.bottom`, via
  `SafeArea` or the project's `context.bottomInset` helper), so it self-adjusts: a big
  gap on phones with the 3-button nav bar, a thin gap on phones using swipe-to-home
  gestures, and the home-indicator height on iPhone. One fix, both nav styles.
- Ran as a multi-agent audit across every screen cluster (POS, inventory, orders,
  customers/payments/expenses/funds, dashboard, stores/staff, auth, settings, sync,
  shared dialogs). 4 clusters were already inset-safe (root layout, dashboard, auth,
  sync/diagnostics); 7 had real overflows.
- Two pre-existing layout bugs were caught and fixed along the way: the Receive Delivery
  sheet was padding its bottom bar twice (a `SafeArea` on top of an inset that already
  included it), and the Add Customer sheet was running the raw inset through the
  font/size scaler so it stretched or shrank depending on screen width.

**Follow-up — modal sweep (same day):**
- Re-audited every modal / dialog / bottom sheet app-wide (65 entry points across 27
  files), orders screen first. Fixed the orders-screen receipt sheet and the
  customer-detail receipt sheet (footers sat under the nav), and aligned two shared
  modals (notifications, user tips) to the project inset idiom.
- IMPORTANT LESSON (now permanent in CLAUDE.md): `showModalBottomSheet(useSafeArea: true)`
  wraps the sheet in `SafeArea(bottom: false)` — it protects top/left/right but does NOT
  inset the bottom. A sweep agent wrongly assumed it covered the bottom and deleted the
  nested `SafeArea(top: false)` from the two receipt sheets, which would have RE-broken
  them. Caught by reading the Flutter source (bottom_sheet.dart line 1121), then fixed
  both by adding `context.bottomInset` to the footer padding instead. flutter analyze clean.

**Follow-up 2 — REAL root cause + full sweep (same day, user-confirmed on-device):**
- The receipt buttons were STILL under the system nav on a physical device even after
  the `context.bottomInset` fix. Root cause (proven via Flutter source + screenshot): a
  `Scaffold` zeroes `padding.bottom` for its WHOLE body whenever it has a
  `bottomNavigationBar` — even a zero-height one (`scaffold.dart`:
  `removeBottomPadding: widget.bottomNavigationBar != null`). `MainLayout`'s app nav bar
  is never null (renders `SizedBox.shrink()` when hidden), so EVERYTHING under MainLayout
  reads `MediaQuery.padding.bottom == 0`. That means `context.bottomInset`,
  `MediaQuery.padding.bottom`, and bottom `SafeArea` ALL silently read 0 there — every
  earlier "fix" was a no-op on-device.
- Fix: added `context.deviceBottomInset` (responsive.dart) — reads the inset from the raw
  `FlutterView` (`MediaQueryData.fromView(View.of(context))`), which no Scaffold can zero.
  User confirmed the orders receipt now clears the nav on a physical device.
- Swept all screens & modals (workflow, 8 clusters, ~62 fixes) to `deviceBottomInset` for
  any content that reaches the physical screen bottom (modals, pushed detail screens,
  drawer-accessed tabs). LEFT ALONE: the five bottom-nav tab-root BODIES (Home, POS,
  Inventory, Orders list, Cart) — the visible bar already insets them, so converting them
  would add a gap above the bar; and auth screens (they run before MainLayout). Caught two
  missed screens (sync_issues, profile). flutter analyze: No issues found.
- CLAUDE.md "Safe-area" section rewritten with the corrected root cause + `deviceBottomInset`
  decision rule.

**Files touched (layout-only, 19 + 4 modal):**
- lib/features/pos/screens/cart_screen.dart (saved-carts list)
- lib/features/inventory/screens/product_detail_screen.dart (Update Stock sheet button)
- lib/features/inventory/screens/stock_count_screen.dart (history sheets)
- lib/features/deliveries/widgets/receive_delivery_sheet.dart (removed double-padding)
- lib/features/customers/screens/customer_detail_screen.dart (Add Funds / Set Limit sheets)
- lib/features/customers/widgets/add_customer_sheet.dart (fixed scaled-inset bug)
- lib/features/staff/screens/staff_detail_screen.dart (action buttons in list)
- lib/shared/widgets/activity_log_screen.dart, lib/shared/widgets/notifications_modal.dart
- lib/core/settings/*.dart (9 list screens) + lib/core/theme/theme_settings_screen.dart

**Database changes:**
- None.

**Master plan sections covered:**
- None — cross-cutting UI polish, no feature scope change.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib` → No issues found. Diffs spot-checked by hand and a regression
  pass confirmed no double-padding, no top/status-bar changes, no logic changes.
- Not yet confirmed on a physical device by the user (the actual symptom is device-only).

**Known issues / left open:**
- On-device confirmation pending — verify on a 3-button-nav phone AND a gesture-nav phone.
- The working tree still carries Session 45's POS long-press feature (edit_item_modal,
  product_grid, product_preview_modal deletion) plus DB/sync/permission work from
  Sessions 43–45. This layout pass did NOT touch those; commit the inset fix separately
  if you want a clean, layout-only commit.

**Next session should:**
- After on-device confirmation, decide how to split/commit the layout fix vs. the
  pending Session 45 POS feature work.

---

## Session 45 — 2026-06-01 — POS long-press: persistent add-to-cart sheet + faster grid load

**Built today:**
- **Removed the 2-second loading delay on the POS screen.** The product grid had a
  hard-coded "minimum loading" timer that held the screen in its loading state for a
  full 2 seconds even after products were ready. Products now appear the moment the
  data arrives (the gentle 250ms fade-in stays).
- **Reworked the long-press modal on a product in POS.** Before, holding a product
  showed a read-only info card that vanished the instant you lifted your finger
  ("Release to close"). Now holding a product opens the same quantity + discount sheet
  used when you tap a line in the cart: it stays open until you confirm or cancel, has
  the quantity box with −/+ (and ±0.5 for products sold in fractions), the %/₦ discount
  field (role-capped, same as the cart), and "Add to Cart" / "Cancel" buttons. Adding
  is fully wired — it sets the cart to the chosen quantity, applies the discount, and
  shows the usual added / stock-limit message.
- **Capped the quantity at available stock.** You can't put more of a product in the
  cart than the count shown on its POS card. The quantity field represents the new
  total for that product (pre-filled with whatever's already in the cart), the −/+ and
  ±0.5 buttons stop at the stock count, and a typed-in over-limit number snaps back
  down. A caption shows "X in stock — quantity can't exceed this." The same live cap
  was applied to the cart's tap-to-edit sheet for consistency (it previously only
  clamped silently on Save).

**Files touched:**
- lib/features/pos/controllers/pos_controller.dart
- lib/features/pos/widgets/edit_item_modal.dart
- lib/features/pos/widgets/product_grid.dart
- lib/features/pos/widgets/product_preview_modal.dart (deleted — replaced by the edit sheet)

**Database changes:**
- None.

**Master plan sections covered:**
- §12 (POS), §13.2 (per-line discount + role cap) — reused the existing cart-edit modal.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze` clean on the touched files and the wider POS feature. On-device
  pass still pending.

**Known issues / left open:**
- Long-press → Add to Cart *sets* the product's cart quantity (it doesn't add on top of
  what's there) — same behaviour as the cart's tap-to-edit sheet. Worth a glance
  on-device to confirm it reads naturally from the grid.

**Next session should:**
- Verify the new long-press sheet on the emulator (qty, ±0.5 visibility, discount cap,
  the stock cap / snap-back, and the "X in stock" caption), then move on.

---

## Session 44 — 2026-06-01 — Sync-error fix (deploy 0066) + Sync Issues access toggle + CEO Settings search

**1. Fixed the live sync error (PGRST204 "could not find after_json").** The v25
app was pushing activity_logs rows with the new generic columns, but cloud
migration **0066 had not been pushed** (it was left for review). Pushed it.
While applying, hit a second issue: the cloud `enforce_append_only` trigger on
activity_logs still listed **`warehouse_id`** in its immutable-column args
(renamed to store_id in 0045, never updated), so the backfill UPDATE raised
42703. Updated 0066 to drop that trigger before the backfill and re-create it
with the corrected new-shape column list (store_id + the generic columns) —
which also repairs that **latent pre-existing bug** (any future activity_logs
void/update would have hit it). Re-pushed; verified cloud now has
entity_type/entity_id/before_json/after_json + notifications.severity, and the
trigger no longer references warehouse_id. The failing queue items now succeed.

**2. Sync Issues access toggle (CEO Settings).** Previously Sync Issues was
gated CEO-only on `settings.manage` with no way to grant it to others. Added a
new `sync.view` permission (catalogue + schema **v26** local re-seed migration;
cloud **0067** adds the key to the cloud catalogue — **pushed**, see fix #4). New
`canViewSyncIssues(ref)` helper = `sync.view` grant **OR** current user is CEO
(CEO always has access without needing the grant; avoids a migration-time
grant + sync-leak). Re-gated all four entry points (screen guard, sidebar item,
sync badge, banner) to it. New **Sync Issues access** toggle screen (mirrors
Activity Logs access — CEO locked on, other roles toggle the synced sync.view
grant) + a tile in CEO Settings.

**3. CEO Settings search.** The CEO Settings menu is now a stateful screen with
a search box at the top that filters the section tiles by title/subtitle.

**4. Fixed: Sync Issues toggle didn't update in real time across devices.**
Granting `sync.view` to a non-CEO role worked locally but never reached other
devices. Root cause: cloud `role_permissions.permission_key` has an FK
(`REFERENCES public.permissions(key) ON DELETE RESTRICT`, from 0042). The local
catalogue had `sync.view` (v26) but the **cloud catalogue did not** — 0067 was
left unpushed as "optional." So the grant's enqueued upsert was **rejected
cloud-side on the FK** and sat erroring in the queue; the other device never saw
it. Confirmed by diffing the local default permission keys against the live
cloud `permissions` table — `sync.view` was the only local-only key (the Session
43 staff/stock split keys were all already in the cloud, so they were unaffected).
Fix: **pushed 0067** (additive, idempotent) so the cloud has `sync.view`;
verified present. The previously-errored grant upsert now succeeds on the next
queue retry. Corrected 0067's header comment — it is **required**, not optional,
precisely because of that FK. No Dart change: the local catalogue, grant/revoke
enqueue, and the reactive provider chain were already correct.

**Master plan:** §10.1 documents the Sync Issues access toggle + the settings
search box.

**Tested:** analyze clean (18 pre-existing infos); full suite **247 pass / 2
skip / 0 fail** (bumped three permission-count assertions 31→32 for the new
`sync.view` catalogue row; CEO *grant* count unchanged at 31 — the isCEO gate
covers it). No Drift codegen needed (catalogue row + version getter only).

**NOT committed** per the standing instruction — left in the working tree for
review (still interleaved with the parallel Sessions 40–43 work + the Session 43
Ring 0 #2 changes). Cloud-side, **0066 and 0067 ARE pushed** (each fixed a live
bug — 0066 the PGRST204, 0067 the real-time toggle). No local git commits yet.

---

## Session 43 — 2026-06-01 — Ring 0 #2: Activity Logs generic schema + notification severity + log/notify helpers

**Goal (PIVOT_PLAN §8.0 Ring 0 #2):** land the FINAL activity_logs shape and the
notifications.severity column + thin helpers BEFORE building any Ring 1 feature
that logs/notifies, so each feature satisfies the log+notify invariant in one
call and never needs a re-migration.

**Schema v25 (local) + cloud 0066 (NOT pushed — see deploy note):**
- `activity_logs` (§24.4): added generic `entity_type` / `entity_id` +
  `before_json` / `after_json`; **locally dropped** the six per-entity FK columns
  (order/product/customer/expense/delivery/wallet_txn) + the "<=1 set" CHECK,
  backfilling `entity_type`/`entity_id` from whichever FK was set. Kept
  `store_id` (the §24.2 store filter needs it). The local drop also removes the
  `delivery_id` FK that blocks the future Deliveries-table removal (Ring 3).
- `notifications` (§26.2/§1.3): added `severity` ('info'/'warning'/'alert',
  default 'info', CHECK) for the card colour.
- onUpgrade v24→v25 drops the activity_logs append-only triggers first (they
  reference the columns being dropped), rebuilds via `TableMigration` with a
  column-transformer backfill, then re-creates the triggers from the NEW
  immutable column set. **Idempotent** — each rebuild is guarded on the old
  shape still being present, so it's safe on partial-state DBs (and the
  revert-then-re-upgrade migration tests, which leave activity_logs current).
- Extracted `_ledgerTriggerStatements()` so onCreate and the v25 rebuild share
  one trigger definition. Updated the `_LedgerImmutability('activity_logs', …)`
  column list to the new shape.

**Helpers (DAOs):**
- `ActivityLogDao.logActivity({action, description, staffId, storeId,
  entityType, entityId, before, after})` — canonical; serializes before/after to
  JSON; enqueueUpsert. The legacy `log({orderId, productId, …})` is kept as a
  thin wrapper that folds the per-entity params onto (entityType, entityId), so
  all ~56 existing call sites + `ActivityLogService.logAction` keep working
  unchanged. `getForOrder/Product/Customer/Expense/Delivery/WalletTxn` rewritten
  to query (entity_type, entity_id).
- `NotificationsDao.fireNotification({type, message, severity, recipientUserId,
  linkedRecordId})` — canonical; Ring 1 features fire §26.4 events through it.
- Updated `ActivityLog` model + `activity_log_screen` filter + `addExpense`'s
  inlined activity-log companion to the generic shape.

**⚠️ Deviation flagged (cloud side):** cloud 0066 is **additive only** — it adds
the generic columns + backfills + adds severity, but does NOT drop the six
cloud FK columns. Reason: the `pos_record_expense` RPC (0011/0045) still INSERTs
`activity_logs(…, expense_id, …)`, so dropping `expense_id` cloud-side would
break it, and re-defining a production RPC unsupervised was not safe. The local
schema is the final shape; the cloud column drop + RPC rewrite is a deliberate
follow-up to bundle with the Ring 1 Expenses RPC pass / Ring 3 Deliveries
removal. Sync is unaffected (activity_logs/notifications aren't in the push
column whitelist; the v25 app pushes the new column set and ignores the
vestigial cloud columns on pull). One minor consequence: expense logs created
via the *RPC* path sync back with `entity_type` NULL until the RPC is updated
(cosmetic; the "View record" jump for expenses is Ring 3 anyway).

**Tested:** `flutter analyze` clean (18 pre-existing avoid_print infos only);
full unit+widget suite **247 pass / 2 skip / 0 fail**. New tests: v24→v25
migration upgrade (backfill + column shape + severity default + re-created
append-only trigger), logActivity entity/before/after round-trip,
fireNotification severity (stored / defaulted / CHECK-rejected).

**DEPLOY ORDER (for the morning):** push cloud `0066` (`supabase db push`)
BEFORE running the v25 app build on any device — the new app's payload includes
entity_type/severity, which must already exist cloud-side. Then rebuild the
emulator/devices.

**NOT committed / NOT pushed** per the standing instruction — left in the
working tree for review. (Note: the tree also carries parallel Sessions 40–42
work — product-unit widen, biometric fix, Product Details realtime sync — e.g.
`stream_providers.allSuppliersProvider` and co-edits in `product_detail_screen`
— none of which is mine.)

**Known follow-ups:** (1) drop the vestigial cloud activity_logs FK columns +
rewrite `pos_record_expense` to set entity_type/entity_id; (2) Ring 0 #3 (the
money-math regression net) is next before Ring 1.

---

## Session 42 — 2026-06-01 — Product Details: full realtime sync (fields, sales, dropdowns)

**Why this session:**
The Product Details screen didn't update in real time. It loaded everything once
into local state via one-shot queries and never watched a stream, so an edit /
stock change / sale on another device never reflected on an open detail screen
(the §5 anti-pattern). Three rounds: (1) make every field live, (2) make the
category/manufacturer/supplier dropdown lists live, (3) make a sale register live.

**Built today:**
- Every product field now syncs live. A single products-with-stock stream (LEFT
  join, so the row is always present even at 0 stock in the selected store) drives
  a `ref.listen` that re-seeds name, description, all prices, manufacturer,
  supplier, category, unit, low-stock, size, expiry, the fractional + track-empties
  toggles, crate value, image, sales target, plus live quantity / status badge /
  stock value. Mid-edit safe: stock still updates while editing, but editable
  fields are re-seeded only when NOT editing, so an incoming sync never clobbers
  unsaved input; the edit baseline is kept fresh so Cancel reverts to synced values.
- Dropdown OPTION lists (categories / manufacturers / suppliers) are live — an add
  or rename on another device relabels without reopening the screen.
- Sales register live. The Sales Summary refreshes the moment an order is recorded
  or synced in (driven off the orders stream, not just stock-total changes, so an
  other-store sale or a missed stock tick still updates the numbers). Stock quantity
  was already live (a sale writes a `stock_transactions` row the products stream
  watches).

**Files touched:**
- lib/core/database/daos.dart (`watchProductsWithStock({String? storeId})`)
- lib/core/providers/stream_providers.dart (`productsWithStockProvider`, `allSuppliersProvider`)
- lib/features/inventory/screens/product_detail_screen.dart (4 `ref.listen`s in build + `_seedFieldsFrom` / `_reloadDerived` helpers)

**Database changes:**
- No new schema from this feature work. BUT the working tree had uncommitted schema
  v25 changes (someone's Ring 0 #2 / §24.4 / §26.2 work — activity_logs generic
  entity shape + notifications.severity, mirroring migration 0066) where
  app_database.dart was edited but `build_runner` had never been re-run, so
  app_database.g.dart was stale and the project did NOT compile (TextColumn type
  errors on the new activity_logs columns). Ran `dart run build_runner build
  --delete-conflicting-outputs` (user-approved) to regenerate against v25 + the
  locked drift 2.28.2. Build is now clean. That regenerated app_database.g.dart /
  daos.g.dart diff belongs with whoever commits the v25 schema, not this feature.

**Tested:**
- `flutter analyze lib/` → No issues found.

**Known issues / left open:**
- On-device check pending: with the detail screen open on two devices, edit a field
  / make a sale / rename a manufacturer on one and confirm the other updates live.
- NOTE: the working tree is carrying several other people's uncommitted changes
  (biometric-login fix, the v25 schema, a debug print in login_screen.dart) — keep
  this feature's commit scoped to the three files above (+ the regen if needed).

**Next session should:**
- Verify the realtime updates on the emulator across two devices.

---

## Session 41 — 2026-06-01 — Biometric button intermittently missing on PIN login

**Built today:**
- Fixed the fingerprint/biometric button sometimes disappearing from the PIN
  entry login screen even though biometrics were enabled. It now stays put, and
  recovers on its own if it ever does drop (no app restart needed).

**Files touched:**
- lib/features/auth/screens/login_screen.dart

**Database changes:**
- None.

**Master plan sections covered:**
- §7 (Login flow) — biometric sign-in affordance.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze` on login_screen.dart — clean.
- Auth widget test (who_is_working_screen_test.dart) — passes.
- Root cause: the availability check ran `canCheckBiometrics || isDeviceSupported()`
  with `canCheckBiometrics` first. That call can transiently throw on cold start
  or during a temporary biometric lockout; the throw hit a silent catch before
  the stable `isDeviceSupported()` check could run, so the flag stayed false and
  the button vanished for the rest of the screen's life. Fix evaluates the two
  checks independently (a flake on one can't mask the other) and re-checks on
  app resume via a WidgetsBindingObserver.

**Known issues / left open:**
- On-device confirmation pending (verify on emulator with biometrics enabled).

**Next session should:**
- Confirm the button stays visible across cold starts / resume on the emulator.

---

## Session 40 — 2026-05-31 — Product unit CHECK widen (non-bottle units reach inventory) + Near Expiry card

**Built today:**
- Fixed the bug where only Bottle-unit products could be added to inventory. The Add / Edit Product form offered units (Can, Keg, …) that the database refused, so saving a non-bottle product silently failed the insert and it never showed up in stock. Widened the allowed unit list — Bottle, Can, PET, Sachet, Keg, Crate, Pack, Carton, Piece, Bag, Box, Tin, Other — and made the dropdowns and the database agree (one shared `kProductUnits` list).
- Added a "Near Expiry" card at the end of the Inventory summary-card row (the scrollable row at the top, all business types). It shows how many products are expired or within 30 days; tapping it filters the product list to those, soonest-expiry first.

**Files touched:**
- lib/core/database/app_database.dart (new `kProductUnits` list, widened `unit` CHECK, schemaVersion 23→24, `from < 24` table-rebuild migration)
- lib/features/inventory/screens/add_product_screen.dart (unit dropdown uses `kProductUnits`)
- lib/features/inventory/screens/product_detail_screen.dart (edit-mode unit dropdown uses `kProductUnits`)
- lib/features/inventory/screens/inventory_screen.dart (Near Expiry card + `'expiry'` list filter)
- supabase/migrations/0065_widen_product_unit_check.sql (new)
- reebaplus_master_plan.md (§16.4 summary cards + Near Expiry; §16.5 unit list)

**Database changes:**
- `products.unit` CHECK widened to the 13-value list above. Local: schema v24 rebuilds the products table (`alterTable`) to apply the new CHECK. Cloud: `0065_widen_product_unit_check.sql` drops + re-adds `products_unit_check`.
- DEPLOYED 2026-06-01: `supabase db push` applied 0065 to the remote (0064 was already on remote from its own session, so only 0065 went up). Triggered by the user reporting a Can product that saved locally but failed to push — the cloud `products_unit_check` was still rejecting non-bottle units until this deploy. The failed sync-queue item clears on the next sync / retry.

**Tested:**
- `flutter analyze` clean on all four changed Dart files (full-project run shows only pre-existing `avoid_print` infos in test/database/roles_v13_report.dart).

**Known issues / left open:**
- Runtime confirmed 2026-06-01: a Can product saved locally (v24 fix works); the push failed only because cloud 0065 wasn't deployed yet. Now deployed — the stuck sync-queue item should push on the next sync / a manual retry from the Sync Issues screen.

**Next session should:**
- Confirm the previously-failed Can product now pushes (Sync Issues screen → retry) and syncs across devices.

---

## Session 39 — 2026-05-31 — Permission-toggle audit + wiring (dead/mis-wired toggles)

**Why this session:**
After the realtime-delete fix, the user found more permission toggles that did
nothing. Ran a wiring audit of all 29 permission keys (grep every key across
`lib/`, classify wired / dead / mis-wired). Findings + fixes:

**Mis-wired (toggle did nothing because it was tied to the wrong control):**
- **Product delete** was gated on `products.edit_price` (via `_canEdit`), so the
  `products.delete` toggle had no effect and turning off "edit prices" also hid
  the delete button. Added a `_canDelete` getter and gated the delete button on
  `products.delete`. Edit and delete are now independent. (Manager has both by
  default, so no behaviour change; the toggles now work.)

**Dead toggles on built features — now wired (user-approved):**
- **`staff.suspend` / `staff.change_role`** — Suspend and Change-role were both
  gated by `staff.invite` (the two perms were only used as activity-log labels).
  Split: Change role → `staff.change_role`, Suspend → `staff.suspend`, each
  button + its action guard. Both are CEO+Manager defaults (same set as
  `staff.invite`), so no default-visibility change.
- **`stock.view`** — now gates Inventory visibility: the sidebar item, the
  bottom-nav "Stock" tab (rewrote the hardcoded 5-way index math into a
  data-driven `tabOrder` list so a hidden tab can't desync the indices), and a
  screen-level guard. On for every role by default.
- **`stock.add`** — now gates the "Add stock" mode of the Update-Stock modal,
  separate from `stock.adjust` (which gates "Remove/adjust"). The modal opens if
  either is held; each mode chip shows only if permitted; save re-checks live.
  Defaults unchanged (Stock keeper + Manager hold both).

**Also gated this session (separate user request):**
- **Sync Issues** screen — was reachable by every role. Now CEO-only
  (`settings.manage`): the sidebar item, the drawer sync badge, and the sync
  banner's navigation are all gated, plus a screen-level guard. Mirrors the
  Activity Logs gating pattern.

**Dead toggles left as-is (feature not built yet — can't wire without building
out-of-scope Ring 1–3 work):** `customers.update`, `expenses.approve`,
`funds.close_day`, `reports.see_*` (4), `sales.cancel`, `shipments.manage`.
Noted for when those screens land. `customers.add` still doubles as the
Customers sidebar visibility gate (no separate `customers.view` exists) — left
as a known limitation.

**Files touched:**
- `lib/features/inventory/screens/product_detail_screen.dart` — `_canDelete`
  (products.delete) gate; `_canAddStock` + split Update-Stock modal.
- `lib/features/staff/screens/staff_detail_screen.dart` — split suspend /
  change-role gates.
- `lib/shared/widgets/app_drawer.dart` — Inventory gated on stock.view; Sync
  Issues item + sync badge gated on settings.manage.
- `lib/shared/widgets/main_layout.dart` — data-driven bottom nav; Stock tab
  gated on stock.view.
- `lib/shared/widgets/sync_banner.dart` — Sync Issues nav gated on settings.manage.
- `lib/features/inventory/screens/inventory_screen.dart` — stock.view guard.
- `lib/features/sync/screens/sync_issues_screen.dart` — settings.manage guard.
- `test/staff/staff_detail_screen_test.dart` — seed the split staff perms.

**Database changes:** none.

**Master plan updates:** §16.7 — added "Delete product" row, split "Update stock"
into "Add stock" / "Remove / adjust stock", documented each row's permission key
incl. `stock.view` gating Inventory visibility. §9.5 — Change-role / Suspend
gated by their own permissions, separate from `staff.invite`.

**Tested:** `flutter analyze` clean (only the 18 pre-existing avoid_print infos);
full unit+widget suite **244 pass / 2 skip / 0 fail** (staff widget test updated
for the split). On-device nav verification of the bottom-nav refactor still
recommended.

**Known issues / left open:**
- Bottom-nav refactor (data-driven tabOrder) covered by tests + analyze; a quick
  on-device pass switching tabs (and as a role lacking stock.view) is worth doing.
- Dead toggles for unbuilt features remain (listed above).

---

## Session 38 — 2026-05-31 — Recall saved carts when the cart is empty (§13)

**Built today:**
- Fixed the Cart screen so a saved cart can be recalled even when the current
  cart has no items. Before, the "Save Cart" and "Recall" buttons only appeared
  once the cart already had items in it, so a cashier who opened an empty cart
  had no way to load a cart they saved earlier. The empty-cart view now shows a
  "Recall" button under the "Cart is empty" message. (The "Save Cart" button
  stays in the items view only, since saving an empty cart is blocked anyway.)

**Files touched:**
- lib/features/pos/screens/cart_screen.dart

**Database changes:**
- None.

**Master plan sections covered:**
- §13 — Cart (per-cashier saved carts / recall).

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze` on the changed file: no issues. On-device emulator check of
  the empty-cart Recall flow still pending user confirmation.

**Known issues / left open:**
- None from this change.

**Next session should:**
- Pick up whatever the user prioritizes next.

---

## Session 37 — 2026-05-31 — Cloud completion of the realtime-DELETE fix (replica identity)

**Why this session:**
Continuing the Session 36 role-permission delete-sync fix. The user re-tested
the original symptom **across two devices/sessions**: CEO revokes a role's
"Activity Logs access" on device A, but the Manager on device B can still open
Activity Logs. Session 36's Dart-side realtime DELETE handler should have caught
this — so we traced why the live DELETE never arrives on device B.

**Root cause Session 36 missed (cloud-side):**
Supabase Realtime authorizes every change against the row's RLS SELECT policy
before broadcasting. For a DELETE, only the columns in the table's REPLICA
IDENTITY are present in the old record. The three hard-delete tables
(`role_permissions`, `saved_carts`, `notifications`) all have RLS policies that
filter by `business_id`, but their replica identity was the Postgres default =
primary key (`id`) only. So `business_id` is absent from a delete's old record,
the RLS check runs against NULL, fails, and Realtime **drops the DELETE event**
before any client sees it. Session 36's `_deleteLocalRowById` handler was
therefore effectively dead-on-arrival in production for these tables — the row
only cleared on the *other* device after a full snapshot reconcile (app
restart), never live. (Session 36 logged "Database changes: none" and did not
identify this.)

**Verified on the live DB before fixing** (via `supabase db query --linked`):
all three tables were in the `supabase_realtime` publication ✓ but on
`replica_identity = default(PK-only)` ✗ — confirming the gap was real, not a
guess.

**Fix (migration 0064):**
`ALTER TABLE … REPLICA IDENTITY FULL` on `role_permissions`, `saved_carts`,
`notifications`. The old record now carries `business_id` (and every column), so
Realtime can authorize the DELETE and deliver it live; Session 36's handler then
removes the row on the other device in real time. Soft-delete tables are
unaffected (they sync as UPDATEs, whose *new* record is always full). Pushed and
re-queried: all three now report `replica_identity = FULL`.

**Files touched:**
- `supabase/migrations/0064_replica_identity_full_hard_delete_tables.sql` (new).

**Database changes:**
- Remote: replica identity set to FULL on `role_permissions`, `saved_carts`,
  `notifications`. No schema/column/data change; additive and reversible.
  Remote migration head now 0064.

**Master plan sections covered:**
- §10.1/§10.2 (Activity Logs access + Roles & Permissions toggles), CLAUDE.md §5
  (sync invariants — incoming cloud DELETE applied local-only, no enqueue).

**Tested:**
- Live remote query confirms replica identity = FULL on all three tables.
- Session 36's Dart suite still green (the 3 new sync/divergence + snapshot-
  reconcile test files pass; full unit+widget suite 231 pass / 2 skip / 0 fail
  with `--exclude-tags=integration`).
- **Confirmed live (two-device):** CEO revokes the Manager's Activity Logs
  access on device A → the Manager loses it on device B. Bug resolved
  end-to-end.

**Known issues / left open:**
- After a replica-identity change, an already-running app may need to
  re-subscribe (app restart) before realtime picks up the new identity — worth
  remembering for any future replica-identity change.
- The Session 36 "cloud push conflicts on `id` for `role_permissions`" and
  `role_settings` divergence items remain open (unchanged by this session).
- The Dart-side work from Session 36 (+ the snapshot-reconcile additions) is
  still **uncommitted** — should be committed alongside migration 0064.

**Answer to "are there other settings with the same enable-works/disable-doesn't
asymmetry?":** Only writes that *hard-delete* a row can have it, and the app's
only `enqueueDelete` call sites are these same three tables. Of those, the only
settings-facing one is `role_permissions` — i.e. **every** Roles & Permissions
toggle and the Activity Logs access toggle, all fixed together here. The
`role_settings` limits (max discount / max expense / "allow viewing other
stores"), Appearance colour, auto-lock interval, and currency are **upserts**
(set a value), so their "disable" always propagated and was never affected.
Biometric login is intentionally device-local (never synced).

---

## Session 36 — 2026-05-31 — Debugging: role-permission toggle sync bugs

**Reported symptom:**
As CEO, granting a role access (e.g. "Activity Logs access" / a Roles &
Permissions toggle) worked, but **disabling it didn't stick** — the toggle
snapped back on. Then, on a follow-up toggle, the app **crashed** with
`SqliteException(2067): UNIQUE constraint failed: role_permissions.role_id,
role_permissions.permission_key`.

**Two distinct root causes found and fixed:**

**Bug 1 — realtime DELETE events were silently dropped (the "won't disable"
symptom).** `SupabaseSyncService.startRealtimeSync` subscribed to
`PostgresChangeEvent.all` but only ever processed `payload.newRecord` (an
upsert via `_restoreTableData`). A DELETE event carries the row in `oldRecord`
with an EMPTY `newRecord`, so DELETEs were never applied locally. Asymmetry was
the tell: INSERT/UPDATE echoes applied (enable stuck) but DELETE echoes dropped
(disable didn't). A revoke deleted the row locally, but a stale INSERT echo of
the prior grant resurrected it and nothing cleaned it up.
- *Fix:* the realtime callback now branches on `eventType`; a DELETE deletes
  the local row by `oldRecord['id']` via new `_deleteLocalRowById`, handling
  only the three hard-delete (`enqueueDelete`) tables — `role_permissions`,
  `saved_carts`, `notifications` — with typed Drift deletes (stream-reactive),
  and a logged no-op for any other table. Deletes locally WITHOUT enqueueing
  (§5 exception #1 — incoming cloud event; re-pushing loops). Also fixes a
  quieter bug: a revoke on one device now propagates to others over realtime,
  not only on the next full snapshot pull.

**Bug 2 — `role_permissions` keyed on a random per-grant `id` instead of its
logical identity (the 2067 crash).** A row's real identity is
`(role_id, permission_key)` (a UNIQUE constraint), but `id` is a fresh UUID per
grant. A grant→revoke→re-grant cycle (or two devices) mint different ids for the
same pair; the restore path's `insertOnConflictUpdate` keys on `id`, so a
divergent cloud id collided with `UNIQUE(role_id, permission_key)` and threw.
- *Fix A:* `RolePermissionsDao.grant` is now idempotent on
  `(role_id, permission_key)` — if the pair is already granted it's a no-op,
  so the blind insert can't itself throw 2067.
- *Fix B:* `_restoreTableData('role_permissions', ...)` drops any local row with
  the same `(role_id, permission_key)` but a different id before applying the
  incoming row, so the device converges on the cloud's id instead of crashing.
  Local-only, no enqueue (§5 exception #1).

**Files touched (code):**
- `lib/core/services/supabase_sync_service.dart` — realtime DELETE handling +
  `_deleteLocalRowById` (+ `@visibleForTesting` seam); restore reconciliation
  for `role_permissions`.
- `lib/core/database/daos.dart` — `RolePermissionsDao.grant` idempotency.

**Files touched (test):**
- `test/sync/realtime_delete_test.dart` (new) — 5 cases: DELETE applied for each
  hard-delete table, resurrection-race convergence, safe no-op default.
- `test/database/role_permissions_id_divergence_test.dart` (new) — 3 cases:
  grant idempotency, divergent-id restore converges (no 2067), same-id restore
  idempotent.

**Database changes:** none.

**Tested:** `flutter analyze` clean; full suite **239 passing / 58 skipped /
0 failing** (was 236 — +3 divergence tests; the 5 realtime-delete tests landed
in this session's earlier pass that took the suite 231→236).

**Known issues / left open (flagged, not fixed):**
- **Cloud push still conflicts on `id` for `role_permissions`.**
  `enqueueUpsert('role_permissions', row)` passes no conflict target, so the
  batched cloud upsert (`supabase_sync_service.dart` ~line 685) defaults to
  ON CONFLICT(id). If a divergent id is ever pushed, the cloud's
  `UNIQUE(role_id, permission_key)` rejects it (a caught, non-crashing push
  error — surfaces in Sync Issues). Fix A+B largely prevent divergence
  single-device; the durable fix is to key `role_permissions` on
  `(role_id, permission_key)` end-to-end (push conflict target, and/or
  deterministic ids derived from the pair). Deferred — needs a sync-behaviour
  change + possibly a re-key migration; out of scope for this hotfix.
- **`role_settings` has the same `id` + `UNIQUE(role_id, setting_key)` shape.**
  Its `set()` is already idempotent (reuses the existing id), so single-device
  divergence won't occur, but cross-device divergence could hit the same
  restore collision. Same restore reconciliation would harden it; not applied
  (no reported failure, keeping this surgical).

---

## Session 35 — 2026-05-31 — Ring 0: wholesaler-tier price fix (§12.2/§16)

**Built today:**
Fixed the shipped money bug where a wholesale customer was *shown* the
wholesale price but *charged* the retailer price. The cart was blind to the
active price tier: `CartService.addItem` always seeded the retailer price, and
the checkout staleness check re-priced every line against the retailer column —
so even a correctly-priced wholesaler line would have been silently reverted to
retailer at checkout. Threaded the selected tier end-to-end so the line is
priced, re-priced, and recorded at the right tier. First item of Ring 0 in the
re-sequenced build order (PIVOT_PLAN §8.0).

**Files touched (code):**
- `lib/shared/services/cart_service.dart` — `addItem` gained an optional
  `PriceTier tier` param; the ProductData branch now seeds
  `wholesalerPriceKobo` vs `retailerPriceKobo` by tier; the cart line Map now
  carries `'priceTier'` so it is self-describing through save/recall.
- `lib/features/pos/screens/pos_home_screen.dart` — `_addToCart` passes
  `tier: _controller!.selectedGroup` (the only real-product caller; covers both
  the CEO/Manager dropdown and customer auto-apply).
- `lib/core/database/daos.dart` — `CartLineSnapshot` gained a `priceTier`
  field (default `'retailer'`); `checkCartStaleness` re-prices against the
  line's own tier instead of the hardcoded `p.retailerPriceKobo`.
- `lib/features/pos/screens/checkout_page.dart` — `_detectCartStaleness` reads
  `item['priceTier']` and passes it into the snapshot.

**Files touched (test):**
- `test/pos/cart_tier_pricing_test.dart` (new) — 6 cases: wholesaler seed,
  retailer default + explicit, staleness re-prices against the wholesaler
  column (never retailer), wholesaler-customer tier, and discount clamps
  against the wholesaler line total.

**Database changes:**
- None. The tier rides inside the in-memory cart Map and the existing
  `saved_carts.cartData` JSON blob — no schema/migration, no new synced column.
  Quick Sale (legacy Map) lines are untouched and stay tier-agnostic.

**Master plan sections covered:**
- §12.2 (price tier auto-apply / dropdown) and §16 (Retailer/Wholesaler prices)
  now hold at the point of sale, not just on the product card.

**Tested:**
- `flutter analyze` on the 4 changed files + the new test — no issues.
- `flutter test` full suite — 231 passing / 58 skipped / 0 failing (the 58
  skips are pre-existing, incl. the two skip:true checkout widget tests).

**Known issues / left open:**
- `daos.dart` `StockTransactionDao._mapRow` still maps the Inventory History
  row's display `unitPriceKobo` to `p.retailerPriceKobo`. This is a
  reporting/display value on the stock-movement History tab, NOT a charge — out
  of scope for this charging bug. Flagged as a display-only follow-up for the
  Ring 3 Reports/History pass (a sale-driven movement arguably ought to show the
  actual sold price).
- `CartService.refreshProduct` is currently uncalled (dead) — its latent
  retailer-only refresh risk is moot until a caller is added.

**Next session should:**
- Continue Ring 0: land the generic `activity_logs` schema migration
  (entityType/entityId/before/after, row-copy) + `notifications.severity`
  column + `logActivity()`/`fireNotification()` helpers (with a migration
  round-trip test), and the OrderService/funds money-math regression net.
  Then Ring 1 starts with Funds Register Close Day + reconciliation.

---

## Session 34 — 2026-05-31 — Build-order re-sequencing (docs only, no code)

**Built today:**
A docs-only re-sequencing pass — no code. Validated a 7-part adversarial audit
against the live code and confirmed the findings are real: the wholesaler-tier
price bug at cart_service.dart:85-86 (wholesale customers see the wholesale price
but are charged the retailer price), Close Day is entirely absent (only the
seeded funds.close_day permission exists), the funds model in the planning docs
has drifted from the code, updateCustomer and _processRefund are still stubs, and
activity logging still sits on the old per-entity-FK shape. Then re-grouped all
remaining pivot work into Rings 0-3 (money-correctness first; logging,
notifications and funds-debit handled as per-feature invariants rather than late
end-passes), and resolved the four plan contradictions C1-C4 below.

**Files touched:**
- PIVOT_PLAN.md (new §8.0 re-sequence block + step-19 checkpoint fix + §9 decisions)
- reebaplus_master_plan.md (§3 build-order re-group + §23 Close Day reconciliation note)
- BUILD_LOG.md (this entry)
- NO code files touched.

**Database changes:**
- None.

**Master plan sections covered:**
- §3 (build order), §16 (POS/pricing), §23 (Funds Register / Close Day / §23.6 /
  §23.8), §26.4 (notifications), §1.3 (notifications.severity), Q2/Q6 decisions.

**Plan updates made during session:**
Re-sequenced the pivot build order into Ring 0/1/2/3 (money-correctness first;
logging/notifications/funds-debit as per-feature invariants), and resolved four
plan contradictions:

- **C1 — Close Day + reconciliation: restored to Phase 1.** Three-way
  contradiction: master plan §23.6/§23.8 (lines 1083-1106) specify Close Day +
  expected-vs-actual reconciliation as core Phase-1 spec with NO Phase-2 marker;
  pivot §8 step 17 and §23.2 sidebar list Open/Close/History/Accounts as one
  Phase-1 deliverable; but the §3 build-order parenthetical (line 107, dated
  2026-05-30) defers Close Day, reconciliation, and Funds History to Phase 2 —
  and the code matches the deferral (zero Close Day code, only the seeded
  funds.close_day permission at app_database.dart:2514). RESOLUTION: restore
  Close Day + reconciliation to Phase 1 (§23.6 is the source-of-truth chapter and
  carries no Phase-2 tag; reconciliation is the highest-value money control and
  the linchpin every money-reversing path debits into). Edit master plan line 107
  to move Close Day + reconciliation back into Phase 1; keep Funds History
  deferred to Phase 2 as an explicitly-marked lower-value view. Schedule Close Day
  as Ring 1's FIRST item so the funds-debit primitive exists before any reversal
  path. The FundDays table already has closedBy/closedAt/status scaffolding
  (app_database.dart:370-391); only closing-amount columns, a closeDay DAO method,
  and the reconciliation UI/math are missing. REVERSIBLE: if the user prefers
  Close Day in Phase 2, revert line 107, add an explicit "*(Phase 2)*" marker to
  §23.6/§23.8 so the chapter stops contradicting the index, remove the Ring 1
  Close Day item + the Ring 3 Daily Reconciliation Report, and drop the §26.4
  "previous-day-not-closed" / "mismatch-at-close" notifications.

- **C2 — Inventory mark is stale; Checkout overstated.** §3 marks Inventory "[ ]"
  (not started, line 106) while declaring it a Checkout prerequisite, yet Checkout
  is "[x]" done (line 108). Inventory is in fact substantially built (Add Product,
  Inventory list, Product Detail screens; tier price columns migrated in v18 and
  written from the form), so "[ ]" is stale; and the tier-pricing path is broken
  end-to-end (cart_service.dart:85-86 always seeds retailerPriceKobo, so wholesale
  customers are charged retail). RESOLUTION: re-mark Inventory "[~]" (built except
  the tier-price-at-sale defect); add a Ring 0 item "POS/Cart wholesaler-tier
  price fix"; keep Checkout "[x]" for its wallet/two-step/account integration but
  cross-reference the Ring 0 tier fix. The fix touches cart_service.dart addItem
  (accept + seed tier price), pos_home_screen.dart _addToCart (pass selected
  tier), and daos.dart:1592 checkCartStaleness + the order/checkout re-price paths
  (respect tier instead of hardcoding retailerPriceKobo). REVERSIBLE: if the user
  wants retailer-only pricing for now, drop the Ring 0 item, make the POS tier
  dropdown retailer-only (or hide it), and note in §16 that wholesaler pricing is
  deferred — but flag that this leaves the displayed-vs-charged mismatch live.

- **C3 — step-19 "wire every money path" is unsatisfiable where it sits.** The
  step-19 checkpoint ("expected balance matches across all touchpoints") names
  touchpoints (Refund=step 22, Expense=step 23, Supplier payment=step 24) that do
  not exist at step 19's position; today expense_service.dart and
  payment_service.dart are in-memory ValueNotifier stubs that never touch the DB,
  and markCancelled never reverses the funds credit. RESOLUTION: dissolve step 19
  as a milestone and redefine money-path wiring as a PER-FEATURE INVARIANT — every
  money-movement feature (Cancel, Refund, Expense, Supplier payment, Add Funds,
  Wallet top-up) credits/debits the correct funds account AND passes the
  order_service-style guard as part of its own definition-of-done. Rewrite
  step-19's checkpoint to scope it to the forward credits that exist when it runs
  (sale + wallet top-up post to the chosen account; live expected balance equals
  SUM(signed_amount_kobo) for those paths). The forward case is already enforced
  at the service boundary (order_service.dart:47-63). REVERSIBLE: re-add step 19
  AFTER steps 22-24 as a consolidated "money-path reconciliation audit" that can
  genuinely exercise all touchpoints; the per-feature invariants remain either way.

- **C4 — activity logging + notifications are late end-passes but are per-write
  invariants.** Pivot §8 step 26 (Activity Logs generic-schema migration) and step
  29 (Notifications wiring) are single late passes, yet CLAUDE.md coding rule #3
  makes activity logging a per-write invariant, §26.4 notification triggers are
  owned by features in steps 17-28, and PIVOT_PLAN.md:409 itself says
  notifications are "spread across multiple sessions — each feature wires its own"
  (contradicting its own step-29 monolith). Building features before step 26
  forces inline logging on the old per-entity-FK schema that the migration must
  later rewrite. RESOLUTION: split into (a) an EARLY Ring 0 schema migration that
  lands the generic activity_logs shape (entityType/entityId/before/after,
  decision Q6, row-copied from the old FK columns) PLUS the missing
  notifications.severity column (§1.3) and small logActivity()/fireNotification()
  helpers; then (b) make "writes its activity log (with before/after) AND fires
  its §26.4 notification(s)" part of every later feature's definition-of-done.
  Keep a lightweight Ring 3 "Notifications verification pass" (verify each §26.4
  event fires) and demote step 29 to verification. The generic migration also
  removes ActivityLogs.deliveryId, untangling the FK and unblocking the
  deliveries-table drop. REVERSIBLE: leave the migration at step 26 and
  notifications at step 29, accept that earlier features log on the old FK columns
  and get re-touched at migration time, and drop the per-feature "inline log +
  notify" invariant — at the cost of guaranteed rework on Cancel/Refund/Expense/
  Supplier logging.

**Tested:**
- None — docs only. Existing suite unchanged at 222 pass / 58 skip.

**Known issues / left open:**
Carrying forward the Session 33 items (BUILD_LOG.md:148-157) with their new
homes in the ring schedule:
- "Add Funds" on the customer screen bypasses the Funds Register
  (CustomerService.updateWalletBalance writes only wallet_transactions, loses the
  actor) — now scheduled as a Ring 1 item.
- Account add/remove not written to activity_logs (coding rule 3) — now covered
  by the Ring 0 logActivity() helper plus the per-feature log-and-notify invariant.
- LOW items still deferred: walk-in delete-button guard checks wrong condition,
  Crates-tab 2→3 flicker, reprints never show wallet info, raw store UUID in funds
  activity-log text (Hard Rule #4), raw order UUID in some snackbars.

New this session:
- The funds-model planning-doc drift vs code is still live — Q2 and steps 16 & 18
  in the planning docs need correcting against the actual code.
- The v2 domain-RPC sale path omits the funds account (daos.dart:1248-1251) —
  latent today but would drop the ledger credit if the v2 flag is flipped on.
- OrderService and CheckoutPage have no executing test coverage — to be addressed
  by the Ring 0 regression net.

**Next session should:**
- Session 34 (this one): DOCS ONLY — apply the three edits (PIVOT_PLAN §8.0
  re-sequence block + step-19 checkpoint fix + §9 C1/C3/C4 decisions; master plan
  §3 re-group + §23 Close Day reconciliation per C1; this BUILD_LOG entry). No
  code. Get user sign-off on the C1 recommendation (restore Close Day to Phase 1)
  before any Ring 1 coding.
- Session 35 (first code session, Ring 0): land the wholesaler-tier price fix
  (cart_service.dart:85-86 + pos_home_screen _addToCart + daos.dart:1592 +
  order/checkout re-price) with a tier-pricing unit test, AND start the
  activity_logs generic-schema migration (entityType/entityId/before/after
  row-copy) + notifications.severity column + logActivity()/fireNotification()
  helpers with a migration round-trip test. Both Ring 0 items are independent and
  both unblock the rest. Defer the OrderService regression-test net to the same
  Ring 0 window if time permits, else Session 36.
- Session 36 (Ring 1 start): Funds Register Close Day + reconciliation math (new
  closing-amount columns on fund_days, closeDay DAO method, §23.8 new-day-blocked
  guard, wire the dead funds.close_day permission) — the primitive every
  subsequent money-reversal path debits into.

---

## Session 33 — 2026-05-31 — Bug-hunt pass: Funds/POS HIGH+MED fixes

**Built today:**
A code review of the recently-touched areas (Customers §18, Checkout §14/15,
Funds §23, plus the Session 32 sync fix). Session 32 verified safe and committed
as-is. Then fixed the highest-impact bugs the review surfaced:

1. **HIGH — midnight rollover on an always-on till.** `todaysBusinessDateProvider`
   was a `FutureProvider` computed once and cached forever, so a till left
   running past midnight kept selling into the new day without a fresh Open Day,
   and new sales bucketed under yesterday's date. Now self-invalidates just
   after the next business-day boundary (new `untilNextBusinessDay` tz helper),
   so "today" rolls over and the POS gate + ledger re-key on the new day.
2. **MED — a paid sale could silently skip the Funds Register credit** when
   `businessDate` was null (the credit needs both account AND date, but the
   entry guard only checked the account). Now `OrderService.addOrder` rejects a
   paid sale with a null/empty businessDate instead of dropping the ledger entry.
3. **MED — re-adding a soft-deleted account name crashed** (UNIQUE ignores
   is_deleted, no try/catch). `createAccount` now reactivates the soft-deleted
   row (and updates its number); an *active* duplicate throws a friendly
   StateError the screen shows as a snackbar.
4. **MED — POS opening-cash gate cold-start race.** The gate read `lockedStoreId`
   without watching it, so it could render unblocked in the window before the
   store locked. `_initStore` now forces one rebuild after locking the store.
5. **MED — "Add Funds" on the customer screen bypassed the Funds Register**
   (coding rule 5). FIXED with the user-approved full fix (§18.779 method
   selector + receiving-account picker): the Add Funds sheet now lets you pick
   the receiving funds account (Cash Till / POS / Bank, account type → cash
   /transfer), and the top-up writes the wallet credit + `payment_transactions`
   + a `fund_transactions` 'topup' credit atomically, with the real staff id.
   Required a new `'topup'` reference_type on `fund_transactions` — a schema
   change on BOTH sides (Drift v22→v23 table rebuild + cloud migration 0063).

**Files touched:**
- lib/core/utils/business_time.dart (new `untilNextBusinessDay`)
- lib/core/providers/stream_providers.dart (self-invalidating today provider)
- lib/shared/services/order_service.dart (businessDate guard on paid sale)
- lib/core/database/daos.dart (createAccount reactivation; new `creditTopup`)
- lib/features/funds/screens/funds_register_screen.dart (add-account try/catch)
- lib/features/pos/screens/pos_home_screen.dart (rebuild after store lock)
- lib/core/database/app_database.dart (v23: 'topup' CHECK + table-rebuild migration)
- lib/shared/services/wallet_service.dart (topup credits the chosen funds account)
- lib/features/customers/data/services/customer_service.dart (new `topUpWallet`)
- lib/features/customers/screens/customer_detail_screen.dart (Add Funds account picker)
- supabase/migrations/0063_fund_transactions_topup_reference_type.sql (new — pushed to remote)
- test/funds/funds_register_dao_test.dart (+2 reactivation regression tests)
- test/funds/wallet_topup_funds_test.dart (new — +3 topup→funds tests)

**Database changes:**
- Drift schema v22 → v23: `fund_transactions.reference_type` CHECK widened to
  include `'topup'`. SQLite can't ALTER a CHECK, so onUpgrade `from < 23`
  rebuilds the table via `m.alterTable(TableMigration(fundTransactions))` —
  which preserves the table's indexes + append-only triggers, verified by
  migration_upgrade_test's schema audit.
- Cloud migration 0063: drops the inline reference_type CHECK (by definition
  lookup, name-agnostic) and re-adds it with `'topup'`. Additive, idempotent.
  Applied to remote via `supabase db push` (confirmed; 0062 already present).

**Tested:**
- flutter analyze (full project): clean (only the 18 pre-existing test-report
  avoid_print infos).
- Full suite: 225 passed / 0 failed (was 220; +5 new tests), 58 skipped.
- migration_upgrade_test green: v17/v19/v21 → v23 upgrades all pass the audit.

**Also fixed this session (LOW / follow-ups):**
- Walk-in delete-button guard now excludes `Customer.walkInId` (was `!= null`
  only — latent logic defect, not reachable today).
- Funds "open day" activity-log description no longer embeds a raw store UUID
  (Hard Rule #4); the store is carried in the structured storeId field.
- S32 follow-up: invite_staff duplicate-guard passes `preferredBusinessId` so a
  multi-business email resolves to the active business's user row.

**Known issues / left open (LOW, still deferred):**
- Crates-tab 2→3 flicker on profile open (cosmetic).
- Reprints never show wallet info even if the original had it — needs the
  showWalletInfo choice persisted on the order (schema change + design call).
- Account add/remove not written to activity_logs (coding rule 3) — needs
  staffId threaded through createAccount + avoiding ensureCashTill log noise.
- Raw order UUID in some Orders-screen snackbars/dialogs (Hard Rule #4) —
  pre-existing, outside the recently-changed scope.

---

## Session 32 — 2026-05-31 — Fix cross-business sync lockout / data-leak (Tier 1)

**Built today:**
- Investigated a Sync Issues error: editing the business name/type was rejected
  by the cloud forever ("new row violates row-level security policy", code 42501).
  Root cause: the cloud decides "which business are you allowed to touch" from a
  single pointer on your profile. Three flows (starting/finishing onboarding a
  second business, or joining another business via invite) silently move that
  pointer to the other business — and then the cloud locks you out of editing the
  FIRST business you actually own, even though you still own it. The same single
  pointer is also the only thing scoping data on the device, and the device never
  wipes the old business's rows, so a second business's data could sit alongside
  the first.
- Fix shipped (Tier 1 — keeps Phase-1 "one business at a time", no new switcher UI):
  1. Cloud: a CEO can now always read/edit a business they OWN, regardless of
     where the pointer drifted (owner escape-hatch on the businesses security
     rules). This directly fixes the reported error and lets the stuck edit flush.
  2. Device: editing-by-email no longer crashes when one email legitimately has a
     row for more than one business — it picks the row for the active business.
  3. Device: a safety net so the sync engine never writes another business's rows
     into the local database while you're signed into a different one.
  4. Device: the role badge now resolves against the business you're actually in,
     not an arbitrary one.

**Files touched:**
- supabase/migrations/0062_businesses_owner_fallback_rls.sql (new — applied to remote)
- lib/core/database/daos.dart (getUserByEmail multi-row tolerance)
- lib/shared/services/auth_service.dart (thread preferredBusinessId through)
- lib/core/providers/stream_providers.dart (userRoleProvider scoped to bound business)
- lib/core/services/supabase_sync_service.dart (_restoreTableData business_id guard)

**Database changes:**
- Migration 0062: businesses_select / businesses_update RLS now allow
  `id = business_id() OR owner_id = auth.uid()`. businesses_insert unchanged.
  Additive, backward-compatible, idempotent. Pushed to remote (confirmed on
  migration list). No local schema change → no Drift version bump.

**Master plan sections covered:**
- §1.1 / §7.1 / §7.2 / §8.3 — confirmed: multi-business is by design, but Phase 1
  is "one business at a time" and the in-app business-switcher PICKER is Phase 2.
  This session fixed the Phase-1 isolation/lockout bug only.

**Plan updates made during session:**
- None. The fix stays strictly inside Phase 1. (The Tier-2 hardening of the
  invite-redemption pointer move touches a §6.2 Phase-2 flow and was NOT done —
  it needs explicit sign-off + a plan note first.)

**Tested:**
- flutter analyze on the 4 changed files: clean.
- Ran restore, auth/email-scoping, businesses-dispatch, onUpgrade, and payload
  whitelist tests: all green. Restore tests that bind a business before restoring
  confirm the new guard is a no-op on the happy path.
- Two independent adversarial reviews of the diff: both SHIP, no real bugs.

**Known issues / left open:**
- Full belt-and-suspanders leak fix (wiping the previous business's local rows on
  a business switch, + recover-on-empty-pull) was DEFERRED. It clears the local
  DB including the offline-write queue, so it has a real "lose un-synced offline
  writes" tradeoff that is the user's call. Awaiting a decision on how to handle
  pending un-synced writes before implementing. The read-scoping invariant +
  getUserByEmail fix + restore guard already mitigate the practical leak.
- Residual (accepted, tracked in 0062 header): cloud RLS still trusts the profile
  pointer as the sole authority for the 31 tenant tables — a removed/suspended
  staff whose pointer still points at a business keeps tenant read access until
  the pointer moves. Closing this fully is the Phase-2 membership-set RLS work.
- Owner-fallback assumes ownership is never transferred (true in Phase 1). Revisit
  if an ownership-transfer feature is ever added.

**Next session should:**
- Get the user's decision on the deferred eviction-on-switch tradeoff (drop
  un-synced outgoing writes vs preserve-and-orphan), then implement #5/#6 if wanted.
- The Phase-2 in-app business switcher (picker UI + set_active_business RPC +
  membership-set RLS revert + in-place realtime rebind) remains deferred pending a
  master-plan update.

---

## Session 31 — 2026-05-31 — Customers (§18) re-pass, part 1

**Built today:**
- Soft-delete for customers (§18.4/§18.5). New CustomersDao.softDeleteCustomer
  flips is_deleted and enqueues the FULL row (customers.name is NOT NULL, so a
  partial upsert would 23502 and never sync). CustomerService forwards + writes
  an activity log. A trash button now sits in the customer-detail AppBar, shown
  only to CEO/Manager (customers.delete). Confirm dialog notes that sales/wallet
  history stays intact (soft-delete only, hard rule #9).
- The customer Crates tab now only appears for Bar / Beer Distributor businesses
  (§18.3) — same business-type gate the Inventory screen uses.
- Phone is now required in the Add Customer form (§18.2; was optional).
- New permission customers.set_debt_limit (§18.4). "Set debt limit" is CEO/Manager
  only — but there was no permission for it, so a Cashier could set limits. The
  Set Limit button now requires the new permission; Add Funds requires
  customers.wallet.update.

**Files touched:**
- lib/core/database/daos.dart (softDeleteCustomer + _enqueueFullCustomer)
- lib/features/customers/data/services/customer_service.dart (softDeleteCustomer + log)
- lib/features/customers/screens/customer_detail_screen.dart (delete action, Crates-tab gate, Set Limit/Add Funds permission gates)
- lib/features/customers/widgets/add_customer_sheet.dart (required phone)
- lib/core/database/app_database.dart (_defaultPermissionRows + schema v21→v22 catalog seed)
- supabase/migrations/0061_customers_set_debt_limit_permission.sql (NEW — deployed)
- test/sync/dispatch/customer_soft_delete_test.dart (NEW); migration_upgrade_test.dart (v21→v22); roles_v13_seed / roles_permissions_screen / role_permissions_detail tests (count 30→31)

**Database changes:**
- Schema v21 → v22: inserts customers.set_debt_limit into the local permissions
  catalog (idempotent; the role grant itself arrives via cloud pull).
- Cloud migration 0061 (deployed via db push): adds the permission, updates
  seed_default_roles_for_business to grant Manager (CEO auto), and backfills every
  existing CEO/Manager role with last_updated_at stamped for the 0048 pull.

**Master plan sections covered:**
- §18.2 (required phone), §18.3 (Crates tab gate), §18.4/§18.5 (soft-delete + Set
  Limit permission). §18 marked [~] — partial.

**Plan updates made during session:**
- None to plan text. Build order + status checklist marked §18 [~].

**Tested:**
- New customer_soft_delete_test (full-row upsert not a tombstone; hidden from list).
- migration_upgrade_test: new v21→v22 case re-seeds the catalog row.
- Full suite 220 passed / 58 skipped. analyze clean (18 pre-existing avoid_print).

**Known issues / left open:**
- Edit Customer flow: CustomerService.updateCustomer is a logging-only STUB — it
  doesn't write to the DB. A real updateCustomerDetails DAO method (that enqueues)
  + an edit form (reuse the add sheet) are still needed (§18.3).
- GPS location capture (§18.2): user chose geolocator capture over a Maps picker;
  not yet added (needs the geolocator dep + Android manifest perms; best verified
  against an emulator build).
- Add Funds payment-method selector (§18.3: Cash/Transfer/POS card/Other) not yet
  added; need to confirm the wallet write also credits a Funds Register account (§23).
- On-device verification of this session's changes still pending.
- barcode_widget remains unused in lib/ (from Session 30) — dependency not removed.

**Next session should:**
- Finish §18: real Edit flow, GPS capture, Add-Funds payment method — then on-device pass.

---

## Session 30 — 2026-05-30 — Checkout §14 final piece + QR removed from receipts

**Built today:**
- Added the "Add wallet info to receipt" checkbox to Checkout (§14.1). Off by
  default. Only shown for registered customers — walk-ins have no wallet (§14.3).
  This was the one §14 element still missing; the two-step payment + receiving
  account picker were already done with Funds Register (Session 26).
- Made the checkbox actually do something: when ticked, the customer's resulting
  wallet balance now prints on the receipt as "Wallet Balance: ₦X (credit/debt)"
  — on both the on-screen receipt and the thermal print (§15.1). Before today the
  `walletBalance` value was passed to both receipts but never displayed at all.
- Removed the QR code from both receipts (on-screen `ReceiptWidget` and the
  thermal `ThermalReceiptService`). The master plan §15.3 says "QR code is removed.
  Replaced by nothing," and CLAUDE.md hard rule #8 forbids it — it was lingering
  drift, found while wiring the wallet info. Nothing replaces it.

**Files touched:**
- lib/features/pos/screens/checkout_page.dart (checkbox state + UI + pass-through)
- lib/shared/widgets/receipt_widget.dart (showWalletInfo param, wallet line, QR removed, unused barcode import dropped)
- lib/features/pos/services/receipt_builder.dart (showWalletInfo param, wallet line, QR removed)
- test/receipt_widget_test.dart (NEW — 5 tests: wallet-info gate + QR-removal regression guard)
- BUILD_LOG.md, reebaplus_master_plan.md (§3 build-order checkbox)

**Database changes:**
- None.

**Master plan sections covered:**
- §14.1 — "Add wallet info to receipt" checkbox (off by default). §14 now complete.
- §15.1 — wallet info on the receipt, gated by the checkbox.
- §15.3 — QR code removed (also satisfies CLAUDE.md hard rule #8).

**Plan updates made during session:**
- None to the plan text. Marked §14 Checkout `[x]` and §15 Receipt `[~]` (partial:
  QR + wallet info done; full §15 pass — refund button, Completed-tab — still open).

**Tested:**
- New test/receipt_widget_test.dart: 5 tests green (hidden by default; shows with
  debt tag; shows with credit tag; null balance renders nothing; QR absent).
- Full suite: 212 passed / 58 skipped. `flutter analyze` clean (only the 18
  pre-existing avoid_print infos in test report scripts).

**Known issues / left open:**
- `barcode_widget` (pubspec) is now unused anywhere in `lib/`. Left in place —
  flagged for the user to decide whether to drop the dependency.
- The Orders > Completed reprint path passes `walletBalance` but not
  `showWalletInfo`, so it defaults to off — reprints never show wallet info. That
  matches "off by default" since the checkbox choice isn't persisted; revisit if
  §15 should persist the choice per order.

**Next session should:**
- Either do the full §15 Receipt pass (refund button for Manager/CEO on the
  Completed tab, rider info), or continue the build order.

---

## Session 29 — 2026-05-30 — Partial-upsert sweep: 19 more methods fixed (sync correctness)

**Built today:**
- **Swept the codebase for the partial-row upsert bug** that the manufacturer fix
  (Session 28) exposed, and fixed all 19 genuine offenders. The push path does an
  `INSERT … ON CONFLICT` upsert; Postgres validates NOT-NULL on the INSERT *before*
  the conflict merges, so any queued payload missing a NOT-NULL-no-default column
  (usually `name`) is rejected (23502) and never syncs. These are latent — each fires
  only when its path runs + a push happens — which is why only the freshly-exercised
  manufacturer one showed on the Sync Issues screen.
- Fixed (each now re-reads and enqueues the FULL row, the proven manufacturer pattern):
  - products: `softDeleteProduct`, `updateMonthlyTarget`, `updateTrackEmpties`
  - orders: `assignRider`, `markCompleted`, `markCancelled` (v1 path)
  - sessions: `revokeSession` (every full logout), `revokeAllSessionsForUser`
  - notifications: `markRead`, `markAllRead`
  - pending_crate_returns: `updateStatus`, service `approve`/`reject` (v1 path)
  - crate_size_groups: `updateCrateGroupStock`
  - customers: `updateWalletLimit`
  - funds_accounts: `softDeleteAccount`
  - stores: soft-delete handler
  - users: the two onboarding-alert notification bumps
- **Corrected the misleading comment** in supabase_sync_service that claimed partial
  upserts were safe — the assumption that institutionalised this whole bug class.

**Files touched:**
- lib/core/database/daos.dart (14 methods + `_enqueueFullProduct` / `_enqueueFullOrder` helpers)
- lib/shared/services/crate_return_approval_service.dart (approve/reject v1 paths)
- lib/shared/services/auth_service.dart (2 users notif bumps)
- lib/features/stores/screens/stores_screen.dart (store soft-delete)
- lib/core/services/supabase_sync_service.dart (corrected the partial-upsert comment)
- test/sync/dispatch/partial_upsert_full_row_test.dart (new — 3 product regression tests)

**Database changes:**
- None. Client-only — no schema bump, no cloud migration. The cloud tables are
  correct; the client was sending incomplete payloads.

**Tested:**
- `flutter analyze` clean. Full suite 212 passed / 0 failed (6 partial-upsert
  regression tests: 3 products here + 3 manufacturers from Session 28).
- Verified by grep that no partial-companion enqueue remains for any offender table.
  The three that look similar (`updateProductDetails`, store create/edit) include
  `name` / use `.insert`, so they're safe.

**Known issues / left open:**
- The full-row `users` enqueue puts local-only columns (pin, etc.) into the LOCAL
  sync_queue payload; the cloud column whitelist strips them on push, so they never
  leave the device. Acceptable; noted for awareness.
- No on-device action needed (unlike Session 28's stuck queue item) — these are
  invisible until the paths run, and now enqueue correctly.

**Next session should:**
- Resume the verification-backlog burndown (POS / Cart / Inventory / Funds Register
  on-device), or the next master-plan screen.

---

## Session 28 — 2026-05-30 — Manufacturer partial-upsert sync fix (Sync Issues 23502)

**Built today:**
- **Fixed manufacturers not syncing** (the "null value in column name … 23502"
  error on the Sync Issues screen). Setting a manufacturer's Empty Crate Value /
  deposit / empty-crate stock enqueued a cloud upsert carrying ONLY the changed
  column (+ id/business_id/last_updated_at) — no `name`. The cloud `manufacturers`
  table has `name NOT NULL`, and a Supabase upsert is an INSERT…ON CONFLICT whose
  INSERT is validated before the merge, so the missing name was rejected and the
  change never reached the cloud (the row retried forever in the queue).
- Three methods had this shape: `updateManufacturerEmptyCrateValue` (CatalogDao),
  `updateManufacturerStock` and `updateManufacturerDeposit` (InventoryDao). Each
  now reads the row back after the local write and enqueues the FULL row
  (`toCompanion(true)`), the same pattern `insertManufacturer` already used.

**Files touched:**
- lib/core/database/daos.dart (a `_enqueueFullManufacturer` helper in each of the two DAOs + the three call sites)
- test/sync/dispatch/manufacturer_partial_upsert_test.dart (new — 3 tests: each update enqueues a payload containing `name`)

**Database changes:**
- None. No schema bump, no cloud migration — the cloud table is correct; the client
  was sending an incomplete payload.

**Master plan sections covered:**
- §16.5 (manufacturer-level Empty Crate Value, Session 25) — sync correctness fix.

**Tested:**
- `flutter analyze` clean. New tests green; full suite (excl. integration) green.

**Known issues / left open:**
- **On the device:** the already-queued bad `manufacturers:upsert` (attempts: 6)
  won't self-heal — tap **Discard** on it in Sync Issues. The fix makes future
  manufacturer saves push correctly; to get that one value to the cloud, re-open
  the product/manufacturer and re-save the Empty Crate Value once (fresh full-row
  upsert).
- **Broader risk — partial-row upserts:** this is one instance of the class flagged
  in the role-refactor work. ANY DAO method that enqueues a partial companion for a
  synced table with NOT NULL cloud columns has the same failure mode. Only the three
  manufacturer methods were fixed here (the reported one); a sweep of per-column
  update methods across the DAOs is worth a dedicated pass.

**Next session should:**
- Optionally sweep for other partial-companion enqueues; otherwise resume the
  verification-backlog burndown / two-device realtime check.

---

## Session 27 — 2026-05-30 — Realtime cross-device sync fix (foundation)

**Built today:**
- **Fixed realtime cross-device sync — the foundation bug.** Before today, a change
  made on one device (a sale, a new product, opening the day, a price/colour edit)
  only reached other devices when they ran a manual/snapshot pull — live updates
  never arrived. Cause: the app subscribed to every table through a single wildcard
  channel (`public:*`) that set a `business_id` filter but named no `table:`, which
  Supabase Realtime can't honour, so the whole subscription silently failed — and
  `..subscribe()` had no status callback, so nothing logged it. The one table that
  DID update live (Business Info) sat on a separate, correctly-formed channel; that
  asymmetry was the tell.
- Now each synced tenant table gets its own realtime channel with an explicit table
  name + `business_id` filter, and each logs whether it `SUBSCRIBED` / `CHANNEL_ERROR`
  / `TIMED_OUT`. A single bad table (e.g. one not in the realtime publication) no
  longer tears down the rest. The working `businesses` channel and the
  single-active-device `sessions`-revoke handling are preserved unchanged.

**Files touched:**
- lib/core/services/supabase_sync_service.dart (per-table realtime channels + status callback; `_realtimeChannel` → `_tableChannels` list)
- PIVOT_PLAN.md (§7 risk register: realtime bullet marked RESOLVED)
- BUILD_LOG.md (this entry)

**Database changes:**
- None. Client-only change. No schema bump, no cloud migration. The cloud realtime
  publication already includes every synced table (migrations 0006 / 0042 / 0057).

**Master plan sections covered:**
- §2.6 (realtime delivery) — the cross-referenced foundation fix.

**Plan updates made during session:**
- PIVOT_PLAN §7 realtime risk bullet marked RESOLVED (was "deferred until CEO
  Settings lands" — that work landed in Sessions 14–17, so the deferral had expired).

**Tested:**
- `flutter analyze` clean. Full suite (excl. integration) 204 passed / 0 failed.
- Realtime channel wiring can't be unit-tested without a live Supabase server; the
  restore path it feeds is unchanged and still covered by `funds_restore_test` +
  the existing restore tests.

**Known issues / left open:**
- ✅ **Two-device realtime delivery CONFIRMED working on-device (2026-05-30, user-run):**
  a change on device A (product / Open Day / CEO colour) lands on device B within a
  tick with NO manual pull. The foundation fix is closed.
- ~35 channels are opened on connect (one per `_pullOrder` tenant table) — within
  Supabase limits, but worth watching the join logs on a real device.
- Cloud funds migrations 0057–0060 confirmed applied remotely (`supabase migration
  list`: remote at 0060), so a second device won't 42501 on funds writes.

**Next session should:**
- Do the two-device realtime confirmation, then burn down the on-device verification
  backlog (POS / Cart / Inventory / Funds Register) before starting new features.

---

## Session 26 — 2026-05-30 — Funds Register Phase 1 (multi-account, §23)

**Built today:**
Funds Register pulled ahead of Checkout because the sales flow can't be correct
without it (Checkout §14 needs an account to credit; hard rule #10 blocks sales
until opening cash is set). Phase 1 is the multi-account model + the till gate.
- **Money accounts per store.** Each store gets a Cash Till automatically; the CEO
  can add POS machines and Bank accounts (and remove the ones they added). Cashier
  and Stock keeper can't see the Funds Register at all.
- **Open the day.** A Manager or CEO enters the starting balance for each account
  and opens the day. Until that's done, the Point of Sale screen is blocked — a
  Cashier is told to wait for a Manager/CEO; a Manager/CEO sees "Tap to enter" and
  tapping jumps straight to the Open Day screen.
- **Every paid sale lands in an account.** At checkout there's now a "Receiving
  Account" step (defaults to Cash Till). The cash/card/transfer that actually
  arrives is credited to the chosen account; wallet payments and credit sales move
  no account money (they're the wallet's job). A live "today's balances" view shows
  each account's running total.
- **New Funds Register sidebar item** (Manager/CEO only), replacing the old Cash
  Register concept (hard rule #8).

**Files touched:**
- lib/core/database/app_database.dart, app_database.g.dart (3 tables, registries, schema v20 migration)
- lib/core/database/daos.dart (FundsAccountsDao, FundDaysDao, FundTransactionsDao; sale credit inside OrdersDao.createOrder)
- lib/core/providers/stream_providers.dart (4 providers incl. todaysBusinessDateProvider)
- lib/core/utils/business_time.dart (businessDateString helper)
- lib/features/pos/screens/pos_home_screen.dart (Open-Day gate + role messages)
- lib/features/pos/screens/checkout_page.dart + lib/shared/services/order_service.dart (Step-2 account picker; thread + enforce funds account)
- lib/features/funds/screens/funds_register_screen.dart (new)
- lib/shared/widgets/main_layout.dart, app_drawer.dart (Funds Register at index 11 + route)
- supabase/migrations/0057_funds_register.sql (new)
- test/funds/funds_register_dao_test.dart (new, 6 tests)

**Database changes:**
- Local schema v19 → v20: three new synced tenant tables — `funds_accounts`,
  `fund_days` (daily open/close header = the gate), `fund_transactions` (append-only
  ledger; opening balances are 'opening' ledger entries, balance = SUM(signed)).
- Cloud `supabase/migrations/0057_funds_register.sql` — same three tables + RLS
  tenant policies + realtime publication + the fund_transactions append-only
  triggers. **Pushed and applied.**
- No new permissions (funds.open_day / funds.close_day / funds.view already seeded +
  granted to CEO/Manager). No new role.

**Master plan sections covered:**
- §23 Funds Register (Phase 1 subset), §14.2 Step 2 (receiving account), §30.3.
- §3 build order amended: Funds Register moved ahead of Checkout (dated note).

**Plan updates made during session:**
- §3 reorder above. Phase 2 (Close Day, reconciliation, Funds History) deferred.

**Tested:**
- `flutter analyze lib/` clean. Full suite green: 203 passed / 58 skipped / 0 failed.
- New DAO tests: ensureCashTill idempotent; openDay creates the header + an opening
  credit per active account (even 0) and a double-open throws; the gate stream
  flips on open; balances sum; every write enqueues (§5).
- Cloud migration round-trips (pushed clean).

**Known issues / left open:**
- On-device pass still pending: open the day → POS unblocks → a cash sale to "POS 1"
  raises that account; wallet/credit sales move no account.
- **R1 (atomicity):** the fund credit is a separate enqueue row from the order/payment
  (same per-table V1 model the existing payment/wallet writes already use); local
  writes are one atomic transaction so on-device balances are always right.
- **R2 (v2 flag):** the credit lives in the V1 sale path only. If
  `feature.domain_rpcs_v2.record_sale` is ever turned on, the credit must move into
  the pos_record_sale_v2 RPC (server mints the row). Flag is OFF today.
- **R4 (cancel):** a same-day sale cancellation does not yet reverse its fund credit
  (refund crediting is Phase 2).

**Next session should:**
- Funds Register Phase 2 (Close Day + reconciliation + Funds History), OR the
  Checkout §14 formal re-pass now that it has accounts to credit.

**Session 26 follow-ups (same working session) — bumped local schema v20 → v21:**
These landed after the main entry above. Both 0058 and 0060 are the exact "new
synced table" gaps the PIVOT_PLAN §1.5 checklist exists to prevent — bugs already
solved earlier in this build, repeated for the funds tables:
- **Pull side was missing (0060).** 0057 added the three funds tables to the push
  side (`_syncedTenantTables`) + realtime, but NOT to the `pos_pull_snapshot` RPC
  or the client `_restoreTableData` cases — so a CEO's Open Day synced UP to the
  cloud but never came back DOWN to a staff till (POS stayed blocked on the second
  device). Same one-sided-sync bug as `invite_codes` in Session 12. Fixed by
  `supabase/migrations/0060_pull_funds_register.sql` (snapshot) + restore cases;
  guarded by the new `test/sync/funds_restore_test.dart`.
- **RLS used the pre-0051 pattern (0058).** 0057 wrote the funds RLS policies with
  the membership-subquery pattern, which 42501-rejected authenticated writes. Same
  fix 0050/0051 already applied to the membership tables. `0058_funds_rls_via_profiles.sql`
  re-expresses the funds policies via `profiles`.
- **Account number (0059 + schema v21).** POS machine / Bank accounts can carry an
  optional account number / terminal id (Cash Till leaves it null). Local v20 → v21
  adds the nullable `funds_accounts.account_number`; cloud `0059_funds_account_number.sql`
  mirrors it.
- **Deploy status of 0058–0060: CONFIRMED applied remotely** (verified 2026-05-30 via
  `supabase migration list` — local and remote both at 0060). The funds RLS fix (0058)
  and pull fix (0060) are live cloud-side.

**Capture / git note (2026-05-30):** Sessions 24, 25, and 26 (+ these follow-ups)
were committed together in a single commit off schema v19 — they were interleaved in
the regenerated `*.g.dart` (final v21 shape), so a clean per-session split was not
safely separable after the fact. Tree was analyzer-clean and the suite was green
(204 passed / 0 failed, excl. integration) at commit time. Discipline going forward:
commit per chunk, log before closing the session.

---

## Session 25 — 2026-05-30 — Product Details edit-in-place + 7 inventory fixes

**Built today (post-emulator round 2 — 7 issues on Product Details + the Update Product form):**
- All 7 changes below are code-complete; `flutter analyze` clean and the full test suite is green. On-device pass still to be done by the user.

Covered two rounds of emulator feedback. Round 2 redesigned the Product Details
edit model and fixed a Sales-Target sync bug.

**Plan updates made during session (per CLAUDE.md, before any code):**
- **Role model — "ignore this".** The "read-only below CEO" request was answered "ignore this" — editing stays on `products.edit_price` (CEO + Manager); Stock keeper keeps "Update Stock"; Cashier view-only. EXCEPT the **Sales Target is CEO-only** (Manager can't set it — explicit follow-up).
- **master plan §16.5** — Empty Crate Value moves directly below Manufacturer and is **set at the manufacturer level** (`manufacturers.depositAmountKobo`): autofilled when a manufacturer is picked, saved back on save, mirrored to the product's `emptyCrateValueKobo` so cart math is untouched.
- **master plan §16.6** — Product Details is now **view-only until a top "Edit" button is tapped** → all fields editable → one **"Save Product"** button (with success/error banner). Sales Target CEO-only. Quantity is read-only (changes via Add Product / Update Stock).
- **master plan §16.8** — product deletions appear in the History tab (as stock-removal adjustments).

**The changes:**
1. Product Details shows **live stock** after an Update Stock adjustment (was a stale navigation snapshot).
2. **Sales Target now syncs** across staff — it was lost to sync-queue coalescing (a separate `updateMonthlyTarget` upsert was overwritten by the product upsert for the same row). Fixed by folding the target into the single `updateProductDetails` payload. The target is now **CEO-only** (Manager sees it read-only).
3. Role gating unchanged ("ignore this"), apart from the CEO-only target.
4. Product Details **redesigned**: a top **Edit** toggle makes all fields editable; **"Save Product"** persists everything in one update with a success/error banner (fixes the old "save does nothing" + no-feedback). **Added the missing fields** (Description, Low Stock Alert, Supplier, Allow-fractional toggle, Track-empties toggle, editable Size, editable Expiry). **Quantity is read-only** here (changed via Add Product / Update Stock). **Stock keeper** gets a restricted view (no Edit button; Supplier + Buying hidden; keeps Update Stock).
5. **Deleting a product** is tracked in History (remaining stock removed via adjustments; explicit "deleted product" record stays in Activity Logs).
6. **Update Product** form header 4.7px right overflow fixed.
7. **Empty crate value** moved directly below Manufacturer in both product forms, autofilled from + saved to the manufacturer level (reuses `manufacturers.depositAmountKobo` — no new column).

**Database changes:**
- No schema bump, no cloud migration. `CatalogDao.updateProductDetails` gained an optional `monthlyTargetUnits` param so the Sales Target rides the same `products` upsert. Otherwise reuses existing columns/DAOs (`manufacturers.depositAmountKobo`, `updateManufacturerEmptyCrateValue`, `adjustStock`).

**Files touched:**
- lib/features/inventory/screens/product_detail_screen.dart (major rework)
- lib/features/inventory/widgets/update_product_sheet.dart
- lib/features/inventory/screens/add_product_screen.dart
- lib/core/database/daos.dart (`updateProductDetails` + `monthlyTargetUnits`)
- reebaplus_master_plan.md (§16.5 / §16.6 / §16.8), BUILD_LOG.md (this entry)

**Tested:**
- `flutter analyze` clean (only pre-existing `avoid_print` infos in a test file); full suite green. On-device pass still to be done by the user.

---

## Session 24 — 2026-05-30 — Cart FAB → Cart fix + post-inventory review of §13

**Built today:**
- **Fixed the POS "Go to Cart" button opening Deliveries.** The floating cart
  button on the Point of Sale screen jumped to screen slot 9 (Deliveries) instead
  of slot 8 (the Cart) — a stale comment had hidden the off-by-one. One-line fix.
  Verified it now matches the other two ways into the Cart (bottom-nav cart tab and
  the sidebar), so all three agree.
- **Reviewed the Session 20 Cart work after the Inventory rework (Sessions 21–23)
  landed on top of it.** Everything still hangs together: the "Allow fractional
  sales" toggle survived the move from the old add-product sheet to the new full
  Add Product screen, and the price-column migrations carried it through; the cart
  now reads the new Retailer price; per-line discounts still reach the recorded
  sale; saved-cart privacy + 24h expiry intact. Full test suite green.

**Corrections to earlier notes (running-memory hygiene):**
- Server migration `0054_cart_step13.sql` **is pushed** and applied — Session 20 had
  marked it "NOT YET PUSHED"; that note is now stale.
- The fractional toggle's create-side home moved: `add_product_sheet.dart` was
  deleted in the Inventory rework, so the toggle now lives in
  `add_product_screen.dart` (Session 20's file list still names the old sheet). It
  remains in `update_product_sheet.dart` for the edit path.
- The Cashier login crash listed as a Cart "known issue" was the realtime
  sync-ordering bug — **fixed in Session 23** (`_insertResilient` skips an orphaned
  row instead of aborting the pull).

**Files touched:**
- lib/features/pos/screens/pos_home_screen.dart (cart FAB index 9 → 8)

**Database changes:**
- None.

**Master plan sections covered:**
- §13 Cart — bug fix only (no behaviour added beyond Session 20).

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze` clean on the touched file; `flutter analyze lib/` clean overall.
- Sync + orders + checkout suites green this session (76 passing locally).

**Known issues / left open:**
- Manual emulator walk-through of the Cart flows still pending — discount role
  behaviour (Cashier blocked / Manager cap snap / CEO unlimited), fractional chips
  on a fractional product, saved-cart privacy + expiry, Undo, and a discounted
  sale's totals after sync. Now that the FAB actually reaches the Cart, this is
  unblocked.

**Next session should:**
- Do the §13 emulator walk-through, then move to Checkout (§14) / Receipt (§15) per
  the build order.

---

## Session 23 — 2026-05-30 — Cashier crash fix (Phase 0) + expiry schema (Chunk 2 start)

**Built today:**
- **Phase 0 — Cashier sync-restore crash fixed.** Logging in as a Cashier could
  abort the whole sync with "FOREIGN KEY constraint failed" while loading
  products. Now, if a product (or any row that hangs off a product) arrives
  before the supplier / manufacturer / category it points to, that single row is
  quietly set aside and logged instead of crashing the app. The rest of the data
  still loads; set-aside rows retry automatically on the next full sync and show
  up in the Sync Issues "Catching up" card meanwhile.
- **Chunk 2 (started) — product Expiry Date schema.** Products gained one optional
  expiry date (all business types). Local schema v18 → v19 (one nullable column,
  no rebuild); cloud `0056_product_expiry.sql` adds the column and threads
  `p_expiry_date` through `pos_create_product_v2`; the create-product payload
  builder forwards it. Cloud migration pushed and confirmed applied.

**Files touched:**
- lib/core/services/supabase_sync_service.dart
- lib/core/database/app_database.dart, app_database.g.dart
- lib/core/database/daos.dart
- supabase/migrations/0056_product_expiry.sql (new)
- reebaplus_master_plan.md (§16.2/16.4/16.5/16.6 amendments)
- test/sync/restore_fk_resilience_test.dart (new)

**Database changes:**
- Local schema v19: `products.expiryDate` (nullable). Cloud 0056: `products.expiry_date timestamptz` + `pos_create_product_v2` gains `p_expiry_date`.

**Master plan sections covered:**
- Phase 0 is sync-layer robustness (no master-plan section).
- §16 Inventory: amendments below cover §16.2/16.4/16.5/16.6.

**Plan updates made during session:**
- Per CLAUDE.md (update the plan before deviating code), amended master plan §16:
  - §16.2 — stat cards are compact.
  - §16.4 — Category chips → a dropdown (between Store and Manufacturer); added a header search toggle; list flags near/past-expiry products and can sort by soonest expiry.
  - §16.5 — Add Product is a full screen (not a modal); added optional Expiry Date (all types); Color selector deferred (keep default `colorHex`, revisit with Boutique/Gadgets).
  - §16.6 — Product Details shows Expiry Date + near-expiry badge.

**Tested:**
- Phase 0 unit tests (new): orphaned product skipped (no crash), good products land, the inventory cascade is also skipped, a fully-satisfiable batch flags nothing.
- `flutter analyze` clean on touched files; sync + database suites pass (118), product-create + migration suites pass (53). `.g.dart` regenerated.
- Still to verify on-device: two-device scenario (CEO creates a product with a brand-new supplier+manufacturer; Cashier on a second device loads with no crash, missing rows surface in Sync Issues).

**Also built this session (Chunk 2 UI, part 1 — the two product forms):**
- **Add Product is now a full screen** (`AddProductScreen`), replacing the bottom-sheet. The Inventory FAB and the post-onboarding auto-show now push the screen. Three prices: Retailer + Wholesaler (both required, the new Wholesaler input replaces the "mirrors retailer" stopgap), Buying (required, hidden unless the role has `products.edit_buying_price`). Empty Crate Value (₦) shows only when "Track empty crate returns" is on. Optional Expiry Date picker (all business types). Colour swatch picker removed (products keep the default colour).
- **Update Product sheet** got the same treatment: editable Wholesaler input, Empty Crate Value, Expiry Date, buying gated by permission, colour picker removed. The Product Details "Update Product" button opens this sheet, so the detail edit surface inherits all of it.
- `CatalogDao.updateProductDetails` gained an optional `expiryDate` param (sentinel-guarded like the other cosmetic fields).

**Files touched (part 1):**
- lib/features/inventory/screens/add_product_screen.dart (new; replaces widgets/add_product_sheet.dart, deleted)
- lib/features/inventory/widgets/update_product_sheet.dart
- lib/features/inventory/screens/inventory_screen.dart, lib/shared/widgets/main_layout.dart (push the screen instead of a modal)
- lib/core/database/daos.dart (`updateProductDetails` + `expiryDate`)

**Tested (part 1):** `flutter analyze` clean (0 errors/warnings); full suite 197 passed / 58 skipped / 0 failed.

**Also built this session (Chunk 2 UI, part 2 — Product Details, inventory layout, tab guards):**
- **Product Details (§16.6) is now role-aware.** `_canEdit` is derived from `products.edit_price` (CEO/Manager) instead of being hardwired true. Buying Price row is hidden unless `products.edit_buying_price`. Expiry Date row + a near-expiry badge (red "Expired" / amber "Expires soon") show when a date is set. Action button by role: CEO/Manager → "Update Product"; **Stock keeper → "Update Stock" modal** (Add/Remove, quantity, reason required on Remove [Damage/Theft/Expired/Other], optional notes → `adjustStock` + History log); Cashier → view-only.
- **Inventory Products tab (§16.4):** category chip row replaced by a **Category dropdown** between Store and Manufacturer; **compact stat cards** (icon+value on one row, smaller); a **header search toggle** (filters name/subtitle); **near-expiry surfacing** — flagged products (expired / ≤30 days) bubble to the top soonest-first and carry an expiry chip.
- **Tab + FAB guards (§16.7/§16.10):** Add Product FAB → `products.add`; tabs are now dynamic — Suppliers needs `suppliers.manage`, Empty Crates shows only for Bar / Beer distributor, History shows for CEO/Manager/Stock keeper and is hidden from Cashier (gated by role slug, as decided). The TabController rebuilds when the visible set resolves.

**Files touched (part 2):**
- lib/features/inventory/screens/product_detail_screen.dart
- lib/features/inventory/screens/inventory_screen.dart

**Tested (part 2):** `flutter analyze` clean (0 errors/warnings); full suite 197 passed / 58 skipped / 0 failed. Chunk 2 (the §16 Inventory restructure) is now feature-complete in code.

**Follow-up fix (dynamic tabs):** the dynamic tab set recreated the `TabController`, which crashed under `SingleTickerProviderStateMixin` (it permanently records its one ticker, so a second controller throws). Switched to `TickerProviderStateMixin`, and `_syncTabController` now rebuilds the controller only when the tab *count* changes, disposing the old one first. Also gated the tab UI behind a "gating data resolved" check so the tab bar reveals its final set in one shot (no staged tab pop-in) — i.e. the screen loads statically like the others. (Note: searched the inventory files for fade-in/stagger/entrance animations — there are none; the only `animate` call is the tab-switch `animateTo`.)

**Known issues / left open:**
- On-device verification still pending (the user will do a manual pass at the end): Phase 0 two-device crash check; the new Add Product full screen + Update sheet (3 prices, empty-crate value, expiry, no colour, buying hidden for Stock keeper/Cashier); Product Details role behavior incl. the Stock keeper Update Stock modal; inventory category dropdown / compact cards / search / near-expiry; and the tab guards across the four roles + business types.
- History tab store-scoping (Manager/Stock keeper "own store") relies on the existing store filter passed to `InventoryHistoryTab`; only tab *visibility* was gated this session.

---

## Session 22 — 2026-05-30 — Product price-column migration (pivot step 14, Chunk 1) — IN PROGRESS

**Built today:**
- (In progress — Chunk 1 of the Inventory work: the behind-the-scenes price-storage change.)
- Plan-change ritual done first (see Plan updates below).

**Plan updates made during session:**
- **Decision Q4 revised — salvage-map instead of wipe.** Original plan said drop the four legacy price columns with NO data migration (re-enter prices by hand). User re-confirmed at the hard checkpoint to instead carry the data over: `retailPriceKobo → retailerPriceKobo`, `coalesce(distributorPriceKobo, retailPriceKobo) → wholesalerPriceKobo`; `sellingPriceKobo` + `bulkBreakerPriceKobo` dropped (no equivalent); `buyingPriceKobo` stays. Updated PIVOT_PLAN §1.3 products block + §8 step 14.
- **§16.5 Add Product form gains an "Empty Crate Value (₦)" field**, shown only when "Track empty crate returns" is on, saved to the existing `products.emptyCrateValueKobo` column (column + DAO param already exist; UI-only gap). Updated master plan §16.5. Wired in Chunk 2 (step 15).
- Corrected the step-14 schema version label in PIVOT_PLAN from the stale "v15" to **v18** (local schema is currently v17).

**Next session should:**
- Finish Chunk 1: local schema v18 (drop 4 legacy price cols, add retailer/wholesaler + nullable barcode, TableMigration salvage-map), regenerate `.g.dart`, cloud migration 0055 (+ rewrite `pos_create_product_v2`), rewire ~20 price-column call sites, `flutter analyze`/`test`. Then checkpoint before Chunk 2 (the §16 Inventory UI).

---

## Session 21 — 2026-05-30 — Re-sequence: Inventory + price migration ahead of the sales flow (docs only)

**Built today:**
- No code. Re-ordered the build plan so all product/pricing work is finished before the remaining POS/sales flow.
- The destructive product price-column migration (drop the four legacy price columns, add buying / retailer / wholesaler) was already scheduled early as pivot step 14, but the Inventory rebuild — where the user re-enters prices after that migration — sat all the way down at step 20. That left step 14's own checkpoint ("re-enter prices in Inventory") with nowhere to actually do it. Inventory now moves up to step 15, directly behind the price migration.

**Files touched:**
- reebaplus_master_plan.md (§3 Build Order — split the combined "Cart and Checkout" bullet; Inventory now listed above Checkout)
- PIVOT_PLAN.md (§8 — Inventory restructure moved from step 20 to step 15; old steps 15–19 shifted down one to 16–20; cross-references re-pointed)
- BUILD_LOG.md (this entry + two "pivot step 16" → "step 17" reference fixes in Sessions 19/20)

**Database changes:**
- None.

**Master plan sections covered:**
- §3 Build Order (re-sequenced). No feature sections built.

**Plan updates made during session:**
- The re-sequence itself. Old → new pivot-step mapping (steps 1–14 and 21–34 unchanged):
  - Inventory restructure: 20 → **15**
  - Schema v16 Funds Register tables: 15 → 16
  - Funds Register screens (Open Day, etc.): 16 → 17
  - Checkout two-step payment UI: 17 → 18
  - Wire every money path: 18 → 19
  - Receipt rebuild: 19 → 20
- Re-pointed the affected cross-references: PIVOT_PLAN §8 step-12 status note (Open Day "step 16" → 17); the two money-path references that cited "step 17" while describing the wire-every-path session (→ step 19); and the two Sessions 19/20 "pivot step 16" Open-Day references (→ step 17).

**Tested:**
- Re-read both plan docs top to bottom: PIVOT_PLAN §8 numbers run 1..34 with no gaps/dupes; Inventory (15) sits right after the price drop (14); master plan §3 shows Inventory above Checkout.

**Known issues / left open:**
- When pivot steps 14–15 are actually built, the destructive price migration removes the `sellingPriceKobo` / `retailPriceKobo` columns that the already-shipped POS (§12) and Cart (§13) code reads — those call sites will need a follow-up pass at that time.
- Pre-existing: Session 19's "pivot step 40" barcode reference is stale (barcode is step 30); left untouched, outside this re-sequence's scope.

**Next session should:**
- Begin pivot step 14 — the destructive Schema v15 price-column drop (HARD CHECKPOINT: re-confirm with user before running), then step 15 Inventory restructure.

---

## Session 20 — 2026-05-30 — Cart: discounts, fractional sales, per-cashier saved carts (§13, pivot step 13)

**Built today:**
The Cart screen already existed; this session added the §13 behaviours that were missing.
- **Per-item discounts in the Edit Quantity modal.** Tap a cart item → there's now an "Apply Discount" section with a % / ₦ toggle (% by default) and a live "Saving ₦X — new line total: ₦Y" readout. It respects each role's limit: a Cashier (0%) sees "Discounts not allowed at your role. Ask Manager." and can't type a discount; a Manager who goes over their cap is snapped back to the max with "Maximum discount is X%. Capped."; a CEO has no limit. The cap is read from the same per-role setting CEO Settings already saves.
- **Discount shows on the cart line** — the old price with a strikethrough, the new price, a small "−10%" / "−₦500" badge, and a green "Saved: ₦X" line under the subtotal.
- **Discounts reach the recorded sale.** The total a customer pays already had the discount taken off; now the sale itself stores the discount amount so the books are right. No server change was needed — the sale RPC already accepted a discount; we just started sending it.
- **"Allow fractional sales" toggle on products.** New checkbox on the add/edit product sheets. The ±0.5 quantity chips in the Edit modal now only appear for products that have it switched on (before, they always showed).
- **Saved carts are now private to each cashier and expire after 24 hours.** You only see carts you saved, and stale ones are cleared automatically when you open the Recall list.
- **Undo on remove.** Removing an item shows a 5-second "Item removed. Undo" banner at the top; tapping Undo puts it back exactly as it was.

**Files touched:**
- lib/features/pos/widgets/edit_item_modal.dart (discount section, role caps, fractional-gated chips, return removed item)
- lib/shared/services/cart_service.dart (per-line discount fields + setLineDiscount + discountTotalKobo + restoreLine)
- lib/features/pos/screens/cart_screen.dart (line strikethrough/badge, Saved row, discount in total, per-cashier recall, Undo)
- lib/shared/services/order_service.dart + checkout_page.dart (forward discount to the sale)
- lib/features/inventory/widgets/add_product_sheet.dart, update_product_sheet.dart (fractional toggle)
- lib/core/providers/stream_providers.dart (currentUserMaxDiscountPercentProvider)
- lib/core/utils/notifications.dart (optional action + custom duration on the top notification)
- lib/core/database/app_database.dart + daos.dart (schema v17, saved-cart filtering/expiry, product create/update wiring)

**Database changes:**
- Local schema bumped v16 → v17: `products.allow_fractional_sales`, `saved_carts.cashier_id`, `saved_carts.expires_at` (all nullable/defaulted so existing rows survive). Migration block added.
- Server migration `supabase/migrations/0054_cart_step13.sql` adds the same three columns and threads `p_allow_fractional_sales` through the `pos_create_product_v2` RPC (parity with `track_empties`).
- **NOT YET PUSHED.** Run `supabase db push` before relying on cross-device sync of these columns — the emulator works locally without it.

**Master plan sections covered:**
- §13.2 Edit Quantity modal (discount + role caps + fractional chips), §13.3 discount display, §13.5 per-cashier + 24h saved carts. §16.5 fractional-sales product toggle.

**Decisions:**
- Per-line discount is recorded at the **order level** (summed into `orders.discount_kobo` / `net_amount_kobo`), not per line item — the server RPC has no per-item discount field and this needed no server change. Receipts/reports show the total saved, not which line.
- Note: `order_service.addOrder` keeps `netAmountKobo = totalAmountKobo` (the payable is already net of discount) — we do **not** re-subtract the discount locally, only forward it so the server records it. Re-subtracting would double-count.

**Tested:**
- `flutter analyze` — clean across all touched files (only pre-existing print infos in a test report remain).
- Full suite (excl. integration): 191 passing. Added 3 saved-cart tests (24h stamp + payload, per-cashier/unexpired filter, deleteExpiredCarts) — all green.

**Known issues / left open:**
- Manual emulator walk-through still to do: Cashier blocked / Manager cap snap / CEO unlimited; fractional chips on a fractional product; saved-cart privacy + expiry; Undo; a discounted sale's totals after sync.
- Server migration 0054 not pushed yet (see Database changes).
- Block-POS-until-Open-Day (hard rule #10) still pending the Funds Register Open Day feature (pivot step 17).

---

## Session 19 — 2026-05-30 — Point of Sale, guarded by role (§12, pivot step 12)

**Built today:**
- Made the Point of Sale screen role-aware. Most of the §12 UI already existed (price tier dropdown, store picker, out-of-stock greying, Quick Sale modal); this session added the role gates around it.
- POS now blocks anyone without "make a sale" permission. The Stock keeper was already hidden from the sidebar; now if they reach POS by any other route they see a plain "You don't have access" message instead of the till.
- The store-switcher icon in the top bar is now CEO-only. Managers and Cashiers just see the current store name; only the CEO can switch which store they're selling from.
- The Retailer/Wholesaler price dropdown is now locked for Cashiers — they stay on Retailer. CEO and Manager can still switch freely. (If a registered wholesaler customer is added to the cart, the price still switches automatically for everyone, as before.)
- Quick Sale now needs a manager. A CEO or Manager opens it straight away; a Cashier must type a CEO or Manager PIN first, and their own PIN is rejected.
- Replaced the spinning loaders on the POS screen with a gentle fade-in, matching the rest of the app.

**Files touched:**
- lib/features/pos/screens/pos_home_screen.dart

**Database changes:**
- None. Every change is read-only display/gating — no synced-table writes, no schema change.

**Master plan sections covered:**
- §12 — Point of Sale (role-based access, store selector CEO-only, price tier defaults, Quick Sale PIN gate, fade-in loading).

**Plan updates made during session:**
- Ticked the §3 build-order box for "Point of Sale, guarded by role" and marked pivot step 12 done.

**Tested:**
- `flutter analyze` on the POS screen — clean, no issues.
- Manual role walk-through still to do on the emulator (switch user across CEO / Manager / Cashier / Stock keeper).

**Known issues / left open:**
- Barcode scan for Pharmacy/Supermarket (§12.6) — deferred to pivot step 40 (needs a camera package).
- Block-POS-until-Open-Day (hard rule #10 / §12) — depends on the Funds Register Open Day feature, which doesn't exist yet (pivot step 17).
- Role-based discount caps — they live in the Cart screen, pivot step 13.
- The realtime inbound-sync bug (flagged 2026-05-30, §2.6 / pivot §7) was parked until POS landed — now eligible to fix.

**Next session should:**
- Pivot step 13: Cart + Edit Quantity modal + role-based discount caps (and the `allowFractionalSales` column). Or take the now-unblocked realtime inbound-sync fix first.

---

## Session 18 — 2026-05-30 — Sidebar role guards + profile role tag (§27, pivot step 10)

**Built today:**
- The sidebar used to show every item to everyone. Now each role only sees what it's allowed to. A Stock keeper no longer sees Point of Sale, Customers, Supplier Accounts, Expenses, Stores, Activity Logs, Staff Management, or CEO Settings — just Home, Inventory, and Orders. A Cashier additionally sees POS and Customers. A Manager sees those plus Expenses and Staff Management. The CEO sees everything.
- Visibility is decided by the same permission a role already has (e.g. a role only sees "Expenses" if it can create expenses), so it stays correct if the CEO later changes a role's permissions. Supplier Accounts and Activity Logs show for a Manager only if the CEO has granted those — matching "Manager if toggled" in the plan.
- Removed three sidebar items: Deliveries (a Phase 3 feature), Cart (it lives in the bottom bar only now), and Pro Tips. The "View Pro Tips" welcome card on Home was removed too, so Pro Tips isn't shown anywhere in Phase 1 (the tips screen stays in the code for Phase 2).
- The sidebar profile area now shows the person's role as a coloured tag (CEO yellow, Manager blue, Cashier green, Stock keeper grey), and the header tint matches.

**Files touched:**
- lib/shared/widgets/app_drawer.dart
- lib/features/dashboard/screens/home_screen.dart
- test/settings/sidebar_role_visibility_test.dart

**Database changes:**
- None.

**Master plan sections covered:**
- Section 27 (27.1 profile role tag, 27.3 visibility-by-role, 27.5 removed items) — sidebar role guards. Decisions Q7 (drop Pro Tips) and Q9 (hide CEO Settings for non-CEO — the CEO Settings gate was already in place; this pass extends the same gating to the rest).

**Plan updates made during session:**
- None. This implements the existing §27 spec.

**Tested:**
- New `sidebar_role_visibility_test` seeds all four roles with the default-grant matrix (migration 0043) and asserts each role sees exactly its §27.3 set. `flutter analyze` clean on the changed files; `flutter test test/settings/` green.

**Known issues / left open:**
- Sync Issues sidebar item was left to the concurrent CEO Settings → Devices relocation work-stream (not touched here).
- Bottom-nav POS guard for Stock keeper (so the POS tab itself is unreachable) belongs to pivot step 12 (POS role guards), not this pass.

---

## Session 17 — 2026-05-30 — Business appearance: CEO picks the colour, device keeps light/dark (§10.1)

**Built today:**
- The CEO can now choose the app's **colour for the whole business** (Amber, Blue, Purple, Green) from a new **CEO Settings → Appearance** page. The choice is synced, so every device in the business shows that colour. Default stays amber.
- **Light/dark/system mode stays a personal, per-device choice** — it did NOT move into CEO settings. The old drawer "Appearance" entry is now **"Display"** and only controls light/dark/system for the device you're on. (So a night-shift cashier can still use dark mode even if the CEO picked a light-ish colour.)
- Under the hood: the business colour lives in a synced setting (`business_design_system`). A small bridge in the app's root applies it to the running theme on every device, so a CEO's change propagates to other devices automatically. Picking a colour is CEO-only and is written to the activity log.

**Plan decision made this session (with the user):**
- Appearance wasn't in the master plan and the plan implied a fixed dark+amber brand. The user chose: **CEO picks the business colour (synced); each device keeps its own light/dark for comfort.** The master plan was updated first (§10.1 + the §4.3 note) before building.

**Files touched:**
- reebaplus_master_plan.md (§10.1 Appearance section + §4.3 accent note)
- lib/core/settings/appearance_settings_screen.dart (new — CEO colour picker, synced)
- lib/core/providers/stream_providers.dart (new `businessDesignSystemProvider` + `kBusinessDesignSystemKey`, guarded against pre-login)
- lib/main.dart (app-root bridge: synced colour → themeController)
- lib/core/settings/settings_screen.dart (new "Appearance" menu row)
- lib/core/theme/theme_settings_screen.dart (trimmed to light/dark only; titled "Display")
- lib/shared/widgets/app_drawer.dart (drawer tile relabelled "Appearance" → "Display")
- test/settings/appearance_settings_screen_test.dart (new)

**Database changes:**
- None. No migration, no schema/version bump. The colour is a synced `settings` key (`business_design_system`), set via the existing `SettingsDao.set` (which already enqueues). Light/dark stays in SharedPreferences.

**Master plan sections covered:**
- §10.1 — Appearance added (CEO business colour, synced; light/dark per-device).

**Plan updates made during session:**
- Added the Appearance section to §10.1 and a note to §4.3 (the accent is CEO-selectable, default amber; light/dark per-device).

**Tested:**
- New test: CEO picks a colour → the synced `business_design_system` setting is written ('green') + a sync upsert is enqueued + the live theme updates; a non-CEO viewer sees the no-access body (no colour cards).
- Full suite green: `flutter analyze` clean for all touched files; `flutter test --exclude-tags=integration` → all passed (186, 2 env-gated skips).

**Known issues / left open:**
- The light/dark "Display" screen and the colour "Appearance" screen are now two separate entries (drawer vs CEO Settings) by design.
- Pre-login the device shows its cached colour (or amber) until the business setting syncs in — then the bridge applies the business colour.

**Next session should:**
- Continue §11 Home (in progress) or the next core screen.

---

## Session 16 — 2026-05-30 — Home screen made role-aware (§11)

**Built today:**
- The Home screen used to show every card to everyone. Now it follows the master plan: each person only sees the cards meant for their role. A CEO sees everything (Total Sales, Net Profit, Pending Orders, Expenses, Stock Value, Customer Wallet, Staff Sales). A Manager sees the same minus Net Profit. A Cashier sees only their own sales total, Pending Orders, Customer Wallet, and a new "Total SKUs" card. A Stock keeper sees just Pending Orders and the Total SKUs card.
- The header subtitle now changes by role: CEO/Manager see "Business Overview", a Cashier sees "Today's Sales", a Stock keeper sees "Stock Overview".
- New "Total SKUs" card (for Cashier and Stock keeper) — tap it to expand a breakdown of how many products each manufacturer has.
- The store filter at the top is now locked for everyone except the CEO. A Cashier or Stock keeper is pinned to their own store. A Manager is pinned to their store too — unless the CEO turns on a new switch.
- New CEO switch: in CEO Settings → Roles & Permissions → Manager, there's now an "Allow viewing other stores" toggle. When on, a Manager can switch stores on Home to check another store's stock and request restock when running low. Off by default.

**Files touched:**
- lib/features/dashboard/screens/home_screen.dart
- lib/core/settings/role_permissions_detail_screen.dart
- lib/core/providers/stream_providers.dart
- reebaplus_MASTER_PLAN.md
- test/settings/role_permissions_detail_test.dart

**Database changes:**
- None. The new Manager toggle is stored in the existing `role_settings` table (key `manager_view_all_stores`), the same place the max-discount and max-expense limits already live. Writes route through the existing DAO, so it syncs to the cloud like the other role settings.

**Master plan sections covered:**
- Section 11 (11.1 subtitle, 11.2 store-filter lock, 11.4 cards by role, 11.5 Total SKUs) — Home made role-aware.

**Plan updates made during session:**
- §11.2 and §10.2 were refined to spell out the Manager "Allow viewing other stores" toggle: that it's built in Phase 1, lives in Roles & Permissions → Manager, defaults off, and unlocks the Home store picker (rationale: a Manager checking another store's stock to request restock). The toggle was already named in §11.2; this pins down its exact behaviour and where it lives, per the no-verbal-only-changes rule.

**Tested:**
- `flutter analyze` clean (no new issues). Full `flutter test` suite green: 184 passed, 0 failed.
- New tests: the Manager toggle defaults off, persists to `role_settings` as `'true'`, and enqueues a sync upsert; the toggle is hidden for CEO and Cashier roles; and the `managerCanViewAllStoresProvider` reads false by default and flips true once the CEO enables it.

**Known issues / left open:**
- The Reports button badge is still a hardcoded "3" placeholder — its real alert count depends on the §21 Reports work, deferred by decision.
- Per-card visibility toggles per role remain Phase-2-deferred (§11.4, §28).
- End-to-end check on the emulator (logging in as each role) not yet done this session — recommended before merge.

---

## Session 15 — 2026-05-29 — Roles & Permissions sub-page (§10.2)

**Built today:**
- The last piece of CEO Settings. The "Roles & Permissions" menu row no longer opens a "coming soon" placeholder — it now opens a real screen listing the four roles (CEO, Manager, Cashier, Stock keeper) as colour-coded cards, each showing how many of the 30 permissions it has. Tap a role to open its detail page.
- The role detail page shows every permission as an on/off switch, grouped by category (Sales, Products, Stock, Expenses, Reports, Customers, Suppliers, Staff, System, Funds — in that master-plan order). Flipping a switch grants or removes that permission for the role and syncs to the cloud.
- The CEO role is locked: all its switches are on and greyed-out, and its limits read "unlimited" — the CEO's access can never be accidentally removed.
- Below the switches are the two role limits: a **maximum discount %** slider (0–100) and a **maximum expense approval** amount (in naira). Both save when you finish adjusting them and sync to the cloud. For the CEO they show "100% (unlimited)" and "Unlimited".
- "Can change product prices" is simply the existing **Edit product prices** permission toggle in the Products group (it already had the right default: Manager on, others off) — so there's no duplicate control and no database change was needed.

**Plan decisions made this session (with the user):**
- "Can change product prices" is represented by the existing `products.edit_price` permission toggle, not a separate new setting — avoids a duplicate control and a migration.

**Files touched:**
- lib/core/settings/roles_permissions_screen.dart (new — the four role cards)
- lib/core/settings/role_permissions_detail_screen.dart (new — grouped toggles + the two limits, CEO locked)
- lib/core/settings/settings_screen.dart (route Roles & Permissions to the new screen; dropped the Coming Soon placeholder)
- test/settings/role_permissions_detail_test.dart (new)
- test/settings/roles_permissions_screen_test.dart (new)

**Database changes:**
- None. No migration, no schema/version bump. Permissions use the existing role_permissions grant/revoke; limits use the existing role_settings `set` (both already sync). The 30-permission catalog and the seeded limit defaults were already in place.

**Master plan sections covered:**
- §10.2 — Roles & Permissions per-role page (permission toggles by category + max discount % and max expense approval limits; CEO locked).
- §10.3 (custom roles, custom permission groups, more limits) remains Phase 2.

**Plan updates made during session:**
- None.

**Tested:**
- 2 new test files (7 tests), all green: CEO detail shows all 30 toggles locked-on with read-only limits; toggling a Cashier permission on grants it (sync upsert) and off revokes it (sync delete); editing the expense limit stores the right kobo value and syncs; dragging the discount slider stores a new percent and syncs; the role list renders four cards with correct counts and navigates to the detail on tap.
- Full suite green: `flutter analyze` clean for all touched files; `flutter test --exclude-tags=integration` → all passed (180, 2 env-gated skips).

**Known issues / left open:**
- Section 10 (CEO Settings) is now fully done for Phase 1. The role limits (max discount, max expense approval, edit-price permission) are stored + synced but not yet *enforced* anywhere — the screens that would honour them (POS discount, Expenses approval, Product price editing) are later sections.

**Next session should:**
- Move on to the next core screen (Home / Dashboard, §11) or another pending section.

---

## Session 14 — 2026-05-29 — CEO Settings menu + sub-pages (§10.1)

**Built today:**
- Turned the old flat "CEO Settings" screen into the proper menu from the master plan. It now lists five sections — Business Info, Stores, Security, Roles & Permissions, Activity Logs access — and each opens its own page. The old Profile card was removed (your profile is still reached by tapping your avatar in the side menu).
- **Business Info** page: edit the business name, type (the six business types), and currency, then Save. The save reaches the cloud and is written to the activity log.
- **Stores** page: read-only for now — shows your store's name and address. Adding more stores is a later (Phase 2) feature, noted on the page.
- **Security** page: auto-lock is now a row of preset chips — 1, 3, 5, 10, 15, 30 minutes. The biometric login switch was moved here and **fixed**: before, the switch saved to a place the login screen never read (so it did nothing and also leaked across devices). It now saves on the device itself, the same place login checks.
- **Activity Logs access** page: a per-role on/off switch for who can view activity logs. The CEO row is locked on and can't be turned off; other roles default off.
- **Roles & Permissions** (the detailed per-role toggles, §10.2) is **deferred** to a follow-up — its row opens a "coming soon" placeholder for now.
- The "CEO Settings" item in the side menu is now **hidden** for anyone who isn't the CEO (it was showing for everyone before).

**Plan decisions made this session (with the user):**
- **Auto-lock now defaults to 5 minutes and is always on**, matching the master plan (§10.1/§8.5). Before, the code defaulted to "Never." The new preset chips have **no "Never" option** — auto-lock can't be switched off entirely anymore, only its interval changed. (This was a deliberate plan-vs-code choice the user confirmed; the master plan already said 5 min, so no plan edit was needed.)
- **Biometric toggle kept** on the Security page (the plan's Security section only mentions auto-lock, but biometrics is an existing shipped feature, so it stays) and switched to device-local storage.

**Files touched:**
- lib/core/database/daos.dart (new `BusinessesDao.updateInfo` — edits name/type, enqueues to cloud)
- lib/core/database/app_database.dart (registered `BusinessesDao`)
- lib/core/data/business_types.dart (new — shared list of the six business types)
- lib/core/settings/settings_screen.dart (rewritten into the menu)
- lib/core/settings/settings_widgets.dart (new — shared section title / tile / fade-in / no-access widgets)
- lib/core/settings/business_info_screen.dart (new)
- lib/core/settings/stores_settings_screen.dart (new)
- lib/core/settings/security_settings_screen.dart (new)
- lib/core/settings/activity_logs_access_screen.dart (new)
- lib/shared/widgets/app_drawer.dart (hide "CEO Settings" unless the user has settings.manage)
- lib/shared/widgets/auto_lock_wrapper.dart (default interval 0/Never → 300s/5min)
- test/sync/dispatch/businesses_dao_dispatch_test.dart (new)
- test/settings/settings_menu_gating_test.dart (new)
- test/settings/activity_logs_access_toggle_test.dart (new)

**Database changes:**
- None. No migration, no schema/version bump. Business name/type write to the existing `businesses` row; currency is the existing synced `default_currency` setting; activity-log access uses the existing role-permissions.

**Master plan sections covered:**
- §10.1 — CEO Settings menu + Business Info, Stores, Security, Activity Logs access sub-pages.
- §10.2 — Roles & Permissions: deferred (placeholder route).

**Plan updates made during session:**
- None. (The auto-lock default already matched the plan once we chose "follow the plan.")

**Tested:**
- 3 new tests, all green: BusinessesDao.updateInfo enqueues a `businesses:upsert` (and coalesces repeats); the drawer "CEO Settings" gate shows for CEO and hides for Cashier; the Activity Logs toggle locks CEO on, grants (upsert) and revokes (delete tombstone) for other roles.
- Full suite green: `flutter analyze` clean for all touched files; `flutter test --exclude-tags=integration` → all passed (173, 2 env-gated skips).

**Known issues / left open:**
- Roles & Permissions detail page (§10.2) still to build.
- Stores page is view-only; the `stores` table stores address as one combined `location` string (no separate state/country columns), so the page shows name + that one line.
- Minor/benign: editing the business row triggers a realtime echo that runs `putIfAbsent('timezone','UTC')` on restore — harmless here because the real timezone lives in `settings`, not the `businesses.timezone` column. Noted, not fixed.

**Next session should:**
- Build the §10.2 Roles & Permissions sub-page (per-role permission toggles grouped by category, CEO locked on, plus the role limits: max discount %, max expense approval, can-change-prices).

---

## Session 13 — 2026-05-29 — Staff full name at sign-up (§6) + view-only own staff card (§9.5)

**Built today:**
- Staff Sign Up now asks for the new staff member's full name. Before this, sign-up never collected a name, so the cloud defaulted each user's name to their email — which is why Staff Management cards and the Who's Working picker showed email addresses instead of names. The name is captured on a new step (after the email code, before creating the PIN) and sent to the cloud at redemption. Fixing it at the source fixes every screen that shows a user's name, automatically.
- Tapping your own card in Staff Management now opens your staff detail in view-only mode. Before, your own card did nothing when tapped. View-only means you can see your details but there are no "Change role" or "Suspend" buttons — you still can't manage yourself. The greyed-out rows a Manager sees for the CEO / other Managers stay non-tappable as before.
- Also in this session (separate fix, same screen file): Staff Management no longer crashes on open. It was firing a background data refresh during the widget build, which is illegal; the refresh now waits until after the first frame. (Roster still refreshes on open and on pull-to-refresh.)

**Files touched:**
- lib/features/auth/screens/staff_sign_up_screen.dart (new full-name step; renumbered the later steps 6→7; sends the name to redeem_invite_code)
- lib/features/staff/screens/staff_detail_screen.dart (new `readOnly` flag hides the manage actions)
- lib/features/staff/screens/staff_management_screen.dart (own card opens view-only detail; chevron shown on own card; + the post-frame crash fix)
- test/auth/staff_sign_up_screen_test.dart (added: renders 7 step dots)
- test/staff/staff_detail_screen_test.dart (new: view-only hides actions; manageable shows them)

**Database changes:**
- None. No migration, no schema/version bump. The cloud `redeem_invite_code` RPC already accepted a name parameter (we were sending null); we now send the entered name. The RPC still falls back to the email only when the name is blank.

**Master plan sections covered:**
- §6 (Staff Sign Up) — full-name step.
- §9.5 (Staff detail) — own card opens view-only.

**Plan updates made during session:**
- Master plan §6 was updated by the planner (before this code): added the Full name step after OTP, bumped "6 steps → 7 steps", and noted in §6.2 that the name step is skipped for an already-linked email (Phase 2). The master plan was already edited — this session only implemented it.

**Tested:**
- `flutter analyze lib/ test/` — clean apart from the 18 pre-existing `avoid_print` infos in test/database/roles_v13_report.dart. No new issues.
- `flutter test` — full suite green: 161 passed / 58 skipped / 0 failures.
- Note on test coverage: the new step-count test guards the 6→7 renumbering. Driving the sign-up flow all the way to the name step / redemption in a widget test needs Supabase + OTP test doubles the harness doesn't have, so the `p_name` send is verified by reading the RPC (uses the name when non-blank) rather than an end-to-end test.

**Known issues / left open:**
- Staff who already signed up keep email-as-name until they're re-created (re-invite / re-sign-up on test devices). No backfill.
- Emulator pass still to do: a brand-new staff sign-up shows a real name in Staff Management + the Who's Working picker; tapping your own card opens a view-only detail.

**Next session should:**
- Continue the pivot plan (next unbuilt step), or run the emulator checks above before committing.

---

## Session 12 — 2026-05-29 — Invite codes now sync to every device (pull-path completion)

**Built today:**
- Fixed a one-sided sync bug: staff invite codes were saved to the cloud but never sent back down to other devices. A code generated on one device showed up in the Staff Management → Invites tab only on that device; every other CEO/Manager login (and the shared till) saw an empty tab. Now a code created anywhere in the business appears in the Invites tab on all devices within a sync tick (and live via realtime).
- No new feature, table, or column — this just finishes the round-trip for an existing table (invite_codes). It was deliberately left out of the pull when the only consumer was Staff Sign Up redemption (which doesn't need local rows); the Invites tab was missed.
- One-time backfill for devices that had already synced before this change: the pull is incremental (only fetches rows changed since the device's last sync), so invites that already existed would never come down. Added a one-shot, device-wide reset that clears the sync cursors once so the next pull is a full pull and backfills the existing invites. New invites already arrive normally; this only recovers the historical ones. No data loss — a full pull just re-reads and overwrites, and nothing waiting to be uploaded is touched.

**Files touched:**
- lib/core/services/supabase_sync_service.dart (added invite_codes to the pull order + a restore case; updated the stale "deferred to Staff Sign Up" comment; added `ensureBackfillOnce()` one-shot cursor reset, called at the top of `pullChanges`)
- test/sync/sync_backfill_once_test.dart (new — backfill guard: clears cursors once, keeps unrelated keys, idempotent)
- supabase/migrations/0053_pull_invite_codes.sql (new — adds invite_codes to pos_pull_snapshot)
- supabase/scripts/rollback/0053_rollback.sql (new — reverses 0053)
- test/database/invite_codes_pull_restore_test.dart (new)

**Database changes:**
- Cloud migration 0053: adds `invite_codes` to the `pos_pull_snapshot` function's table list so a pull returns the business's invite codes. No schema change — the table already existed (0042) and already pushed. Deploy 0053 before/with shipping the client change.
- No client schema change (no Drift version bump). invite_codes was already a synced table.

**Master plan sections covered:**
- §6 / §9.3 (Staff Management → Invites tab, CEO + Manager). The tab query (InviteCodesDao.watchActive) was already business-scoped; it just had no rows from other devices to show.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — (see session output; expected 18 pre-existing avoid_print infos, no new issues).
- `flutter test` — full suite + 3 new restore tests (row lands locally; used/revoked/expired/deleted codes filtered out of watchActive while the full set still pulls; restore is idempotent).
- RLS confirmed unchanged: `invite_codes_tenant_rw` (0050/0051, profiles-based) already lets a tenant's CEO/Manager SELECT their codes; pos_pull_snapshot is SECURITY DEFINER with its own tenant guard.

**Known issues / left open:**
- None for this fix. Emulator check (cross-device): generate an invite on device A → it appears in the Invites tab on device B within a pull/realtime tick.

**Next session should:**
- Continue the pivot plan (drawer rebuild §27.3, or the next unbuilt step).

---

## Session 11 — 2026-05-29 — Who Is Working picker (master plan §8, pivot step 7)

**Built today:**
- The shared-till "Who's working?" picker. It's the screen staff see all day when they switch shifts or come back after the screen auto-locks — different from the Login screen, which is only for a fresh device or a full logout.
- The picker shows the business name and today's date, the title "Who's working?", and one tappable card per active staff member (avatar initials, name, role colour tag). Suspended staff are hidden. If there's only one staff member (or none), it skips straight to the PIN screen.
- Tapping a card opens the PIN screen already pointed at that person. If that person hasn't set a PIN yet, it emails them a one-time code instead.
- A manual lock, the "Switch User" button, and the silent auto-lock now all return to this picker. A cold start (first launch of the day) still goes straight to the PIN screen as before.
- The sidebar's lock button is now a "Switch User" button (switch icon + tooltip); it behaves exactly as before, just better named for the shared-till use.
- Reused the Login screen for PIN entry by letting callers hand it a specific staff member. This also fixed a small bug where a different staff member's PIN screen could show the device-owner's email carried over from setup — the email field is now locked to whoever was picked, which keeps the PIN check pointed at the right person when two staff share a PIN.

**Files touched:**
- lib/core/database/daos.dart (new `WhoIsWorkingEntry` + `UserBusinessesDao.watchActiveStaffForBusiness`; added Users/Roles to the accessor)
- lib/core/database/daos.g.dart, lib/core/database/app_database.g.dart (regenerated)
- lib/core/providers/stream_providers.dart (new `activeStaffProvider`)
- lib/shared/services/auth_service.dart (`showPickerOnUnlock` flag)
- lib/features/auth/screens/login_screen.dart (`presetUser` param + read-only email when identified)
- lib/features/auth/screens/who_is_working_screen.dart (new)
- lib/main.dart (route to picker on unlock)
- lib/shared/widgets/app_drawer.dart (lock → Switch User control)
- lib/features/staff/screens/staff_management_screen.dart (removed leftover FAB debug print)
- test/staff/who_is_working_dao_test.dart (new)
- test/auth/pin_email_scoping_test.dart (new)
- test/auth/who_is_working_screen_test.dart (new)

**Database changes:**
- None. No new tables or columns. The picker reads existing tables (user_businesses + users + roles) through a new read-only DAO query. Nothing new is written or synced.

**Master plan sections covered:**
- §8 (Who Is Working picker) — §8.1 layout, §8.2 cards, §8.3 rules (suspended hidden, single-staff skip), §8.4 tap-to-PIN, §8.5 Switch User / auto-lock routing.
- §30.7 (no spinners) — branded fade while resolving.
- Deferred from §8.2: the "active now" dot (needs multi-till presence; not in this step's scope).

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — 18 issues, all the pre-existing `avoid_print` infos in test/database/roles_v13_report.dart. No new issues.
- `flutter test` — 155 passed, 58 skipped (baseline 150/58 + 5 new). New tests: DAO returns only active staff of the right business with role joined; getUsersByPin scopes by email when two users share a PIN; picker shows N cards with suspended hidden and tap routes to the PIN screen.

**Known issues / left open:**
- The "active now" dot (§8.2) is deferred until multi-till presence tracking exists.
- The picker resolves the business from the device user, with a single-local-business fallback. Multi-business on one device is Phase 2, so this is fine for now.
- The full labelled "Switch User" button in the redesigned drawer (§27.3 / master plan §27 line 1287) is part of the later drawer-rebuild step; this step only renamed the existing lock control.

**Next session should:**
- Continue the pivot plan (next unbuilt step after the picker). The drawer rebuild (§27.3) will replace the icon-only Switch User control with the full labelled button and the grouped sidebar items.

---

## Session 10 — 2026-05-29 — Staff Management + Invite Codes + Staff Sign Up (pivot step 8)

**Built today:**

The whole staff onboarding + management feature. Step 8 was pulled ahead of the Who-Is-Working picker (step 7): the picker has nothing to show until staff exist, so building staff first gives it real data.

- **Staff Management screen** (§9; CEO + Manager only — hidden entirely for Cashier/Stock keeper). Two tabs (Staff, Invites) with search and an "Invite new staff" button. Staff cards show avatar, name, role colour tag, and last login; suspended staff drop to a greyed section. A Manager sees the CEO and other Managers as faded read-only rows, and sees themselves as a normal card marked "You".
- **Invite a staff member** modal — pick a role and store, enter the person's email, generate an 8-character one-use code (7-day expiry), and share it by Copy / SMS / WhatsApp. A Manager can only invite Cashiers and Stock keepers, and only to their own store. Pending invites can be revoked.
- **Staff detail screen** — change role and suspend/reactivate (each behind a confirm dialog), plus total sales and last login. You can't open or manage your own card.
- **Staff Sign Up flow** (§6) — a new single screen with 6 fading steps (invite code → email → OTP → create PIN → confirm PIN → "Welcome to {business}"). The invited person enters the code, the app shows the business + role and pre-fills their email, they verify by OTP and set a device PIN, then land on Home as the right role with the right store. The Welcome and "No account found" screens' "Join with invite code" buttons now open this (they previously showed a "coming soon" placeholder).
- **Role / permission checks** — new providers for "the current user's role" and "what they're allowed to do", used to hide Staff Management from staff who can't invite and to restrict a Manager's invite options.
- **Smaller fixes:** the store dropdown no longer lists a store twice (it had been including soft-deleted / other-business stores); "last login" is now actually recorded on sign-in (it always read "Never" before); and the staff list refreshes when opened (and pull-to-refresh) so a CEO sees newly-joined staff without re-logging in.

**Decisions / scope:**
- Redemption runs server-side and the device mirrors the result locally, exactly like CEO onboarding — added as the 7th documented direct-write exception in CLAUDE.md §5.
- The "active now" dot (staff logged in on another till) is deferred — there is no presence data yet.
- "Last login" is a single timestamp; a richer "last 5 logins" history is deferred (no data source yet).
- The login email auto-fill / "this PIN belongs to multiple accounts, pick one" issue is deferred to the Who-Is-Working / login work (step 7). Logout deliberately keeps device data (shared-till model).

**Files touched:**
- New: lib/features/auth/screens/staff_sign_up_screen.dart, lib/features/staff/screens/staff_management_screen.dart, lib/features/staff/screens/staff_detail_screen.dart, lib/features/staff/widgets/invite_staff_sheet.dart
- lib/core/database/daos.dart (InviteCodesDao.revoke; UserBusinessesDao.setStatus/setRole/touchLastLogin; StoresDao.watchActiveStores)
- lib/core/providers/stream_providers.dart (currentUserRoleProvider, currentUserPermissionsProvider, hasPermission, usersByBusinessProvider; allStoresProvider now active-only)
- lib/shared/services/auth_service.dart (stamp last login on sign-in)
- lib/shared/widgets/app_drawer.dart (permission-gated Staff Management item)
- lib/features/auth/screens/welcome_screen.dart, no_account_found_screen.dart ("Join with invite code" → Staff Sign Up)
- CLAUDE.md (§5 exception #7)
- Tests: test/auth/staff_sign_up_screen_test.dart, test/staff/invite_staff_sheet_test.dart, test/sync/dispatch/staff_dao_dispatch_test.dart, plus route updates in test/auth/no_account_found_screen_test.dart and welcome_screen_test.dart

**Database changes:**
- No local schema change (still Drift v16) — the membership / invite tables already existed from v13.
- Four cloud migrations, all deployed (each with a rollback script): 0049 (lookup_invite_code + redeem_invite_code RPCs), 0050 (fix infinite-recursion in the user_businesses RLS policy — 42P17), 0051 (resolve the membership tables' RLS via profiles, matching the rest of the app — fixes the 42501 rejections), 0052 (fix an ambiguous "email" column reference in the redeem RPC — 42702). 0050–0052 were latent issues surfaced because Step 8 is the first feature to read/write these tables from the authenticated client rather than via SECURITY DEFINER RPCs.

**Master plan sections covered:**
- §6 Staff Sign Up — built.
- §9 Staff Management — built (§9.1–9.7).

**Plan updates made during session:**
- No master-plan change. CLAUDE.md §5 gained a 7th sync-exception entry (staff-redemption local mirror).

**Tested:**
- `flutter analyze lib/ test/` — clean (only the 18 pre-existing `avoid_print` infos in roles_v13_report.dart).
- `flutter test` — 150 pass, 58 skipped, 0 failures (new: invite-sheet Manager role-filter, staff DAO sync-leak, staff sign-up code step).
- On device: full invite → redeem → join loop confirmed working after the four cloud fixes; cross-role checks (Manager invite restrictions, hide-don't-grey) confirmed.

**Known issues / left open:**
- FAB can still sit behind the system nav bar on the physical device — an inset-fix attempt plus temporary debug logging are in staff_management_screen.dart, awaiting on-device inset values to finish.
- Login email auto-fill / "pick an account" picker — deferred to step 7.
- §6.2 "email already linked to another business → confirm existing PIN" — deferred to Phase 2.
- Redeem-failure message is generic ("Something went wrong, re-enter your PIN") — could be made specific later.

**Next session should:**
- Confirm the FAB on the physical device, decide the login email-fill fix (now vs step 7), then continue the pivot — Who Is Working picker (step 7) and/or CEO Settings Roles & Permissions (step 9).

---

## Session 9 — 2026-05-28 — Auth visual unification (branded look across all auth screens)

**Built today:**

Purely visual pass — no behaviour changed. Brought the older auth screens onto the same branded dark/amber look as CEO Sign Up, Welcome, and No-account-found, and pulled the shared styling into one place.

- **Two new shared widget files (single source of truth):**
  - `pin_keypad.dart` — `PinDots` (6 amber dots), `PinKey` (one 64×64 glass key), and `PinKeypad` (the full numpad, with a `leadingKey` slot for Login's biometric button).
  - `auth_form_kit.dart` — `authTitleStyle` / `authSubtitleStyle`, `AuthFormShell` (title/subtitle scroll shell), `AuthInputCard` (glass field wrapper), `AuthErrorText` (fixed-height inline error).
- **CEO Sign Up now consumes those shared widgets** (its inline `_PinDots`/`_PinPad`/`_formShell`/`_inputCard`/`_errorText` were removed). This kills the duplicate PIN-pad that used to live in both ceo_sign_up and create_pin.
- **Restyled five screens** to the branded look (`BrandedAuthBackground` + the form kit / shared PIN widgets / `AppButton`), preserving every routing branch, timer, lockout, biometric path, and the "capture providers before await" pattern:
  - **email_entry** — branded form shell, glass email field, Google + "Login with PIN" preserved.
  - **otp_verification** — matches the CEO OTP step (title, `OtpBoxRow`, verify/"Verified ✓"/resend). Expiry copy aligned to "5 minutes" (consistent with the rest of auth / master plan §7.1).
  - **existing_account** — branded business card + the real role badge (color tag).
  - **create_pin** — branded background + shared `PinDots`/`PinKeypad`, shared `ShakeWidget` (its private copy removed).
  - **login** — branded background + shared `PinDots`/`PinKeypad`, biometric button passed via `leadingKey`; success overlay + user-picker (with role tags) preserved.
- **Folded in the pending fix:** `fetchSupabaseAccount` resolves the app `users.id` from `auth_user_id` first, then queries `user_businesses` by that id (the column holds the app id, not the auth uid).

**Decisions / scope:**
- The legacy `auth_background.dart` (blurred-photo look) is intentionally **kept** — still used by the deferred screens (biometric setup, store assignment, access-granted, success-dashboard, welcome-verification) and main.dart. Expect a small visual seam at the biometric/success tail of the existing-account path; acceptable since biometric is deferred to CEO Settings.
- No logic/flow change anywhere.

**Files touched:**
- New: lib/features/auth/widgets/pin_keypad.dart, lib/features/auth/widgets/auth_form_kit.dart
- Refactored to consume shared widgets: lib/features/auth/screens/ceo_sign_up_screen.dart
- Restyled: email_entry_screen.dart, otp_verification_screen.dart, existing_account_screen.dart, create_pin_screen.dart, login_screen.dart
- Fix: lib/shared/services/auth_service.dart (fetchSupabaseAccount role lookup)

**Database changes:**
- None.

**Master plan sections covered:**
- §4.3 branded visual style (now applied across the whole auth surface). No plan change.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — clean except the 18 pre-existing `avoid_print` infos in roles_v13_report.dart.
- `flutter test` — 144 pass, 58 skipped, 0 failures (no finder tests broke from the extraction).
- Emulator: not yet run this session — see below.

**Known issues / left open:**
- **Emulator regression gate not yet run** (auth is hard to unit-test): returning-device PIN + biometric unlock; 5-wrong → forced Forgot-PIN; existing-email fresh-device → branded email → OTP → existing-account (real role) → create-PIN → Home; brand-new email → OTP → No-account-found → Create → CEO Sign Up (visually continuous); multi-user PIN sheet with role tags; CEO Sign Up still end-to-end (now consumes the extracted widgets).
- The `_UserPickerSheet` modal keeps theme-surface colors (not rebranded) — preserved per scope.

**Next session should:**
- Run the emulator regression gate above, then continue the pivot: Staff Sign Up (§6) / Who Is Working picker (§8).

---

## Session 8 — 2026-05-28 — §7 Login + Forgot PIN (pivot step 6)

**Built today:**

Targeted changes to the Login flow — most of §7 already existed (PIN entry, biometrics, attempt counter, a wired Forgot-PIN link), so this session fixed the gaps.

- **No account found (§7.1).** A brand-new email that signs in through the Login flow now lands on a proper "No account found" screen (Create a new business / Join with invite code) instead of being silently dropped into sign-up. New `no_account_found_screen.dart` (dark theme, shared branded background). The OTP screen's brand-new branch and the email screen's Google brand-new branch both route here now.
- **Double-OTP wart fixed.** "Create a new business" on the No-account-found screen hands the already-verified email to CEO Sign Up via a new `verifiedEmail` argument. When set, the sign-up flow skips its own email + OTP steps (business name → type → store → full name → create PIN → confirm PIN → ready; 7 steps, dots adjust). The Welcome path (no verified email) keeps the full 9 steps.
- **5 wrong PINs → forced Forgot-PIN (§7.1).** Dropped the old 15-minute device lockout entirely. The fifth wrong PIN now sends an email OTP and routes into the existing reset flow (OTP → create new PIN → biometric setup → signed in). The 3rd/4th wrong attempt still warns "N attempts remaining" — reworded from "before lockout" to "before PIN reset".
- **"Owner" hardcode → real role (§8.2).** Built a reactive role-badge resolver (`userRoleProvider`) that resolves a user's role by id (works before login binds a business, e.g. the shared-PIN picker). Replaced the literal "Owner" in five places: the login user-picker, the existing-account card, and three spots in the profile screen (two app-bar subtitles + the role tag). Each shows the real role name with the master-plan color tag (CEO amber, Manager blue, Cashier green, Stock keeper grey). The existing-account screen is reached before any local pull, so it reads the role from the cloud (added to `SupabaseAccountInfo`).

**Decisions / scope (told to the user up front):**
- §5.2 "one PIN across businesses" and the §7.2 multi-business picker stay **Phase 2** (they depend on multi-business membership + cross-device PIN). Phase 1's existing "email already linked to X — sign out & use a different email" handling stays.
- **PINs stay local-only** (device unlock; email/OTP = portable identity). The Phase-2 "PIN portability" goal is met by local re-establishment after OTP, not by cloud-storing a brute-forceable 6-digit hash. Documented in the master plan (§7.4 + §28); no schema or CLAUDE.md change — those already state PINs are local-only.

**Files touched:**
- lib/features/auth/screens/no_account_found_screen.dart (new)
- lib/features/auth/screens/login_screen.dart (removed 15-min lockout + lockout UI; 5-wrong forces Forgot-PIN; user-picker role badge; robust `_forgotPin` email)
- lib/features/auth/screens/ceo_sign_up_screen.dart (`verifiedEmail` arg + email/OTP step skip + dot mapping)
- lib/features/auth/screens/otp_verification_screen.dart, email_entry_screen.dart (brand-new branch → No-account-found)
- lib/features/auth/screens/existing_account_screen.dart (real role tag from cloud)
- lib/features/profile/screens/profile_screen.dart (real role in 3 spots)
- lib/shared/services/auth_service.dart (`SupabaseAccountInfo` carries roleName/roleSlug; fetch from cloud)
- lib/shared/utils/role_display.dart (new — `roleTagColor` by slug)
- lib/core/providers/stream_providers.dart (`userRoleProvider` + two private non-scoped helpers)
- lib/core/database/daos.dart (`RolesDao.watchAllUnscoped`, `UserBusinessesDao.watchForUser`)
- test/auth/no_account_found_screen_test.dart (new — 2 tests)
- reebaplus_master_plan.md (§7.3 forced-path note, new §7.4 PIN local-only, §28 PIN-portability entry)

**Database changes:**
- None. No schema change (still v16), no cloud migration.

**Master plan sections covered:**
- §7 Login Flow (§7.1 no-account-found + 5-wrong-force, §7.3 forgot-PIN verified, new §7.4 PIN storage/recovery).
- §8.2 role color tags (CEO/Manager/Cashier/Stock keeper).
- §28 Phase 2 — PIN portability entry.

**Plan updates made during session:**
- Master plan only: added §7.3 forced-path bullet, new §7.4 (PIN local-only intent), and a §28 Phase-2 PIN-portability entry. No behavioural plan change.

**Tested:**
- `flutter analyze lib/ test/` — clean except the 18 pre-existing `avoid_print` infos in roles_v13_report.dart.
- `flutter test` — 144 pass (142 prior + 2 new No-account-found tests), 58 skipped, 0 failures.
- Emulator: not yet run this session — see below.

**Known issues / left open:**
- **Emulator smoke not yet run** for: returning-device PIN → role badge; fresh-device existing account → OTP → set device PIN; brand-new email → OTP → No-account-found → Create (7-step, email/OTP skipped); 5 wrong PINs → forced reset.
- Shared PIN-pad widget duplication (create_pin_screen + ceo_sign_up_screen) — tracked tech-debt, not done.
- §5.2 / §7.2 multi-business confirm-PIN + picker — Phase 2.

**Next session should:**
- Run the emulator smoke list above, then continue the pivot: Staff Sign Up (§6) / Who Is Working picker (§8).



**Built today:**

Two pieces, done in order.

- **Task A — roles reach the local DB on pull.** The 5 role/membership tables (`roles`, `role_permissions`, `role_settings`, `user_businesses`, `user_stores`) were seeded cloud-side by `complete_onboarding` and already pushed from the client, but the *pull* path never listed them — so a fresh device's role tables stayed empty. Added them to the pull in three places: the cloud snapshot function (`pos_pull_snapshot`), the client's pull order, and the restore handlers. Now a sign-up pulls the 4 default roles (+ their permissions/settings + the CEO's membership/store link) down to the device. New test proves a role-bearing snapshot restores locally.

- **Task B — one CEO Sign Up screen, nine fading steps (master plan §5).** Replaced the old 8-screen onboarding chain (which ran email-first and in a different order) with a single screen that fades between the 9 steps in the master-plan order: business name → business type → store details → full name → email → OTP → create PIN → confirm PIN → "your business is ready". A small dots indicator sits at the top. Business name first; email/OTP mid-flow; explicit confirm-PIN; store details has searchable State + Country (default Nigeria) with currency auto-filling from the country. The "business is ready" step auto-continues to Home after 3 seconds, and the Add-Product sheet auto-opens on the first Home frame (behaviour kept from the old success screen).
- The six business types are the master-plan set (Restaurant, Supermarket, Bar, Beer distributor, Pharmacy, Boutique) — not the old 8-item list.
- Dropped from the flow (not in §5): business phone, business email, timezone, tax-reg-number. The commit feeds safe defaults (business email = CEO email, phone = '', timezone = Africa/Lagos, tax-reg = none); currency comes from the country.
- Biometric setup is no longer part of the CEO flow (it'll be wired into CEO Settings › Security later). The biometric screen file stays (the PIN-reset / staff path still uses it).
- The Welcome "Create a new business" button now opens the new screen. The Welcome background (dark + amber glow + dot grid) was extracted into a shared widget so both screens match.

**Decisions / conflicts resolved (told to the user up front):**
- OTP resend cooldown is **30s** (master plan §5.1) — the old login OTP screen used 60s.
- OTP step shows "expires in 5 minutes" (master plan) — actual expiry is whatever Supabase is configured for (server-side, unchanged).
- Progress indicator is plain dots (master plan says "small dots") rather than the old labelled 7-step indicator, which doesn't fit 9 steps.
- **New-email login fallthrough repointed.** The kept login screens (`email_entry`, `otp_verification`) used to route a brand-new email into the old chain. They now route to the new CEO Sign Up screen (which re-collects email/OTP). This is a known double-OTP wart for the rare "Sign in → brand-new email" path; the proper "No account found" handling (§7.1) lands with the login restructure (PIVOT_PLAN step 6).

**Files touched:**
- supabase/migrations/0048_pull_roles_tables.sql (new — DEPLOYED 2026-05-28; 0047 was already remote)
- supabase/scripts/rollback/0048_rollback.sql (new)
- lib/core/services/supabase_sync_service.dart (`_pullOrder` + 5 restore cases + `restoreTableDataForTesting` seam)
- lib/features/auth/screens/ceo_sign_up_screen.dart (new — the single-screen flow; PIN-step crash fix: split create/confirm shake keys so the shared GlobalKey isn't duplicated during the AnimatedSwitcher cross-fade)
- lib/features/auth/widgets/branded_auth_background.dart (new — extracted Welcome background)
- lib/features/auth/onboarding/onboarding_draft.dart (email mutable, set at step 5; stale doc comments updated)
- lib/features/auth/screens/welcome_screen.dart (CTA → CeoSignUpScreen; uses shared background)
- lib/features/auth/screens/email_entry_screen.dart, otp_verification_screen.dart (new-email branch → CeoSignUpScreen)
- lib/core/data/countries.dart, currencies.dart, nigerian_states.dart (new — Autocomplete data, no new packages)
- test/database/roles_pull_restore_test.dart (new — 2 tests)
- DELETED: business_type_selection_screen.dart, new_owner_name_screen.dart, business_details_screen.dart, location_details_screen.dart, business_settings_screen.dart

**Database changes:**
- No local schema change (still v16).
- Cloud 0048 DEPLOYED 2026-05-28 (`supabase db push`). Correction: the remote was already at 0047 — the earlier "cloud through 0046 / 0047 undeployed" notes (Sessions 4/5 and this entry's first draft) were stale. Remote is now at 0048.

**Master plan sections covered:**
- §5 (CEO Sign Up) — built, new-email path. §5.2 existing-email branch deferred.
- Touches §4 (Welcome CTA repoint), §2.4 (roles now pulled), §30.6 (currency auto-fill / Nigeria default).

**Plan updates made during session:**
- None to the master plan. PIVOT_PLAN step 5 is the work; no scope change.

**Tested:**
- `flutter analyze lib/ test/` — clean except the 18 pre-existing `avoid_print` infos in roles_v13_report.dart.
- `flutter test` — 142 pass (140 prior + 2 new restore tests), 58 skipped, 0 failures.
- Emulator smoke (user-run): full 9-step §5 sign-up, the PIN-step crash fix, and `complete_onboarding` all work end-to-end. The §5 "4 roles in the local DB" role-check is deferred to staff onboarding (now unblocked since cloud 0048 is deployed).

**Known issues / left open:**
- **§5 role-check not yet confirmed on-device.** Cloud 0048 is deployed, so a fresh sign-up's post-onboarding pull should now land 4 roles + their permissions/settings + 1 user_businesses + 1 user_stores locally — to be verified during staff onboarding (§6).
- **Double-OTP** on the "Sign in → brand-new email" path (see decisions above) — cleaned up in step 6.
- §5.2 existing-email → confirm-existing-PIN branch deferred.
- `auth_service.createNewOwner` is still dead (no callers) and its internal comment still names a deleted screen — left untouched (out of scope; surgical).

**Next session should:**
- Run the emulator smoke + DB checkpoint above. Then continue PIVOT_PLAN: Staff Sign Up (§6) / Login restructure (§7, incl. "No account found" + "Owner" hardcode removal), per the recommended order.

**Session 7 follow-ups (same session):**
- Store-name field placeholder set to "Abuja Branch".
- Fixed a duplicate-GlobalKey crash in the PIN step: the create (step 6) and confirm (step 7) bodies both came from `_buildPinStep()` sharing one `ShakeWidget` GlobalKey, and the AnimatedSwitcher kept both mounted during the cross-fade. Split into `_createPinShakeKey` / `_confirmPinShakeKey` (mismatch path shakes the create key via a post-frame callback since step 6 isn't mounted yet at that synchronous point).

---

## Session 6 — 2026-05-28 — Welcome screen (master plan §4)

**Built today:**
- The new Welcome screen — the first screen on a fresh install and after a full logout (master plan §4). Branded entry, centred: logo (with an "RP" rounded-square fallback per §4.1), "Reebaplus", the tagline, an amber **Create a new business** button, an outlined **Join with invite code** button, an "Already have an account? Sign in" link, and the Terms/Privacy small print.
- §4.3 visuals: dark base (`adBg`) with a faint dotted grid (CustomPaint), a soft amber glow from the top-right corner (RadialGradient), and a gentle fade + slide entrance driven by an AnimationController — no spinner (§30.7).
- `ComingSoonScreen` — one reusable dark placeholder, used for Join / Terms / Privacy.
- **Scope split (decided with the user):** this session built the Welcome screen ONLY. The §5 CEO sign-up restructure is the next step and will be **faithful to §5** (one screen, 9 fading steps + dots, business-name first, email/OTP mid-flow).
- **Routing:** `main.dart` fresh-device branch now returns `WelcomeScreen` (was `EmailEntryScreen`); returning-device → `LoginScreen` unchanged; a full logout re-renders this branch → Welcome (verified the `fullLogout` path nulls the device-user notifier; updated its stale comment).
- **CTA destinations (today's entry points):** Create a new business / Sign in → `EmailEntryScreen` (it branches new-vs-existing by email); Join with invite code → the placeholder. The §5 restructure will later repoint "Create a new business" to the business-name step; the real invite-code entry is step 8.
- Reused `AppButton` (amber primary + outline), `SmoothRoute`, and the `colors.dart` tokens — no new theming or button widgets.

**Files touched:**
- lib/features/auth/screens/welcome_screen.dart (new)
- lib/features/auth/screens/coming_soon_screen.dart (new)
- lib/main.dart (fresh-device branch → WelcomeScreen; dropped the now-unused EmailEntryScreen import)
- lib/shared/services/auth_service.dart (comment-only: fullLogout now routes to WelcomeScreen)
- test/auth/welcome_screen_test.dart (new — 2 widget tests: renders logo/name/tagline + 3 CTAs; Join routes to the placeholder)

**Database changes:**
- None. UI only — no schema, cloud, or migration change; nothing to deploy.

**Master plan sections covered:**
- §4 (Welcome screen) — built. §4.2 CTA routing wired to current entry points (final §5/§8 destinations come in later steps).

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — clean (only the 18 pre-existing `avoid_print` infos in roles_v13_report).
- `flutter test` — 140 passing / 58 skipped, 0 failures (2 new Welcome widget tests).
- Emulator smoke (run by the user): fresh install → Welcome; CTAs route correctly; after full logout → returns to Welcome; a returning device user still goes to `LoginScreen`. Confirmed clean.

**Known issues / left open:**
- "Join with invite code" is a placeholder until step 8 (manual invite-code entry / staff sign-up). "Create a new business" and "Sign in" both currently land on `EmailEntryScreen` — differentiation arrives with the §5 restructure.
- The "Owner" hardcode (existing_account_screen.dart, profile_screen.dart) is untouched — that's step 6.

**Next session should:**
- Begin the §5 CEO Sign Up restructure, faithful to §5: one screen with content fading between the 9 steps + dots indicator, reordered to business-name first with email/OTP at steps 5–6, store details with searchable state/country + currency auto-fill, explicit Confirm-PIN, and the "business is ready" screen. Biometric setup moves out of the flow (PIVOT_PLAN §10). Role seeding already works server-side via `complete_onboarding` — no backend change needed for the checkpoint.

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
