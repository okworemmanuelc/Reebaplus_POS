# Reebaplus POS

**Master Plan Document**

*Complete planning specification for build handoff*

Version 1.0

Prepared for Okwor Emmanuel

---

## 1. Introduction

This document is the complete planning specification for the Reebaplus POS app. It covers every screen, flow, rule, and decision made during planning. The agent building this should treat it as the source of truth.

The plan is written in plain English. Where role names appear (CEO, Manager, Cashier, Stock keeper), they refer to the four default roles. Where Phase 2 or Phase 3 is mentioned, those features are deferred for a later release.

### 1.1 What Reebaplus is

Reebaplus is a multi-business point of sale app. One business is owned by one CEO, and one CEO can own multiple businesses. The CEO adds staff in different roles. The till (the device the app runs on) is shared by multiple staff during a shift.

In Phase 1, each user belongs to one business at a time. The database supports multiple memberships per email from day one (via the `user_businesses` table), so a single CEO email can map to many businesses — but the "switch business" picker UI is deferred to Phase 2. A user who needs to belong to a second business in Phase 1 signs in with a different email.

### 1.2 Business types supported

The app supports six business types, selected during sign up:

- Restaurant
- Supermarket
- Bar
- Beer distributor
- Pharmacy
- Boutique

Some features (like empty crate tracking) are only visible for Bar and Beer distributor types.

---

## 2. Architectural Foundation

### 2.1 Data-driven roles

Roles and permissions live in database tables, not in code. Each business gets its own copies of roles and permissions, seeded when the business is created. This means adding a new role later is just adding a row. Changing what a role can do is a toggle in CEO Settings, not a code release. Each CEO can tune their own business without affecting any other business on the platform.

### 2.2 Stores

Every business has at least one store, and one business can have many stores. The app is built with multi-store data structures from day one, but the UI only shows one store per business in this phase. Multi-store features (store picker, transfers, per-store reports) ship in Phase 2.

Each store has a name, address, state, and country. The CEO sets up the first store during sign up. The word "Store" replaces the word "Warehouse" everywhere in the app.

### 2.3 Starting from a clean schema

The old staff and role system has been wiped clean (commit 38ea06b, Supabase migration 0041_remove_staff_management.sql). The `business_members` and `invites` tables are gone. The `role` and `role_tier` columns and their CHECK constraints have been dropped from `users` and `profiles`. The pivot starts from a clean schema. All tables in §2.4 must be built fresh.

### 2.4 Database tables

The agent should design these tables (names are illustrative — match your existing naming convention):

- `businesses` — id, name, type, currency, auto_lock_minutes
- `users` — id, email, name, pin_hash. Drop the old role/tier check constraint.
- `roles` — id, business_id, name, is_system_default
- `permissions` — id, key, description, category
- `role_permissions` — role_id, permission_id
- `role_settings` — role_id, setting_key, setting_value
- `user_businesses` — user_id, business_id, role_id, status, last_login_at
- `invite_codes` — id, business_id, role_id, code, generated_by_user_id, expires_at, used_by_user_id, revoked_at, email, store_id
- `stores` — id, business_id, name, address, state, country
- `user_stores` — user_id, store_id
- `activity_logs` — id, business_id, user_id, store_id, action_key, entity_type, entity_id, before, after, device_label, created_at

### 2.5 Permission keys (starter set)

More keys can be added as features grow:

- `sales.make`, `sales.cancel`, `sales.discount.give`
- `products.add`, `products.edit_price`, `products.edit_buying_price`, `products.delete`
- `stock.add`, `stock.view`, `stock.adjust`
- `expenses.create`, `expenses.approve`
- `reports.see_sales`, `reports.see_profit`, `reports.see_cost_prices`, `reports.see_expenses`
- `customers.add`, `customers.update`, `customers.delete`, `customers.wallet.update`, `customers.wallet.totals.view`
- `suppliers.manage`, `shipments.manage`
- `staff.invite`, `staff.suspend`, `staff.change_role`
- `activity_logs.view`, `settings.manage`, `settings.delete_business` (CEO-only, locked ON; §10.3)
- `funds.open_day`, `funds.close_day`, `funds.view`

### 2.6 Live sync across devices

The app is offline-first with cloud sync. Beyond pull-on-open, a change made on one device should appear on the other devices in the same business **live**, without a manual refresh — the CEO changing the business colour (§10.1), a price edit, a new sale, a stock adjustment. This live, cross-device behaviour is the reason the synced tables exist; it is a product requirement, not a nicety.

**Known issue (flagged 2026-05-30):** live (realtime) delivery is currently broken — inbound changes only land when the user pulls to refresh. Pushing changes to the cloud is unaffected; this is purely the inbound realtime channel. Root cause (a malformed wildcard realtime subscription, not a publication gap) and the planned fix are tracked in the pivot plan's risk register (§7). To be fixed after the in-flight CEO Settings work lands.

---

## 3. Build Order

Each step unlocks the next. Build in this order:

