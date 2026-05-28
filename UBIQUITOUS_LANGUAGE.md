# Ubiquitous Language

Shared vocabulary for the Reebaplus POS project. Everyone — agent, planner, future contributors — uses these exact words to mean these exact things. No synonyms, no drift. If a word is in here, use it everywhere. If a concept isn't in here, add it before using it.

---

## People and Roles

- **CEO** — Owner of a business. Has full access to everything. Created automatically when a new business is set up.
- **Manager** — Runs a store on behalf of the CEO. Permissions are limited by what the CEO toggles in settings.
- **Cashier** — Person making sales at the till. Cannot see profit, buying prices, or expenses.
- **Stock Keeper** — Handles inventory. Cannot make sales or see money-related info.
- **Staff** — Any of the four roles above. Anyone working in a business.
- **Walk-in Customer** — A customer with no profile, no wallet, no credit. Must pay in full at the moment of sale. No credit sales and no partial payments. Payment can be cash, POS card, or bank transfer.
- **Registered Customer** — A customer with a saved profile, a wallet, and a price tier.
- **Active Now Dot** — The small indicator on staff cards showing a staff member is logged in on another till. Used on the Who Is Working picker and in Staff Management.
- **Color Tag** — The colour used to identify a role across the app: CEO yellow, Manager blue, Cashier green, Stock keeper grey. Used on staff cards and the sidebar profile area.

---

## Business Setup

- **Business** — One business is owned by one CEO. A business has at least one store. One email can belong to more than one business.
- **Store** — A single business location (name, address, state, country). Replaces the old word "Warehouse" everywhere in the app.
- **Till** — The physical device the app runs on. Shared by multiple staff during a shift.
- **Terminal** — Same thing as a till. Each device shows a terminal label (e.g., "Terminal 01").
- **Shift** — The period one staff member is signed in and working on the till.

---

## Money and Accounts

- **Wallet** — A registered customer's money record. The source of truth for their balance. Every sale to a registered customer flows through the wallet.
- **Funds Register** — The system that tracks balances for all accounts (cash, POS machines, bank). Replaces the old "Cash Register" concept.
- **Cash Till** — The physical cash box for a store. One per store, always exists.
- **POS Machine** — A card-reader device. Each one has its own balance. CEO can add multiple per store.
- **Bank Account** — A bank account linked to a store. CEO can add multiple per store.
- **Opening Day** — Setting the day's starting balances. Cash is counted; POS machines and bank accounts default to zero.
- **Closing Day** — End-of-day count. Cash counted; amounts withdrawn from POS machines and bank accounts recorded.
- **Reconciliation** — Comparing expected vs actual balances at close of day. Mismatches flagged in the report.
- **Daily Reconciliation Report** — The report auto-generated when a stock take is saved. Combines stock audit, cash audit, sales summary, top item, and best staff. Goes to CEO and Manager.
- **Debt Limit** — The maximum a registered customer is allowed to owe. Set by CEO or Manager per customer.
- **Credit Sale** — A sale paid for entirely on credit. The full amount becomes debt on the customer's wallet.
- **Partial Payment** — A sale where part is paid now and the rest becomes credit.

---

## Pricing

- **Price Tier** — Either "Retailer" or "Wholesaler". Each registered customer is attributed to one tier. Replaces the old "Customer Group".
- **Retailer Price** — The price for retail customers.
- **Wholesaler Price** — The price for wholesale customers.
- **Buying Price** — What the business paid for the product. Required when adding a product. Hidden from Cashier and Stock keeper.

---

## Inventory

- **Product** — An item the business sells. In Phase 1, each product belongs to one store. Phase 2 may allow products to be shared across stores.
- **SKU** — A single unique product line. "Total SKUs" = the count of unique products in stock.
- **Stock** — Quantity of a product on hand. The bottom-nav label that points to the Inventory screen.
- **Inventory** — The full list of products and quantities. The sidebar label for the same screen as Stock.
- **Manufacturer** — Who made the product. Used to group products on screen.
- **Supplier** — Who the business buys products from. Tracked in Supplier Accounts.
- **Low Stock Alert** — Threshold per product. When stock drops to it, low-stock notifications fire.
- **Stock Take / Daily Stock Count** — Physically counting products and entering the actual numbers to compare against the system.
- **Damage** — Stock removed because it's broken, expired, spilled, or stolen. Logged and reduces system stock.
- **Fractional Sales** — A per-product toggle. When on, the Edit Quantity modal shows ±0.5 chips so a cashier can sell half a crate, half a bottle, etc. Default off.

---

## Shipments and Crates

- **Shipment** — Incoming goods from a supplier. Two states: Pending (expected) and Received. Replaces the old "Goods Received".
- **Empty Crate** — A returnable crate. Only used by Bar and Beer Distributor businesses. Tracked separately from products.
- **Crate Deposit** — Money a customer pays upfront when they take crates home. Refunded when crates return.

