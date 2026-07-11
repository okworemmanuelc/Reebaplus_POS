# Reebaplus POS

## Overview

Reebaplus POS is an offline-first, mobile point-of-sale app for small and medium retail businesses — built in this first phase specifically for beverage distributors, with support for the remaining six business types (Restaurant, Supermarket, Bar, Pharmacy, Building Materials, and Boutique) coming in later phases — that run on a single shared till handled by several staff across a shift. One CEO owns a business and adds staff in four data-driven roles (CEO, Manager, Cashier, Stock keeper); the app runs offline-first with live cloud sync, so a sale, price edit, or stock change made on one device appears on the others in the same business without a manual refresh. It covers the full retail loop — selling, cart and checkout with cash/transfer/credit payment, inventory and stock counts, customer credit balances and debt, orders, expenses with approvals, supplier ledgers, activity logs, and role-aware reports — with every action gated by permissions stored in the database rather than in code, so a CEO tunes what each role can do with a toggle. It solves the problem of running an entire retail operation — money, stock, staff, and customer credit — on one shared device that often works offline.

## Goals

1. A signed-in cashier can complete a full sale (add products, apply allowed discounts, take payment, print or share a receipt) on a shared till while fully offline, and the order syncs to the cloud once a connection returns.
2. A change made on one device — price edit, new sale, stock adjustment, business colour — appears on every other device in the same business live, without a manual refresh (when realtime sync is healthy).
3. During registration, the business type picker shows all seven types (Restaurant, Supermarket, Bar, Beverage distributor, Pharmacy, Building Materials, and Boutique) but only Beverage distributor is selectable; the other six are visible and greyed out with a "coming soon" indicator, and the full interface for Beverage distributor — including empty-crate tracking — is built and functional. Empty-crate tracking is an onboarding opt-in for crate-eligible types (default on): the type picker shows a "Track empty crates" switch when a crate-eligible type is selected, and the choice is editable later in Settings → Business Info. When opted out, every empty-crate surface is hidden app-wide.
4. A CEO can change what any role is allowed to do — a Manager's maximum discount, whether a Cashier sees wallet totals — by toggling a permission in Settings, with no code release and without affecting any other business on the platform.
5. Every money movement for a registered customer and a registered supplier is recorded in their ledger, so the credit balance is the single source of truth for what each customer or supplier owes or is owed.
6. Multiple staff share one till: each is identified explicitly via the "Who's working?" picker and a 6-digit PIN, and the device auto-locks after inactivity, never assuming the last user.
7. An uncaught error never drops a cashier to a blank or red error screen mid-sale; it is caught, recorded to a synced crash log, shown as a calm message, and the till keeps working.

## Core User Flow

1. On a fresh install, the user opens the app and lands on the Welcome screen.
2. The CEO taps "Create a new business" and completes sign-up step by step: business name, business type (all seven types are shown but only Beverage distributor is selectable — the other six are greyed out as coming soon), first store details (name, phone number, street address, local government / district, state / region, country; currency auto-fills from country), full name, email, 6-digit email OTP, create 6-digit PIN, confirm PIN.
3. On completion, the app auto-creates the four default roles with default permissions, creates the first store, assigns the CEO to it, and lands the CEO on Point of Sale.
4. The CEO opens Staff Management, taps "Invite new staff", picks a role and store, and generates an 8-character invite code. The code is emailed to the invitee automatically (branded as Reebaplus, sent server-side once the invite syncs to the cloud), and the CEO can still copy or share it via SMS / WhatsApp.
5. A staff member installs the app, taps "Join with invite code", and enters the code, then their email (must match the invite), email OTP, their first name and last name, phone number, street address, local government / district, state / region, country, create PIN, and confirm PIN; they are signed in with the role and store carried from the invite.
6. The CEO opens Inventory and adds products (name, per-tier prices, stock quantity, store) so the POS grid has stock to sell.
7. On the shared till, a cold start shows the "Who's working?" picker; the staff member taps their card and enters their PIN, which unlocks only that chosen identity.
8. They open Point of Sale, select a price tier (Retailer or Wholesaler) and category, and tap products to add them to the cart; out-of-stock products appear greyed out and are not tappable.
9. In the Cart they review line items, adjust quantities, apply any discount allowed by their role (capped if they exceed the cap), optionally attach a registered customer, then tap "Proceed to Checkout".
10. At Checkout they pick a payment method — Cash/Transfer (enter amount paid), Pay with Credit, or Register as Credit Sale — and tap "Confirm Payment"; a sale that would push a customer past their debt limit is blocked.
11. The order is recorded with status Pending, the registered customer's credit balance is updated (debit the order total, credit the amount paid), and the Receipt opens with Print and Share options.
12. The cashier taps "Done — Back to POS"; the cart clears and the till is ready for the next sale.
13. The order moves to the Orders > Completed tab once confirmed (pickup or rider assigned), and Activity Logs, Reports, and the customer's credit history all reflect the sale.
14. After inactivity, the till silently auto-locks back to the "Who's working?" picker for the next staff member.

