# VERIFICATION_PLAN.md — Testing & verifying everything built through Session 35

A step-by-step plan to confirm that the Phase-1 work logged in `BUILD_LOG.md`
(Sessions 1–35) actually works — code, sync, and on-device behaviour. Plain
English. Work the layers top to bottom: each is cheaper and catches more than
the one below it, so a failure early saves you the expensive manual passes.

Tick boxes as you go. When something fails, note it under "Findings" at the
bottom rather than fixing in place — that keeps the pass honest.

---

## What has actually been built (the scope of this plan)

Done / mostly done in Phase 1, and therefore worth verifying:

- **Auth** — Welcome (§4), CEO Sign Up 9-step (§5), Staff Sign Up 7-step (§6),
  Login + Forgot PIN (§7), Who's Working picker (§8).
- **Staff Management** — roster, invite codes, suspend/role-change, staff detail (§9).
- **CEO Settings** — Business Info, Stores (view-only), Security, Roles &
  Permissions, Activity Logs access, Appearance/colour (§10).
- **Home** — role-aware cards, store-filter lock, Total SKUs (§11).
- **Point of Sale** — role guards, store selector CEO-only, price-tier dropdown,
  Quick Sale PIN gate, **tier-correct pricing** (Session 35 fix) (§12).
- **Cart** — per-item discounts + role caps, fractional chips, per-cashier saved
  carts (24h expiry), Undo on remove (§13).
- **Funds Register Phase 1** — per-store Cash Till + CEO-added POS/Bank accounts,
  Open Day, the POS opening-cash gate, sale credits the chosen account,
  Add-Funds top-up credits funds (§23, partial — Close Day still open).
- **Checkout** — two-step payment, receiving-account picker, wallet-info checkbox (§14).
- **Receipt** — QR removed, wallet-info line (§15, partial).
- **Customers** — soft-delete, Crates-tab gate, required phone,
  `set_debt_limit` permission, Add-Funds with account picker (§18, partial).
- **Inventory + Product Details** — full Add Product screen, three price tiers,
  expiry, role-aware Product Details, Stock keeper Update-Stock modal (§16, partial).
- **Sync foundation** — per-table realtime channels, partial-upsert sweep,
  FK-resilient restore, cross-business isolation (owner-fallback RLS), funds pull.

**NOT built / partial — do NOT spend manual-test time here yet:** Orders screen
(§19), Daily Stock Count (§17), Expenses approval (§20), Supplier Accounts (§21),
Track Shipments (§22), Reports hub (§25), Notifications wiring (§26), Activity
Logs feature screen (§24), Close Day + reconciliation (§23.6/§23.8), Customer
Edit flow + GPS capture, barcode scanner (§12.6). These are Ring 1–3 work in
`PIVOT_PLAN.md §8.0`.

---

## Layer 0 — Automated baseline (run first, every time, ~minutes)

These are the cheapest gates. Get them green before touching a device.

- [ ] **Static analysis.** `flutter analyze`
  - Expected: clean except the ~18 pre-existing `avoid_print` infos in
    `test/database/roles_v13_report.dart`. Any NEW error/warning is a fail.
- [ ] **Unit + widget suite.** `flutter test --exclude-tags=integration`
  - Expected (confirmed 2026-05-31): **231 passed / 2 skipped / 0 failed.** With
    `--exclude-tags=integration` the ~56 Tier-2 integration tests are *filtered
    out* (not counted), so the live tally shows `~2` — the two intentionally
    `skip:true` checkout widget tests. (Running the suite *without* the exclude
    flag is where the historical "58 skipped" comes from.) **0 failures is the bar.**
- [ ] **Migration round-trip.** Already inside the suite, but eyeball it:
    `flutter test test/database/migration_upgrade_test.dart`
  - Expected: v17 / v19 / v21 → v23 upgrades all pass the schema audit (proves
    the `'topup'` CHECK rebuild from Session 33 preserved indexes + triggers).
- [ ] **Sync-invariant tests.** `flutter test test/sync/`
  - Expected: green. These guard the contract in CLAUDE.md §5 — payload
    whitelist, partial-upsert full-row enqueue, FK-resilient restore, funds
    restore, backfill-once. A failure here means a sync leak.

**Gate:** do not proceed to manual testing until Layer 0 is fully green.

---

## Layer 1 — Tier-2 integration tests (real Supabase RPCs, ~10 min setup once)

