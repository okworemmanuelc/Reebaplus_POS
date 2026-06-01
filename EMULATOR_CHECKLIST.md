# EMULATOR_CHECKLIST.md — On-device tests to verify by hand

Extracted from `verification_plan.md` Layers 2–5: only the things you check on
the emulator. Layer 0 (analyze + 231 tests + migrations + sync) is already
**green** and Layer 1's cloud schema is confirmed at **0063** — no device work
needed there.

Switch across the four roles (CEO → Manager → Cashier → Stock keeper) wherever a
step differs by role. Log failures in the table at the bottom.

---

## A. Onboarding & auth (needs a FRESH business — wipe app data first)

### A1 — CEO Sign Up (§5)
- [ ] Fresh install → Welcome shows logo, name, tagline, 3 CTAs, fade-in.
- [ ] "Create a new business" → 9 steps in order (name → type → store → full name
  → email → OTP → PIN → confirm → ready). Dots track steps; Back keeps values.
- [ ] Obvious PINs (000000, 123456, 111111) are blocked.
- [ ] "Business is ready" auto-continues to Home after 3s; Add Product sheet opens.
- [ ] DB checkpoint: 4 default roles + permissions/settings + 1 `user_businesses`
  + 1 `user_stores` land locally after sign-up.

### A2 — Staff invite + Staff Sign Up (§6, §9)
- [ ] As CEO: Staff Mgmt → invite a Cashier → 8-char code, 7-day expiry,
  Copy/SMS/WhatsApp share.
- [ ] As Manager: can invite ONLY Cashier/Stock keeper, ONLY to own store.
- [ ] Redeem on a second device/session: code → email (must match) → OTP →
  full name → PIN → confirm → "Welcome to {business}" → Home as right role+store.
- [ ] New staff shows REAL NAME (not email) in Staff Mgmt + Who's Working picker.
- [ ] Suspend a staff member → drops to greyed section; reactivate restores.
- [ ] Manager sees CEO/other Managers as faded read-only rows; own card = "You".

### A3 — Who's Working picker + lock/login (§7, §8)
- [ ] Switch User / auto-lock / manual lock → Who's Working picker (not Welcome).
- [ ] Suspended staff hidden; single-staff skips straight to PIN.
- [ ] Tap a card → PIN screen pinned to that person (email locked, not editable).
- [ ] 5 wrong PINs → forced Forgot-PIN (OTP → new PIN), NO timed lockout.
- [ ] Cold start (first launch of day) → PIN screen directly.

---

## B. CEO Settings (§10) — log in as CEO

> Reach via the side drawer → **CEO Settings**. The whole area is gated by the
> `settings.manage` permission (CEO only by default). Each change also writes an
> `activity_logs` row (coding rule #3) — the in-app Activity Logs *viewer* (§24)
> isn't built yet, so treat those as "verify later / via DB" unless you're
> checking the table directly. Cloud-sync of each change is re-verified in
> section D, not here.

### B0 — Access guard + menu (hard rules #6/#7)
- [ ] As **CEO**: side drawer shows a "CEO Settings" item; tapping it opens a menu
  titled **"CEO Settings"**.
- [ ] As **Manager / Cashier / Stock keeper**: "CEO Settings" is **absent** from
  the drawer entirely (not greyed).
- [ ] Menu shows exactly **6 rows in this order**, each with a chevron:
  1. Business Info — "Name, type, and currency"
  2. Stores — "Your store locations"
  3. Security — "Auto-lock and biometric login"
  4. Roles & Permissions — "What each role can do"
  5. Activity Logs access — "Which roles can view activity logs"
  6. Appearance — "Business colour (applies to all devices)"
- [ ] Each row opens its own sub-page with a back arrow; back returns to the menu.
- [ ] Whole screen fades in (no spinner) — coding rule #6.

### B1 — Business Info
- [ ] Opens pre-filled: current **Business name** (text), **Business type**
  (dropdown), **Currency** (dropdown). No empty/blank fields on first load.
- [ ] Business type dropdown lists the standard types; current type is selected.
- [ ] Currency dropdown lists currency codes; current currency is selected.
- [ ] Edit the name → tap **"Save changes"** → green "Business info saved." toast;
  reopen the screen → the new name persisted.
- [ ] Change type and currency → Save → both persist on reopen. (Currency change
  should reflect in ₦/symbol shown elsewhere, e.g. prices.)
- [ ] **Empty-name guard:** clear the name → Save → red "Business name can't be
  empty." and nothing saved.
- [ ] (Activity log, verify-later) a `settings.business_info.update` row is written.

### B2 — Stores (read-only this phase, §10.1)
- [ ] Lists the business's store(s): each shows store **name** + location (or
  "No address set" if none).
