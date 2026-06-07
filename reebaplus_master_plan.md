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
- `user_permission_overrides` — id, business_id, user_id, permission_key, is_granted (per-staff override of the role default; §10.2.1)
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
- `customers.add`, `customers.update`, `customers.delete`, `customers.wallet.update`, `customers.set_debt_limit`, `customers.wallet.withdraw`, `customers.wallet.totals.view`
- `suppliers.manage`, `shipments.manage`
- `staff.invite`, `staff.suspend`, `staff.change_role`
- `activity_logs.view`, `settings.manage`, `settings.delete_business` (CEO-only, locked ON; §10.3)

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
- [REMOVED 2026-06-04] Funds Register — the entire feature (per-account balances, Open/Close Day, the POS opening-cash gate, and the money ledger) was removed at user request. POS is now gateless; money is tracked as recorded sales / expenses / refunds / supplier-payments rather than per-account balances. See §23.
- [x] Checkout flow with wallet integration (§14). *(Two-step payment, Session 26; "Add wallet info to receipt" checkbox added Session 30. §14 complete. The receiving-account step was removed with Funds Register, 2026-06-04.)*
- [~] Customers screen with wallet (§18). *(Re-pass Session 31: soft-delete CEO/Manager, Crates-tab gated to Bar/Beer, required phone, new customers.set_debt_limit permission. Still open: Edit flow (updateCustomer is a stub), GPS location capture, Add-Funds payment-method selector.)*
- [~] Orders (Pending, Completed, Cancelled).
- [~] Daily Stock Count.
- [x] Expenses with pending approval flow. *(Full impl Session 59: approval flow, searchable categories, per-business/per-store monthly budget, edit/delete, stats. Cloud 0073 pending deploy. The Funds Register debit-on-approve/reversal was removed with Funds Register, 2026-06-04.)*
- [~] Supplier Accounts — per-supplier ledger (Invoice Total / Payment), real DB-backed (§21). *(Absorbs the former Track Shipments §22, removed 2026-06-06.)*
- [REMOVED 2026-06-06] Track Shipments — folded into Supplier Accounts; see the §22 tombstone.
- [~] Activity Logs.
- [~] Reports.
- [ ] Notifications.
- [ ] **Delete Business & Account (CEO Danger Zone)** — the last Phase 1 item. CEO permanently deletes their account, their business, and every business-scoped row, via one atomic cloud RPC (deliberate hard-delete exception to hard rule #9). Two-gate confirmation (type business name + PIN), online-only, then full local wipe and logout. Full spec in §10.3. *(Build last — after Ring 3, once every feature it cascades over exists.)*

> **Remaining work re-grouped 2026-05-31 into Rings 0-3 — see PIVOT_PLAN.md §8.0.** Ring order: Ring 0 (foundation invariants) — POS/Cart wholesaler-tier price fix, Activity Logs generic-schema migration + notifications.severity column + logActivity()/fireNotification() helpers, money-math consistency regression net. Ring 1 (close the money loop) — Orders Cancel reversal, Orders Refund, Customers Add Funds via WalletService.topup, Expenses approval/stats/budget, Supplier Accounts (per-supplier ledger; absorbs the former Track Shipments, removed 2026-06-06). Ring 2 (operational daily loop) — Customers Edit (real DAO write), Customers GPS capture, Daily Stock Count + Record Damages. Ring 3 (reporting & cross-cutting verification) — Daily Reconciliation Report, Notifications verification pass, Activity Logs feature screen, Reports hub + missing reports, barcode scanner, Deliveries removal, loading-state fade-in sweep, sync regression test, end-to-end QA.

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

- The accent (business colour) is CEO-selectable in CEO Settings → Appearance (§10.1) and applies business-wide; default amber. Light/dark/system stays a per-device choice.
- The whole auth/onboarding flow (Welcome, CEO/Staff Sign Up, Login, OTP, PIN, Who-is-working, etc.) is theme-aware: it follows the device's light/dark mode AND the selected accent. In dark mode it keeps the branded dark base; in light mode the base is the theme's light background with dark text. All content (titles, labels, typed input text, icons) is theme-aware so it stays legible in both modes — never hardcode a single-mode colour on an auth screen.
- Background: a base surface with a subtle pattern (faint dotted grid) and a soft gradient glow from one corner. The glow follows the active accent colour (e.g. green theme → green glow); dots are light on the dark base and dark on the light base.
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

- Single-staff device: PIN screen with email already filled in and shown.
- Multi-staff shared till: a cold start returns to the Who Is Working picker (§8) so the right person is chosen explicitly — the device never assumes the last user. Tapping a card opens that person's PIN screen. (This is the same anti-assumption rule as §8: identity is always chosen, never inherited from "whoever logged in last".)
- Goes straight to last-used business → Home. User can switch business from inside the app.

### 7.2a Identity is carried, never re-derived (security invariant)

- Whenever a user has been authenticated by email + OTP, that exact identity is carried forward into the PIN screen. The PIN screen must never re-derive "who is signing in" from sticky device state (the last device user / last email). On a shared till those are only prefill conveniences for the email box — never the basis for deciding whose PIN to check or whose data to bind.
- A PIN can only ever unlock the identity that was authenticated/selected. Two staff on the same till who happen to share a PIN are disambiguated by the chosen identity, not by "the last user".

### 7.3 Forgot PIN flow

- Sends email OTP.
- After verifying, user creates a new PIN (same rules — block obvious patterns).
- Signs them in.
- This is also the forced path: 5 wrong PIN attempts drop the user straight into this flow. There is no timed lockout — email/OTP access is the recovery gate.

### 7.4 PIN storage and recovery (local-only by design)

- The 6-digit PIN is a **device unlock** factor, not a portable identity. Its hash (`pin_hash` / `pin_salt` / `pin_iterations`) lives only in the local `users` row and is **never** sent to the cloud. The portable identity is the email + OTP.
- A new device re-establishes the PIN locally: the user verifies by email OTP, then sets a device PIN (re-entering the same digits is fine — it's a fresh local hash). The Phase-2 "PIN portability across devices/businesses" goal (§28) is met this way — by local re-establishment after OTP — **not** by cloud-storing the PIN. A readable 6-digit hash column would be trivially brute-forceable, which is why fintech apps keep the PIN device-local.
- If server-side verification is ever genuinely required, the only acceptable form is a rate-limited `SECURITY DEFINER` verify RPC that takes a candidate PIN and returns a boolean — never a readable hash column the client can pull.

### 7.6 Log Out clears the leaving user (not a device wipe)

- "Log Out" is distinct from "Switch User". Log Out signs the current user out and **clears that user's PIN** (`pin_hash`/`pin_salt`/`pin_iterations` → null, `pin` → setup-required) and revokes their session, so their **old PIN can no longer unlock the device** — they must re-authenticate with Email + OTP and set a **new PIN** (per §7.4). It also clears the device pointer + token, so the next launch demands Email + OTP with a blank email box (no sticky prefill of the last user).
- Log Out is deliberately **NOT a full device wipe**. The till is a shared, offline-first device: the business's data (orders, inventory, the sync queue) and **other staff's PINs** are kept, so the till stays usable offline and never needs a full re-pull after one person logs out. (This is why there's no unsynced-data block — nothing the cloud needs is deleted.) It only removes the leaving user's local credentials. A confirmation is shown first.
- "Switch User" / lock / auto-lock are the everyday fast path — they keep the current user's PIN and return to the Who Is Working picker (§8.5). Log Out is the deliberate "I'm leaving this device" exit that forces a fresh email/OTP + new PIN next time for that person.
- A full local wipe (`clearAllData`) is reserved for fresh CEO onboarding, not logout.

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

- Avatar, name, role, status, and the staff member's assigned store(s).
- Total sales made.
- Last 5 logins.
- **Assigned stores (multi-store, Phase 2, 2026-06-05, user).** The staff
  member's store assignment is the set of stores they work at — held in
  `user_stores`, the source of truth the Home store-lock already reads (a member
  assigned to more than one store gets the limited store picker, §16.2). A new
  staff member starts assigned to the one store chosen on their invite; the CEO
  can then **add or remove stores** for that member from this screen. The
  "Assigned store" detail row is tappable (for a permitted manager, on a
  below-CEO member) and opens a multi-select of the business's stores; saving
  applies the diff (`assign` upserts a `user_stores` row, un-assign hard-deletes
  it — junction-row tombstone, same path as a revoked role permission). A member
  must keep at least one store. Gated by **`staff.assign_stores`** (category
  Staff, CEO-only by default, revocable per role — separate from
  `staff.change_role` / `staff.suspend`). The CEO is never store-assigned (sees
  every store), so this is not shown on a CEO target. Hidden, not greyed,
  without the permission (hard rule #7).
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
- Appearance — CEO picks the business colour (accent): Amber, Blue, Purple, Green, or Black & White. Synced, so it applies to every device in the business. Light/dark/system mode is NOT here — that stays a per-device comfort choice, set from "Display" in the side menu. Default colour: amber. All accents share one typeface (the system default font).
- Danger Zone — CEO-only, sits at the bottom, visually separated. Holds **Delete Business** (delete the account, the business, and everything attached to it). Full behaviour in §10.3.

### 10.2 Roles & Permissions sub-page (per role)

- All permissions shown as toggles, grouped by category (Sales, Products, Stock, Reports, Customers, etc.). Exception: `sales.discount.give` has no toggle — whether a role can discount is governed entirely by the **Max discount %** limit shown under the Sales section (0% = no discount), so a separate on/off toggle would be redundant. The key remains in the catalogue, unenforced.
- **Stores** section sits first, at the very top. It groups the Manager-only **Allow viewing other stores** toggle (Default OFF; when ON, the Manager's Home store picker is unlocked — see §11.2 — so they can view other stores and request restock; stored per role in `role_settings` key `manager_view_all_stores`) together with the **Add, edit, and remove stores** permission toggle directly below it. The `Stores`-category permission group always renders here at the top, never at the bottom of the list. The "Add, edit, and remove stores" toggle is backed by the **`stores.manage`** permission key (category `Stores`, **CEO-only by default**, built 2026-06-05); it gates the sidebar Stores screen (add / edit / delete / stock transfer — create and cancel) and the Settings → Stores name/address editor — all of which previously rode on the generic `settings.manage`. Catalogue + CEO backfill: client schema v38 (`INSERT OR IGNORE`) and cloud `0095_add_stores_manage_permission.sql`. A second Stores permission — **`stores.receive_transfer`** (CEO-only by default, grantable to Manager/Stock keeper per role and per-store via §10.2.1) — gates confirming receipt of an incoming transfer; create/cancel remains `stores.manage`. Catalogue + CEO backfill: client schema v44 and cloud `0103_add_stores_receive_transfer_permission.sql`.
- The **Max discount %** limit (per role) sits directly under the Sales section near the top (Default: Manager 10%, Cashier 0%) — it is the discount control.
- The **Max expense approval** amount (per role) sits directly under the Expenses section (Default: Manager amount set by CEO).
- CEO role: all toggles locked ON (greyed out) so CEO's access can never be accidentally removed.
- Other role settings near the toggles:
  - Can change product prices (toggle). Default: Manager ON, others OFF.

#### 10.2.1 Permission scopes (Business → Store → User) (2026-06-04, user)

Permission settings are layered by scope, most-specific wins: **User > Store > Business**.

- **Business (default).** For each role, the CEO sets its permission toggles on the Roles & Permissions sub-page (everything described above). These apply to **every store** in the business — they are the default.
- **Store (default for users in that store).** A store can override a role's permissions just for that store; that becomes the default for every user working in that store. Reached from the role's page via a scope selector (Business / Store).
- **User (override the rest) — BUILT (Phase 1).** The CEO opens an **individual staff member's profile** (Staff Management → tap a staff member → **Permission access → Customize**) and adjusts *that one person's* permission access. Each permission toggle shows the **effective** value (the role default, unless overridden); flipping it away from the role default stores an override, flipping it back to the role default clears the override (inherit). A user override wins over both the store and business defaults. This lives on the staff profile, **not** the per-role Roles & Permissions page (which is by role, not by person). The CEO is never overridable (always all-on). Per-user overrides do **not** depend on multi-store, so they ship in Phase 1; they cover the boolean permission toggles only (the per-role limits — discount %, expense approval — stay role-level). A **Restore defaults** button at the bottom of this screen clears *all* of the staff member's overrides at once and returns them to the role defaults; it asks for confirmation first (so a stray tap can't wipe them) and is disabled when the person has no overrides. (Not shown for the CEO, who has none.)

**All three scopes ship.** Business and User shipped in Phase 1; the **Store** scope shipped 2026-06-06 as an authorized Phase 2 multi-store slice. On the role page, selecting **Store** reveals a store picker and the role's permission toggles for the chosen store: each toggle shows the **effective** value for that store (the business default, unless the store overrides it), flipping it away from the business default stores a per-store override, flipping it back clears it (inherit). A **Restore store defaults** action clears every override for that store+role at once. The CEO is never overridable (always all-on).

**Storage & resolution.** Per-user overrides live in the synced tenant table `user_permission_overrides` (`business_id`, `user_id`, `permission_key`, `is_granted`); presence of a row = an override, `is_granted` true/false = force-grant/force-revoke, absence = inherit the role default. It follows the §5 sync contract (in `_syncedTenantTables`, written through a DAO that enqueues, stream provider added). The **Store** layer is the synced tenant table `store_role_permissions` (`business_id`, `store_id`, `role_id`, `permission_key`, `is_granted`) — the same override shape as `user_permission_overrides` but keyed by store+role: a row forces a permission on/off for everyone working in that store, absence = inherit the business (role) default. It follows the same §5 contract (synced, DAO-enqueued, hard-delete junction like `role_permissions`, REPLICA IDENTITY FULL for live realtime deletes, stream provider). The runtime resolver (`currentUserPermissionsProvider`) merges the layers most-specific-wins, **User > Store > Business**: it starts from the role's business grants, applies the **active store's** overrides, then the user's overrides. The *active store* is the store the person is working at — the store chosen in the §12.1 navigation-drawer store picker, falling back to their sole assigned store; when neither resolves (e.g. a multi-store all-stores viewer who has "All Stores" selected), no store layer applies and effective = business ± user. The CEO skips both the store and user override layers (always all-on).

### 10.3 Delete Business & Account (Danger Zone)

The **last Phase 1 item to build** (see §3). A CEO can permanently delete their account, their business, and everything attached to the business. Irreversible. CEO-only — no other role ever sees this section. Gated by the `settings.delete_business` permission, which is locked ON for CEO and unavailable to all other roles.

- **Where it lives:** a red "Danger Zone" section at the bottom of the CEO Settings menu (§10.1), visually separated from the normal sections. One action inside it: **Delete Business**.
- **What "everything" means:** deleting the business removes every row owned by that `business_id` across all synced tenant tables — products and prices, stock, customers and wallets, suppliers, orders, payments, expenses, funds accounts and entries, crate ledgers, stores, roles, permissions grants, role settings, invite codes, staff memberships (`user_businesses` / `user_stores`), and activity logs. Nothing business-scoped survives.
- **What happens to staff:** their membership in *this* business is removed. A staff member who belonged only to this business keeps their login account but now has no business — on their next sign-in they land on the Welcome screen and must create a business or join another by invite. (Their account itself is not deleted; only the CEO's own account is deleted, because that was the CEO's explicit request.)
- **What happens to the CEO:** after the business is gone, the CEO's own user account (auth + local) is deleted, and the device is fully logged out back to the Welcome screen.
- **Confirmation (irreversible-action ritual):** never a single tap. A plain-English warning makes clear the action is **permanent and cannot be undone** and lists what will be lost ("all sales, stock, customers, staff access, and money records for this business will be permanently deleted and cannot be recovered"). The CEO then taps Delete and **re-enters their PIN** to confirm — the PIN is the confirmation gate. *(Updated 2026-06-07, user: the earlier "type the exact business name" gate was removed; PIN + the permanent-warning is the confirmation.)*
- **How it syncs (deliberate exception to hard rule #9):** this is the one place a hard delete is correct — soft-delete would leave a tombstoned but recoverable business, which defeats the purpose. It runs as a single atomic cloud RPC (`public.delete_business(p_business_id)`, `SECURITY DEFINER`) that the cloud executes in one server-side transaction: a cascade delete of the whole business (every business-scoped table has `business_id … REFERENCES businesses(id) ON DELETE CASCADE`, so `DELETE FROM businesses` fans out automatically; the append-only ledger `forbid_delete` guards are disabled for the duration via `ALTER TABLE … DISABLE TRIGGER USER`), plus the CEO's `auth.users` row. **It is called directly online, never enqueued** (not a `domain:` queue envelope, because the §6 queue would retry it blindly when connectivity returns) — the client calls the RPC, and only after the cloud confirms success does the device wipe local data (`clearAllData()`) and full-logout to the Welcome screen. If the device is offline, the action is blocked with a clear message before anything local is destroyed. Add `delete_business` to the build's irreversible-action list when implemented.
- **Notifying the console (added 2026-06-07, user):** the operator's web admin console (§32, "Admin Hub") must learn that a business was deleted so it can reconcile billing (e.g. cancel the Paystack subscription) and keep a compliance record. Because the business row itself is destroyed, the `delete_business` RPC writes — in the **same transaction**, just after the cascade — one row into a dedicated **cloud-only** audit table **`public.account_deletion_events`** (NOT a synced tenant table; the POS app never reads it, and it has **no FK to `businesses`** so it survives the cascade). The row snapshots `business_id`, `business_name`, `owner_user_id`, `owner_auth_user_id`, `owner_email`, the subscription `status`/`plan` at deletion time, `deleted_at`, and whether the in-RPC `auth.users` delete succeeded (`auth_user_deleted`, a backstop flag the console can act on). RLS restricts the table to `service_role` (the console's key); the SECURITY-DEFINER RPC inserts regardless of RLS. The console polls / realtime-subscribes this table and reconciles asynchronously — consistent with how subscription state already flows one-way through the cloud (§32).

### 10.4 Phase 2 (deferred)

- Create custom roles beyond the four defaults.
- Custom permission groups.
- More tunable limits beyond discount, expense, and price-change toggle.

### 10.5 Staff Settings (roles below CEO) (2026-06-04, user)

CEO Settings (§10.1) is CEO-only — it tunes the whole business. Staff **below CEO**
(Manager, Cashier, Stock keeper) get their own lightweight **Settings** page instead,
reached from a "Settings" sidebar item (§27.2). It is *personal*, not business-wide,
and holds only what an individual staff member may change about themselves:

- **Profile** — edit their own **name and avatar colour** (the same self-service edit
  described in §27.1; email stays out of scope — needs OTP). Saving fires the §26.4
  "Staff updated their profile" notification to every CEO + Manager.
- **Change PIN** — update their own device-unlock PIN (local-only, not synced).
- **Display** — the per-device light/dark/system mode, **moved here** from the side
  menu for these roles (the CEO keeps "Display" in the side menu). The business accent
  colour is *not* here — that stays CEO-only under §10.1 Appearance.

No new permission key: the page is role-gated (shown only to roles below CEO) and
re-checks at build. The CEO never sees it (they use CEO Settings).

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
- Period dropdown uses the canonical calendar chip set (§30.11), default Today.

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

The screen where sales actually happen. POS and Cart are gated on `sales.make`: any role without it (the stock keeper by default) has both tabs hidden from the bottom nav entirely (hard rule #7), with the POS screen guard as defense-in-depth.

### 12.1 Header

- Hamburger menu, app logo, business name with current store as subtitle (e.g., "Keffi"), search icon, notification bell.
- **Store selector (2026-06-05; moved to the navigation drawer 2026-06-06).** A single store picker lives in the **navigation drawer, just above "Home"** — not on the POS header. It is the **one app-wide active-store control**: the store chosen there drives the view filter on Home, Inventory, POS, the Customers list, the Activity Log, and the **Orders list** (added 2026-06-07 — orders are stamped with a `store_id` at checkout, so the Orders list shows only the active store's orders; "All Stores", offered to all-stores viewers, shows every store's orders) all at once (it replaced the per-screen store dropdowns those screens used to carry). It shows whenever the user has **more than one store they may select** — every active store for a CEO / all-stores Manager, otherwise their **assigned** store(s) (§11.2/§28 confinement). Single-store users (and confined staff assigned to just one store) see no selector. **"All Stores"** is offered only to all-stores viewers (CEO / all-stores Manager); picking it shows combined data on the overview screens — and on POS, which always needs a concrete selling store, the sale falls back to the user's **first selectable store** (shown in the POS header subtitle). The selected store drives the product grid, the price tier, and the order's `store_id` at checkout. There is no longer a one-time "pick your store" modal on POS entry (the old §28 gate); a confined multi-store staff member is auto-defaulted to their first assigned store and switches via the drawer picker. (Was CEO-only until staff multi-store assignment shipped, §9.5; was a POS-header icon until 2026-06-06.)

### 12.2 Filters row

- Price tier dropdown: Retailer / Wholesaler.
  - CEO and Manager: can switch freely.
  - Cashier: defaults to Retailer.
  - When a customer is selected in the cart, the price tier auto-applies based on the customer's attributed tier (overrides for everyone including Cashier).
  - If the customer is removed from the cart, price snaps back to default Retailer.
- Category dropdown.
- Lightning bolt — Quick Sale button (for items not in inventory).

### 12.3 Quick Sale

- Tapping the lightning bolt opens the modal to enter: product name, unit price, quantity.
- **CEO / Manager:** the item is added to the cart and calculated normally — no approval.
- **Cashier / any role below Manager:** the item is **not** added straight to the cart.
  "Send for Approval" records a **pending Quick Sale request** (§12.3.1) and the
  modal shows a "Waiting for approval…" state. The cashier cannot proceed until a
  Manager/CEO decides.
- All Quick Sales are tracked in Activity Logs.

#### 12.3.1 Cashier Quick Sale approval (added 2026-06-06, user)

The old CEO/Manager **PIN gate** for a Cashier Quick Sale is **replaced** by an
approval request — the same async, cross-device approval pattern as stock-keeper
adjustments (§16.6.1), surfaced in the renamed Reports → **Approvals** card (§25.2).

- A role below Manager fills the modal and taps **Send for Approval**. This writes
  a **pending request** (item name, quantity, unit price, the active selling
  store) and notifies the **CEO and the Manager(s) of that store** (if no Manager
  is tied to the store, only the CEO). The modal stays open showing
  "Waiting for approval…", with a **Cancel** to withdraw the request.
- The approver opens the **Approvals** card on the Reports hub — CEO sees every
  store's requests, a Manager only their assigned store(s). Each request is a
  tappable card with **Approve / Reject**.
- **Approve** notifies the cashier; their device then **drops the item into the
  cart**. Because a Quick Sale bypasses inventory (§26.4), approval moves **no
  stock** — it only releases the one item into the cart, after which Quick Sale is
  locked again (every Quick Sale needs its own approval).
- **Reject** (with an optional reason) notifies the cashier; their modal **closes**
  and a "Quick sale was rejected" message shows. They cannot proceed.
- Either decision is written to the activity log. **Manager/CEO** Quick Sales add
  directly and never enter this queue.

> Recorded as a real order line (2026-06-04, user). A Quick Sale checks out like
> any sale: it becomes a normal order line with **no product** (`order_items.
> product_id` is nullable — schema v35 / cloud `0091`); the typed name is carried
> in the line's price snapshot and shown everywhere via the line's display name.
> Because the item is not in inventory it **bypasses inventory** (§26.4) — no
> stock deduction, no stock-transaction, no inventory-cache row. **Reports:** a
> Quick Sale **counts in the Sales Report and the Daily Reconciliation revenue +
> items sold**, but is **excluded from the Profit Report** (no buying price is
> captured, so its cost is unknown — like any uncosted line). On checkout it
> writes an activity-log entry (`quick_sale`) and fires the §26.4 "Quick Sale
> used" notification to CEO + Manager.

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
- **Recording a return from the customer profile (2026-06-06, user).** The customer profile's **Crates tab** has a **"+" card pinned at the top** ("Record crate return"). It opens a modal that takes a **manufacturer** + a **crate count**, records the empties into physical stock, and nets the customer's balance for that manufacturer (the same ledger the order-return modal uses): it **reduces an owed balance**, or — when the customer **owes nothing** for that brand — records a **crate credit** (the business now holds their crates), shown as "N crates credit". This top card **replaces** the earlier per-row "+" that only appeared on owed brands, so a return can be recorded for any manufacturer (including one with no debt). Gated on `sales.make` (hidden otherwise); the card shows even when the customer has no crate activity yet. This is the registered-customer, outside-an-order path; the mark-delivered crate-return modal (§19.5) still covers crates returned with a Pending order.

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
- Payment Method section (method chips + Credit Sale card — see 14.2).
- Checkbox: "Add wallet info to receipt" (off by default).
- Confirm Payment button.

### 14.2 Payment Method (redesigned 2026-06-05, user)

Pick how the customer is paying. The Full-payment and Partial-payment cards were
removed; the cashier now sees **two payment-method chips** plus the retained
**Register as Credit Sale** card:

- **Cash / Transfer** — the customer pays now. The cashier enters the **amount
  paid**, and the wallet absorbs the difference against the order total:
  - **shortfall** (paid < total) → booked as **debt** on the customer's wallet;
  - **excess** (paid > total) → **tops up** the wallet;
  - **exact** → wallet unchanged.
- **Pay from Wallet** — charge the **whole order total** to the wallet. No amount
  is entered: available wallet credit is consumed and any **shortfall becomes
  debt**. (Registered customers only; walk-ins have no wallet, hard rule 14.)
- **Register as Credit Sale** — nothing is paid now; the **whole total becomes
  debt**. Registered customers only.

The payment **method** (cash / transfer) is recorded on the order. There is no
receiving-account step — the Funds Register was removed (§23).

Walk-ins (no wallet) only ever see **Cash / Transfer** and must pay in full; they
see neither the wallet chip nor the Credit Sale card.

**Debt-limit gate.** Any sale that would leave the wallet in **debt** is blocked
**and the cashier is notified** when the resulting debt would breach the
customer's **debt limit**, or when the customer has **no debt limit set**. A
fully-paid or overpaid Cash / Transfer never adds debt, so it is never gated —
even for a customer already in debt. The live preview shows the resulting wallet
balance and a red over-limit warning before Confirm. (See §983: a sale over the
debt limit is blocked.)

**Default selection.** Checkout opens on **Cash / Transfer** for everyone — in
this model a wallet default would book a full-total debt on a thoughtless confirm
when the customer has no credit, so the cashier opts into Pay from Wallet /
Credit Sale.

> Supersedes (2026-06-05): the prior Full / Partial cards, the "apply existing
> wallet credit" + "Outstanding paid" sub-flow (2026-06-01 / 2026-06-03), and the
> "default to Pay from Wallet" selection (2026-06-03). Partial payment is now just
> a Cash / Transfer with an amount below the total; applying existing credit is
> automatic (Pay from Wallet consumes credit first, then books the rest as debt).
> The underlying two-leg wallet math (§14.3) is unchanged — net = paid − total.

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
> broke the "wallet history is the source of truth" rule (#4). **"Owes" = the
> wallet balance, and is shown only when that balance is below zero.** Walk-ins
> are unaffected (no wallet; cannot owe). *(The Funds Register that used to credit
> the chosen account for the till count was removed 2026-06-04, §23.)*

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

- Business name + **store address** + Sales Receipt. The address is the
  **recording store's own address** (the `stores.location` of the sale's
  `store_id`), resolved from the **order**, not the device's currently-selected
  store — so a reprinted/reshared receipt always shows the branch that actually
  made the sale. **Country is excluded** from the receipt address: the stored
  `location` is the fused `"<street>, <city/state>, <country>"` string, so the
  receipt shows everything **except the trailing country segment** (street +
  city/state only). The old `Branch: <store name>` line is **removed** — the
  address replaces it. (2026-06-05, user.)
- Customer details (name, address, phone for registered customers).
- Order number (short format: ORD-000002-XXXXXX — the per-device tag suffix per §30.8.1) + date + time.
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
  - Save → **submits the change for approval** (§16.6.1); inventory is not
    touched until a Manager/CEO approves.
- Cashier: no edit buttons. View-only. Buying price hidden.

### 16.6.1 Stock-keeper adjustment approval (added 2026-06-04, user)

A stock keeper's Add/Remove does **not** change inventory directly. Saving the
Update Stock modal records a **pending request** and notifies the **CEO and the
Manager(s) of the affected store** (if no Manager is tied to that store, only the
CEO). The stock keeper sees a "Sent for approval" confirmation; the stored
quantity is unchanged until a decision is made.

- The approver opens the **Stock Approvals** card on the Reports hub (§25.2) —
  CEO sees every store's requests, a Manager only their assigned store(s). Each
  request is a **tappable card that expands** to the full detail (who, store,
  reason, when) with **Approve / Reject** actions.
- **Approve** runs the real adjustment (the same atomic inventory + ledger path a
  Manager/CEO uses), so the stock number changes only now. If the store no longer
  has enough stock for a Remove, approval fails and the request stays pending.
- **Reject** discards the request — no inventory change. The approver may add an
  **optional reason**; it is shown to the stock keeper in the rejection
  notification and recorded in the activity log. (Added 2026-06-04, user.)
- Either decision notifies the stock keeper who submitted (approved / rejected) and
  is written to the activity log.
- **Manager/CEO** adjustments are applied **directly** and never enter this queue —
  approval gates stock-keeper actions only.

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
- **View buying price** = `products.edit_buying_price`;
  **See Suppliers** = `suppliers.manage`.

### 16.8 History tab

- Tracks sales-driven stock movements, stock added, transfers between stores, and damages recorded.
- Product deletions also appear here: deleting a product removes its remaining stock via adjustment rows, which show in History (with the units removed, who deleted it, and when). (Amended 2026-05-30, pivot step 15.)
- Time filters: Today, 7 Days, 30 Days, All.
- CEO: full history across all stores. Manager: own store. Stock keeper: own store. Cashier: hidden.

#### §16.8.1 Stock transfer between stores (shipped 2026-06-06)

**State machine (send → receive):** A transfer moves through `in_transit → received` (or `in_transit → cancelled`). Single-product per transfer row (multi-product = queue multiple transfers).

- **Create / in_transit:** CEO (or anyone with `stores.manage`) dispatches from the Stores screen → Transfer screen. Source inventory is **decremented immediately** (via `pos_inventory_delta_v2` `transfer_out` leg); stock is un-sellable until receipt. The `StockTransfers` header row is written `in_transit` in the same local transaction as the inventory envelope (atomicity, mirror of approval pattern).
- **Received:** Destination user with `stores.receive_transfer` confirms on the Incoming Transfers screen. Destination inventory is incremented (`transfer_in` leg). `receivedBy` / `receivedAt` stamped.
- **Cancelled:** CEO cancels an in-flight transfer. A compensating `transfer_in` at the source restores inventory. The header flips to `cancelled`.

**Permissions:** `stores.manage` → create + cancel (CEO only by default). `stores.receive_transfer` → confirm receipt (CEO only by default; grantable to Manager/Stock keeper per role and per-store via §10.2.1).

**Insufficient-stock guard:** `pos_inventory_delta_v2` rejects the `transfer_out` leg server-side (`insufficient_stock` P0001); the transfer is not created.

**Ledger / History:** `transfer_out` and `transfer_in` `stock_transactions` rows are minted by the server, feed §16.8 Inventory History automatically.

**Per-store empty-crate tracking (`store_crate_balances` — shipped Phase 2):**

- Today empty crates were tracked business-wide on `manufacturers.empty_crate_stock`. Phase 2 re-architects this: a new **`store_crate_balances (business_id, store_id, manufacturer_id, balance)`** cache table holds per-store empty-crate counts; `crate_ledger` gains a nullable `store_id` column (set only on business-held movements; customer rows stay null). `customer_crate_balances` is unchanged (customer owes the *business*, not a store).
- **Backfill rule:** on schema v44 upgrade, existing `manufacturers.empty_crate_stock` is folded into the **primary store = MIN(created_at) non-deleted Stores row** (deterministic; CEO can re-transfer crates after migration to the physical location).
- **Crate leg on transfers (Phase 3):** a `pos_transfer_crates` RPC will move `store_crate_balances` between stores atomically; the transfer create screen gains an optional crate component for Bar/Beer Distributor businesses.

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
- **Per store (2026-06-02, user):** a count is always *taken* for **one store at a time** — there is no combined all-stores count. When the screen is opened with a store lock it is fixed to that store; when opened unscoped a **Store picker** chooses which store to count (hidden when there is only one store in scope).
- **Role-based store visibility (2026-06-02, user):** who may see which store follows the app's standard "view all stores" rule (same as the Home filter): the **CEO** — and a **Manager** the CEO has granted all-stores — may view **every store**, including an **"All stores" overview** at the top of the picker. That overview is **read-only** (a stock snapshot across all stores; no Actual input, Save Count, or Record Damages — counting is per store, so they pick a store to take a count). **Roles below that (Stock keeper, and Manager without the grant) are confined to their own assigned store(s)** — both for taking a count and for the Stock Count History, which only shows their store(s).

### 17.2 Body

- Columns: Product, System (current), Actual (editable), Diff (auto-calculated, red if negative).
- Save Count button. **Save Count shows a confirmation** summarising the adjustments (and any shortages) before it commits, since saving updates live stock (2026-06-02, user).
- Record Damages button — opens form: product, quantity, reason (broken/expired/spilled/theft/other). Submitting logs to History and reduces system stock.

### 17.3 Behaviour

- Multiple counts per day allowed, each with timestamp.
- Each saved count is recorded as a session (store, date, products counted, the per-product shortages/surpluses). The **Stock Count History** lists these per store, newest first — every saved count appears, including one with no changes.
- Saving triggers the daily reconciliation report → goes to CEO and Manager in Reports tab.
- Reconciliation report includes: shortages/unaccounted items, items sold, best-selling item, best-performing staff, empty crates balance (Bar/Beer Distributor only). *(The cash-balance/Close-Day gate was removed with Funds Register, 2026-06-04, §23.)*

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
- Wallet Balance card: balance, debt limit, "Set Limit" button (CEO and Manager only), period filter, "Add Funds" button, "Refund Cash" button (CEO and Manager only).
- Add Funds flow: amount + payment method (Cash, Bank Transfer, POS card, Other) + optional note → updates wallet.
- **Refund flow (CEO and Manager only — 2026-06-05, user).** Pays the customer back money the business holds for them: a **positive spendable wallet credit** and/or a **held crate deposit** once the crates are back. The sheet shows what's available to refund — broken into "Wallet credit" and "Crate deposit held" — and the amount entered is drawn from the held deposit first, then from spendable credit, capped at the total available. **The destination depends on whether the wallet is in debt (user, 2026-06-05):**
  - **Wallet in debt** → the held deposit is refunded **to the wallet** (a `crate_refund` spendable credit) so it **reduces what the customer owes** — **no cash option**. (Spendable credit is zero when in debt, so only the deposit is refundable.) e.g. a customer owing ₦30,100 with ₦12,000 held → after the refund they owe ₦18,100 and hold ₦0.
  - **Wallet not in debt** → paid out as **cash** via the chosen method (Cash / Bank Transfer / POS card / Other).
  In both cases it is **recorded** — a `crate_deposit_refunded` debit clears "held"; the cash path adds a `payment_transactions` refund row, the to-wallet path adds the `crate_refund` credit — plus an `activity_logs` entry and a notification to CEO + Manager (§26.4). Gated by the new `customers.wallet.withdraw` permission. This is the only in-app way to release a **completed** sale's held crate deposit (the mark-delivered crate-return modal only covers Pending orders, §13.4).
- 3 tabs: Wallet, Orders, Crates (Crates tab hidden for non-Bar/Beer Distributor businesses). The Crates tab lists the customer's per-manufacturer crate balance (owed / clear / credit) and has a top "+" card to record crates brought back (§13.4).

### 18.4 Role access

| Action | CEO | Manager | Cashier | Stock keeper |
|--------|-----|---------|---------|--------------|
| View customers | All | Own store | Own store | Hidden |
| Add customer | Yes | Yes | Yes | — |
| Edit customer | Yes | Yes | Yes | — |
| Soft delete | Yes | Yes | No | — |
| Set debt limit | Yes | Yes | No | — |
| Add funds to wallet | Yes | Yes | Yes | — |
| Refund cash from wallet | Yes | Yes | No | — |
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
- Default period filter: Today (canonical chip set, §30.11).
- The period filter is a **dropdown** that sits inline with the search bar (on the Completed and Cancelled tabs). It replaces the old row of filter chips.
- **Roles below Manager (Cashier, Stock keeper) are capped to a Month maximum** on this filter — they get Today / This Week / This Month only. Manager and CEO also get This Year / To Date.

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

Uses short Order ID (e.g., ORD-000001-XXXXXX — the per-device tag suffix per §30.8.1), not the long UUID. Shows customer name, address, status badge, payment method, timestamp, **who created the order**, line items, total, paid amount.

> Created by (2026-06-04, user). "Who created the order" is the staff member who
> rang up the sale (`orders.staff_id`). Shown on **every** tab (Pending /
> Completed / Cancelled) and to **every** role — it is not a monetary value, so
> it is not hidden from Cashier / Stock keeper (§19.3). Falls back to "—" for any
> legacy order with no recorded seller.

> Order creator shown (2026-06-04, user). Every order card shows the name of the
> staff member who created it (`orders.staffId` → user name), on **all three
> tabs** — Pending, Completed, Cancelled. The creator's name is **not** a monetary
> value, so unlike the §19.3 money-hiding rule it is visible to **every** role.
> Falls back to "Unknown" when the staff row can't be resolved (e.g. a member
> removed from the business). Resolved via `usersByBusinessProvider`.

### 19.5 Pending order flow

> Decision (2026-06-01, user): **revenue is recognized at checkout**, not at
> Confirm — the sale and its money (the wallet legs, §14.3) are
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
  restored, payment voided, and the **wallet legs reversed** (so the customer's
  wallet returns to its pre-sale balance, §14.3). *(The Funds Register account
  debit for the cash going back out was removed with Funds Register, 2026-06-04,
  §23 — the refund is recorded as a cancelled order, not posted to an account
  balance, and no open day is required.)*
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
- Total Expenses card with period selector (default "This Month"; canonical chip set, §30.11).
- Budget Activity bar (Spent vs Goal) — only counts approved expenses. Small text below shows "₦X pending approval" if any.
  - **Always visible (2026-06-02, user):** the budget is a **monthly** goal, so the bar is shown on **every** period selection (not gated to the "This Month" view). Its Spent/pending figures always reflect the **current calendar month**, independent of the period selector above the list (which only filters the expense list and the "Total Expenses" headline).
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

> **"View Expenses" now follows the active-store picker (§20.8, 2026-06-07).**
> "All stores" / "Own store" above is the *scope* the picker enforces — a CEO /
> all-stores Manager can pick "All Stores" (aggregate) or any one store; a
> confined viewer is pinned to their assigned store(s). The scope drives the
> list, Stats, and the budget goal.

### 20.4 Pending approval flow

- Manager records expense above their limit.
- Expense saved as "Pending CEO approval". Manager sees it in their list with the pending badge.
- CEO sees it in two places: Pending Approvals section on Expenses screen + notification bell badge.
- CEO opens it, approves or rejects (with optional reason on reject).
- Approved: expense becomes normal, counted in budget.
- Rejected: expense stays in list with "Rejected" badge and CEO's reason. Manager is notified.

### 20.5 Payment-method and approval rules

- The expense records its **payment method** (Cash, Bank Transfer, POS card,
  Other) for reporting; it no longer posts a debit to any account balance.
- An expense counts toward spend (budget, Stats, Daily Reconciliation) only once
  it is **approved**: an auto-approved expense (CEO, or a Manager within their
  limit) counts at record time; a Pending expense (Manager over limit) counts
  only when the CEO **approves** it; a **Rejected** expense never counts.

> **Funds Register removed (2026-06-04, user).** Expenses used to post a Funds
> Register debit on approval against the chosen account (Cash Till / Bank / POS),
> dated to the open funds day, and recording a tracked-method expense required an
> open day. The Funds Register was removed (§23): there is no account balance to
> debit and **no open-day requirement** — an expense can be recorded and approved
> any time. The receipt photo (§20.2) is stored as a **local file path** in Phase
> 1; cloud upload + cross-device sync of the image is deferred.

### 20.6 Stats tab

- Total by category (chart).
- Trend over time (line chart).
- Comparison to budget.
- Top recorded-by staff.

### 20.7 Empty state

"No expenses found" — unchanged.

### 20.8 Per-store expense scope (2026-06-07, user)

Expenses are tracked per store, consistent with the active-store picker (§12.1)
and per-store supplier ledgers (§21.11). Each expense carries a `store_id` — the
store it was recorded against.

- **Stamping.** A recorded expense is stamped with the **active store** (the
  §12.1 nav-drawer store picker), using the same resolution as a POS sale: the
  locked store, else the user's first selectable store. The Record Expense form
  shows a read-only **"Recording for: store name"** line so the target store is
  explicit; to record against a different store, switch the active store from the
  menu (the drawer picker is the single store control — no per-screen dropdown).
- **Viewing.** The active-store picker filters the whole Expenses screen — the
  list, Stats, and the budget bar — exactly like Home / Inventory / POS /
  Supplier Accounts:
  - A **concrete store** selected → only that store's expenses (and its budget goal).
  - **"All Stores"** (offered only to all-stores viewers — CEO / all-stores
    Manager) → the business-wide aggregate across every store; each expense row
    also shows which store recorded it.
  - A store-confined viewer (e.g. a single-store Manager) is always pinned to
    their active store; they never see another store's costs. This supersedes the
    old role-based "CEO: all stores / Manager: own store" confinement in §20.3 —
    the scope now follows the picker for everyone, with confinement enforced by
    the picker's selectable set (§12.1).
- **Budget.** The monthly budget bar/goal resolves by the **active store**: a
  concrete store shows that store's goal (falling back to the business-wide goal
  if it has none, §20.1); "All Stores" shows the business-wide goal. The CEO-only
  "Set monthly budget" action sets the goal for the active scope (a concrete
  store's goal, or the business-wide goal under "All Stores").
- Expenses recorded before this change (no `store_id`) are treated as
  **unassigned** — they appear only in the "All Stores" aggregate, not under any
  single store.

The `store_id` already exists on the `expenses` table (client schema v47 and
cloud migration 0073), so this slice only wires it to the active-store picker —
no schema or migration change.

---

## 21. Supplier Accounts

### 21.1 Layout (redesigned 2026-06-07, user)

- Header: Supplier Accounts / Manage supplier payments / notification bell.
- **Single screen — the Suppliers list (no tabs).** The old Payments tab (with its Total-Payments card, supplier filter chips, and "Add Payment" floating button) is removed.
- A **"Transaction history" link** sits at the top of the list → opens the all-suppliers **Transaction History** screen: every ledger entry (invoices, payments, voids) across all suppliers, newest first, filtered by a **period dropdown**.
- Floating **"Add Supplier"** button (replaces the old "Add Payment" FAB).

### 21.2 Suppliers list

- List of suppliers, each showing its live ledger balance (red when owed); tap to open Supplier Details. Suppliers are **business-wide** — the same list shows in every store (§21.11); only the **balance** is scoped to the active store.
- New supplier via the floating "Add Supplier" button.
- A caption shows the balance scope ("Balances for: store name" or "All Stores"), reflecting the §12.1 active-store picker (§21.11).

### 21.3 Supplier Details screen

- Bank icon, supplier name, contact + bank details.
- Balance card. Calculation: SUM(payments) − SUM(invoice totals), from the supplier ledger (§21.10), **scoped to the active store** (§21.11). Negative (shown red) = you owe the supplier; positive = the supplier owes you (a credit balance). The card notes the active-store scope.
- Period selector as a **dropdown** (alongside the "Activity" heading).
- Activity ledger: invoice entries (red / negative) and payment entries (green / positive), each with its date and a note/receipt indicator, filtered by period and by the active store. In an "All Stores" view each row also shows which store recorded it.
- Floating **"Record Activity"** button → records either an Invoice Total or a Payment (§21.4 / §21.10). (Moved off the balance card to a bottom FAB, 2026-06-07.)
- Available Empty Crates section (Bar / Beer Distributor only) — real-data wiring deferred; the current mock display is not part of this ledger pass.

### 21.4 Record Activity (Invoice Total or Payment)

The floating "Record Activity" button on Supplier Details opens a chooser: **Invoice Total** or **Record Payment**.

**Invoice Total** (goods received — a debit, shown red / negative):

- Amount.
- Date received (defaults to today).
- Note (optional).

**Record Payment** (money paid to the supplier — a credit):

- Amount.
- Payment Method: Cash, Bank Transfer, POS card, Other.
- Date (defaults to today).
- Proof of payment — **required**: attach a receipt (camera/photo or file) **OR** enter a reference / note (e.g. bank-transfer reference, cheque number, or a short written explanation when no physical receipt exists). One of the two is mandatory.

No "Link to Delivery / Shipment" field.

### 21.5 Add Supplier form

- Name (required).
- Phone.
- Address.
- Bank Account Name, Account Number, Bank.
- Notes.

### 21.6 Role access

CEO only by default. Toggleable to Manager in CEO Settings. Cashier and Stock keeper hidden.

### 21.7 Edit / Delete

- Suppliers: soft-delete only; edit by CEO only.
- Ledger entries (invoices & payments): append-only — never edited or hard-deleted. Corrections are made by **voiding** an entry (a compensating reversal), CEO only.

### 21.8 No Stats tab

Supplier Accounts does not have a Stats tab.

### 21.9 Payment-method rules

A supplier payment records its **payment method** (Cash, Bank Transfer, POS card,
Other) for reporting. *(It no longer reduces a Funds Register account balance —
Funds Register was removed 2026-06-04, §23.)*

### 21.10 Supplier ledger (semantics)

Each supplier has an append-only ledger (mirrors the customer wallet, §14.3). Every
Record Activity action appends one entry:

- **Invoice Total → debit (negative):** increases what we owe the supplier.
- **Payment → credit (positive):** reduces what we owe.

Balance = SUM(signed amounts). Negative = we owe the supplier (red); positive = the
supplier owes us (credit). Entries are never edited or hard-deleted; corrections are
made by voiding (a compensating reversal entry). Payment receipts are stored as a
**local file path** (Phase 1, like expense receipts §20.2 — the image does not
cross-sync between devices; the amount, method, date, and reference/note always sync).

### 21.11 Per-store ledger scope (2026-06-07, user)

Supplier **ledgers are tracked per store**, while supplier **records stay business-wide** (one supplier is visible in every store; you don't re-add a vendor per store). Each ledger entry carries a `store_id` — the store that recorded it.

- **Stamping.** A Record Activity entry is stamped with the **active store** (the §12.1 nav-drawer store picker), using the same resolution as a POS sale: the locked store, else the user's first selectable store. The Record Activity sheets show a read-only **"Recording for: store name"** line so the target store is explicit; to record against a different store, switch the active store from the menu (the drawer picker remains the single store control — no per-screen store dropdown).
- **Viewing.** The active-store picker filters the whole Supplier Accounts area, exactly like Home / Inventory / POS:
  - A **concrete store** selected → balances, history, and the Transaction History screen show **only that store's** entries.
  - **"All Stores"** (offered only to all-stores viewers — CEO / all-stores Manager) → the **business-wide aggregate** across every store; each transaction row also shows which store recorded it.
- **Balance** is therefore per store: `SUM(signed amounts WHERE store matches the active store)`, or the business-wide sum under "All Stores".
- **Voids** copy the original entry's `store_id`, so a reversal nets the same store's balance.
- Entries recorded before this change (no `store_id`) are treated as **unassigned** — they appear only in the "All Stores" aggregate, not under any single store.

The `store_id` is part of the append-only entry (immutable after insert) and syncs like the other columns; only the receipt image stays local (§21.10).

---

## 22. Track Shipments — REMOVED (2026-06-06, user)

Track Shipments has been **folded into Supplier Accounts** (§21) and removed as a
separate feature. Recording an **Invoice Total** on a supplier's ledger (§21.4 /
§21.10) is now the single way goods-received value is captured — there is no separate
Pending/Received shipment tracker and no separate "Mark Received" flow. This section is
kept as a tombstone so cross-references read coherently.

**What was removed:**

- The Track Shipments sidebar item and its Pending / Received tabs.
- The Add Shipment (expected value / expected date) and Mark Received modals.
- The separate invoice-photo upload on Mark Received (a payment's receipt now lives on
  the supplier-ledger payment entry, §21.4).

**What replaces it:** the supplier ledger's Invoice Total entries (§21.10). Expected /
pending-shipment forecasting is not carried forward (out of scope; revisit in a later
phase if needed).

---

## 23. Funds Register — REMOVED (2026-06-04, user)

The entire Funds Register feature has been **removed** from the app at the user's
request. This section is kept as a tombstone so the rest of the plan's
cross-references (§14, §19.7, §20.5, §21.9, §25, §26.4, §27, §30.3) read
coherently.

**What was removed:**

- The Funds Register sidebar item and its screens (Open Day, Close Day, Accounts,
  Funds History) and the Funds Register Report (§25.2).
- The per-store money accounts — Cash Till, POS machines, Bank accounts — and
  their per-account, reset-daily balances.
- The daily **Open Day / Close Day** ceremony and the expected-vs-counted cash
  reconciliation (variance flagging, mismatch notifications).
- The append-only money ledger that credited sales/wallet top-ups and debited
  expenses/refunds/supplier payments to an account.
- The four database tables (`funds_accounts`, `fund_days`, `fund_transactions`,
  `fund_day_closings`) and the `expenses.funds_account_id` column — dropped
  locally (Drift schema v36) and in the cloud (Supabase migration 0092).
- The three permissions `funds.view`, `funds.open_day`, `funds.close_day`.

**What replaces it:**

- **POS is gateless.** There is no opening-cash requirement and no day
  open/close. Sales, refunds, and expenses can happen any time.
- Money is tracked as **recorded activity**, not per-account balances. Money in
  (sales, wallet top-ups) is compared against money out (expenses, supplier
  payments, refunds) from the recorded transactions — the Orders list, Expenses,
  Supplier Accounts, the customer wallet ledger (§14.3, still the source of truth
  for registered customers), and the Daily Reconciliation Report (§25.2, minus
  its cash-audit card).
- Payment **method** (cash / transfer / card / POS / wallet) is still recorded on
  each order/expense/payment — only the receiving **account** is gone.

> Tradeoff the user accepted: removing Funds Register also removes the
> expected-vs-counted cash-drawer reconciliation (a shrinkage/theft control).
> Balancing is now done from the recorded money-in vs money-out totals rather
> than an enforced daily till count.

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

- Header: back, "Business Reports", global period filter (defaults to Today; canonical chip set, §30.11).
- Grid of report cards (2-column).

### 25.2 Reports list

- Daily Reconciliation Report — the business roll-up, **store-scoped** via the §12.1 active-store picker (a concrete store, or **All Stores** for an all-stores viewer) and **groupable by Day / Week / Month / Year** (§25.9; **Manager capped at Month**). For the selected store + bucket it shows: sales summary (items/SKUs sold, value, best staff, top item), stock audit (shortage/surplus + itemised shortages), **valued shrinkage** (shortages + damages — at **cost** for the CEO, at **selling price** for a Manager, who never sees cost/profit), outstanding customer debt, expenses, empty crates (Bar/Beer Distributor only), **and — CEO only — a cost-based Profit & Loss** (Revenue − COGS − Expenses − Damages-at-cost = Net profit) **plus a recorded "statement of account"** (goods received, supplier payments, refunds — flows, not a balanced cash ledger; §23). Draws its debt/expense/supplier figures from the existing subsystems (a summary, not a duplicate). Depends on Daily Stock Count (Ring 3). *(The Close Day cash-audit card was removed with Funds Register, 2026-06-04, §23, and is not reintroduced.)*
- Supplier Accounts Report — outstanding balances, total paid, total received per supplier.
- Profit Report — CEO only. Revenue, cost of goods, gross profit, margins.

> Removed from the Reports hub 2026-06-07 (user) — the standalone **Sales Report**,
> **Expense Tracker**, and **Customer Ledger** hub cards were dropped from the
> Business Reports screen (which was also redesigned: the global period filter moved
> from a cramped AppBar dropdown into the canonical horizontal chip set above the
> grid, §25.1 / §30.11). The underlying data is **not** gone — the sales summary /
> Sales detail is still reachable from Home (§19), Expenses keeps its own drawer
> screen (§20), and the per-customer wallet/credit history lives on each customer's
> profile (§18 wallet ledger). The §25.3 rows for these three were removed to match.
> The standalone `CustomerLedgerScreen` has no other entry point and is now dead
> code (kept, not deleted, per the build guardrails).

> Quick Sales in reports (2026-06-04, user). A Quick Sale (§12.3) is a real sale
> with no product/cost, so it **counts in the Sales Report and the Daily
> Reconciliation revenue + items sold**, but is **excluded from the Profit
> Report** (unknown cost — treated like any uncosted line). It carries no
> product, so it is omitted from the per-product "top item" / SKU breakdowns.

- Approvals — CEO + Manager. Both stock-keeper Add/Remove requests (§16.6.1) **and** cashier Quick Sale requests (§12.3.1) awaiting approval. A tappable card per request with Approve / Reject; a count badge shows the combined outstanding total. (Renamed from "Stock Approvals" 2026-06-06 when Quick Sale approvals were folded in; originally added 2026-06-04, user.)

Note: **expense** pending approvals are not on Reports — they live on the Expenses screen and notification bell (§20.4). The Approvals card above is the one exception, added 2026-06-04 on user request to surface stock-keeper adjustment approvals (§16.6.1) — and, from 2026-06-06, cashier Quick Sale approvals (§12.3.1) — in the Reports tab.

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
| Profit Report | Yes | Hidden | Hidden | Hidden |

> Daily Reconciliation lens (2026-06-07, user) — the CEO sees the cost-based P&L
> + statement of account inside the report; a Manager sees the same reconciliation
> **without** any cost / COGS / margin / profit (shrinkage is shown at selling
> price, an accountability figure). The cost wall is enforced in the data path,
> not by hiding a card.

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

### 25.9 Daily Reconciliation — store scope + period grouping (2026-06-07, user)

The Daily Reconciliation does not open straight to a single detail screen; it opens
to a list of **tappable period cards**. Two controls drive it:

- **Store scope** — the §12.1 active-store picker (`lockedStoreId`). A concrete store
  shows only that store's figures; **"All Stores"** (offered to all-stores viewers —
  CEO / all-stores Manager) shows the business-wide aggregate; a confined Manager is
  pinned to their assigned store(s). (Replaced the previous all-stores-only
  behaviour, 2026-06-07.)
- **Grouping** — **Day / Week / Month / Year**. The list shows one card per bucket at
  the chosen grouping that has data, newest first. **A Manager is capped at Month (no
  Year).** Weeks start Sunday (matches `date_period.dart` / §30.11).

**Drill-down.** Tapping a bucket opens that bucket's reconciliation detail for the
active store; a non-Day bucket also lists the next-finer buckets inside it as
sub-cards (Year → Months → Weeks → Days), bottoming out at a single **Day** detail.
Each card headlines items sold and flags a **stock-shortage mismatch**.

**Detail content** (for the bucket's span + active store): sales summary (items/SKUs
sold, value, best staff, top item); stock audit (shortage/surplus + itemised
shortages); **valued shrinkage** (shortages + damages — at **cost** for the CEO,
**selling price** for a Manager); outstanding customer debt; expenses; empty crates
(Bar/Beer Distributor only); **and — CEO only — a cost-based Profit & Loss** (Revenue
− COGS − Expenses − Damages-at-cost = Net profit) **plus a recorded statement of
account** (goods received, supplier payments, refunds — recorded flows, not a
balanced cash ledger, §23). A Manager never sees cost, COGS, margin, profit, or
goods-received (cost wall, §25.3); shrinkage shown at selling price is an
accountability figure, not the company's true (cost) loss.

Role visibility per §25.3 (Cashier & Stock keeper never see it). CSV export per
§25.6 / §25.7; empty state §25.8.

> Supersedes the previous per-calendar-day-only rule (2026-06-02): on user request
> (2026-06-07) the report now **aggregates** Day/Week/Month/Year. The Day bucket is
> still the leaf (anchored to that day's saved stock count); Week/Month/Year are
> roll-ups of the days inside them. This also **folded in** the short-lived separate
> "Business Statement / Store Reconciliation" report (former §25.10 — see tombstone).
> Quick Sales still count in revenue/items but are excluded from COGS/profit.

### 25.10 Business Statement / Store Reconciliation — MERGED into §25.9 (2026-06-07, user)

A separate period-aggregated report was briefly specced (and partly built) earlier on
2026-06-07, then **merged into the Daily Reconciliation** (§25.9) the same day at user
request: rather than a second report, the Daily Reconciliation itself became
store-scoped (via the §12.1 picker) and groupable by Day/Week/Month/Year, carrying the
CEO P&L + statement of account and the valued shrinkage. There is **no standalone
Business Statement / Store Reconciliation screen or hub card.** This tombstone is kept
so cross-references read coherently.

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

- Expense pending approval (fires to CEO when Manager submits over-limit).
- Expense approved/rejected (fires to Manager who submitted).
- Customer hit debt limit (fires to Cashier at sale time as a block).
- Customer crate balance went negative (fires to Manager/CEO).

**Stock**

- Low stock alert (fires to Stock keeper, Manager, CEO).
- Out of stock (fires to Stock keeper, Manager, CEO).
- Stock count saved → daily reconciliation report ready (fires to Manager, CEO).
- Damage recorded (fires to Manager, CEO).
- Stock keeper requested a stock change → **approval needed** (fires to the CEO and the Manager(s) of the **affected store** — info for an add, warning for a removal, with the reason). Only fires when the actor is a stock keeper. CEOs always receive it (they aren't store-assigned); Managers are narrowed to those assigned to the store where the stock moved. If no Manager is tied to that store, only the CEO is notified. The approver acts on it via the Stock Approvals card (§16.6.1 / §25.2). (Amended 2026-06-04, user: stock-keeper changes are now approval-gated — the old post-hoc "added/removed stock" notice became this approval request. The audience rule is unchanged; no all-Managers fallback.)
- Stock change approved / rejected (fires to the stock keeper who submitted; §16.6.1).
- Cashier requested a Quick Sale → **approval needed** (fires to the CEO and the Manager(s) of the **active selling store**; only fires when the actor is below Manager). The approver acts on it via the Approvals card (§12.3.1 / §25.2). (Added 2026-06-06, user — types `quick_sale_approval.requested`.)
- Quick Sale approved / rejected (fires to the cashier who submitted; §12.3.1). Approval releases the item into the cashier's cart; rejection closes their modal with a "Quick sale was rejected" message. (Added 2026-06-06, user — types `quick_sale_approval.approved` / `quick_sale_approval.rejected`.)

**Staff**

- New staff invite generated (fires to CEO). Added 2026-06-04 (user) — distinct
  from "invite accepted" below: the CEO is alerted when a **Manager** creates an
  invite code, not only when it is later redeemed.
- New staff invite accepted (fires to inviter + CEO).
- Staff suspended/reactivated (fires to CEO).
- Role changed (fires to CEO + affected staff).
- Staff updated their profile (fires to CEO + Manager). Added 2026-06-04 (user) —
  when a staff member **below CEO** edits their own onboarding info (name / avatar)
  from the Staff Settings page (§10.5), every active CEO and Manager is notified
  (the editor is never self-notified). A CEO editing their own profile does not
  fire it. PIN changes are local-only and do not notify.
- Staff hit 5 wrong PIN attempts → forced Forgot PIN (fires to CEO).

> Actor is never self-notified (2026-06-04, user). The CEO-facing staff events
> above fire only when **someone other than the CEO** performed the action (i.e.
> a Manager) — the CEO is not notified of their own invite/suspend/role-change.
> The "affected staff" recipient on a role change is always notified (they can't
> change their own role, so they're never the actor).

**Sales / Orders**

- Sale cancelled (fires to CEO + Manager).
- Refund issued (fires to CEO + Manager).
- Quick Sale used (fires to CEO + Manager for audit, since it bypasses inventory). Implemented 2026-06-04 — notification type `quick_sale_used`, warning severity, fired on checkout when the order contains a Quick Sale line (§12.3).
- Pending order awaiting confirmation > 24h (fires to Manager, CEO).

**Suppliers**

- Supplier payment recorded (fires to Manager, CEO — a cash outflow). *(The former pending-shipment-overdue / new-shipment-received triggers were dropped with Track Shipments, §22, 2026-06-06.)*

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
>
> Staff Settings (2026-06-04, user). For roles **below CEO**, the same name/avatar
> edit (plus Change PIN and the Display mode) also lives on the dedicated Staff
> Settings page (§10.5), reached from the new "Settings" sidebar item. When a
> staff member edits their profile, every CEO + Manager is notified (§26.4).

### 27.2 Sidebar items (visually grouped, no text headings)

- Home
- Point of Sale
- Orders
- Inventory

*Visual group break.*

- Expenses
- Supplier Accounts

*Visual group break.*

- Customers
- Staff Management

*Visual group break.*

- Stores (shows with one store from day one for CEO)

*Visual group break.*

- Reports
- Activity Logs
- CEO Settings
- Settings (staff self-service — shown to roles below CEO only; §10.5)

### 27.3 Visibility by role

| Item | CEO | Manager | Cashier | Stock keeper |
|------|-----|---------|---------|--------------|
| Home | Yes | Yes | Yes | Yes |
| Point of Sale | Yes | Yes | Yes | Hidden |
| Orders | Yes | Yes | Items only | Items only |
| Inventory | Yes | Yes | Yes (view only) | Yes |
| Expenses | Yes | Yes | Hidden | Hidden |
| Supplier Accounts | Yes | If toggled | Hidden | Hidden |
| Customers | Yes | Yes | Yes | Hidden |
| Staff Management | Yes | Limited | Hidden | Hidden |
| Stores | Yes | Hidden | Hidden | Hidden |
| Reports | Yes | Yes | Hidden | Hidden |
| Activity Logs | Yes | If toggled | Hidden | Hidden |
| CEO Settings | Yes | Hidden | Hidden | Hidden |
| Settings (staff self-service, §10.5) | Hidden | Yes | Yes | Yes |

### 27.4 Bottom nav

- Home, Stock (links to Inventory — same screen, consistent name), POS, Orders, Cart.
- Cart is in bottom nav only — removed from sidebar (it was duplicated).

### 27.5 Removed sidebar items

- Cart (now bottom nav only).
- Warehouse (renamed to Stores).
- Cash Register (removed; the Funds Register that replaced it was also removed 2026-06-04, §23).
- Funds Register (removed 2026-06-04, §23).
- Deliveries (deferred to Phase 3).

---

## 28. Phase 2 (Deferred Features)

These are flagged for the second release. The architecture supports them — only the UI is held back for now.

- Multi-store UI: store picker on login (if staff assigned to multiple stores), stock transfer screens, per-store filters in reports, ability for CEO to add/remove stores. *(Partly shipped: stores list/management screen + `stores.manage`; receipt store-address; **staff multi-store assignment** — the CEO add/remove of a staff member's `user_stores` set from the staff profile, `staff.assign_stores`, §9.5, 2026-06-05; **multi-store active-store selection** — a single store picker in the navigation drawer (above "Home") sets the one app-wide active store driving Home/Inventory/POS/Customers/Activity Log, confined to the user's assigned stores, §12.1, 2026-06-05 (moved from a POS-header icon to the drawer 2026-06-06). **Shipped 2026-06-06: stock transfer UI** — send → receive confirm workflow, `stores.manage` (create/cancel, CEO) + `stores.receive_transfer` (confirm, CEO default / grantable to Manager/Stock keeper); single-product per transfer; in-transit stock un-sellable; cancel restores source; per-store empty-crate tracking (`store_crate_balances`, §16.8.1). Still deferred: per-store report filters.)*
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
- Supplier shipment forecasting (the former Track Shipments pending/received tracker, §22, removed 2026-06-06) — re-introduce expected-shipment tracking and auto-linking stock additions to a supplier's recent invoices if a later phase needs it.
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

### 30.3 Funds Register multi-account model — REMOVED (2026-06-04, user)

The per-store, reset-daily account model (Cash Till, POS machines, Bank accounts)
was removed with the Funds Register feature (§23). Money is now tracked as
recorded activity (sales / expenses / supplier payments / refunds), not per-account
balances.

### 30.4 Empty crates flow

Only visible and active for Bar and Beer distributor business types. Hidden for all others.

### 30.5 Hide-don't-block

UI elements a user doesn't have permission to use should not appear at all. Don't show greyed-out menus or disabled buttons unless visually intentional (e.g., suspended staff in the Staff Management list).

### 30.6 Smart defaults

Currency auto-fills based on country (editable in Settings). Period filters default to **Today** on most screens and **This Month** on the Expenses / Supplier-Accounts totals (the canonical chip set is in §30.11). Country defaults to Nigeria.

### 30.7 Loading animations

Rotating loading spinners replaced everywhere with subtle fade-in transitions. Sync progress bars stay.

### 30.8 IDs

Internal UUIDs are never shown to users. Short, human-readable codes are used instead (e.g., ORD-000001, INV-K7M2QX, REC-0912).

#### 30.8.1 Order numbers — collision-proof across offline devices (2026-06-07, user)

> **Why this exists.** The app is offline-first and runs on multiple tills per
> business. The original order number was a *per-device running count*
> (`ORD-` + count+1). Two tills that are both offline each hand the **same**
> next number to **different** sales; when they later sync, the two orders share
> `(business_id, order_number)` with different ids and trip the
> `UNIQUE(business_id, order_number)` constraint. That used to crash a live
> sale (`SqliteException 2067`). See BUILD_LOG Session 122.

The order number is now **`ORD-NNNNNN-XXXXXX`**:

- **`NNNNNN`** — the per-device running count, zero-padded to 6 digits. This is
  the familiar sequential part a cashier reads aloud ("order one-two-three").
  It stays monotonic on a given device, so that device never repeats it.
- **`XXXXXX`** — a short, **stable per-device tag**: a deterministic Crockford
  base32 code derived once from the device's opaque, persisted device id (the
  same id used for single-active-device sessions). Same device → always the same
  tag; different devices → different tag. No server round-trip, so it works
  fully offline.

Because the tag differs per device, two offline tills can no longer mint the
same full code even when their counts coincide. The `UNIQUE(business_id,
order_number)` constraint and the sync restore's graceful **skip-the-duplicate**
behaviour (BUILD_LOG Session 122) remain as the backstop for the astronomically
unlikely tag collision — a clash degrades quietly, it never crashes a sale.

**Backward compatibility:** orders created before this change keep their
suffix-less `ORD-NNNNNN`. A legacy `ORD-000123` and a new `ORD-000123-XXXXXX`
are different strings, so they never collide. No history is rewritten.

**Legacy-collision self-heal (2026-06-07, user).** The tag fix prevents *new*
collisions, but devices that recorded offline sales **before** it shipped can
still hold a legacy `ORD-NNNNNN` that already exists in the cloud under a
different id (another till's same-count sale). That order is stuck both ways:
its upload fails with the `(business_id, order_number)` duplicate-key error, and
because the local copy still occupies that number, the cloud's colliding order
can never restore on this device — so every child of the cloud order
(order_items, stock_transactions, wallet_transactions, crate_ledger,
payment_transactions, order_crate_lines) is FK-orphaned on each pull and the
sync loops forever (it is **not** a slow-connection problem; a faster link can't
fix it). The self-heal renumbers the **local** order by appending **this
device's** tag — `ORD-NNNNNN` → `ORD-NNNNNN-XXXXXX` (the same `XXXXXX` device tag
above, derived from the device's own id) and re-enqueues it. It fires from
**both** ends so a stuck device recovers regardless of which side is blocked:
(1) **on pull** — when the cloud's authoritative order can't restore because a
local order holds its number, the restore renumbers the **local blocker** and
retries the insert in the same pull, so the cloud order *and* its children land
at once (orders restore before their children, so the whole orphan set clears in
one sync); (2) **on push** — when *this device's* order fails to upload with the
duplicate-number error, its local copy is renumbered and re-enqueued so it
uploads cleanly. Either way the number frees up and both tills' sales survive
(they were genuinely different sales that happened to share a count). Renumber,
never delete. The only visible change is the healed order's number gains its
device-tag suffix, like every post-fix order; the receipt's original base number
is preserved inside the new code (`ORD-000050` → `ORD-000050-XXXXXX`).

### 30.9 Soft deletes

Customers, suppliers, payments, expenses are all soft-deleted to preserve audit trails. Hard delete is not available anywhere by design.

### 30.10 Confirmation prompts

Destructive or significant actions confirm before proceeding (suspend staff, change role, revoke invite, delete supplier, etc.). Non-destructive removals (e.g., remove cart item) use undo snackbars for 5 seconds instead of upfront confirmation.

### 30.11 Date-range filter chips (canonical)

> Added 2026-06-01 (user). Reversed to calendar periods 2026-06-04 (user).
> Every browse/report **period filter chip** uses one shared set so the same
> chip means the same thing on every screen:
>
> - **Today** — since local midnight today
> - **This Week** — since local midnight of the most recent **Sunday**
> - **This Month** — since the 1st of the current month
> - **This Year** — since Jan 1 of the current year
> - **To Date** — unbounded (everything up to now)
>
> These are **calendar** periods anchored to the start of the current day /
> week / month / year (not rolling spans measured back from now). Because they
> are calendar-anchored they are computed from the **local** date parts of now
> (local-zone dependent). One helper computes them
> (`lib/core/utils/date_period.dart`); screens must not roll their own date math.
> Default selection: **Today** on most screens; **This Month** on the Expenses
> and Supplier-Accounts totals (§30.6).
>
> **Role cap:** roles **below Manager** (Cashier, Stock keeper) may only choose
> **Today / This Week / This Month** — This Year / To Date are hidden for them.
> Manager and CEO get all five. Enforced via `datePeriodLabelsForRole(...)` on
> every selector a non-Manager can reach (Home, Orders, Customer wallet, and
> the Expenses / Supplier-Accounts totals); the Reports hub and its sub-screens
> are already CEO/Manager-only (§11.3) so they keep the full set.
>
> The label parser still understands every legacy/rolling label ("Day", "Last
> 24 hours", "30 Days", "All Time", etc.) so any in-flight value resolves.
>
> **Scope / exceptions:** This governs Home, Reports, Orders, Expenses, Supplier
> Accounts (Payments + Supplier detail), and the Customer wallet. It does **not**
> change the calendar-day-bound machinery — the daily reconciliation (§25.9) stays
> per-calendar-day. *(Funds Register Open/Close Day, formerly also per-calendar-day,
> was removed 2026-06-04, §23.)* **Inventory History (§16.8)** keeps its own labels
> ("Today / 7 Days / 30 Days / All"). The Phase-3 Deliveries screen is untouched.

---

## 32. Subscriptions and Access Gating

*(Added 2026-06-06.)*

Reebaplus is a paid app. Each business pays a monthly fee after a free trial. The
business owner does **not** pay or manage the subscription inside the POS app — the
**operator** (us) manages every business's subscription from a separate **web admin
console** ("Admin Hub"). The POS app only **reads** the subscription state and
**surfaces it** (a status screen and name badges). There is no in-app payment screen.

> **Update 2026-06-06 — no in-app lockout.** The blocking paywall/lockout overlay
> (and its "Thank you for subscribing" celebration) was **removed**. An expired
> trial or Inactive status **no longer blocks the app**; the subscription state is
> now purely informational — surfaced via the Settings → Subscription screen and the
> PRO / FREE TRIAL name badges (§32.1). The console remains the source of truth and
> the app still cannot write subscription state. The lockout wording below is kept
> for history.

**Plans and price**

- **Local** — ₦5,000 / $5 per month (Nigerian businesses).
- **International** — $10 per month (businesses outside Nigeria).
- The plan is chosen by the operator in the console. It is shown on the
  Settings → Subscription screen but does **not** itself change what the app does.

**Status (set by the console)**

- **Trial** — a free **30-day** trial. Every new business starts here automatically;
  the trial runs 30 days from sign-up. While the trial is live, the app works fully.
- **Active** — paid and current. The app works fully.
- **Inactive** — not paid (trial ended without payment, or the operator switched it
  off). ~~The app is **fully locked**.~~ The app is **no longer locked** (lockout
  removed 2026-06-06); the status simply shows as Inactive / Trial ended in §32.1.

**What the app does with it**

- The subscription state lives on the business record in the cloud and is
  **read-only inside the app** — only the console can change it. A cashier or even
  the CEO cannot turn their own subscription back on from the app.
- It is **informational only** (since 2026-06-06): the state is surfaced through the
  **Settings → Subscription** screen and the **PRO / FREE TRIAL** name badges
  (§32.1). The app is **never blocked** by it — every role keeps full access
  regardless of a trial-expired / Inactive status.
- Status still updates **live**: console changes arrive via the `businesses`
  realtime channel and the regular pull, so the badge and status screen reflect a
  switch to Active / Inactive within seconds — but nothing is locked or unlocked.
- **Grace / unknown:** if the app does not yet know a business's subscription state
  (brand-new install before its first sync, or an unknown value), no badge is shown.
- **Offline:** the trial countdown shown in the badge / status screen uses the
  device clock, so a FREE TRIAL badge can lapse with no internet; it is display-only.

> **Removed 2026-06-06 (former behaviour, kept for history):** ~~when a trial
> expired or status was Inactive, a blocking full-screen overlay (Subscribe / Sign
> out) covered Home for every role, blocked all interaction and the back button,
> self-healed by re-pulling the business row on mount / resume / every 15s, and on
> the locked→Active transition swapped to an animated "Thank you for subscribing"
> celebration before auto-dismissing.~~

**Rollout:** when this ships, every business that already exists is given a fresh
30-day trial so no current user is ever locked out on launch day.

### 32.1 In-app subscription surface *(added 2026-06-06)*

- **CEO Settings → Subscription** screen (CEO-only, under the existing
  `settings.manage` gate). Read-only: it shows the plan (Local ₦5,000/$5,
  International $10), the status (Free Trial / Active / Trial ended / Inactive),
  and the trial-countdown or renewal date. It does **not** change subscription
  state — the console remains the source of truth (the DB trigger blocks app
  writes). It carries a "Subscribe / Renew" button.
- **Name tag:** next to the current user's name — **PRO** when the business is
  paid (Active), **FREE TRIAL** during the 30-day trial — shown in the side
  drawer header and the user's Profile header. Nothing shown when trial-expired,
  inactive, or unknown.

### 32.2 In-app payment *(planned next phase — not yet built)*

In-app renewal/payment will use **Paystack** (NGN ₦5,000 / USD $5 Local, USD $10
International). Because the app is blocked from writing subscription state, the
flow is: app takes payment → a **Supabase Edge Function verifies the transaction
with Paystack's API** and sets `subscription_status='active'` +
`current_period_end` via the **service_role** key → the realtime channel unlocks
the app. When this lands, the "no in-app payment" note in §32 above is replaced
by this flow. Until then, the "Subscribe / Renew" button shows a "renew from the
console" placeholder.

---

## 33. Reliability and Crash Handling

*(Added 2026-06-06, user-authorized.)*

The till is a shared device a cashier uses all day, often mid-sale, often offline.
A crash that drops them to a blank or red Flutter error screen — especially during
a sale — is unacceptable. This section adds a safety net so an unexpected error is
**caught, recorded, and shown as a friendly message**, and the till keeps working.

This is a cross-cutting reliability layer, not a new user feature: there is **no new
sidebar item, tab, or button** for it. It works silently in the background.

### 33.1 What this is NOT

- **No third-party crash service.** We deliberately do **not** use Sentry,
  Crashlytics, or any external reporting cloud. Crash data stays inside the
  business's own infrastructure (see §33.3). No new network dependency is added.
- **No blocking.** A caught error never stops the till. Offline-first already
  means a failed cloud write is saved locally and retried by the sync queue
  (§2.6) — §33 does not change that and does not block a sale because a write or a
  sync failed.
- **No detailed personal-data capture.** Crash records store the error type, a
  short message, the stack trace, the screen/context, the active user's role, and
  the app version — **not** customer names, phone numbers, or money amounts. We do
  not deliberately log user-entered field values.

### 33.2 Global crash safety net

- A **global error handler** catches every otherwise-uncaught error — Flutter
  framework errors (`FlutterError.onError`), uncaught async/platform errors
  (`PlatformDispatcher.onError`), and zone errors (the app runs inside a guarded
  zone). Each caught error is recorded (§33.3) and, in debug builds, still printed
  to the console.
- A **friendly fallback widget** replaces Flutter's default red/grey error box
  (`ErrorWidget.builder`), so a build error in one widget shows a small, calm
  "Something went wrong here" card instead of a red screen — matching the tone of
  the existing schema-error fallback screen.
- These sit alongside the existing boot-time fallbacks (the schema self-heal
  → schema-error screen, and the session-expired → re-verify screen in §7), which
  are unchanged.

### 33.3 The crash log (a new synced table)

Caught errors are written to a new **`error_logs`** table. It is a normal
**synced tenant table** and follows the §2.4 / sync contract in full: business-
scoped, append-only, registered for cloud sync, written only through a DAO that
enqueues. Because it syncs to the **business's own cloud (Supabase)**, the CEO/
operator can review crashes across every till in one place — the practical benefit
of a crash service, but in our own data store, RLS-scoped to the business.

- **Stored per row:** error type, short message, stack trace, screen/context tag,
  the active user's id + role (no name), whether it was fatal (uncaught) vs caught
  by a boundary, app version, platform, and timestamp.
- **Append-only.** Rows are never edited or user-deleted. (A future retention
  sweep may prune old rows — deferred.)
- **Pre-login crashes stay local-only.** A crash before a business is bound has no
  tenant to scope to, so that row is kept on the device and not pushed (it cannot
  be RLS-scoped cloud-side). This is a deliberate, documented exception in the
  crash-logging DAO.
- **Writing a crash record never crashes.** The crash logger is fully defensive: if
  recording the error itself fails (database down, no session), it is swallowed —
  the safety net can never become the thing that breaks.
- **Viewing.** Phase 1 has **no in-app crash-log screen** — crashes are reviewed in
  the Supabase console. An in-app CEO-only viewer is a possible later addition and
  would be gated like any other screen.

### 33.4 Protection by role (priority order)

The safety net is applied with a reusable guarded-execution helper and per-screen
error states, prioritized by how costly a crash is:

1. **Cashier sale flow first** — POS, Cart, Checkout, Receipt. A failure here shows
   a clear, recoverable message ("Couldn't complete that — try again"), never a
   blank screen, and never silently loses the cart.
2. **Stock keeper** — shipment receiving and inventory/stock writes.
3. **Manager / CEO** — reports and the sync/diagnostics surfaces.

Guards wrap **screen and action logic**, not the DAO enqueue path: the sync
invariants (CLAUDE.md §5) and their enqueue guard must still fail loudly, so the
crash net deliberately does not swallow sync-registration errors.

---

## 31. Document Status

This document is the final, locked planning specification for Phase 1 of Reebaplus POS. Every screen and flow has been planned. The agent should treat this as the source of truth and refer to it during build.

Phase 2 and Phase 3 features are listed but not in scope for the current build. They are listed so the data model and architecture decisions support them without rework.

*End of document.*
