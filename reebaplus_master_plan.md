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
- `customers.add`, `customers.update`, `customers.delete`, `customers.wallet.update`
- `suppliers.manage`, `shipments.manage`
- `staff.invite`, `staff.suspend`, `staff.change_role`
- `activity_logs.view`, `settings.manage`
- `funds.open_day`, `funds.close_day`, `funds.view`

---

## 3. Build Order

Each step unlocks the next. Build in this order:

- Database schema rebuild. Drop the brittle role constraint. Build all new tables. Seed default roles and permissions on business creation.
- Auth flow. Welcome screen, CEO Sign Up, Staff Sign Up, Login (with Forgot PIN), Who is working picker.
- Staff Management screen with invite flow.
- CEO Settings page.
- Home screen, role-aware.
- Point of Sale, guarded by role.
- Cart and Checkout flow with wallet integration.
- Inventory and Product Details, role-aware.
- Customers screen with wallet.
- Orders (Pending, Completed, Cancelled).
- Daily Stock Count.
- Funds Register (new — multi-account model).
- Expenses with pending approval flow.
- Supplier Accounts.
- Track Shipments (new).
- Activity Logs.
- Reports.
- Notifications.

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

- Match the existing dark theme with yellow/orange accent.
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
- Action buttons: Change role, Suspend (or Reactivate if suspended).

### 9.6 Confirmations

- Suspending a staff — confirm dialog.
- Changing a role — confirm with before/after.
- Revoking an invite code — confirm.

### 9.7 Role access

CEO: full access. Manager: can manage Cashiers and Stock keepers only; CEO and other Managers appear as read-only. Cashier and Stock keeper: hidden completely.

Note: there is no permanent delete option, because deleting a staff would break old sales records. Suspended staff stay in the list, greyed out.

---

## 10. CEO Settings Page

Where the CEO tunes everything about the business. Menu screen with tappable sections. Each section opens into its own sub-page.

### 10.1 Sections from day one

- Business Info — business name, type, currency (editable).
- Stores — shows Store 1 (name, address, state, country). Phase 2 adds ability to add more stores.
- Security — auto-lock timer with preset chips: 1, 3, 5, 10, 15, 30 minutes (default 5).
- Roles & Permissions — four role cards (CEO, Manager, Cashier, Stock keeper). Tap to open.
- Activity Logs access — toggle for which roles can view activity logs (CEO only by default).

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

### 10.3 Phase 2 (deferred)

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
- Day/period dropdown stays as is.

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

### 14.3 Wallet flow

Wallet is the source of truth for registered customers' money movements.

- Registered customers: every sale flows through the wallet. Customer's payment enters wallet, immediately leaves as payment for goods. Net wallet change = 0 if fully paid, negative if credit sale, positive if overpaid.
- Walk-in customers: no wallet flow. Money goes directly to the chosen account. No wallet record.

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

### 16.3 Tabs

- Products.
- Suppliers (CEO only by default, toggleable in Settings).
- Empty Crates (Bar & Beer Distributor only).
- History.

### 16.4 Products tab

- Filters: Store (renamed from Warehouse), Manufacturer.
- Category chips.
- Product list. Each product shows: name, in-stock badge, quantity, unit.
- "Add Product" floating button — only visible to CEO and Manager.
- Tap a product opens the Product Details screen.

### 16.5 Add Product form

The four legacy price columns (retail / bulk breaker / distributor / selling) are dropped during the pivot. Products now hold exactly three prices: Buying Price (required, hidden from Cashier and Stock keeper), Retailer Price, Wholesaler Price.

Required fields:

- Product name.
- Category.
- Description.
- Retailer Price.
- Wholesaler Price (new — added next to Retailer Price).
- Buying Price (required — products cannot be added without it; blocks save without a value).
- Low Stock Alert.
- Product Unit.
- Manufacturer (searchable).
- Store.
- Initial Quantity.

Optional fields:

- Color.
- Size.
- Supplier.
- Allow fractional sales — toggle, default OFF. Controls whether −0.5 / +0.5 chips appear in the Edit Quantity modal.
- Track empty crate returns — toggle, only shown for Bar / Beer Distributor businesses.
- Barcode — optional text field with scan-via-camera helper. Only surfaced on Pharmacy and Supermarket businesses (see §16.11).

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
- Color, Size (if set).
- Empty crate tracking status (if applicable).
- Store assignment.
- Last updated timestamp.
- Recent activity: last 5 stock movements with timestamps and who did it. "View all" jumps to History tab filtered to this product.