These hit a **dev** Supabase project and verify the v2 domain RPCs end-to-end
(round-trip, idempotent replay, tenant-guard atomicity). They self-skip when env
vars are absent — which is why they show as "skipped" in Layer 0.

- [ ] **One-time setup** per `test/integration/README.md`: create a dev test
  user + business, capture the refresh token, export the six `TEST_*` env vars.
  **Never point these at production.**
- [ ] **Run them.** `flutter test test/integration/ --tags=integration`
  - Covers: `complete_onboarding`, `pos_record_sale_v2`, `pos_create_product_v2`,
    `pos_inventory_delta_v2`, `pos_create_customer`, `pos_cancel_order`,
    `pos_record_expense`, `pos_record_crate_return`, `pos_approve_crate_return`,
    `pos_record_crate_return`, `pos_void_wallet_txn`, `pos_wallet_topup`.
- [ ] **Confirm cloud migrations are live.** `supabase migration list`
  - Expected: remote at **0063** (latest is the funds `'topup'` reference_type).
    If remote is behind, `supabase db push` (pre-authorized) before trusting any
    cross-device test.

---

## Layer 2 — On-device single-device walkthrough (the documented backlog)

Run on the Android emulator (`flutter run` — **never** `flutter build apk`).
This burns down the on-device backlog noted across Sessions 27–35. Verified
through Session 26 already; Sessions 27–35 changes are the priority.

Do the walkthrough as a fresh business so every step has real data. For each
feature, switch across the four roles (CEO → Manager → Cashier → Stock keeper)
where the master plan differentiates them.

### 2.1 Onboarding & CEO Sign Up (§5)
- [ ] Fresh install → Welcome screen shows logo, name, tagline, 3 CTAs, fade-in.
- [ ] "Create a new business" → 9 steps in order (name → type → store → full name
  → email → OTP → PIN → confirm → ready). Dots track steps; Back keeps values.
- [ ] Obvious PINs (000000, 123456, 111111) are blocked.
- [ ] "Business is ready" auto-continues to Home after 3s; Add Product sheet opens.
- [ ] **DB checkpoint:** after sign-up, 4 default roles + permissions/settings + 1
  `user_businesses` + 1 `user_stores` land locally (Session 7 deferred check).

### 2.2 Staff invite + Staff Sign Up (§6, §9)
- [ ] As CEO: Staff Management → invite a Cashier to the store → 8-char code,
  7-day expiry, Copy/SMS/WhatsApp share.
- [ ] As Manager: can only invite Cashier/Stock keeper, only to own store.
- [ ] Redeem the code on a second device/fresh session: code → email (must match)
  → OTP → **full name** → PIN → confirm → "Welcome to {business}" → Home as the
  right role + store.
- [ ] New staff shows their **real name** (not email) in Staff Management and the
  Who's Working picker (Session 13 fix).
- [ ] Suspend a staff member → drops to greyed section; reactivate restores.
- [ ] Manager sees CEO/other Managers as faded read-only rows; own card = "You".

### 2.3 Who's Working picker + lock/login (§7, §8)
- [ ] Switch User / auto-lock / manual lock → Who's Working picker (not Welcome).
- [ ] Suspended staff hidden; single-staff skips straight to PIN.
- [ ] Tap a card → PIN screen pinned to that person (email locked, not editable).
- [ ] 5 wrong PINs → forced Forgot-PIN (OTP → new PIN), **no timed lockout**.
- [ ] Cold start (first launch of day) → PIN screen directly.