- [x] Database schema rebuild. Drop the brittle role constraint. Build all new tables. Seed default roles and permissions on business creation.
- [x] Auth flow. Welcome screen, CEO Sign Up, Staff Sign Up, Login (with Forgot PIN), Who is working picker.
- [x] Staff Management screen with invite flow.
- [x] CEO Settings page.
- [x] Home screen, role-aware.
- [x] Point of Sale, guarded by role.
- [x] Cart flow with discounts, role caps, fractional sales, per-cashier saved carts (§13). *(Session 20.)*
- [~] Inventory and Product Details, role-aware — includes the destructive product price-column migration (buying / retailer / wholesaler). *(moved ahead of Checkout 2026-05-30: products + prices must be finished before the sales flow.)* *(screens + v18 tier-price migration built; tier-price-at-sale fix landed Session 35 — POS/Cart now charge the selected tier. Remaining: barcode field UI is Ring 3.)*
- [~] Funds Register (new — multi-account model). Phase 1 done: accounts (Cash Till auto + CEO adds POS/Bank), Open Day, the POS Opening-Cash gate, and crediting the chosen account on each sale (§23). Phase 1 remaining: Close Day + expected-vs-actual reconciliation (§23.6/§23.8) — confirmed Phase 1 per decision C1 (2026-05-31). *(moved ahead of Checkout 2026-05-30: §14 Step-2 "pick receiving account" + hard rule #10 both require it. Phase 2 — Funds History (§23.2) — deferred.)*
- [x] Checkout flow with wallet integration (§14). *(Two-step payment + receiving account with Funds Register, Session 26; "Add wallet info to receipt" checkbox added Session 30. §14 complete.)*
- [~] Customers screen with wallet (§18). *(Re-pass Session 31: soft-delete CEO/Manager, Crates-tab gated to Bar/Beer, required phone, new customers.set_debt_limit permission. Still open: Edit flow (updateCustomer is a stub), GPS location capture, Add-Funds payment-method selector.)*
- [~] Orders (Pending, Completed, Cancelled).
- [~] Daily Stock Count.
- [x] Expenses with pending approval flow. *(Full impl Session 59: approval flow, Funds Register debit-on-approve + reversal, searchable categories, per-business/per-store monthly budget, edit/delete, stats. Cloud 0073 pending deploy.)*
- [ ] Supplier Accounts.
- [ ] Track Shipments (new).
- [~] Activity Logs.
- [~] Reports.
- [ ] Notifications.
- [ ] **Delete Business & Account (CEO Danger Zone)** — the last Phase 1 item. CEO permanently deletes their account, their business, and every business-scoped row, via one atomic cloud RPC (deliberate hard-delete exception to hard rule #9). Two-gate confirmation (type business name + PIN), online-only, then full local wipe and logout. Full spec in §10.3. *(Build last — after Ring 3, once every feature it cascades over exists.)*

> **Remaining work re-grouped 2026-05-31 into Rings 0-3 — see PIVOT_PLAN.md §8.0.** Ring order: Ring 0 (foundation invariants) — POS/Cart wholesaler-tier price fix, Activity Logs generic-schema migration + notifications.severity column + logActivity()/fireNotification() helpers, money-math consistency regression net. Ring 1 (close the money loop) — Funds Register Close Day + reconciliation (built first; the funds-debit primitive), Orders Cancel reversal, Orders Refund, Customers Add Funds via WalletService.topup, Expenses approval/stats/budget, Supplier Accounts + Track Shipments (shared payments+shipments model). Ring 2 (operational daily loop) — Customers Edit (real DAO write), Customers GPS capture, Daily Stock Count + Record Damages. Ring 3 (reporting & cross-cutting verification) — Funds History, Daily Reconciliation Report, Notifications verification pass, Activity Logs feature screen, Reports hub + missing reports, barcode scanner, Deliveries removal, loading-state fade-in sweep, sync regression test, end-to-end QA.

---

## 4. Welcome Screen

This is the first screen users see on a fresh install and after a full logout. Not shown for auto-lock or Switch User actions — those go to the Who is working picker.

### 4.1 Layout (top to bottom, centered)

- Logo (placeholder for now — circle or rounded square with "RP" inside, in yellow accent).
- App name: Reebaplus.
- Tagline: "Sales, stock, and staff — all in your pocket."
- Primary button (full width, yellow accent): Create a new business.
- Secondary button (full width, outlined): Join with invite code.
- Text link: Already have an account? Sign in.
- Small print at bottom: "By continuing, you agree to our Terms of Service and Privacy Policy." Both link to placeholder routes.

### 4.2 Behaviour

- Create a new business — routes to business name step of CEO sign up.
- Join with invite code — routes to invite code step of staff sign up.
- Sign in — routes to email step of login.
- Terms and Privacy — placeholder routes.

### 4.3 Visual style

- Match the existing dark theme with yellow/orange accent. The accent (business colour) is CEO-selectable in CEO Settings → Appearance (§10.1) and applies business-wide; default amber. Light/dark/system stays a per-device choice.
- Background: dark base with a subtle pattern (faint dotted or grid) and a soft yellow gradient glow from one corner.
- Small fade-in animation on load — logo, name, tagline, and buttons fade in gently.

---

## 5. CEO Sign Up Flow

Triggered by tapping "Create a new business" on the Welcome screen. One screen, content fades between 9 steps. Small dots progress indicator at the top, also fading between steps.

### 5.1 Steps in order

- Business name (min 2 characters, no numbers or symbols except "&" and "-").
- Business type — tappable cards: Restaurant, Supermarket, Bar, Beer distributor, Pharmacy, Boutique.
- Store details (single screen, all four fields): store name, address, state, country. State and country are searchable fields with suggestions from a predefined list. Country defaults to Nigeria. Currency auto-fills based on country (editable later in Business Info settings).
- Full name (min 2 characters, no numbers or symbols, no repeated single characters).
- Email.
- OTP — 6 digits, valid 5 minutes, resend after 30 seconds, 5 wrong attempts max.
- Create PIN — 6 digits. Block obvious patterns (000000, 123456, 111111, etc.).
- Confirm PIN.
- "Welcome, your business is ready" — auto-continues to Home after 3 seconds.

### 5.2 Behaviour

- Back button goes back one step. Already typed values are kept.
- On completion, the four default roles are auto-created with default permissions.
- The first store is created and the CEO is assigned to it.
- If the email is already linked to another business: skip PIN creation, ask to confirm the existing PIN.

---

## 6. Staff Sign Up Flow

Triggered by tapping "Join with invite code" on the Welcome screen. One screen, content fades between 7 steps. Small dots progress indicator at the top.

### 6.1 Steps in order

- Invite code (8 letters and numbers mixed). If invalid, expired, or already used, show error on the same step with "Try again" option.
- Email. Must match the email the invite was generated for.
- OTP — 6 digits, valid 5 minutes, resend after 30 seconds, 5 wrong attempts max.
- Full name — the staff member's own name. Required; shown everywhere they appear (Staff Management, Who's Working picker, receipts). Mirrors the full-name step in CEO Sign Up (§5). Added 2026-05-29 — §6 originally had no name step, so staff defaulted to showing their email.
- Create PIN — 6 digits, block obvious patterns.
- Confirm PIN.
- "Welcome to [Business Name]" — auto-continues to Home after 3 seconds.

### 6.2 Behaviour

- Back button goes back one step, keeps typed values.
- If email is already linked to another business, skip the full-name and PIN creation steps, confirm existing PIN instead (that account already has a name). (Phase 2.)
- Role and assigned store are read from the invite code and applied automatically.

---

## 7. Login Flow

Triggered by tapping "Already have an account? Sign in" on the Welcome screen. One screen, content fades between steps. No progress indicator (short flow).

### 7.1 First sign-in on a fresh device

- Email. If not recognised: show "No account found. Create a new business or join with an invite code" with buttons to both flows.
- OTP — 6 digits, valid 5 minutes, resend after 30 seconds, 5 wrong attempts max.
- PIN — 6 digits. "Forgot PIN" link sits under the input. 5 wrong attempts forces Forgot PIN flow.
- Straight to Home for the user's single business. (Multi-business picker is Phase 2 — see §1.1.)

### 7.2 Every login after that on the same device

- PIN screen with email already filled in and shown.
- Goes straight to last-used business → Home. User can switch business from inside the app.

### 7.3 Forgot PIN flow

- Sends email OTP.
- After verifying, user creates a new PIN (same rules — block obvious patterns).
- Signs them in.
- This is also the forced path: 5 wrong PIN attempts drop the user straight into this flow. There is no timed lockout — email/OTP access is the recovery gate.

### 7.4 PIN storage and recovery (local-only by design)

- The 6-digit PIN is a **device unlock** factor, not a portable identity. Its hash (`pin_hash` / `pin_salt` / `pin_iterations`) lives only in the local `users` row and is **never** sent to the cloud. The portable identity is the email + OTP.
- A new device re-establishes the PIN locally: the user verifies by email OTP, then sets a device PIN (re-entering the same digits is fine — it's a fresh local hash). The Phase-2 "PIN portability across devices/businesses" goal (§28) is met this way — by local re-establishment after OTP — **not** by cloud-storing the PIN. A readable 6-digit hash column would be trivially brute-forceable, which is why fintech apps keep the PIN device-local.
- If server-side verification is ever genuinely required, the only acceptable form is a rate-limited `SECURITY DEFINER` verify RPC that takes a candidate PIN and returns a boolean — never a readable hash column the client can pull.

---

## 8. Who Is Working Picker

The daily-use screen on the shared till. Different from Login — Login is for a fresh device or full logout. This picker is what staff see all day when switching shifts or returning after auto-lock.

### 8.1 Layout

- Top of screen: business name + today's date.
- Title: Who's working?
- Scrollable list of tappable staff cards.

### 8.2 Each staff card shows

- Avatar circle (image if uploaded, initials if not).
- Name.
- Role with color tag (CEO yellow, Manager blue, Cashier green, Stock keeper grey).
- Small "active now" dot if logged in on another till.

### 8.3 Rules

- Suspended staff are hidden from this picker.
- Only shows staff of the currently-active business.
- If only 1 staff exists, skip this picker and go straight to PIN.

### 8.4 Tap a card → PIN screen

- Person's name and role shown at top.
- 6-digit PIN input.
- 5 wrong attempts forces Forgot PIN flow.

### 8.5 Switch User and auto-lock

- "Switch User" button (and existing lock icon) in the sidebar return to this picker.
- After 5 minutes of no activity (adjustable in CEO Settings), screen silently fades back to this picker.
- No message or toast on auto-lock — completely silent.

---

## 9. Staff Management

Where CEO and Manager add, view, and manage their team. Also where invite codes are generated.

### 9.1 Layout

- Two tabs at the top: Staff and Invites.
- Search bar at the top of each tab (from day one).
- Floating "Invite new staff" button at the bottom-right.

### 9.2 Staff tab

- List of active staff cards. Each card: avatar, name, role with color tag, last login, "active now" dot if logged in elsewhere.
- Suspended staff pushed to the bottom under a small "Suspended" heading, greyed out.
- For Managers: CEO and other Managers appear as visibly faded read-only rows.
- As soon as a new business is created, the CEO appears as the first staff card.

### 9.3 Invites tab

- List of pending invite cards. Each card shows: the code, role attached, email it was sent to, who generated it, date generated, days left, Revoke button.

### 9.4 Invite new staff modal

Single form with all fields visible at once:

- Email of the person being invited.
- Role (CEO sees all four, Manager sees only Cashier and Stock keeper).
- Store (CEO can pick any store; Manager's store dropdown is locked to their own store).
- "Generate code" button at the bottom.

After tapping Generate, the modal switches to show the generated code with Copy, SMS, and WhatsApp sharing options.

If the email is already a staff in this business, show error: "This email is already a staff member."

Each code can be used by only one person, expires after 7 days, can be revoked any time before use.

### 9.5 Tap a staff card → full new screen

- Avatar, name, role, status, assigned store (shows "Store 1" for now).
- Total sales made.
- Last 5 logins.
- Action buttons: Change role, Suspend (or Reactivate if suspended). Each is
  gated by its own permission — Change role = `staff.change_role`, Suspend =
  `staff.suspend` (both CEO + Manager by default, revocable per role; separate
  from `staff.invite`, which gates the Invites tab). Each button is hidden
  entirely without its permission (hard rule #7).

### 9.6 Confirmations

- Suspending a staff — confirm dialog.
- Changing a role — confirm with before/after.
- Revoking an invite code — confirm.

### 9.7 Role access

CEO: full access. Manager: can manage Cashiers and Stock keepers only; CEO and other Managers appear as read-only. Cashier and Stock keeper: hidden completely.

Note: there is no permanent delete option, because deleting a staff would break old sales records. Suspended staff stay in the list, greyed out.

---

## 10. CEO Settings Page

Where the CEO tunes everything about the business. Menu screen with tappable sections. Each section opens into its own sub-page. A **search box** at the top of the menu filters the sections by name/description so a specific setting is quick to find.

### 10.1 Sections from day one

- Business Info — business name, **phone**, type, currency (all editable). The
  chosen currency now actually drives money formatting app-wide (receipts and
  every money surface), and the business name shows on receipts (§15.1) and the
  POS header (§12.1); both reflect a rename live. (Phone editable + currency made
  real + receipt/header business name fixed 2026-06-03, user.)
- Stores — shows Store 1 (name, address). **The CEO can edit the existing
  store's name and address** (Phase 1, 2026-06-03, user) — the local store keeps
  a single fused `address` field (street/state/country were merged at
  onboarding). Phase 2 still adds the ability to add *more* stores.
- Security — auto-lock timer with preset chips: 1, 3, 5, 10, 15, 30 minutes (default 5).
- Roles & Permissions — four role cards (CEO, Manager, Cashier, Stock keeper). Tap to open.
- Activity Logs access — toggle for which roles can view activity logs (CEO only by default).
- Sync Issues access — toggle for which roles can open the Sync Issues troubleshooting screen (gated by the `sync.view` permission). The CEO always has access; other roles default off. (Sync Issues is an infra/troubleshooting screen, not otherwise in the role tables.)
- Appearance — CEO picks the business colour (accent): Amber, Blue, Purple, or Green. Synced, so it applies to every device in the business. Light/dark/system mode is NOT here — that stays a per-device comfort choice, set from "Display" in the side menu. Default colour: amber.
- Danger Zone — CEO-only, sits at the bottom, visually separated. Holds **Delete Business** (delete the account, the business, and everything attached to it). Full behaviour in §10.3.

### 10.2 Roles & Permissions sub-page (per role)

- All permissions shown as toggles, grouped by category (Sales, Products, Stock, Reports, Customers, etc.).
- CEO role: all toggles locked ON (greyed out) so CEO's access can never be accidentally removed.
- Role limits below the toggles:
  - Max discount % (per role). Default: Manager 10%, Cashier 0%.
  - Max expense approval amount (per role). Default: Manager amount set by CEO.
  - Can change product prices (toggle). Default: Manager ON, others OFF.
  - Allow viewing other stores (Manager role only). Default OFF. When ON, the Manager's Home store
    picker is unlocked (see §11.2) so they can view other stores and request restock. Stored per role
    in `role_settings` (key `manager_view_all_stores`).

### 10.3 Delete Business & Account (Danger Zone)

The **last Phase 1 item to build** (see §3). A CEO can permanently delete their account, their business, and everything attached to the business. Irreversible. CEO-only — no other role ever sees this section. Gated by the `settings.delete_business` permission, which is locked ON for CEO and unavailable to all other roles.

- **Where it lives:** a red "Danger Zone" section at the bottom of the CEO Settings menu (§10.1), visually separated from the normal sections. One action inside it: **Delete Business**.
- **What "everything" means:** deleting the business removes every row owned by that `business_id` across all synced tenant tables — products and prices, stock, customers and wallets, suppliers, orders, payments, expenses, funds accounts and entries, crate ledgers, stores, roles, permissions grants, role settings, invite codes, staff memberships (`user_businesses` / `user_stores`), and activity logs. Nothing business-scoped survives.
- **What happens to staff:** their membership in *this* business is removed. A staff member who belonged only to this business keeps their login account but now has no business — on their next sign-in they land on the Welcome screen and must create a business or join another by invite. (Their account itself is not deleted; only the CEO's own account is deleted, because that was the CEO's explicit request.)
- **What happens to the CEO:** after the business is gone, the CEO's own user account (auth + local) is deleted, and the device is fully logged out back to the Welcome screen.
- **Confirmation (irreversible-action ritual):** a two-gate confirmation, never a single tap. The CEO must (1) type the exact business name to confirm, and (2) re-enter their PIN. A plain-English warning lists what will be lost ("all sales, stock, customers, staff access, and money records for this business will be permanently deleted and cannot be recovered"). Only then is Delete enabled.
- **How it syncs (deliberate exception to hard rule #9):** this is the one place a hard delete is correct — soft-delete would leave a tombstoned but recoverable business, which defeats the purpose. It runs as a single atomic domain RPC (e.g. `domain:delete_business`) that the cloud executes in one server-side transaction (cascade delete by `business_id`, plus the CEO's auth user), rather than per-row `enqueueDelete`. Only after the cloud confirms success does the device wipe the local rows for that business and log out. If the device is offline, the action is blocked with a clear message — account/business deletion must be confirmed by the server before anything local is destroyed, so it is never queued blindly. Add `delete_business` to the build's irreversible-action list when implemented.

### 10.4 Phase 2 (deferred)

- Create custom roles beyond the four defaults.
- Custom permission groups.
- More tunable limits beyond discount, expense, and price-change toggle.

---

## 11. Home (Dashboard)

Renamed from Dashboard to match the bottom nav. Role-aware screen showing business overview.

### 11.1 Header

- Hamburger menu, Reebaplus POS logo, business overview subtitle, notification bell.
- Subtitle changes by role: CEO/Manager see "Business Overview"; Cashier sees "Your Shift" or "Today's Sales"; Stock keeper sees "Stock Overview".

### 11.2 Filters row

- Store dropdown (renamed from "All Warehouses" → "All Stores").
  - CEO: can pick any store or All Stores.
  - Manager: locked to assigned store by default. The CEO can flip a per-role toggle — "Allow viewing
    other stores" in Roles & Permissions → Manager (§10.2) — that unlocks the full store picker for
    Managers, so a Manager can check another store's stock and request restock when running low. Built
    in Phase 1.
  - Cashier and Stock keeper: locked to own store (no toggle).
  - A locked user assigned to more than one store gets a dropdown limited to their assigned stores
    (no "All Stores" entry).
- Period dropdown uses the canonical rolling chip set (§30.11), default Last 24 hours.

### 11.3 Reports button

Stays at top. Visible to CEO and Manager only — roles below Manager (Cashier, Stock keeper) do not see it. Badge counts actionable alerts across all reports (low stock, overdue payments, debt issues, reconciliation mismatches, etc.). Full Reports planning in section 21.

### 11.4 Cards by role

All cards are tappable and redirect to the corresponding screen. Visibility:

| Card | CEO | Manager | Cashier | Stock keeper |
|------|-----|---------|---------|--------------|
| Total Sales | All stores/staff | Own store/staff | Own sales only | Hidden |
| Net Profit | Yes | Hidden | Hidden | Hidden |
| Pending Orders | Yes | Yes | Yes | Yes |
| Total Expenses | Yes | Yes | Hidden | Hidden |
| Stock Value (selling price) | Yes | Yes | Hidden | Hidden |
| Total SKUs (expandable by manufacturer) | Hidden | Hidden | Yes | Yes |
| Customer Wallet | Yes | Yes | Yes | Hidden |
| Staff Sales section | All stores/staff | Own store/staff | Hidden | Hidden |

Active user indicator: not added — sidebar already shows it.

Per-card visibility toggles per role: deferred to a later phase (after Phase 2).

### 11.5 Total SKUs card behaviour

Expandable card. Closed shows total SKUs. Expanded shows the full list grouped by manufacturer. Visible only to Cashier and Stock keeper.

---

## 12. Point of Sale

The screen where sales actually happen. Stock keeper does not see this screen at all.

### 12.1 Header

- Hamburger menu, app logo, business name with current store as subtitle (e.g., "Keffi"), search icon, store selector icon (CEO only), notification bell.
- Store selector icon visible only to CEO — lets them switch which store they're selling from.

### 12.2 Filters row

- Price tier dropdown: Retailer / Wholesaler.
  - CEO and Manager: can switch freely.
  - Cashier: defaults to Retailer.
  - When a customer is selected in the cart, the price tier auto-applies based on the customer's attributed tier (overrides for everyone including Cashier).
  - If the customer is removed from the cart, price snaps back to default Retailer.
- Category dropdown.
- Lightning bolt — Quick Sale button (for items not in inventory).

### 12.3 Quick Sale

- Tapping the lightning bolt prompts for CEO or Manager PIN if user is Cashier.
- On unlock, modal opens to enter: product name, unit price, quantity.
- Item is added to cart and calculated normally.
- All Quick Sales are tracked in Activity Logs.

### 12.4 Category chips and product grid

- Category chips stay as currently designed.
- Product grid shows products from the user's assigned store (CEO can switch via store selector).
- Out-of-stock products: visible but greyed out and not tappable.
- Search icon at top searches products in the current store.

### 12.5 Loading behaviour

- All rotating loading animations removed.
- Replaced with subtle fade-in for content.
- Sync progress bar at top stays as is.

### 12.6 Discount and cancel rules

- Discount is applied in the cart (per item — see Cart section).
- If user tries to exceed their role's max discount, message shows: "Maximum discount is X%. Capped." and discount caps at the max.
- Cashier default discount: 0% (cannot discount).
- Manager: limited by max set in CEO Settings.
- CEO: unlimited.
- Cancel sale is handled in the Orders screen, not POS.

### 12.7 Empty state

Unchanged from current (magnifying glass + "No products found").

---

## 13. Cart

Where the cashier reviews the order before checkout. Reached from the bottom nav.

### 13.1 Layout

- Header: Cart / Review Selection / notification bell / Clear button.
- Customer card at top, defaulting to "Walk-in Customer" with Change button.
- Wallet balance shown next to customer (for registered customers).
- Cart items list. Each line shows product, quantity × unit price, line total.
- Subtotal.
- Empty Crates section (Bar / Beer Distributor only).
- Total.
- Save Cart and Recall buttons.
- Proceed to Checkout button.
- Cart count badge on bottom nav.

### 13.2 Edit Quantity modal

Tap any cart item to open this modal. Contains:

- Product name at top.
- Quantity input with − and + buttons.
- −0.5 / +0.5 chips (only shown if product has "Allow fractional sales" toggle on).
- Apply Discount section:
  - Toggle between % and ₦ (% default).
  - Numeric input.
  - Live calculation below: "Saving ₦X — new line total: ₦Y".
  - Cashier blocked with message: "Discounts not allowed at your role. Ask Manager."
  - Manager exceeding cap: message "Maximum discount is X%. Capped." auto-snaps to max.
- Remove button (red): immediate remove with snackbar at top "Item removed. Undo" for 5 seconds.
- Save Changes button (yellow): closes modal, updates cart.

### 13.3 Discount display on cart line

- Strikethrough original price + new discounted price.
- Small "−10%" or "−₦500" badge.
- Subtotal section shows "Saved: ₦X" in green.

### 13.4 Empty Crates section (Bar / Beer Distributor only)

- Crate value is set in the manufacturer card on the Inventory screen.
- Required Deposit is calculated from that crate value.
- Deposit Paid = amount customer is paying upfront for the crates (editable).
- Tracked in customer's wallet history and customer's crate balance in their profile.
- Empty crates are tracked **by manufacturer**, not by crate size (2026-06-01,
  user). A customer's (and a manufacturer's) crate balance is one figure **per
  manufacturer** — e.g. "owes 3 NB crates" — derived from the bottle products of
  that manufacturer on the order. The earlier Big/Medium/Small "crate size group"
  dimension is removed from crate balances: products were never assigned one, so
  the crate-return confirmation modal (§19.5) showed nothing. (Manufacturer is
  the level where crate value already lives, per the bullets above.)
- For walk-in customers: this section is hidden entirely. Walk-ins must return crates equal to receipt at the same time as the sale.
- Walk-in customers who have already paid the full deposit for empty crates can purchase goods without taking crates home.
- Inventory of empty crates is still adjusted automatically when the order is confirmed (for walk-ins too).

### 13.5 Save Cart and Recall

- Saved carts are per-cashier (only see your own).
- Auto-expire after 24 hours.

### 13.6 Empty state

"Cart is empty" — unchanged.

---

## 14. Checkout

Opens when user taps Proceed to Checkout on Cart.

### 14.1 Layout

- Order Summary (line items, subtotal, crate deposit if applicable, total).
- Customer card.
- Payment Method section (two-step — see 14.2).
- Checkbox: "Add wallet info to receipt" (off by default).
- Confirm Payment button.

### 14.2 Payment Method — two-step

Step 1 — Pick how customer is paying:

- Full payment now (covers the total).
- Partial payment now (rest becomes credit).
- Credit sale (entire amount becomes credit). NOT available for walk-ins.
- Pay from wallet (if registered customer has wallet credit).

Step 2 — Pick the receiving account:

- Cash Till.
- POS machine X (if multiple, pick which one).
- Bank Account X (if multiple, pick which one).

Selected account is credited in the Funds Register.

> Full payment — apply existing wallet credit (2026-06-01, user). When a
> **registered customer with positive wallet credit** chooses **Full payment**
> and that credit is **less than the order total**, checkout first **applies the
> wallet credit toward the order** and shows what is left to settle: it displays
> the **balance after the wallet is emptied** (the wallet drops to **₦0**) and
> the **outstanding** amount (total − wallet credit). The cashier then ticks an
> **"Outstanding paid"** checkbox and picks the **receiving account** (Cash Till
> / POS / Bank) for that outstanding cash, then confirms. The cash collected
> **flows through the wallet** (it posts as a wallet credit too, §14.3), so the
> wallet ends at exactly **₦0**. Walk-ins are unaffected (no wallet). If the
> customer's wallet credit already **covers** the total, this is the existing
> "Pay from wallet" path; if the customer has **no** credit, Full payment is
> unchanged (collect the total into the chosen account).

### 14.3 Wallet flow

Wallet is the source of truth for registered customers' money movements.

- Registered customers: every sale flows through the wallet. Customer's payment enters wallet, immediately leaves as payment for goods. Net wallet change = 0 if fully paid, negative if credit sale, positive if overpaid.
- Walk-in customers: no wallet flow. Money goes directly to the chosen account. No wallet record.

> Implementation note (2026-06-01, user — closes a code/plan gap): "every sale
> flows through the wallet" means **every** registered sale posts **two** wallet
> rows, regardless of payment method (cash, transfer, card, partial, credit):
>
> 1. a **debit** for the order **total** (goods leave), and
> 2. a **credit** for the **amount paid** at checkout (money in),
>
> netting to `paid − total` (0 when fully paid; negative = the customer owes).
> This includes **fully-paid cash sales** (debit total, credit total, net 0) —
> previously the code skipped the wallet entirely when nothing was owed, which
> broke the "wallet history is the source of truth" rule (#4). The **Funds
> Register is a separate ledger**: the cash/card/transfer still credits the
> chosen account (§14.2) for the till count — the wallet's payment-credit leg
> records the same money against the *customer's* account, not the business's,
> so there is no double-count. **"Owes" = the wallet balance, and is shown only
> when that balance is below zero.** Walk-ins are unaffected (no wallet; straight
> to the account; cannot owe).

> Ledger ordering (2026-06-01, user). The customer's wallet history is
> **newest-activity-first**. The order **charge (debit)** is the last step of a
> sale (money leaves after the payment comes in), so it sits at the **top** of
> the list, with the payment **credit** directly **below** it. Both legs are
> stamped the same instant; the display query tie-breaks the charge above the
> payment (`signed_amount_kobo` ascending). Display/ordering only — the net
> (paid − total) is unchanged.

### 14.4 After Confirm Payment

- Sale is recorded; order created with status "Pending" in Orders.
- Receipt opens.
- User can Print or Share.
- Tap "Done — Back to POS" → cart cleared → back to POS.
- The order sits in Orders > Pending until confirmed (rider assigned or pickup).

---

## 15. Receipt

Shown after Confirm Payment, and accessible from Orders > Completed tab.

### 15.1 Contents

- Business name + branch (store name) + Sales Receipt.
- Customer details (name, address, phone for registered customers).
- Order number (short format: ORD-000002) + date + time.
- Line items with quantities and prices.
- Discounts shown per line and in totals section: Subtotal, Discount, Total.
- Payment Method + Amount Paid.
- Wallet info — only if checkbox was ticked at checkout.
- Rider info — defaults to "Pick-up Order". When a rider is assigned at the Pending stage, rider name appears here.

### 15.2 Buttons

- Print Receipt (thermal printer integration — real, from day one).
- Share Receipt.
- Done — Back to POS.
- Refund button — visible to Manager and CEO only (on Completed tab receipts).

### 15.3 Removed

QR code is removed. Replaced by nothing.

---

## 16. Inventory

Bottom nav label "Stock" and sidebar item "Inventory" refer to the same screen. Use one consistent name in both places.

### 16.1 Header

- Title: Inventory. Subtitle: Stock Management.
- Stock Take icon (top right) → opens Daily Stock Count screen.
- Notification bell.

### 16.2 Top stat cards

- Total SKUs, Low Stock, Out of Stock.
- For Empty Crates tab: Total Crates, Out of Stock (different color).
- Cards are compact (reduced height/padding/font) so the product list gets more of the screen. (Amended 2026-05-30, pivot step 15.)

### 16.3 Tabs

- Products.
- Suppliers (CEO only by default, toggleable in Settings).
- Empty Crates (Bar & Beer Distributor only).
- History.

### 16.4 Products tab

- Filters: Store (renamed from Warehouse), Category, Manufacturer — all three as dropdowns, in that order. (Amended 2026-05-30, pivot step 15: Category was previously a row of chips; it is now a dropdown placed between Store and Manufacturer.)
- Search: a search toggle in the header (same pattern as Point of Sale) filters the product list by name/subtitle.
- Summary cards: a horizontally-scrollable row of tap-to-filter stat cards above the list — Total SKUs, Low Stock, Out of Stock, (Total Crates for Bar / Beer Distributor only), and **Near Expiry**. Near Expiry shows the count of products expired or within 30 days; tapping it filters the list to those, soonest-expiry first. Shown for all business types. (Near Expiry card added 2026-05-31.)
- Product list. Each product shows: name, in-stock badge, quantity, unit. Products at or past their Expiry Date (§16.5) are flagged, and the list can be sorted by soonest expiry.
- "Add Product" floating button — only visible to CEO and Manager. Opens the Add Product screen (§16.5).
- Tap a product opens the Product Details screen.

### 16.5 Add Product form

Add Product is a full screen (pushed route with an app bar and a pinned save button), not a bottom-sheet modal. (Amended 2026-05-30, pivot step 15: the form outgrew a modal.) The same form, prefilled, is the "Update Product" surface (§16.6).

The four legacy price columns (retail / bulk breaker / distributor / selling) are dropped during the pivot. Products now hold exactly three prices: Buying Price (required, hidden from Cashier and Stock keeper), Retailer Price, Wholesaler Price.

Required fields:

- Product name.
- Category.
- Description.
- Retailer Price.
- Wholesaler Price (new — added next to Retailer Price).
- Buying Price (required — products cannot be added without it; blocks save without a value).
- Low Stock Alert.
- Product Unit — chosen from a fixed list: Bottle, Can, PET, Sachet, Keg, Crate, Pack, Carton, Piece, Bag, Box, Tin, Other. The list is DB-enforced (a CHECK on `products.unit`, mirrored local + cloud); widening it is a schema change. (Widened 2026-05-31 so non-bottle units — Can / PET / etc. — actually save; the old list rejected them and the product silently never reached inventory.)
- Manufacturer (searchable).
- Store.
- Initial Quantity.

Optional fields:

- Expiry Date — a single optional date (all business types; not per-batch — per-batch/FIFO stays Phase 2). Used to flag and sell-down the stock closest to expiry. Saved to the product's `expiryDate` (schema v19 + cloud `0056_product_expiry.sql`). Businesses that don't track expiry leave it blank. (Added 2026-05-30, pivot step 15.)
- Size.
- Supplier.
- Allow fractional sales — toggle, default OFF. Controls whether −0.5 / +0.5 chips appear in the Edit Quantity modal.
- Track empty crate returns — toggle, only shown for Bottle-unit products. Positioned directly below the Manufacturer field. (Amended 2026-05-30, pivot step 15.)
- Empty Crate Value (₦) — shown only when "Track empty crate returns" is on, directly under the toggle (below Manufacturer). The crate value is **set at the manufacturer level** (`manufacturers.depositAmountKobo`): selecting a manufacturer autofills this field from that manufacturer's stored value, and saving writes the entered value back to the manufacturer so every product of the same manufacturer shares one crate value. The value is also mirrored to the product's `emptyCrateValueKobo` so the cart's deposit math is unchanged. (Amended 2026-05-30, pivot step 15.)
- Barcode — optional text field with scan-via-camera helper. Only surfaced on Pharmacy and Supermarket businesses (see §16.11).

Color selector is deferred (2026-05-30, pivot step 15): the 12-swatch picker is removed for now; products keep a default `colorHex`. It will be revisited when Boutique / Gadgets product types land, where colour is a real product attribute rather than a tile tint.

### 16.6 Product Details screen (tap a product)

Contents:

- Product image / icon, name, category badge.
- Stock status badge (In Stock / Low Stock / Out of Stock).
- Current quantity + unit.
- Retailer Price, Wholesaler Price.
- Buying Price (hidden for Cashier and Stock keeper).
- Manufacturer, Supplier.
- Low Stock Alert threshold.
- Allow fractional sales (read-only here).
- Expiry Date (if set), with a near-expiry badge when the date is near or past.
- Size (if set). (Color is deferred — see §16.5.)
- Empty crate tracking status (if applicable).
- Store assignment.
- Last updated timestamp.
- Recent activity: last 5 stock movements with timestamps and who did it. "View all" jumps to History tab filtered to this product.

Action buttons by role:

- CEO / Manager: the detail screen is **view-only until the top "Edit" (pencil) button is tapped**, which makes every field editable in place — name, description, prices, category / manufacturer / supplier / unit dropdowns, low-stock alert, size, expiry date, the allow-fractional and track-empties toggles, the empty-crate value, and the product image. A single **"Save Product"** button at the bottom persists everything in one update and shows a success / error banner. **The Sales Target is editable by CEO only** (a Manager sees it read-only with a "(CEO only)" note). **Quantity is read-only here** — stock changes go through Add Product (restock) or the Stock keeper's Update Stock modal, never inline. (Amended 2026-05-30, pivot step 15: replaces the old "opens the Add Product form prefilled" flow.)
- Stock Keeper: "Update Stock" — opens small modal:
  - Adjustment type: Add stock / Remove stock.
  - Quantity.
  - Reason (required if Remove): Damage / Theft / Expired / Other.
  - Notes (optional).
  - Save → updates quantity + logs to History.
- Cashier: no edit buttons. View-only. Buying price hidden.

### 16.7 Role access

| Action | CEO | Manager | Cashier | Stock keeper |
|--------|-----|---------|---------|--------------|
| View Inventory | All | Own store | Own store (view only) | Own store |
| Add product | Yes | Yes (if toggle on) | No | No |
| Edit product (full) | Yes | Yes | No | No |
| Delete product | Yes | Yes | No | No |
| Add stock | Yes | Yes | No | Yes |
| Remove / adjust stock | Yes | Yes | No | Yes |
| See buying price | Yes | Yes | Hidden | Hidden |
| See Suppliers tab | Yes | If toggled | Hidden | Hidden |
| See History tab | All stores | Own store | Hidden | Own store |
| See Empty Crates tab | Bar/Beer only | Bar/Beer only | Bar/Beer only | Bar/Beer only |

Each row is gated by a permission the CEO can revoke per role in Roles &
Permissions (defaults shown above):
- **View Inventory** = `stock.view` — also gates the sidebar item and the
  bottom-nav "Stock" tab. On for every role by default; revoking it hides
  Inventory entirely for that role.
- **Add product** = `products.add`; **Edit product** = `products.edit_price`;
  **Delete product** = `products.delete` (its own permission, not edit).
- **Add stock** = `stock.add` and **Remove / adjust stock** = `stock.adjust` —
  the two modes of the Update-Stock modal, gated independently.
- **See buying price** = `products.edit_buying_price`;
  **See Suppliers** = `suppliers.manage`.

### 16.8 History tab

- Tracks sales-driven stock movements, stock added, transfers between stores (Phase 2), and damages recorded.
- Product deletions also appear here: deleting a product removes its remaining stock via adjustment rows, which show in History (with the units removed, who deleted it, and when). (Amended 2026-05-30, pivot step 15.)
- Time filters: Today, 7 Days, 30 Days, All.
- CEO: full history across all stores. Manager: own store. Stock keeper: own store. Cashier: hidden.

### 16.9 Suppliers tab

CEO only by default. Manager access toggleable in CEO Settings.

### 16.10 Empty Crates tab

Only visible for Bar and Beer Distributor business types. Hidden for Restaurant, Supermarket, Pharmacy, Boutique. Manufacturers section — products should be associated with manufacturers for tracking.

### 16.11 Barcode scanning (Pharmacy and Supermarket only)

Phase 1 includes camera-based barcode scanning, but only for Pharmacy and Supermarket business types. Hidden for Bar, Beer Distributor, Restaurant, Boutique.

- Add Product form: optional Barcode field with a "Scan" helper button that opens the camera.
- Product Details: shows the barcode if set.
- Point of Sale: a barcode icon next to the search field opens the camera; a scan looks up the product by barcode and adds it to the cart (or opens Quick Sale if not found).
- The existing `barcode_widget` package stays in pubspec.yaml for this feature.
- The QR code on the receipt is still removed (see §15.3) — barcode scanning is a separate feature, not related to the old receipt QR.

---

## 17. Daily Stock Count

Accessed from the Stock Take icon at the top of the Inventory screen.

### 17.1 Header

- Back button, title "Daily Stock Count", subtitle = store name only (no warehouse ID).
- Store icon replaces warehouse icon.
- Stock Count History icon (top right).
- **Per store (2026-06-02, user):** a count is taken for **one store at a time** — there is no combined all-stores count. When the screen is opened with a store lock it is fixed to that store; when opened unscoped (e.g. a CEO with no store lock) a **Store picker** chooses which store to count (hidden when the business has a single store).

### 17.2 Body

- Columns: Product, System (current), Actual (editable), Diff (auto-calculated, red if negative).
- Save Count button. **Save Count shows a confirmation** summarising the adjustments (and any shortages) before it commits, since saving updates live stock (2026-06-02, user).
- Record Damages button — opens form: product, quantity, reason (broken/expired/spilled/theft/other). Submitting logs to History and reduces system stock.

### 17.3 Behaviour

- Multiple counts per day allowed, each with timestamp.
- Each saved count is recorded as a session (store, date, products counted, the per-product shortages/surpluses). The **Stock Count History** lists these per store, newest first — every saved count appears, including one with no changes.
- Saving triggers the daily reconciliation report → goes to CEO and Manager in Reports tab.
- A saved count for the store that day also **unlocks Close Day** for that store (§23.6 stock-count gate).
- Reconciliation report includes: shortages/unaccounted items, items sold, best-selling item, best-performing staff, cash balance, empty crates balance (Bar/Beer Distributor only).

### 17.4 Access

Stock keeper, Manager, CEO. Cashier blocked.

---

## 18. Customers

### 18.1 List view

- Header: Customers / Client Management / notification bell.
- Filter: "Showing: All Stores" (renamed from Warehouses) with store icon.
- Customer cards: avatar, name, address, price tier badge, wallet balance (green for credit, red for debt).
- "Add Customer" floating button.

### 18.2 Add New Customer form

- Customer Name (required).
- Price Tier (renamed from Customer Group) — Retailer / Wholesaler.
- Assign to Store (renamed from Warehouse).
- Address (required).
- Google Maps Location — map picker (upgraded from text input). Tap to open map, drop pin, save.
- Phone Number (required).
- Save button.

### 18.3 Customer Profile screen

- Avatar, name, price tier badge, phone, address, "Since [Month Year]".
- Edit button (CEO and Manager only).
- Wallet Balance card: balance, debt limit, "Set Limit" button (CEO and Manager only), period filter, "Add Funds" button.
- Add Funds flow: amount + payment method (Cash, Bank Transfer, POS card, Other) + optional note → updates wallet.
- 3 tabs: Wallet, Orders, Crates (Crates tab hidden for non-Bar/Beer Distributor businesses).

### 18.4 Role access

| Action | CEO | Manager | Cashier | Stock keeper |
|--------|-----|---------|---------|--------------|
| View customers | All | Own store | Own store | Hidden |
| Add customer | Yes | Yes | Yes | — |
| Edit customer | Yes | Yes | Yes | — |
| Soft delete | Yes | Yes | No | — |
| Set debt limit | Yes | Yes | No | — |
| Add funds to wallet | Yes | Yes | Yes | — |
| View wallet totals (Total In / Total Out) | Yes | Yes | Hidden by default¹ | — |

> ¹ **Wallet totals (2026-06-01, user):** the **Total In / Total Out** tiles on
> the customer's Wallet tab are **hidden by default for roles below Manager**.
> The CEO can re-enable them per role via the `customers.wallet.totals.view`
> permission in CEO Settings → Roles & Permissions. Manager and CEO always see
> them.

### 18.5 Business rules

- Duplicate names allowed (phone number differentiates).
- Sale that would exceed customer's debt limit → blocked. CEO or Manager PIN override at the till unlocks the sale.
- Soft delete only. Customer marked deleted, hidden from list, sales history stays intact.
- Walk-in customers: nothing tracked. Walk-ins cannot buy on credit. Empty crates must be returned in equal amount to receipt at the same time.

---

## 19. Orders

### 19.1 Tabs

- Three tabs: Pending, Completed, Cancelled.
- Default period filter: Last 24 hours (canonical chip set, §30.11).
- The period filter is a **dropdown** that sits inline with the search bar (on the Completed and Cancelled tabs). It replaces the old row of filter chips.
- **Roles below Manager (Cashier, Stock keeper) are capped to a Month maximum** on this filter — they get Day / Week / Month only. Manager and CEO also get Year / To Date / All Time.

### 19.2 Stat cards per tab

> Decision (2026-06-01, user): "Outstanding" is removed from the Pending tab.
> A debt is a **wallet** figure, not an order figure (§14.3, rule #4), and a
> per-tab `net − paid` sum wouldn't match the wallet (it double-counts a
> customer with several open orders and ignores prior wallet credit). Owing is
> instead shown **per order card** via the live wallet-debt badge, and **only
> when the customer's wallet balance is below zero**.

- Pending: count, Total Value, Pick-up.
- Completed: count, Revenue, Collected, Crate Deposits.
- Cancelled: count, Value Forfeited, Refunds Issued.

### 19.3 Tab visibility by role

| Role | What they see |
|------|---------------|
| CEO | All stores, all data |
| Manager | Own store only |
| Cashier | Items + quantities only — **no monetary values** (prices, totals, paid amounts) |
| Stock keeper | Own store, items + quantities only (no prices, totals, payment info) |

> **Monetary visibility (2026-06-01, user):** roles **below Manager** (Cashier,
> Stock keeper) do **not** see monetary values anywhere in the Orders list — the
> per-tab stat cards (Total Value / Revenue / Collected / Crate Deposits / Value
> Forfeited), the per-line item prices, and the order-card Total / Paid /
> wallet-debt amounts are all hidden. Manager and CEO see all of it. (The
> printed/shared **receipt** itself is unchanged — it is the customer's document
> and still carries its total.)

### 19.4 Order card

Uses short Order ID (e.g., ORD-000001), not the long UUID. Shows customer name, address, status badge, payment method, timestamp, line items, total, paid amount.

### 19.5 Pending order flow

> Decision (2026-06-01, user): **revenue is recognized at checkout**, not at
> Confirm — the sale and its money (Funds credit + wallet legs, §14.3) are
> already booked when the order is created. Moving a Pending order to Completed
> is therefore a purely **operational** milestone, not a financial one. It
> signals three things only: the order is now **closed to refund** (§19.7/§19.8),
> it has been **picked up / delivered**, and its **empty crates have been
> received**. (So "Completed" must not be treated anywhere as the point revenue
> is earned.)

- Sale completed at POS → order lands in Pending (already settled at checkout — received, or charged through the wallet, §14.3).
- User opens pending order → picks Pick-up OR assigns a Rider (rider just shown on receipt for now; full logistics in Phase 3).
- Taps Confirm.
- Bar / Beer Distributor only: Empty Crates confirmation modal opens, pre-filled with expected crate count. User confirms actual received count. Shortfall is automatically added to customer's crate balance, shown in red.
- Order moves to Completed (now closed to refund; picked up/delivered; crates received).

### 19.6 No editing of Pending orders

Wrong items → cancel and create a new order. When an order is in Pending, the sale is already complete and just waiting for confirmation.

### 19.7 Refund (Pending tab) — Manager and CEO only

> Decision (2026-06-01, user): the Pending order's reversal action is a single
> **Refund** button — it **replaces** the former Cancel button. There is no
> separate Cancel. Refund on the Completed tab is removed (§19.8).

- Reason required.
- Full refund only. It **reverses every leg the sale posted**: inventory
  restored, payment voided, the **wallet legs reversed** (so the customer's
  wallet returns to its pre-sale balance, §14.3), and the **Funds Register
  account debited** for the cash that goes back out.
- **Dating (2026-06-01, user):** the reversal is dated to the **refund day —
  the day/till the cash actually leaves — not the original sale day.** So a
  refund only ever affects *today's* Funds Register and *today's* Close Day; a
  day that was already closed is never reopened (§23.5, §23.8).
- **Requires an open funds day** (like a sale requires Opening Cash, §23.8):
  cash can't leave the till before the day is opened. Blocked with a clear
  message otherwise.
- The order moves to the Cancelled tab (which tracks Refunds Issued, §19.2).
- Logs the refund (before/after) and fires the §26.4 'sale cancelled/refunded'
  notification.

### 19.8 Refund on the Completed tab — removed

> Decision (2026-06-01, user): the Completed tab is read-only (receipt view) and
> has **no** Refund button. All refunds happen from the Pending tab (§19.7),
> before an order is confirmed. Tradeoff: once an order is confirmed → Completed
> it can't be refunded in-app; a post-completion return means the customer places
> a new order. (Was: "Refund button on the receipt modal" — superseded.)

---

## 20. Expenses

### 20.1 Main view

- Header: Expenses / Manage operating costs / notification bell (with pending approval count badge for CEO).
- 2 tabs: Expenses, Stats.
- Total Expenses card with period selector (default "Last 30 days"; canonical chip set, §30.11).
- Budget Activity bar (Spent vs Goal) — only counts approved expenses. Small text below shows "₦X pending approval" if any.
  - **Always visible (2026-06-02, user):** the budget is a **monthly** goal, so the bar is shown on **every** period selection (not gated to the "Last 30 days" view). Its Spent/pending figures always reflect the **last-30-days window**, independent of the period selector above the list (which only filters the expense list and the "Total Expenses" headline).
  - **Budget scope (2026-06-02, user):** the monthly budget goal is set **overall for the business and, optionally, per store** within the business. A store with no goal of its own falls back to the business-wide goal. The bar resolves the goal by the viewer's scope — CEO viewing all stores sees the business-wide goal; a store-scoped view (Manager, or a CEO filtered to one store) sees that store's goal. Stored in an `expense_budgets` table (`business_id`, nullable `store_id`, `amount_kobo`); set via the CEO-only "Set monthly budget" action (§20.3).
- Pending Approvals section at top (CEO only, shows when there are pending items).
- Expense list with status badges (Approved, Pending CEO approval, Rejected).
- "Add Expense" floating button.

### 20.2 Record Expense form

> **Presentation (2026-06-02, user):** the Add/Record Expense form opens as a
> full **screen** (pushed route), not a bottom-sheet modal. Same fields and
> rules below; only the presentation changed.

- Category — searchable dropdown. Pre-seeded with Fuel, Salary, Rent, Maintenance, Utilities, Supplies, Others. New categories are saved to the database on the fly. Anyone who can record expenses can create new ones.
- Amount.
- Payment Method — dropdown: Cash, Bank Transfer, POS card, Other.
- Date — picker, defaults to today.
- Description — optional.
- Reference / Receipt No. — optional.
- Receipt Photo — optional upload (camera or gallery, auto-compressed).
- Recorded By — auto-filled with logged-in user.
- Save Expense button.

### 20.3 Role access

| Action | CEO | Manager | Cashier | Stock keeper |
|--------|-----|---------|---------|--------------|
| View Expenses | All stores | Own store | Hidden | Hidden |
| Record expense | Unlimited | Up to limit | — | — |
| Edit own (within 24h) | Yes | Yes | — | — |
| Edit any expense | Yes | No | — | — |
| Delete (soft) | Yes | No | — | — |
| Approve / reject pending | Yes | No | — | — |
| Set monthly budget | Yes | No | — | — |
| Add custom category | Yes | Yes | — | — |

### 20.4 Pending approval flow

- Manager records expense above their limit.
- Expense saved as "Pending CEO approval". Manager sees it in their list with the pending badge.
- CEO sees it in two places: Pending Approvals section on Expenses screen + notification bell badge.
- CEO opens it, approves or rejects (with optional reason on reject).
- Approved: expense becomes normal, counted in budget.
- Rejected: expense stays in list with "Rejected" badge and CEO's reason. Manager is notified.

### 20.5 Cash and account rules

- Cash payment automatically reduces Cash Till for the day.
- Bank Transfer reduces selected Bank Account balance.
- POS card reduces selected POS machine balance.
- Other does not affect any tracked balance.

> **When the money leaves the account (2026-06-02, user):** the Funds Register
> debit is posted **when the expense becomes approved**, never while it is
> Pending. An auto-approved expense (CEO, or a Manager within their limit) debits
> immediately at record time; a Pending expense (Manager over limit) debits only
> when the CEO **approves** it; a **Rejected** expense never touches funds. The
> debit is dated to the **open funds day on which it posts** (today), mirroring
> the refund-day rule (§19.7) — a closed day is never reopened. Like a refund,
> recording/approving an expense that moves a tracked account (Cash / Bank / POS)
> **requires an open funds day** (§23.8); blocked with a clear message otherwise.
> "Other"-method expenses move no tracked account, so they do not need an open
> day. The receipt photo (§20.2) is stored as a **local file path** in Phase 1;
> cloud upload + cross-device sync of the image is deferred.

### 20.6 Stats tab

- Total by category (chart).
- Trend over time (line chart).
- Comparison to budget.
- Top recorded-by staff.

### 20.7 Empty state

"No expenses found" — unchanged.

---

## 21. Supplier Accounts

### 21.1 Layout

- Header: Supplier Accounts / Manage supplier payments / notification bell.
- 2 tabs: Payments, Suppliers.
- Total Payments card with period selector.
- Supplier filter chips ("All" + each supplier).
- Payment list with floating "Add Payment" button.

### 21.2 Suppliers tab

- "Add Supplier" button at top.
- List of suppliers, tap to open Supplier Details.

### 21.3 Supplier Details screen

- Bank icon, supplier name.
- Amount Paid + Amount Owed card. Calculation: Total Payments Made − Total Shipments Value. Negative means you owe the supplier. Positive means the supplier owes you.
- Available Empty Crates section (Bar / Beer Distributor only).
- Period selector chips.
- Shipments section at the bottom (renamed from "Goods Received") with per-period totals and the shipment list.

### 21.4 Record Payment form

- Supplier Name (searchable dropdown).
- Amount.
- Payment Method: Cash, Bank Transfer, POS card, Other.
- Date (defaults to today).
- Reference Number (optional).
- Notes (optional).
- Save Payment button.

No "Link to Delivery / Shipment" field — removed.

### 21.5 Add Supplier form

- Name (required).
- Phone.
- Address.
- Bank Account Name, Account Number, Bank.
- Notes.

### 21.6 Role access

CEO only by default. Toggleable to Manager in CEO Settings. Cashier and Stock keeper hidden.

### 21.7 Edit / Delete

- Both suppliers and payments are soft-delete only.
- Payments edit within 24h by CEO.
- Suppliers edit by CEO only.

### 21.8 No Stats tab

Supplier Accounts does not have a Stats tab.

### 21.9 Account rules

Cash payment to supplier reduces Cash Till. Other payment methods reduce their respective accounts in Funds Register.

---

## 22. Track Shipments

New sidebar item. Manages incoming shipments from suppliers. Fully decoupled from the Inventory "Add Stock" flow — stock additions and shipment recording are separate actions. Auto-linking deferred to Phase 3.

### 22.1 Layout

- Header: Track Shipments / Manage incoming goods / notification bell.
- 2 tabs: Pending, Received.
- Search by supplier name.
- Supplier filter.
- Period selector (default Month).
- "Add Shipment" floating button.

### 22.2 Pending tab

- List of pending shipments per supplier.
- Each card: supplier name, expected value, expected date, days until expected.
- Tap to view/edit or mark received.

### 22.3 Received tab

- List of received shipments.
- Each card: supplier name, value, date received, thumbnail of invoice photo.
- Tap to view full details.

### 22.4 Add Shipment form (creates a Pending shipment)

- Supplier (searchable dropdown).
- Expected value.
- Expected date.
- Notes (optional).
- Save.

### 22.5 Mark Received modal

- Upload invoice photo (camera or gallery).
- Total value of goods on invoice.
- Date received (auto-filled to today, editable).
- Save → moves shipment from Pending to Received and subtracts value from Total Payments on the supplier's account.

### 22.6 Role access

CEO only by default. Toggleable to Manager in CEO Settings. Cashier and Stock keeper hidden.

---

## 23. Funds Register

New sidebar item. Replaces the old Cash Register concept. Tracks balances for every payment method (Cash, POS machines, bank accounts) per store. Each day is its own complete ledger — no running balances carried week-over-week.

### 23.1 Daily model

Every day works like a fresh start. At the start of the day:

- Cash till: opening cash counted and entered (whatever the manager left in the float).
- POS machines: each starts at zero.
- Bank accounts: each starts at zero.

Through the day, sales, refunds, expenses, and supplier payments move money between these accounts based on the payment method used.

At the end of the day, all money in POS machines and bank accounts is withdrawn (transferred out manually by the manager — the app just notes it). Cash till closing is counted.

Next day begins fresh: POS and bank back at zero, cash at whatever the manager leaves as opening float.

### 23.2 Sidebar sections

- Open Day — set the day's starting balances per store.
- Close Day — enter closing/withdrawn amounts per store.
- Funds History — view past days' open/close records and reconciliations.
- Accounts — CEO manages the list of accounts per store.

### 23.3 Per-store accounts

- 1 Cash Till (auto-created, always exists).
- 0+ POS machines (CEO adds, names them).
- 0+ Bank accounts (CEO adds, names them).

### 23.4 Opening Day

Manager/CEO enters per store:

- Cash Till: opening cash counted.
- Every POS machine: opening balance (default 0, editable).
- Every bank account: opening balance (default 0, editable).

Until this is done, POS is blocked.

### 23.5 During the day

Every transaction moves the right account up or down:

- Sales: account up (based on payment method).
- Refunds: account down — **on the refund day** (the day the cash leaves), not
  the day the original sale was made (§19.7). Each day's Funds Register only
  ever reflects activity that happened on that day; a closed day is never
  reopened by a later refund.
- Expenses: account down.
- Supplier payments: account down.

The app shows a live "expected balance" per account in the Funds Register screen.

### 23.6 Closing Day

Manager/CEO enters per store:

- Cash Till: closing cash counted.
- Every POS machine: amount withdrawn (since the machine should be cleared).
- Every bank account: amount withdrawn / transferred out.

App calculates expected vs actual for each account. Mismatches go into the reconciliation report along with the stock reconciliation.

A **Close Day** button sits at the bottom of the Funds Register screen (visible to
CEO/Manager once the day is open, gated by `funds.close_day`). Closing fires a
§26.4 notification to **CEO and Manager** that the day is closed and the
reconciliation is ready (the funds-mismatch alert to the CEO still fires
separately when any account is off). The full Daily Reconciliation Report screen
(§25.9) remains its planned Ring 3 item.

**Stock-count gate (2026-06-02, user).** Closing the **current** business day is
blocked until a Daily Stock Count (§17) has been saved for that store that day —
the day's reconciliation needs the stock audit alongside the cash audit. The
Close Day button still shows; tapping it without a saved count opens a "Take
stock first" prompt with a shortcut to the Stock Count screen, and does **not**
close the day. **Exception:** closing a *stale previous* day (the §23.8
unclosed-previous-day path) is exempt — that day can no longer be counted, and
blocking it would deadlock the next day from ever opening. So the gate applies
only when the day being closed is today; back-dated closes proceed unchanged.

> Confirmed Phase 1 (2026-05-31, decision C1) — the earlier §3 build-order parenthetical that deferred this to Phase 2 is superseded; Funds History (§23.2) remains Phase 2.

### 23.7 Role access

- CEO: any store.
- Manager: own store only.
- Cashier & Stock keeper: hidden completely.

### 23.8 Blocking rules

- POS blocked until Open Day is done. Block message differs by role:
  - Cashier: "Opening cash not set. Wait for Manager or CEO."
  - Manager/CEO: "Opening cash not set. Tap to enter."
- Refunds (§19.7) are blocked until Open Day is done too — a refund moves real
  cash out of the till, so it needs an open day to land on (the void debit is
  dated to today, §23.5).
- New day blocked until previous day's Close Day is entered.
- Notifications fire to CEO and Manager every morning the previous day remains unclosed.
- Big banner shown when entering the screen if a previous day is unclosed.

> Confirmed Phase 1 (2026-05-31, decision C1) — the earlier §3 build-order parenthetical that deferred this to Phase 2 is superseded; Funds History (§23.2) remains Phase 2.

---

## 24. Activity Logs

### 24.1 Header

Activity Logs / System History / notification bell.

### 24.2 Filters

- Filter by Store (renamed from Warehouse). Defaults to "All Stores" for CEO.
- Filter by Action Type (Sales, Stock, Staff, Money, Customers, Settings, Security, etc.).
- Filter by Staff Member.
- Filter by Period (Today, Week, Month, All).
- Search bar (searches log description text).

### 24.3 Log entry card

- Icon (colored by category, red for Security).
- Title — human-readable (e.g., "Stock Count Saved", "New Product Added", "Invite Accepted").
- Time-ago badge.
- Description (no raw UUIDs — uses short codes or names).
- Full timestamp.

### 24.4 Tap a log entry

- Opens detail view with before/after values where applicable.
- "View record" link at the bottom that jumps to the related entity (customer profile, product page, etc.).

### 24.5 What gets logged

Unusual or sensitive actions only — discounts given, sales cancelled, refunds, role changes, suspensions, invites generated/accepted, settings changes, deletions, overrides, money movements, errors. Routine sales are NOT logged here (they live in Orders).

### 24.6 Sensitive entries

Role changes, suspensions, overrides are highlighted in red with a "SECURITY" tag.

### 24.7 Role access

- CEO: all stores by default.
- Manager: own store only (when toggled on in CEO Settings).
- Cashier and Stock keeper: hidden.

### 24.8 Retention

- Logs kept for 1 year, then archived.
- Archived logs viewable via a separate "Archived Logs" view.

### 24.9 Export

CSV/PDF export with selectable time frame. Deferred to Phase 3.

### 24.10 Empty state

"No activity yet."

---

## 25. Reports

### 25.1 Business Reports screen

- Header: back, "Business Reports", global period filter (defaults to Last 24 hours; canonical chip set, §30.11).
- Grid of report cards (2-column).

### 25.2 Reports list

- Sales Report — revenue, volume, top items, top staff, by period and store.
- Daily Reconciliation Report — auto-generated when the stock take is saved. The day's roll-up: total SKUs/items sold, the Close Day cash audit (expected vs actual per account, **fund shortages / misappropriations flagged**), empty crates details (Bar/Beer Distributor only), outstanding customer debts, and expenses recorded that day — plus the stock audit, sales summary, best staff, and top item. Opens via the period drill-down cards (§25.9). Draws its debt/expense figures from the existing Customer Ledger / Expense Tracker subsystems (a summary, not a duplicate). Depends on Close Day + Daily Stock Count, so it is built after both (Ring 3).
- Expense Tracker — by category, trend, vs budget.
- Customer Ledger — wallet balances, top debtors, top credit balances.
- Supplier Accounts Report — outstanding balances, total paid, total received per supplier.
- Funds Register Report — daily open/close per account, mismatches flagged.
- Profit Report — CEO only. Revenue, cost of goods, gross profit, margins.

Note: there is no Pending Approvals card on Reports. Pending approvals live on the Expenses screen and notification bell.

> Removed 2026-06-02 (user) — the standalone **Stock Audit report** (hub card +
> screen) was dropped from Phase 1. Stock health stays visible in Inventory, and
> the stock-reconciliation summary still appears inside the Daily Reconciliation
> Report (§25.2 / §25.9). The §25.3 row and the §30.11 scope reference were removed
> to match.

### 25.3 Role-based visibility

| Report | CEO | Manager | Cashier | Stock keeper |
|--------|-----|---------|---------|--------------|
| Sales | All | Own store | Hidden | Hidden |
| Daily Reconciliation | All | Own store | Hidden | Hidden |
| Expense Tracker | All | Own store | Hidden | Hidden |
| Customer Ledger | All | Own store | Hidden | Hidden |
| Supplier Accounts | All | If toggled | Hidden | Hidden |
| Funds Register | All | Own store | Hidden | Hidden |
| Profit Report | Yes | Hidden | Hidden | Hidden |

> Reconciled 2026-06-02 (user) — the Reports hub is **CEO + Manager only**, per
> §11.3 / §27.3. Earlier drafts of this matrix gave Cashier an "Own sales" Sales
> report and Stock keeper an "Own store (no money)" Stock Audit; those contradicted
> §11.3's "Cashier, Stock keeper do not see it" and the §27.3 sidebar. Resolved in
> favour of §11.3: Cashier and Stock keeper are **Hidden** for every report. A
> cashier's own-sales summary lives on Home / Orders, not in the Reports hub; a
> stock keeper's stock view lives in Inventory.

### 25.4 Reports badge on Home

Counts actionable alerts across reports (low stock, overdue payments, debt issues, reconciliation mismatches, etc.).

### 25.5 Period filter scope

Global default at top of Reports screen. Each report's detail screen can override.

### 25.6 Each report's detail screen

- Period filter (overrides global).
- Store filter (CEO sees switcher, others locked).
- Headline numbers at top.
- Charts where useful.
- Detailed list / breakdown below.
- CSV export button.

### 25.7 Export

CSV from day one. PDF in Phase 3.

### 25.8 Empty state

"No data for this period."

### 25.9 Daily Reconciliation drill-down (period cards)

The Daily Reconciliation Report does not open straight to a single detail screen; it opens to a list of **tappable period cards**, driven by the global period filter (§25.5):

- Period = **Day** → one card per calendar day. Tapping opens that day's reconciliation.
- Period = **Week / Month / Year** → one card per week / month / year. Tapping opens the reconciliation aggregated over that span (sums SKUs/items sold, expenses, and debts; lists each day's Close Day cash audit and any shortage / misappropriation flags inside the span).
- Each card shows a headline (e.g. items sold, net cash variance) and a **mismatch indicator** when any day in the span had a Close Day shortage or unaccounted funds.
- Role visibility follows §25.3 (Cashier & Stock keeper never see this report). CSV export per §25.6 / §25.7.

This per-period drill-down is specific to the Daily Reconciliation Report; the other reports keep the §25.6 single detail-screen + period-filter model.

> Confirmed Phase 1 (2026-06-01) — the Daily Reconciliation Report's content roll-up (SKUs sold, closing-day cash audit, empty crates, debts, expenses, fund-shortage flags) and the period-card drill-down were added on user request. The Sales Report card is **kept** (a distinct report). Build order unchanged: this stays a Ring 3 item, after Close Day (Ring 0/1) and Daily Stock Count (Ring 2) produce its data.

---

## 26. Notifications

### 26.1 Bell icon

Badge with count of unread notifications.

### 26.2 Notifications panel (bottom sheet)

- Title + "Dismiss All" button (no confirm, but undo snackbar at top for 5 seconds).
- List of notifications. Each card: icon, severity color (blue info / yellow warning / red alert), title, short description, timestamp.
- Empty state: "No notifications yet."

### 26.3 Tap behaviour

Opens the relevant screen (Inventory for low stock, Expense for pending approval, etc.).

### 26.4 Notifications that fire

**Money / Operations**

- Opening cash not set (every morning for Manager/CEO if not done).
- Previous day not closed (blocks new day, fires to Manager/CEO).
- Expense pending approval (fires to CEO when Manager submits over-limit).
- Expense approved/rejected (fires to Manager who submitted).
- Funds Register mismatch flagged at close (fires to CEO).
- Customer hit debt limit (fires to Cashier at sale time as a block).
- Customer crate balance went negative (fires to Manager/CEO).

**Stock**

- Low stock alert (fires to Stock keeper, Manager, CEO).
- Out of stock (fires to Stock keeper, Manager, CEO).
- Stock count saved → daily reconciliation report ready (fires to Manager, CEO).
- Damage recorded (fires to Manager, CEO).

**Staff**

- New staff invite accepted (fires to inviter + CEO).
- Staff suspended/reactivated (fires to CEO).
- Role changed (fires to CEO + affected staff).
- Staff hit 5 wrong PIN attempts → forced Forgot PIN (fires to CEO).

**Sales / Orders**

- Sale cancelled (fires to CEO + Manager).
- Refund issued (fires to CEO + Manager).
- Quick Sale used (fires to CEO + Manager for audit, since it bypasses inventory).
- Pending order awaiting confirmation > 24h (fires to Manager, CEO).

**Suppliers**

- Pending shipment overdue (expected date passed but not received — fires to Manager, CEO).
- New shipment received (fires to Manager, CEO).

**System**

- Sync issue (fires to user currently logged in).
- App update available (fires to all).

### 26.5 Grouping

Similar notifications grouped by type with count (e.g., "12 products are low on stock" — tap to see all).

### 26.6 Persistence

Stay until dismissed. Auto-expire after 30 days.

### 26.7 Sound and vibration

Vibrate by default. User can change via OS notification settings.

### 26.8 Settings

Hardcoded for now. Custom notification settings = Phase 2.

---

## 27. Sidebar and Bottom Nav

### 27.1 Profile area at top of sidebar

- Avatar circle (initials or photo).
- Name.
- Role under name (e.g., "Okwor Emmanuel — CEO").
- Terminal badge below (e.g., "Terminal 01").
- Lock icon (existing).
- "Switch User" labelled button (new).
- Background color matches role tag (CEO yellow, Manager blue, Cashier green, Stock keeper grey).

> Profile edit (2026-06-03, user). Tapping the avatar opens the profile screen,
> where the logged-in user can **edit their own name and avatar colour** (self-
> service, any role). The name change syncs to the cloud (it appears in Staff
> Management, the Who's-Working picker, and on receipts as the seller); avatar
> colour follows the existing per-device avatar behaviour. Editing the email
> (login identity) stays out of scope for now — it needs OTP re-verification.

### 27.2 Sidebar items (visually grouped, no text headings)

- Home
- Point of Sale
- Orders
- Inventory

*Visual group break.*

- Funds Register
- Expenses
- Supplier Accounts
- Track Shipments

*Visual group break.*

- Customers
- Staff Management

*Visual group break.*

- Stores (shows with one store from day one for CEO)

*Visual group break.*

- Reports
- Activity Logs
- CEO Settings

### 27.3 Visibility by role

| Item | CEO | Manager | Cashier | Stock keeper |
|------|-----|---------|---------|--------------|
| Home | Yes | Yes | Yes | Yes |
| Point of Sale | Yes | Yes | Yes | Hidden |
| Orders | Yes | Yes | Items only | Items only |
| Inventory | Yes | Yes | Yes (view only) | Yes |
| Funds Register | Yes | Yes | Hidden | Hidden |
| Expenses | Yes | Yes | Hidden | Hidden |
| Supplier Accounts | Yes | If toggled | Hidden | Hidden |
| Track Shipments | Yes | If toggled | Hidden | Hidden |
| Customers | Yes | Yes | Yes | Hidden |
| Staff Management | Yes | Limited | Hidden | Hidden |
| Stores | Yes | Hidden | Hidden | Hidden |
| Reports | Yes | Yes | Hidden | Hidden |
| Activity Logs | Yes | If toggled | Hidden | Hidden |
| CEO Settings | Yes | Hidden | Hidden | Hidden |

### 27.4 Bottom nav

- Home, Stock (links to Inventory — same screen, consistent name), POS, Orders, Cart.
- Cart is in bottom nav only — removed from sidebar (it was duplicated).

### 27.5 Removed sidebar items

- Cart (now bottom nav only).
- Warehouse (renamed to Stores).
- Cash Register (replaced by Funds Register).
- Deliveries (deferred to Phase 3).

---

## 28. Phase 2 (Deferred Features)

These are flagged for the second release. The architecture supports them — only the UI is held back for now.

- Multi-store UI: store picker on login (if staff assigned to multiple stores), stock transfer screens, per-store filters in reports, ability for CEO to add/remove stores.
- CEO can create custom roles beyond the four defaults.
- Custom permission groups.
- Per-card Home visibility toggles per role.
- Custom expense category cleanup tools (merge duplicates like "Fuel" / "Petrol").
- Per-line item discounts beyond what's already planned.
- Custom notification settings (CEO can toggle which notifications fire and to whom).
- Stats tab on Suppliers (currently no Stats tab).
- More tunable limits beyond discount, expense, and price-change toggle.
- PIN portability across devices/businesses. Met by **local re-establishment after email OTP** (re-enter the same PIN on a new device), **not** by cloud-storing the PIN. PINs stay device-local (§7.4); if cloud verification is ever needed, it must be a rate-limited `SECURITY DEFINER` verify RPC, never a readable hash column.

---

## 29. Phase 3 (Deferred Features)

Larger features deferred to the third release:

- Deliveries + Rider management (full screens, rider status tracking, route assignment, etc.). For now, when a rider is assigned to a Pending order, the rider's name just appears on the receipt — no status tracking, no rider management screen.
- Auto-linking stock additions to shipments (soft suggestion or auto-create when Stock keeper adds stock from a supplier with a recent Pending shipment).
- PDF export for reports.
- Activity Logs export.
- Logistics flow expansion.

---

## 30. Cross-cutting Decisions

Rules that apply across many screens:

### 30.1 Role-based guards everywhere

Every screen, button, and action checks the user's permissions before rendering or running. If a role doesn't have access, the menu item or button should NOT appear at all — do not show then block.

### 30.2 Wallet as source of truth

For registered customers, every money movement flows through the wallet, including cash sales. Wallet history is the complete audit trail.

### 30.3 Funds Register multi-account model

Cash Till, POS machines, and Bank accounts each have their own balance, tracked per store, reset daily.

### 30.4 Empty crates flow

Only visible and active for Bar and Beer distributor business types. Hidden for all others.

### 30.5 Hide-don't-block

UI elements a user doesn't have permission to use should not appear at all. Don't show greyed-out menus or disabled buttons unless visually intentional (e.g., suspended staff in the Staff Management list).

### 30.6 Smart defaults

Currency auto-fills based on country (editable in Settings). Period filters default to **Last 24 hours** on most screens and **Last 30 days** on the Expenses / Supplier-Accounts totals (the canonical chip set is in §30.11). Country defaults to Nigeria.

### 30.7 Loading animations

Rotating loading spinners replaced everywhere with subtle fade-in transitions. Sync progress bars stay.

### 30.8 IDs

Internal UUIDs are never shown to users. Short, human-readable codes are used instead (e.g., ORD-000001, INV-K7M2QX, REC-0912).

### 30.9 Soft deletes

Customers, suppliers, payments, expenses are all soft-deleted to preserve audit trails. Hard delete is not available anywhere by design.

### 30.10 Confirmation prompts

Destructive or significant actions confirm before proceeding (suspend staff, change role, revoke invite, delete supplier, etc.). Non-destructive removals (e.g., remove cart item) use undo snackbars for 5 seconds instead of upfront confirmation.

### 30.11 Date-range filter chips (canonical)

> Added 2026-06-01 (user). Every browse/report **period filter chip** uses one
> shared, rolling set so the same chip means the same thing on every screen:
>
> - **Last 24 hours** — `now − 24h`
> - **Last 7 days** — `now − 7 days`
> - **Last 30 days** — `now − 30 days`
> - **Last year** — `now − 365 days`
> - **To date** — unbounded (everything up to now)
>
> These are **rolling** windows (a span measured back from now), not calendar
> periods ("this week / this month"). One helper computes them
> (`lib/core/utils/date_period.dart`); screens must not roll their own date math.
> Default selection: **Last 24 hours** on most screens; **Last 30 days** on the
> Expenses and Supplier-Accounts totals (§30.6).
>
> This replaced an earlier mix of per-screen, inconsistent implementations
> (some rolling, some calendar-bound, with divergent labels — "Day", "Today",
> "This Week", "All Time", etc.) and a class of off-by-one / fragile date bugs.
>
> **Scope / exceptions:** This governs Home, Reports, Orders, Expenses, Supplier
> Accounts (Payments + Supplier detail), and the Customer wallet. It does **not**
> change the calendar-day-bound machinery — Funds
> Register Open/Close Day and the daily reconciliation (§23) stay
> per-calendar-day. **Inventory History (§16.8)** keeps its own labels
> ("Today / 7 Days / 30 Days / All"). The Phase-3 Deliveries screen is untouched.

---

## 31. Document Status

This document is the final, locked planning specification for Phase 1 of Reebaplus POS. Every screen and flow has been planned. The agent should treat this as the source of truth and refer to it during build.

Phase 2 and Phase 3 features are listed but not in scope for the current build. They are listed so the data model and architecture decisions support them without rework.

*End of document.*