## Features

### Authentication & Onboarding

- Welcome screen, CEO sign-up (9 steps), staff sign-up via invite code (7 steps), login with email + OTP + PIN, and Forgot PIN via email OTP. All transactional email — OTP, login, Forgot PIN, and the staff invite code — is sent from the Reebaplus domain (auth email via Supabase Custom SMTP; the invite code via the `send-invite-email` Edge Function), with the invite code also copyable/shareable on-device.
- PINs are device-local unlock factors that are never sent to the cloud; email + OTP is the portable identity and the recovery path. A new device re-establishes the PIN locally after OTP.
- "Who's working?" picker for shared tills with explicit identity selection; auto-lock and Switch User keep the current PIN, while Log Out clears the leaving user's PIN and device pointer.

### Roles & Permissions

- Four default roles (CEO, Manager, Cashier, Stock keeper) seeded per business at creation.
- Permissions live in database tables; the CEO tunes each role with toggles in CEO Settings, with no code release.
- Per-staff permission overrides on top of the role default, plus hide-don't-block (items a user lacks permission for do not render at all).

### Point of Sale & Cart

- Role-gated POS grid scoped to the active store, with price tiers (Retailer/Wholesaler), category filter, and product search.
- Quick Sale for items not in inventory: CEO/Manager add directly, while Cashier (and roles below Manager) submit an async approval request.
- Per-line discounts capped by role, per-cashier saved and recalled carts, and empty-crate deposit handling for Beverage distributor.

### Checkout & Receipts

- Payment methods: Cash/Transfer (enter amount paid), Pay with Credit, and Register as Credit Sale, with the method recorded on the order.
- Debt-limit gate that blocks any sale leaving a customer over their limit (or with no limit set), and thermal-printer receipts that can be printed or shared.

### Inventory & Stock

- Products with per-tier prices, stock, and expiry dates; tabs for Products, Suppliers, Empty Crates (Beverage distributor only), and History.
- Low-stock, out-of-stock, and near-expiry stat cards; stock-keeper adjustment approvals; and Daily Stock Count.
- A POS-style Receive Stock flow (gated on `products.add`): a tap-to-add grid, a receive cart with an Invoice Total, and an invoice checkout that atomically posts the supplier invoice, increments stock, records empty crates returned to the supplier, and logs the receipt.

### Customers & Wallets

- Customer profiles with price tier, address, local government / district, state / region, country, and phone, organised into Credits, Orders, and Crates tabs for businesses that track empty crates.
- Credit balance ledger as the source of truth for registered customers (debit the total, credit the amount paid on every sale), plus debt limits, Add Credit, and cash/crate refunds.

### Orders, Expenses & Suppliers

- Orders in Pending / Completed / Cancelled tabs, with refunds restricted to Manager and CEO, and an Approve All floating action button for Manager and CEO on the Pending Orders screen.
- Expenses with a pending-approval flow, searchable categories, and per-store monthly budgets.
- Supplier Accounts with a real per-supplier ledger of invoice totals and payments.

### Reporting & Oversight

- Role-aware reports: Daily Reconciliation, Supplier Accounts, Profit (CEO only), and an Approvals queue for stock-keeper adjustments and cashier Quick Sales.
- Activity Logs of every significant action and an in-app notification system.

### Platform & Reliability