### 2.4 CEO Settings (§10) — CEO only
- [ ] "CEO Settings" hidden in sidebar for non-CEO roles (hard rule #7).
- [ ] Business Info: edit name/type/currency → Save reaches cloud + activity log.
- [ ] Security: auto-lock preset chips (1/3/5/10/15/30, no "Never"); biometric
  toggle persists **device-local** and login actually reads it.
- [ ] Roles & Permissions: 4 role cards by tier (CEO→Manager→Cashier→Stock keeper,
  never alphabetical); CEO locked all-on; toggling a Cashier permission
  grants/revokes + syncs; max-discount slider + max-expense limit save + sync.
- [ ] Activity Logs access: CEO row locked on; other roles default off.
- [ ] Appearance: CEO picks colour (Amber/Blue/Purple/Green) → applies app-wide,
  synced; light/dark stays per-device under "Display".

### 2.5 Home, role-aware (§11)
- [ ] CEO: all cards (Total Sales, Net Profit, Pending Orders, Expenses, Stock
  Value, Customer Wallet, Staff Sales). Manager: same minus Net Profit.
- [ ] Cashier: own sales, Pending Orders, Customer Wallet, Total SKUs only.
  Stock keeper: Pending Orders + Total SKUs only.
- [ ] Subtitle by role (Business Overview / Today's Sales / Stock Overview).
- [ ] Store filter locked for all but CEO; Manager unlocks only if CEO enabled
  "Allow viewing other stores".
- [ ] Total SKUs card expands a per-manufacturer breakdown.

### 2.6 Inventory + Product Details (§16) — Sessions 23–25
- [ ] Add Product full screen: Retailer + Wholesaler (both required), Buying
  (hidden unless `products.edit_buying_price`), optional Expiry, Empty Crate
  Value shown only when "Track empty crate returns" is on.
- [ ] Inventory list: Category dropdown, compact stat cards, header search,
  near-expiry products bubble to top with an expiry chip.
- [ ] Product Details: view-only until Edit; one "Save Product" saves all fields;
  Sales Target is **CEO-only** (Manager read-only); live stock after Update Stock.
- [ ] Stock keeper: restricted view (no Edit, no Supplier/Buying) but gets the
  Update-Stock modal (Add/Remove, reason required on Remove → History log).
- [ ] Cashier: view-only.
- [ ] Tabs/FAB guards: Add Product → `products.add`; Suppliers → `suppliers.manage`;
  Empty Crates only for Bar/Beer distributor; History hidden from Cashier.

### 2.7 Funds Register + POS Open-Day gate (§23) — Session 26 + 33
- [ ] Funds Register sidebar item shows only for Manager/CEO (hidden for Cashier/
  Stock keeper). Replaces old Cash Register (hard rule #8).
- [ ] Each store auto-gets a Cash Till; CEO adds POS/Bank (with account number);
  CEO can remove ones they added.
- [ ] Re-adding a previously-removed account **name** reactivates (no crash) —
  Session 33 fix.
- [ ] Before Open Day: POS is **blocked** (hard rule #10). Cashier sees "wait for
  Manager/CEO"; Manager/CEO sees "Tap to enter" → jumps to Open Day.
- [ ] Manager/CEO enters starting balance per account → opens day → POS unblocks.
- [ ] Live "today's balances" view sums correctly.

### 2.8 POS + tier pricing (§12) — Session 19 + **35 (money bug)**
- [ ] Stock keeper reaching POS by any route sees "no access" (not the till).
- [ ] Store-switcher icon CEO-only; Manager/Cashier see store name only.
- [ ] Cashier locked to Retailer tier; CEO/Manager can switch.
- [ ] **Tier-price regression (Session 35):** add a wholesaler customer (or pick
  Wholesaler) → the line is **charged** the wholesaler price, not retailer.
  Verify the amount on the cart line, at checkout, and on the recorded sale all
  match the wholesaler price. This was the shipped money bug — verify carefully.
- [ ] Quick Sale: CEO/Manager open directly; Cashier must enter a CEO/Manager PIN
  (own PIN rejected).

### 2.9 Cart (§13) — Session 20
- [ ] Per-item discount: Cashier blocked ("Ask Manager"); Manager over cap snaps
  to max ("Capped"); CEO unlimited. Cap reads the per-role setting.
- [ ] Discount shows on the line (strikethrough + badge + "Saved ₦X") and is taken
  off the total; the recorded sale stores the discount (books are right).
- [ ] Fractional ±0.5 chips appear **only** for products with "Allow fractional
  sales" on.
- [ ] Saved carts private to each cashier; stale (>24h) cleared on opening Recall.
- [ ] Remove item → 5s "Undo" banner restores it exactly.
- [ ] "Go to Cart" FAB opens the Cart (slot 8), matching bottom-nav + sidebar
  (Session 24 off-by-one fix).

### 2.10 Checkout + Receipt (§14, §15) — Sessions 26, 30
- [ ] Two-step payment; Step 2 receiving-account picker (defaults Cash Till).
- [ ] Cash/card/transfer credits the chosen funds account; wallet/credit sales
  move **no** account money. Walk-ins go straight to the account, never a wallet
  (hard rule #14).
- [ ] **Funds guard (Session 33):** a paid sale with no business date is rejected,
  not silently dropped from the ledger.
- [ ] "Add wallet info to receipt" checkbox: off by default; shown only for
  registered customers; when ticked, wallet balance prints on screen + thermal.
- [ ] **No QR code** on either receipt (hard rule #8 / §15.3).

### 2.11 Customers + wallet (§18) — Session 31, 33
- [ ] Add Customer: phone now **required**.
- [ ] Crates tab on customer profile shows only for Bar/Beer distributor.
- [ ] Soft-delete (CEO/Manager only via `customers.delete`): trash button, confirm
  dialog notes history stays; customer hidden from list, sales/wallet intact
  (hard rule #9). Cashier cannot see the button.
- [ ] "Set debt limit" requires the new `customers.set_debt_limit` (CEO/Manager);
  a Cashier cannot set limits.
- [ ] **Add Funds (Session 33):** sheet lets you pick the receiving funds account;
  top-up writes wallet credit + `payment_transactions` + a `'topup'`
  `fund_transactions` credit atomically with the real staff id (coding rule #5).

---

## Layer 3 — Two-device / cross-device sync (needs 2 emulators or 2 devices)

Confirmed working at Session 27 (realtime) — re-verify after the Session 28–35
sync changes.

- [ ] **Realtime delivery:** change on device A (new product / Open Day / CEO
  colour / price edit) lands on device B within a tick, **no manual pull**.
- [ ] **Invite codes pull (Session 12):** invite generated on A appears in the
  Invites tab on B.
- [ ] **Funds Open Day pull (Session 26 follow-up 0060):** CEO opens the day on A
  → staff till B sees POS unblocked (Open Day pulled down, not just pushed up).
- [ ] **Cross-business isolation (Session 32):** a CEO who owns business 1 can
  still edit business 1's name/type even after touching a second business (no
  42501); device B signed into a different business never shows business 1's rows.
- [ ] **Partial-upsert fixes (Sessions 28–29):** edit a manufacturer's Empty Crate
  Value / soft-delete a product / assign a rider on A → the change reaches B (no
  stuck `23502` row in Sync Issues).
- [ ] **Sync Issues screen:** open it on both devices — should be empty. Any
  errno-7 host-lookup errors are device DNS/VPN, not code (memory note).

---

## Layer 4 — Regression spot-checks for the freshest fixes (Sessions 28–35)

These are the least-verified changes — give them a focused pass even if Layer 2
covered them in passing.

- [ ] **S35 tier pricing:** wholesaler line charged wholesaler price end-to-end
  (covered by `test/pos/cart_tier_pricing_test.dart` + manual 2.8).
- [ ] **S33 midnight rollover:** leave the till open past the business-day
  boundary → "today" rolls over, POS gate + ledger re-key to the new day, new
  sales bucket under the new date (hard to script — observe or set device clock).
- [ ] **S33 account re-add:** covered by `funds_register_dao_test` + manual 2.7.
- [ ] **S33 opening-cash gate race:** cold-start POS doesn't briefly render
  unblocked before the store locks.
- [ ] **S32 owner-fallback RLS:** the stuck business-edit from the bug report now
  flushes (Sync Issues clears it).
- [ ] **S23 Cashier restore crash:** a Cashier logging into a second device with a
  product whose supplier/manufacturer hasn't arrived yet does **not** crash; the
  orphan surfaces in Sync Issues "Catching up" and retries.

---

## Layer 5 — Role-permission matrix sweep (hard rules #6 / #7)

Cross-cutting: for **each** of CEO / Manager / Cashier / Stock keeper, confirm
unauthorized items are **hidden entirely**, never greyed (exception: suspended
staff in Staff Management).

- [ ] Sidebar set per role matches §27.3 (Stock keeper: Home/Inventory/Orders
  only; Cashier adds POS/Customers; Manager adds Expenses/Staff Mgmt; CEO all).
- [ ] No removed items anywhere: QR on receipt, Deliveries sidebar, Cash Register
  sidebar, Cart sidebar (hard rule #8).
- [ ] No raw UUIDs in user-facing text — short codes only (ORD-/INV-/REC-). Known
  open: some Orders snackbars still show raw UUIDs (tracked, Ring 3).
- [ ] Every write that should also write `activity_logs` does (coding rule #3).
  Known open: account add/remove not yet logged (Ring 0 helper pending).

---

## Suggested order of execution

1. Layer 0 (automated) — must be green first.
2. Layer 1 (integration) — once env is set up; cheap to re-run after.
3. Layer 2 (single-device walkthrough) — the bulk; burns down the backlog.
4. Layer 3 (two-device sync) — needs a second device; do after 2 is clean.
5. Layers 4 & 5 — focused regression + permission sweep; can interleave with 2.

---

## Findings (log failures here as you go)

| Layer / step | What happened | Severity | Notes |
|---|---|---|---|
| | | | |