- [ ] Footer reads "Adding more stores is coming in a future update."
- [ ] **No "Add store" button / FAB** anywhere (add-store is Phase 2 — hard rule
  about not adding unplanned buttons).
- [ ] "Store" wording only — never "Warehouse" (hard rule #15).

### B3 — Security
- [ ] **Auto-lock** card shows preset chips exactly: **1, 3, 5, 10, 15, 30 min**.
  - [ ] There is **NO "Never"** chip.
  - [ ] Current value is highlighted; default is **5 min** if never set.
  - [ ] Tap a different chip (e.g. 1 min) → it becomes selected and persists on
    reopen. (Behaviour check: after that idle time the app returns to the
    Who's-Working / PIN picker.)
- [ ] **Biometric login** toggle:
  - [ ] Subtitle: "Use fingerprint or Face ID on this device".
  - [ ] Turning ON triggers the OS biometric prompt. On an **emulator with no
    fingerprint enrolled** the acceptable outcomes are either a "Biometrics not
    supported on this device." error OR the system prompt (enroll a fingerprint
    in emulator Settings first to test the happy path).
  - [ ] If enabled successfully, it persists **device-local** (survives app
    restart) and the **login screen actually offers biometric unlock**.
  - [ ] This toggle does **NOT** sync to other devices (device-local only).

### B4 — Roles & Permissions
- [ ] List shows **4 role cards in tier order: CEO → Manager → Cashier → Stock
  keeper** (NEVER alphabetical — hard rule / role-tier-ordering memory).
- [ ] Each non-CEO card subtitle reads "X of Y permissions"; **CEO card reads
  "All Y permissions"**.

  **CEO role detail:**
- [ ] Opens with hint "The CEO always has full access — these can't be changed."
- [ ] **Every** permission toggle is **ON and disabled** (can't be turned off).
- [ ] Max discount shows **"100% (unlimited)"** with **no slider**; Max expense
  approval shows **"Unlimited"** (no input field).

  **Cashier (or Manager/Stock keeper) role detail:**
- [ ] Permissions are grouped by category in this order: **Sales, Products, Stock,
  Expenses, Reports, Customers, Suppliers, Staff, System, Funds** (only
  non-empty groups show).
- [ ] Toggle a permission OFF→ON (e.g. a Cashier permission) → switch flips and
  the change sticks on reopen (count on the role card updates).
- [ ] Toggle it back → reverts. (Each toggle writes an activity log — verify later.)
- [ ] **Max discount slider** (0–100%): default **Manager 10%, Cashier 0%,
  Stock keeper 0%**. Drag it → value label updates → commits on release →
  persists on reopen.
- [ ] **Max expense approval** field (₦): type an amount → commits on focus-loss /
  submit / leaving the screen → persists on reopen.
- [ ] **Manager only:** an extra **"Stores"** section with **"Allow viewing other
  stores"** toggle, **OFF by default**. Turning it ON should unlock the Home
  store picker for Managers (cross-check in C1). Cashier/Stock keeper details
  have **no** such toggle.

### B5 — Activity Logs access
- [ ] One toggle per role. Helper text: "Choose which roles can open Activity Logs.
  The CEO always has access."
- [ ] **CEO row is ON and locked** (subtitle "Always on", switch disabled).
- [ ] Manager / Cashier / Stock keeper default **OFF** (subtitle "Can view
  activity logs").
- [ ] Toggle a non-CEO role ON → sticks on reopen; toggle OFF → reverts.

### B6 — Appearance
- [ ] Helper text explains it's the business-wide colour and that light/dark is a
  per-device choice under "Display".
- [ ] Exactly **4 colour cards: Amber, Blue, Purple, Green** (2×2), each with
  swatches; the active one has a 2px border + check mark.
- [ ] Tap a new colour → the app accent changes **immediately** (this device) and
  the card shows as active; reopen → still selected.
- [ ] Confirm light/dark mode is **NOT** offered here (it lives under "Display" in
  the drawer). Switching light/dark there stays per-device.
- [ ] (Sync: the colour change reaching other devices is checked in section D.)

---

## C. Works in the current Manager session (and re-check per role)

### C1 — Home, role-aware (§11)
- [ ] CEO: all cards (Total Sales, Net Profit, Pending Orders, Expenses, Stock
  Value, Customer Wallet, Staff Sales). Manager: same MINUS Net Profit.
- [ ] Cashier: own sales, Pending Orders, Customer Wallet, Total SKUs only.
  Stock keeper: Pending Orders + Total SKUs only.
- [ ] Subtitle by role (Business Overview / Today's Sales / Stock Overview).
- [ ] Store filter locked for all but CEO; Manager unlocks only if CEO enabled
  "Allow viewing other stores".
- [ ] Total SKUs card expands a per-manufacturer breakdown.

### C2 — Inventory + Product Details (§16)
- [ ] Add Product: Retailer + Wholesaler (both required), Buying (hidden unless
  `products.edit_buying_price`), optional Expiry, Empty Crate Value shown only
  when "Track empty crate returns" is on.
- [ ] Inventory list: Category dropdown, compact stat cards, header search,
  near-expiry products bubble to top with an expiry chip.
- [ ] Product Details: view-only until Edit; one "Save Product" saves all fields;
  Sales Target CEO-only (Manager read-only); live stock after Update Stock.
- [ ] Stock keeper: restricted view (no Edit, no Supplier/Buying) but GETS the
  Update-Stock modal (Add/Remove, reason required on Remove → History log).
- [ ] Cashier: view-only.
- [ ] Tabs/FAB guards: Add Product → `products.add`; Suppliers → `suppliers.manage`;
  Empty Crates only for Bar/Beer distributor; History hidden from Cashier.

### C3 — Funds Register + POS Open-Day gate (§23)
- [ ] Funds Register sidebar item shows ONLY for Manager/CEO (hidden for Cashier/
  Stock keeper). No old "Cash Register" item (hard rule #8).
- [ ] Each store auto-gets a Cash Till; CEO adds POS/Bank (with account number);
  CEO can remove ones they added.
- [ ] Re-adding a previously-removed account NAME reactivates (no crash) — S33.
- [ ] Before Open Day: POS is BLOCKED (hard rule #10). Cashier sees "wait for
  Manager/CEO"; Manager/CEO sees "Tap to enter" → jumps to Open Day.
- [ ] Manager/CEO enters starting balance per account → opens day → POS unblocks.
- [ ] Live "today's balances" view sums correctly.

### C4 — POS + tier pricing (§12)  ⚠️ PRIORITY: the Session 35 money bug
- [ ] Stock keeper reaching POS by any route sees "no access" (not the till).
- [ ] Store-switcher icon CEO-only; Manager/Cashier see store name only.
- [ ] Cashier locked to Retailer tier; CEO/Manager can switch.
- [ ] **TIER-PRICE REGRESSION:** add a wholesaler customer (or pick Wholesaler) →
  the line is CHARGED the wholesaler price, NOT retailer. Verify the amount on
  the cart line, at checkout, AND on the recorded sale all match the wholesaler
  price. (This was the shipped money bug — verify carefully.)
- [ ] Quick Sale: CEO/Manager open directly; Cashier must enter a CEO/Manager PIN
  (own PIN rejected).

### C5 — Cart (§13)
- [ ] Per-item discount: Cashier blocked ("Ask Manager"); Manager over cap snaps
  to max ("Capped"); CEO unlimited. Cap reads the per-role setting.
- [ ] Discount shows on the line (strikethrough + badge + "Saved ₦X") and comes
  off the total; the recorded sale stores the discount.
- [ ] Fractional ±0.5 chips appear ONLY for products with "Allow fractional sales".
- [ ] Saved carts private to each cashier; stale (>24h) cleared on opening Recall.
- [ ] Remove item → 5s "Undo" banner restores it exactly.
- [ ] "Go to Cart" FAB opens the Cart (slot 8), matching bottom-nav + sidebar.

### C6 — Checkout + Receipt (§14, §15)
- [ ] Two-step payment; Step 2 receiving-account picker (defaults Cash Till).
- [ ] Cash/card/transfer credits the chosen funds account; wallet/credit sales
  move NO account money. Walk-ins go straight to the account, never a wallet
  (hard rule #14).
- [ ] Funds guard (S33): a paid sale with no business date is rejected, not
  silently dropped from the ledger.
- [ ] "Add wallet info to receipt" checkbox: off by default; shown only for
  registered customers; when ticked, wallet balance prints on screen + thermal.
- [ ] NO QR code on either receipt (hard rule #8 / §15.3).

### C7 — Customers + wallet (§18)
- [ ] Add Customer: phone now REQUIRED.
- [ ] Crates tab on customer profile shows only for Bar/Beer distributor.
- [ ] Soft-delete (CEO/Manager only via `customers.delete`): trash button, confirm
  dialog notes history stays; customer hidden from list, sales/wallet intact.
  Cashier cannot see the button.
- [ ] "Set debt limit" requires `customers.set_debt_limit` (CEO/Manager); Cashier
  cannot set limits.
- [ ] Add Funds (S33): sheet lets you pick the receiving funds account; top-up
  writes wallet credit + `payment_transactions` + a `'topup'` `fund_transactions`
  credit atomically with the real staff id.

---

## D. Two-device sync (needs 2 emulators/devices)

- [ ] Realtime: change on device A (new product / Open Day / CEO colour / price
  edit) lands on device B within a tick, NO manual pull.
- [ ] Invite codes pull: invite generated on A appears in the Invites tab on B.
- [ ] Funds Open Day pull: CEO opens day on A → staff till B sees POS unblocked.
- [ ] Cross-business isolation: CEO who owns business 1 can still edit business 1's
  name/type after touching a second business (no 42501); device B on a different
  business never shows business 1's rows.
- [ ] Partial-upsert fixes: edit a manufacturer's Empty Crate Value / soft-delete a
  product / assign a rider on A → reaches B (no stuck `23502` in Sync Issues).
- [ ] Sync Issues screen: empty on both devices. (errno-7 host-lookup errors are
  device DNS/VPN, not code.)

---

## E. Freshest-fix regression spot-checks (Sessions 28–35)

- [ ] S35 tier pricing: wholesaler line charged wholesaler price end-to-end (same
  as C4 — do it deliberately).
- [ ] S33 midnight rollover: leave the till open past the business-day boundary
  (set device clock) → "today" rolls over, POS gate + ledger re-key to new day,
  new sales bucket under the new date.
- [ ] S33 opening-cash gate race: cold-start POS doesn't briefly render unblocked
  before the store locks.
- [ ] S32 owner-fallback RLS: a stuck business-edit now flushes (Sync Issues clears).
- [ ] S23 Cashier restore crash: Cashier logging into a 2nd device with a product
  whose supplier/manufacturer hasn't arrived yet does NOT crash; the orphan
  surfaces in Sync Issues "Catching up" and retries.

---

## F. Role-permission matrix sweep (hard rules #6 / #7)

For EACH of CEO / Manager / Cashier / Stock keeper, confirm unauthorized items are
HIDDEN entirely, never greyed (exception: suspended staff in Staff Mgmt).

- [ ] Sidebar set per role matches §27.3 (Stock keeper: Home/Inventory/Orders only;
  Cashier adds POS/Customers; Manager adds Expenses/Staff Mgmt; CEO all).
- [ ] No removed items anywhere: QR on receipt, Deliveries sidebar, Cash Register
  sidebar, Cart sidebar (hard rule #8).
- [ ] No raw UUIDs in user-facing text — short codes only (ORD-/INV-/REC-).
  Known open: some Orders snackbars still show raw UUIDs (tracked, Ring 3).
- [ ] Every write that should also write `activity_logs` does. Known open:
  account add/remove not yet logged (Ring 0 helper pending).

---

## Findings (log failures here)

| Section / step | What happened | Severity | Notes |
|---|---|---|---|
| | | | |