- Offline-first operation with live cross-device cloud sync.
- Multi-store data model with a single app-wide active-store picker in this phase, staff multi-store assignment, and a store-scoped, requester-initiated stock-transfer workflow: a store raises a request from inside its own details, the holder store accepts (and may adjust the quantity) and dispatches, and the requesting store confirms receipt — all inside a store's details. A Manager sees the stores menu but gets the full view (and transfer actions) only for stores they're assigned to; other stores are read-only for raising requests. Gated by `stores.request_transfer` / `stores.dispatch_transfer` / `stores.receive_transfer` (CEO + Manager by default); `stores.manage` (CEO-only) covers store add/edit/delete. Empty-crate counts entered on Receive Stock are per-manufacturer (one figure per manufacturer, not per SKU); moving empty crates alongside a transfer is fully supported in the UI (capped at the holder store's available empties), updating the local crate ledger and enqueuing the `domain:pos_transfer_crates` sync transaction. The store details hub also displays a read-only transfer history showing completed received/cancelled transfers.
- Read-only subscription state (Trial / Active / Inactive) surfaced via a Settings screen and PRO / FREE TRIAL name badges, managed by the operator outside the app.
- A global crash safety net that catches uncaught errors, shows a calm fallback, and writes to a synced crash-log table without ever blocking the till.
- Data is sent in small chunks of 25 KB to reduce latency and accommodate regions with poor internet connectivity, with battery optimisation applied throughout.

## Scope

### In Scope

- All authentication and onboarding flows: Welcome, CEO sign-up, staff sign-up via invite code, login, Forgot PIN, and the "Who's working?" picker.
- Data-driven roles and permissions with CEO toggles and per-staff overrides.
- Point of Sale, Cart, Checkout, and Receipt, including cash/transfer/credit payment, role discount caps, and thermal-printer receipts.
- One-shot barcode scanning at the POS (scan a product's barcode to add it to the cart), an optional per-product barcode, and a camera-based scanner; continuous/rapid scanning is a later upgrade (ADR 0017).
- Inventory and Product Details and Daily Stock Count.
- Customers with credit balances, debt limits, Add Credit, and cash/crate refunds.
- Orders (Pending / Completed / Cancelled) with Manager/CEO refunds.
- Expenses with a pending-approval flow, categories, and per-store monthly budgets.
- Supplier Accounts with a per-supplier invoice/payment ledger.
- Activity Logs, role-aware Reports (Daily Reconciliation, Supplier Accounts, Profit, Approvals), and Notifications.
- Offline-first cloud sync, multi-store data structures with one active-store picker, staff multi-store assignment, and the stock-transfer UI.
- A read-only in-app subscription surface and a global crash safety net writing to a synced crash log.
- The CEO Danger Zone: permanent, atomic deletion of the business and account behind a two-gate confirmation; this also deletes the accounts of all staff and wipes the data from all their devices — the ultimate kill switch for a business.
- One email, one business: each email address is tied to exactly one business; a user who needs to belong to a second business signs up with a different email.

### Out of Scope

- Multi-business support: each email is tied to exactly one business; the multi-business picker UI and the multi-membership data model are not built.
- Six of the seven business types are disabled at registration in this phase: Restaurant, Supermarket, Bar, Pharmacy, Building Materials, and Boutique appear in the business type picker as greyed-out "coming soon" options and cannot be selected; their type-specific interfaces are not built.
- Continuous / rapid barcode scanning (camera stays open, scanning many items in a row) — deferred; the first cut is one-shot (scan one item, it adds to the cart, camera closes). Deeper per-industry IMEI / serial capture also remains deferred (ADR 0015). Basic one-shot barcode scanning is now **in scope** (ADR 0017) — see In Scope.
- Per-store report filters and full multi-store reporting.
- CEO-created custom roles beyond the four defaults, custom permission groups, and per-card Home visibility toggles per role.
- Custom notification settings and tunable limits beyond discount, expense, and the price-change toggle.
- In-app subscription payment (Paystack); subscriptions are read-only in the app and managed in the external Admin Hub console, and there is no in-app lockout.
- Deliveries and rider management screens with status tracking; a rider's name only appears on the receipt when assigned.
- Supplier shipment forecasting, PDF report export, and Activity Logs export.
- Funds Register (per-account balances, Open/Close Day, the POS opening-cash gate) — removed entirely; money is tracked as recorded sales, expenses, refunds, and supplier payments.
- Track Shipments as a standalone feature — folded into Supplier Accounts.
- An in-app crash-log viewer; crashes are reviewed in the Supabase console.
- Cloud-stored PINs; PINs remain device-local by design.

## Success Criteria

1. A CEO can create a business from a fresh install, reach Point of Sale, and see themselves as the first staff card in Staff Management.
2. A CEO can generate an invite code, and a new staff member can join with it and sign in with the role and store carried from the invite.
3. A staff member can select themselves in the "Who's working?" picker and unlock with their PIN, and five wrong PIN attempts force the Forgot-PIN (email OTP) flow.
4. A cashier can add in-stock products to the cart, apply a discount up to their role cap (and be capped if they exceed it), and complete a Cash/Transfer sale that produces a printable and shareable receipt — fully offline.
5. A registered-customer sale posts two ledger rows (debit the total, credit the amount paid) so the credit balance net equals paid minus total, and a credit sale that would breach the debt limit is blocked.
6. A price edit, new sale, or stock adjustment made on one device appears on another device in the same business without a manual refresh (when realtime sync is healthy).
7. A stock-keeper stock adjustment and a cashier Quick Sale each create a pending request that a CEO or Manager can Approve or Reject from the Reports → Approvals card.
8. An out-of-stock product appears in the POS grid greyed out and is not tappable, and a Beverage distributor business that opted into crate tracking at onboarding (the default for crate-eligible types) shows the Empty Crates tab and empty-crate deposit flow that no other business type exposes in this phase; a crate-eligible business that opted out shows none of these surfaces.
9. An uncaught error during the sale flow shows a calm "try again" message instead of a red or blank screen, is written to the synced crash log, and does not silently lose the cart.
10. A CEO can permanently delete the business and account through the two-gate Danger Zone (type the business name plus PIN), wiping local data, deleting all staff accounts, and logging out every device.
11. A supplier payment or invoice recorded in Supplier Accounts is reflected in that supplier's running ledger balance, confirming the supplier ledger is the source of truth for what the business owes or has paid each supplier.
12. Attempting to create a second business with an email already registered returns an error, confirming the one-email-one-business constraint is enforced at sign-up.
13. On the business type selection screen, Restaurant, Supermarket, Bar, Pharmacy, Building Materials, and Boutique are all visible but greyed out and not tappable; only Beverage distributor can be selected to proceed.
