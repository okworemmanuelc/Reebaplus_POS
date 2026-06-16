# Reebaplus POS: Phase 1 Pivot Build Plan

This document outlines the sequential build order for the remaining Phase 1 Pivot features of the Reebaplus POS application, structured into Rings 0–3 and the CEO Settings Danger Zone. This build order follows the precepts of spec-driven development as defined in the [README.md](file:///Users/solomonizu/Six-File+Context+Methodology/README.md).

---

## 🚦 Build Order Principles

Before executing any unit, verify the following:
1. **Dependencies First**: If Unit B requires Unit A, Unit A must be fully implemented and verified first.
2. **Security Before Functionality**: Access control and database triggers must be set up before building the UI screens they protect.
3. **Backend Before Frontend**: Database models and API routes are built first, followed by the UI screens.
4. **UI Shells Before Real Data**: Screens are built with placeholder/mock data to verify visual flow before wiring them to live data providers.

---

## 📦 Numbered List of Build Units

### Ring 0: Foundation Invariants
*Core database migrations, shared utilities, and critical pricing logic.*

#### Unit 01: Wholesaler-tier Price Fix at POS & Cart
* **What it builds**: Wires the price tier selection at the POS and Cart (§12.2). Correctly charges the Wholesaler price tier if selected manually or automatically by customer selection. Resets to default Retailer when the customer is removed from the cart.
* **System Boundary**: POS & Cart UI / State Management
* **Dependencies**: Existing POS and Cart workflows

#### Unit 02: Core Logging and Notifications Database Foundation
* **What it builds**: Supabase schema migrations for the generic activity log schema (`activity_logs` table), the `notifications.severity` column, and the database/client helpers `logActivity()` and `fireNotification()` (§24, §26.4).
* **System Boundary**: Supabase Database Migrations & Shared Core Helpers
* **Dependencies**: None

#### Unit 03: Money-Math Consistency Regression Net
* **What it builds**: Core unit tests and schema-level validation logic to guarantee that money calculations (stored as kobo integers in the database) remain consistent across POS, Cart, Wallet, and Expenses transactions.
* **System Boundary**: Testing & Shared Core Helpers
* **Dependencies**: None

---

### Ring 1: Close the Money Loop
*Primary transaction reversals, wallet services, expense tracking, and supplier ledgers.*

#### Unit 04: Order Reversal & Refund (Pending Orders Tab)
* **What it builds**: Replaces the "Cancel" button on the Pending orders tab with a "Refund" button (gated to Manager/CEO; §19.7). Prompts for a reason, reverses inventory deltas, voids payment transactions, reverses wallet transactions, and moves the order to the Cancelled tab. Logs via `logActivity()` and triggers notifications via `fireNotification()`.
* **System Boundary**: Orders Screen & Order Processing Core
* **Dependencies**: Unit 02

#### Unit 05: Customer Wallet - Add Funds (Top-up)
* **What it builds**: The "Add Funds" button on the Customer Profile wallet card (§18.3). Opens a form for amount, payment method (Cash, Bank Transfer, POS card, Other), and optional note. Updates the wallet balance.
* **System Boundary**: Customers Screen & Wallet Service
* **Dependencies**: Unit 03

#### Unit 06: Customer Wallet - Refund Flow
* **What it builds**: The "Refund Cash" button and modal (CEO & Manager only) on the Customer Profile (§18.3). If the wallet is in debt, held crate deposits are refunded *to the wallet* to reduce debt (no cash option). If not in debt, refunds are paid out as cash. Inserts a `payment_transactions` refund or `crate_refund` credit, records to activity logs, and fires notifications. Gated by `customers.wallet.withdraw`.
* **System Boundary**: Customers Screen & Wallet Service
* **Dependencies**: Unit 02, Unit 05

#### Unit 07: Expenses - Store Scope & Budgeting UI
* **What it builds**: Updates the Record Expense form to open as a full screen stamped with the active store's name ("Recording for: [Store Name]"; §20.2, §20.8). Wires the Monthly Budget spent-vs-goal bar on the Expenses screen (which always reflects the current calendar month) to resolve its goal and spent figures based on the active store/business scope.
* **System Boundary**: Expenses Screen & Active Store picker
* **Dependencies**: Existing Expenses

#### Unit 08: Supplier Accounts - List View and Add Supplier Form
* **What it builds**: The main Supplier Accounts screen (under `suppliers.manage` role gate; §21.1, §21.2). Lists suppliers showing their active-store-scoped balances. Includes a floating "Add Supplier" button opening a form (name, phone, address, bank details, notes) and a caption displaying the active-store scope.
* **System Boundary**: Supplier Accounts UI
* **Dependencies**: None

#### Unit 09: Supplier Accounts - Details, Activity Ledgers, and Record Activity
* **What it builds**: The Supplier Details screen showing contact and bank info, active-store-scoped balance card, and period-filtered activity list (invoices, payments, and voids; §21.3, §21.4). Wires the floating "Record Activity" button to record Invoices (amount, date, note) and Payments (amount, payment method, date, required proof ref/image). Adds CEO void action (compensating reversal).
* **System Boundary**: Supplier Accounts Detail UI & Ledger Service
* **Dependencies**: Unit 03, Unit 08

#### Unit 10: Supplier Accounts - Transaction History Screen
* **What it builds**: Adds a "Transaction history" link at the top of the main Suppliers list (§21.1). Opens a screen displaying a list of all ledger transactions (invoices, payments, voids) across all suppliers, filtered by period and active store.
* **System Boundary**: Supplier Accounts UI
* **Dependencies**: Unit 09

---

### Ring 2: Operational Daily Loop
*Daily store operations, customer details, and stock counts.*

#### Unit 11: Customer Edit Flow & GPS Capture
* **What it builds**: Implements the `updateCustomer` real DAO write edit flow (§18.3). On the Customer Add/Edit form, replaces the text-based address with a Google Maps location picker map widget allowing pin drops to capture latitude/longitude coordinates (§18.2).
* **System Boundary**: Customers Screen
* **Dependencies**: None

#### Unit 12: Daily Stock Count - Count Grid & Live Adjustments
* **What it builds**: The Daily Stock Count screen scoped to the active store (§17.1, §17.2). Renders a grid showing Product, System (current count), Actual (editable textfield), and Diff (auto-calculated, red if negative). Tapping "Save Count" prompts a confirmation summary before committing stock adjustments to the database.
* **System Boundary**: Inventory Screen
* **Dependencies**: None

#### Unit 13: Daily Stock Count - Record Damages Form
* **What it builds**: Wires the "Record Damages" button on the Stock Count screen (§17.2). Opens a form to select product, quantity, and reason (broken, expired, spilled, theft, other). Committing reduces system stock and appends a damage adjustment row to the Inventory History.
* **System Boundary**: Inventory Screen
* **Dependencies**: Unit 12

#### Unit 14: Daily Stock Count - Session History & Reconciliation Trigger
* **What it builds**: Adds the "Stock Count History" icon on the Stock Count screen. Opens a screen showing past saved stock count sessions (§17.3). Wires the "Save Count" action to trigger the daily reconciliation report calculation.
* **System Boundary**: Inventory Screen
* **Dependencies**: Unit 12

---

### Ring 3: Reporting & Cross-Cutting Verification
*Business intelligence reports, activity logs, notification sweeps, and hardware integration.*

#### Unit 15: Daily Reconciliation Report - Period Cards List
* **What it builds**: The Daily Reconciliation Report list view (§25.9). Shows period cards groupable by Day / Week / Month / Year. Filters based on active-store scope. Managers are capped at Month.
* **System Boundary**: Reports Screen
* **Dependencies**: Unit 14

#### Unit 16: Daily Reconciliation Report - Details & Cost Gating
* **What it builds**: Reconciliation Detail screen (§25.9). CEO sees a full cost-based Profit & Loss (Revenue, COGS, Expenses, Damages-at-cost) and Statement of Account (goods received, payments, refunds). Managers see the same report but with a "cost wall" (no cost/profit figures; shrinkage shown at selling price).
* **System Boundary**: Reports Screen
* **Dependencies**: Unit 15

#### Unit 17: Reports Hub - Supplier Accounts Report
* **What it builds**: Renders a Supplier Accounts report in the Reports Hub summarizing outstanding balances, total paid, and total received per supplier, scoped to the active store (§25.2).
* **System Boundary**: Reports Screen
* **Dependencies**: Unit 09

#### Unit 18: Reports Hub - Profit Report (CEO Only)
* **What it builds**: Renders the Profit Report in the Reports Hub summarizing Revenue, COGS, Gross Profit, and Margins, groupable by period (§25.2, §25.10). Locked to the CEO.
* **System Boundary**: Reports Screen
* **Dependencies**: None

#### Unit 19: Reports Hub - Layout Redesign & Approvals Card
* **What it builds**: Redesigns the Business Reports grid (§25.1). Adds the "Approvals" report card showing pending Stock-keeper adjustment requests (§16.6.1) and Cashier Quick Sale requests (§12.3.1). Approvers can tap to Approve / Reject.
* **System Boundary**: Reports Screen
* **Dependencies**: Unit 02

#### Unit 20: Activity Logs - Screen & Diffs
* **What it builds**: The Activity Logs screen showing a scrollable list of sensitive/unusual log events with filter controls (store, action type, staff, period; §24.1, §24.2). Tapping an entry opens a modal displaying before/after diffs.
* **System Boundary**: Settings & Logs Screen
* **Dependencies**: Unit 02

#### Unit 21: Global Reliability Safety Net & Error Logging
* **What it builds**: Wires the `error_logs` synced database table (§33.3) and registers the global uncaught error handler. Replaces Flutter's default red error box with a friendly fallback card widget (§33.2) to prevent screen-blocking crashes.
* **System Boundary**: Notification Service & System Reliability
* **Dependencies**: None

#### Unit 22: Notifications - Verification Pass & UI Links
* **What it builds**: A comprehensive audit and integration pass ensuring all 20+ notification triggers in §26.4 fire correctly, update the bell badge, persist for 30 days, and correctly navigate to target screens on tap.
* **System Boundary**: Notification Service
* **Dependencies**: Unit 02

#### Unit 23: Barcode Scanning (Pharmacy & Supermarket)
* **What it builds**: Integrates camera-based barcode scanning via `barcode_widget` on the Add Product, Product Details, and POS search fields for Pharmacy and Supermarket business types only (§16.11).
* **System Boundary**: POS & Inventory Screens
* **Dependencies**: None

#### Unit 24: UI Cleanup - Deliveries Removal & Loading Sweep
* **What it builds**: Removes all sidebar/nav references to the deferred Deliveries feature. Sweeps the entire codebase to replace traditional loading spinners with smooth visual fade-in transitions (§30.7).
* **System Boundary**: Navigation & Core App Theme
* **Dependencies**: None

---

#### CEO Danger Zone (Build Last)
*Critical account destruction and downstream synchronization propagation.*

#### Unit 25: Delete Business & Account - Danger Zone UI & Confirmation
* **What it builds**: Adds the red "Danger Zone" to the bottom of the CEO Settings page (§10.1). Clicking "Delete Business" opens a plain-English warning screen explaining that the action is permanent. The CEO must confirm by entering their 6-digit PIN (§10.3).
* **System Boundary**: Settings Screen
* **Dependencies**: None

#### Unit 26: Delete Business & Account - Online RPC & Device Wipes
* **What it builds**: Executes the online RPC `delete_business` to drop all business-scoped records. Upon success, wipes local data (`clearAllData()`) and redirects the CEO to the Welcome screen. Creates `account_deletion_events` and `deleted_businesses` tombstones on the server (§10.3). Wires staff devices to listen/poll for these tombstones and perform their own local wipe + logout.
* **System Boundary**: Settings Screen & Database Synced Services
* **Dependencies**: Unit 25

---

## 🚦 Build Order Verification

1. **Self-Consistency Audit**:
   * Unit 02 (Helpers/DB migrations) and Unit 03 (Money math) are at the top of the queue, ensuring all subsequent transactional units (Units 04, 05, 06, 07, 09) write correctly.
   * Supplier details (Unit 09) precede the Supplier Report (Unit 17).
   * Daily Stock Count (Unit 12) precedes the Daily Reconciliation Report (Unit 15).
   * The global safety net (Unit 21) runs prior to the final QA pass and barcode scanner integrations.
   * The highly destructive cascade delete (Unit 26) is built dead last.
2. **Merge Check**:
   * The "Record Damages" form (Unit 13) and "Stock Count History" (Unit 14) depend on the count grid (Unit 12), but are separated since they touch different UI actions and flows, keeping each unit focused on a single visible result.