---

## Sales and Orders

- **Cart** — The active sale being built up at the till. Private to the logged-in cashier.
- **Saved Cart** — A cart held for later (using Save Cart). Per-cashier. Recall opens the list of your own saved carts. Auto-expires after 24 hours.
- **Edit Quantity Modal** — The modal that opens when a cart item is tapped. Contains quantity adjustment buttons, ±0.5 chips (if fractional sales are on), the Apply Discount control, and Remove / Save Changes.
- **Checkout** — The screen where payment is finalised.
- **Order** — A confirmed sale. Has three states:
  - **Pending** — Sale is paid but goods are not yet handed over (waiting on pickup or rider).
  - **Completed** — Goods handed over.
  - **Cancelled** — A pending order cancelled before handover.
- **Pick-up Order** — A confirmed pending order with no rider assigned. The customer collects in person. Default behaviour for any pending order until a rider is assigned.
- **Rider** — The person who delivers an order. In Phase 1, the rider's name just appears on the receipt — no status tracking, no rider management screen. Full implementation in Phase 3.
- **Quick Sale** — Selling an item not in the inventory. Needs CEO or Manager PIN if the user is a Cashier.
- **Receipt** — The proof-of-sale document. Printed or shared after Confirm Payment.
- **Refund** — Returning money for a completed order. Inventory is restored. CEO and Manager only.
- **Discount** — A reduction on a cart line. Capped by the user's role.

---

## Expenses

- **Expense** — A cost the business pays (fuel, rent, salary, etc.).
- **Pending Approval** — An expense recorded by a Manager above their limit. Waits for CEO to approve or reject.
- **Budget** — Monthly spending goal set by the CEO. Only approved expenses count toward it.

---

## Access and Security

- **Role** — A bundle of permissions stored in the database (not in code). Four default roles: CEO, Manager, Cashier, Stock keeper.
- **Permission** — One specific action a role is allowed to do (for example, `sales.cancel`). Toggled per role by the CEO.
- **Invite Code** — An 8-character code generated by CEO or Manager to bring in new staff. One use only, expires in 7 days.
- **PIN** — A 6-digit personal code for signing in. Each staff member has their own.
- **Auto-lock** — Screen silently returns to the Who Is Working picker after 5 minutes of no activity (adjustable in settings).
- **Switch User** — Manually returning to the Who Is Working picker without logging out.
- **Who Is Working Picker** — The daily-use screen on the shared till. Shows all active staff. Tap your card → enter PIN → start working.

---

## Logs and History

- **Activity Log** — Record of unusual or sensitive actions (discounts, cancellations, role changes, deletions, overrides, etc.). Routine sales are NOT logged here — they live in Orders.

---

## Common UI Patterns

- **Stat Cards** — The row of summary number cards at the top of screens like Inventory, Orders, and Expenses.
- **Period Filter** — The Day / Week / Month / Year / All chips. Most screens default to Day; Expenses defaults to Month.
- **Empty State** — The message shown when there's no data ("No expenses found", "Cart is empty", etc.).
- **Store Selector** — The small icon on POS that lets CEO switch which store they're selling from. CEO only.
- **Snackbar** — A small message that slides in (top or bottom) with an Undo button. Used for non-destructive removals (cart item, dismissed notifications) instead of upfront confirmation dialogs.

---

## Conventions

- **Soft Delete** — Marking something as deleted without actually removing it. Hidden from lists but history stays intact. Applies to customers, suppliers, payments, expenses.
- **Hide-don't-block** — If a user lacks permission for something, the menu item or button does not appear at all. No greyed-out blocked elements.
- **Source of Truth** — Used in one specific way: the customer wallet is the source of truth for a registered customer's money movements. Every sale, refund, top-up, and credit flows through it.
- **Sync** — Pushing local writes to the cloud and pulling cloud changes back. Happens automatically in the background. The app is offline-first, so sync may lag, but writes are queued and never lost.
- **Order ID format** — Short, human-readable codes (e.g., ORD-000001, INV-K7M2QX, REC-0912). Internal UUIDs are never shown to users.
- **Phase 1** — The current build. Everything in the master plan that's not flagged as Phase 2 or Phase 3.
- **Phase 2** — Deferred features for the next release (multi-store UI, custom roles, custom permission groups, etc.).
- **Phase 3** — Larger deferred features (deliveries and rider management, PDF export, activity log export, etc.).

---

## Renamed Things (Old → New)

| Old name | New name |
|----------|----------|
| Warehouse | Store |
| Cash Register | Funds Register |
| Customer Group | Price Tier |
| Goods Received | Shipment |
| Dashboard | Home |
| All Warehouses (filter) | All Stores |

Use the new names everywhere. The old names should not appear in code, UI, or documentation.