Action buttons by role:

- CEO / Manager: "Update Product" — opens Add Product form prefilled with all values. Can edit anything including quantity.
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
| Update stock (qty only) | Yes | Yes | No | Yes |
| See buying price | Yes | Yes | Hidden | Hidden |
| See Suppliers tab | Yes | If toggled | Hidden | Hidden |
| See History tab | All stores | Own store | Hidden | Own store |
| See Empty Crates tab | Bar/Beer only | Bar/Beer only | Bar/Beer only | Bar/Beer only |

### 16.8 History tab

- Tracks sales-driven stock movements, stock added, transfers between stores (Phase 2), and damages recorded.
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

### 17.2 Body

- Columns: Product, System (current), Actual (editable), Diff (auto-calculated, red if negative).
- Save Count button.
- Record Damages button — opens form: product, quantity, reason (broken/expired/spilled/theft/other). Submitting logs to History and reduces system stock.

### 17.3 Behaviour

- Multiple counts per day allowed, each with timestamp.
- Saving triggers the daily reconciliation report → goes to CEO and Manager in Reports tab.
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

### 18.5 Business rules

- Duplicate names allowed (phone number differentiates).
- Sale that would exceed customer's debt limit → blocked. CEO or Manager PIN override at the till unlocks the sale.
- Soft delete only. Customer marked deleted, hidden from list, sales history stays intact.
- Walk-in customers: nothing tracked. Walk-ins cannot buy on credit. Empty crates must be returned in equal amount to receipt at the same time.

---

## 19. Orders

### 19.1 Tabs

- Three tabs: Pending, Completed, Cancelled.
- Default period filter: Day.

### 19.2 Stat cards per tab

- Pending: count, Total Value, Outstanding, Pick-up.
- Completed: count, Revenue, Collected, Crate Deposits.
- Cancelled: count, Value Forfeited, Refunds Issued.

### 19.3 Tab visibility by role

| Role | What they see |
|------|---------------|
| CEO | All stores, all data |
| Manager | Own store only |
| Cashier | Own sales only |
| Stock keeper | Own store, items + quantities only (no prices, totals, payment info) |

### 19.4 Order card

Uses short Order ID (e.g., ORD-000001), not the long UUID. Shows customer name, address, status badge, payment method, timestamp, line items, total, paid amount.

### 19.5 Pending order flow

- Sale completed at POS → order lands in Pending (already paid).
- User opens pending order → picks Pick-up OR assigns a Rider (rider just shown on receipt for now; full logistics in Phase 3).
- Taps Confirm.
- Bar / Beer Distributor only: Empty Crates confirmation modal opens, pre-filled with expected crate count. User confirms actual received count. Shortfall is automatically added to customer's crate balance, shown in red.
- Order moves to Completed.

### 19.6 No editing of Pending orders

Wrong items → cancel and create a new order. When an order is in Pending, the sale is already complete and just waiting for confirmation.

### 19.7 Cancel (Pending tab) — Manager and CEO only

- Reason required.
- Inventory restored.
- Full refund — choice of wallet (auto) or cash (logged manually).

### 19.8 Refund (Completed tab) — Manager and CEO only

- Refund button on the receipt modal.
- Reason required.
- Inventory restored.
- Full refund only — choice of wallet (auto) or cash (logged manually).
- For partial returns: customer places a new order.

---

## 20. Expenses

### 20.1 Main view

- Header: Expenses / Manage operating costs / notification bell (with pending approval count badge for CEO).
- 2 tabs: Expenses, Stats.
- Total Expenses card with period selector (default "This Month").
- Budget Activity bar (Spent vs Goal) — only counts approved expenses. Small text below shows "₦X pending approval" if any.
- Pending Approvals section at top (CEO only, shows when there are pending items).
- Expense list with status badges (Approved, Pending CEO approval, Rejected).
- "Add Expense" floating button.

### 20.2 Record Expense form

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
- Refunds: account down.
- Expenses: account down.
- Supplier payments: account down.

The app shows a live "expected balance" per account in the Funds Register screen.

### 23.6 Closing Day

Manager/CEO enters per store:

- Cash Till: closing cash counted.
- Every POS machine: amount withdrawn (since the machine should be cleared).
- Every bank account: amount withdrawn / transferred out.

