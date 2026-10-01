# Features and known limits

The full list of what Reebaplus POS does today, and what it does not. For the short version, see the [README](../README.md).

## Contents

- [Selling](#selling)
- [Stock](#stock)
- [Money owed, both directions](#money-owed-both-directions)
- [Oversight](#oversight)
- [Reliability](#reliability)
- [What's live](#whats-live)
- [Known limits](#known-limits)

## Selling

- Point of Sale grid for the active store, with Retailer and Wholesaler price tiers, category filter, and product search. Out-of-stock items are clearly unavailable.
- One-at-a-time barcode scanning at the till, with an optional barcode on each product.
- Cart with per-line discounts capped by role, saved and recalled carts for each cashier, and Quick Sale for items not yet in inventory. Cashiers send a Quick Sale for approval; a CEO or Manager adds it directly.
- Checkout by Cash or Transfer, Pay with Credit, or Register as Credit Sale. Receipts print to a Bluetooth thermal printer or share as an image.
- Empty-crate deposits handled at checkout for businesses that track crates.

## Stock

- Products with per-tier prices, buying price, stock level, expiry dates, manufacturers, and categories.
- Receive Stock works like the till in reverse: tap products, build an invoice, and one confirm records the supplier invoice, adds the stock, and logs empties returned to the supplier.
- Low-stock, out-of-stock, and near-expiry alerts; a Daily Stock Count; and stock adjustments by stock keepers that a Manager or CEO approves.
- Transfers between stores: one store requests, the holding store accepts and dispatches, and the requester confirms receipt. Empty crates can travel with the transfer.

## Money owed, both directions

- Customer profiles with a credit ledger as the single source of truth, debt limits that block any sale that would break them, Add Credit, and cash or crate refunds.
- Supplier accounts with a running ledger of invoices and payments per supplier.
- Empty-crate tracking for beverage businesses: what each customer owes the business, what the business owes each supplier, the physical empties held per store and per manufacturer, and deposit value at each manufacturer's rate.

## Oversight

- Reports by role: Daily Reconciliation, Supplier Accounts, Crate Deposits, Profit (CEO only), and an Approvals queue for stock adjustments and Quick Sales.
- Expenses with approval, searchable categories, and monthly budgets per store.
- Orders as Pending, Completed or Cancelled, with refunds limited to Managers and the CEO.
- Activity logs of every significant action and in-app notifications.
- Four roles out of the box (CEO, Manager, Cashier, Stock keeper), with permission switches per role and per staff member. Changes take effect without an app update and affect only that business.

## Reliability

- Works fully offline and syncs live between devices in the same business whenever there is a connection.
- Sync adjusts to the connection, sending smaller batches on poor links, and picks up where it left off if the app is closed.
- Offline work cannot be silently lost. Anything the server has not confirmed is protected from being overwritten or wiped, and can be viewed and exported if it cannot be sent.
- A crash never leaves a cashier on a blank or red screen mid-sale. The error is caught and logged, and the till keeps working.

## What's live

Sign-up and onboarding, the till, cart, checkout and receipts, barcode scanning, orders, inventory, receive stock, daily stock count, customers and credit, suppliers, expenses, staff and invite codes, transfers between stores, crate tracking, reports, activity logs, sync, and crash protection.

## Known limits

- **Android only.** The `ios/`, `web/`, `macos/`, `linux/` and `windows/` folders are Flutter defaults. The database opens a native SQLite file with no web equivalent, so these are not supported. Tablets and large screens get a wider layout.
- **Three business types can be chosen at sign-up:** Beverage distributor, Pharmacy, and Frozen Foods and Grocery. Supermarket, Restaurant, Bar, Building Materials, Boutique, and Phone and Gadgets are defined in code but not yet selectable.
- **Planned, not built:** supermarket support, and changing a business's type after sign-up.
- **One email, one business.** Someone who owns a second business signs up with a different email.
- **Van sales is complete but switched off** behind a build setting until it has been tested on the road.
- **Subscriptions are read-only in the app.** Trial, Active or Inactive status shows in Settings and is managed by the operator in a separate console. There is no in-app payment.
- **Logging out clears the phone's local data**, which downloads again at the next sign-in, because a device belongs to one user at a time. Unsynced work blocks the wipe rather than being thrown away.
- **Crash reports are reviewed in the Supabase console**, not in the app.
- **Continuous scanning**, where the camera stays open across several items, is in progress. Today each scan adds one item.
- **This is the mobile app only.** A separate online-first web client lives in its own repository.