App calculates expected vs actual for each account. Mismatches go into the reconciliation report along with the stock reconciliation.

### 23.7 Role access

- CEO: any store.
- Manager: own store only.
- Cashier & Stock keeper: hidden completely.

### 23.8 Blocking rules

- POS blocked until Open Day is done. Block message differs by role:
  - Cashier: "Opening cash not set. Wait for Manager or CEO."
  - Manager/CEO: "Opening cash not set. Tap to enter."
- New day blocked until previous day's Close Day is entered.
- Notifications fire to CEO and Manager every morning the previous day remains unclosed.
- Big banner shown when entering the screen if a previous day is unclosed.

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

- Header: back, "Business Reports", global period filter (defaults to Day).
- Grid of report cards (2-column).

### 25.2 Reports list

- Sales Report — revenue, volume, top items, top staff, by period and store.
- Daily Reconciliation Report — auto-generated when stock take is saved. Stock audit + cash audit + sales summary + best staff + top item.
- Expense Tracker — by category, trend, vs budget.
- Stock Audit — stock levels, low stock, out of stock, stock value, movement summary.
- Customer Ledger — wallet balances, top debtors, top credit balances.
- Supplier Accounts Report — outstanding balances, total paid, total received per supplier.
- Funds Register Report — daily open/close per account, mismatches flagged.
- Profit Report — CEO only. Revenue, cost of goods, gross profit, margins.

Note: there is no Pending Approvals card on Reports. Pending approvals live on the Expenses screen and notification bell.

### 25.3 Role-based visibility

| Report | CEO | Manager | Cashier | Stock keeper |
|--------|-----|---------|---------|--------------|
| Sales | All | Own store | Own sales | Hidden |
| Daily Reconciliation | All | Own store | Hidden | Hidden |
| Expense Tracker | All | Own store | Hidden | Hidden |
| Stock Audit | All | Own store | Hidden | Own store (no money) |
| Customer Ledger | All | Own store | Hidden | Hidden |
| Supplier Accounts | All | If toggled | Hidden | Hidden |
| Funds Register | All | Own store | Hidden | Hidden |
| Profit Report | Yes | Hidden | Hidden | Hidden |

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
- Settings

### 27.3 Visibility by role

| Item | CEO | Manager | Cashier | Stock keeper |
|------|-----|---------|---------|--------------|
| Home | Yes | Yes | Yes | Yes |
| Point of Sale | Yes | Yes | Yes | Hidden |
| Orders | Yes | Yes | Yes | Items only |
| Inventory | Yes | Yes | Yes (view only) | Yes |
| Funds Register | Yes | Yes | Hidden | Hidden |
| Expenses | Yes | Yes | Hidden | Hidden |
| Supplier Accounts | Yes | If toggled | Hidden | Hidden |
| Track Shipments | Yes | If toggled | Hidden | Hidden |
| Customers | Yes | Yes | Yes | Hidden |
| Staff Management | Yes | Limited | Hidden | Hidden |
| Stores | Yes | Hidden | Hidden | Hidden |
| Reports | Yes | Yes | Own sales | Hidden |
| Activity Logs | Yes | If toggled | Hidden | Hidden |
| Settings | Yes | Hidden | Hidden | Hidden |

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

Currency auto-fills based on country (editable in Settings). Period filters default to Day on most screens, Month on Expenses Total. Country defaults to Nigeria.

### 30.7 Loading animations

Rotating loading spinners replaced everywhere with subtle fade-in transitions. Sync progress bars stay.

### 30.8 IDs

Internal UUIDs are never shown to users. Short, human-readable codes are used instead (e.g., ORD-000001, INV-K7M2QX, REC-0912).

### 30.9 Soft deletes

Customers, suppliers, payments, expenses are all soft-deleted to preserve audit trails. Hard delete is not available anywhere by design.

### 30.10 Confirmation prompts

Destructive or significant actions confirm before proceeding (suspend staff, change role, revoke invite, delete supplier, etc.). Non-destructive removals (e.g., remove cart item) use undo snackbars for 5 seconds instead of upfront confirmation.

---

## 31. Document Status

This document is the final, locked planning specification for Phase 1 of Reebaplus POS. Every screen and flow has been planned. The agent should treat this as the source of truth and refer to it during build.

Phase 2 and Phase 3 features are listed but not in scope for the current build. They are listed so the data model and architecture decisions support them without rework.

*End of document.*
