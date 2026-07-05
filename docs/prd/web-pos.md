# PRD — Web POS (online-first browser client)

> Status: draft for review (not yet published to the issue tracker).
> Grilled 2026-07-04. Decisions recorded in ADRs 0007–0012 and CONTEXT.md (Web section).
> Scope of this PRD: **Phase 1** of a full-parity roadmap — the selling loop,
> inventory management, and reports. Later parity phases are in *Out of Scope*.

## Problem Statement

The business runs entirely on the mobile app today. A CEO, manager, or cashier who
is at a desk — not standing at the shared till — has no way to operate the business
from a computer. They cannot ring up a sale on a laptop, manage the catalogue on a
big screen with a keyboard, or pull up reports in a browser tab. Everything requires
picking up the phone/tablet that runs the offline-first app. As businesses grow past
a single till, "you must use the mobile device" is a real ceiling: back-office work
and a second selling station both want a browser.

## Solution

A browser-based version of the app — the **Web POS** — that operates the same
business, live, from any computer. Unlike the mobile app it is **online-first**: it
reads the Supabase cloud directly (PostgREST + Realtime) and performs every
money-write through a **server-authoritative RPC**, with no offline mode. A staff
member signs in with their own email-OTP or Google identity and that session is the
**Operator**; they see the same catalogue, customers, and inventory the mobile
tills see, updated live, and every sale they ring up appears on the mobile devices
(and vice-versa) through the existing sync path. Phase 1 delivers the full selling
loop, inventory management, and reports; later phases bring the rest of the app to
parity.

Because the same money math (FIFO COGS, wallet/crate ledger posting, order
numbering, revenue recognition) now runs in *two* places — Dart on offline mobile,
SQL RPC on online web — a **Golden-Scenario Suite** runs the same fixtures against
both and fails CI on any drift, so the two implementations can never disagree.

## User Stories

### Authentication & session (Operator model, ADR 0011)

1. As a staff member, I want to open the Web POS in a browser and sign in with my
   email + OTP, so that I can operate my business from a computer.
2. As a staff member, I want to sign in with Google, so that I can use the identity
   I already have without waiting for an email code.
3. As an Operator, I want the app to know my business, stores, and role automatically
   after sign-in, so that I only see and act on my own business's data.
4. As an Operator, I want the tab to lock back to the sign-in screen after a period
   of inactivity, so that a walk-away doesn't leave the business exposed on a shared
   computer.
5. As an Operator, I want every sale I make attributed to me, so that activity logs
   and reports show who did what.
6. As a business owner, I want a staff member with no permission for an action to not
   see it in the web UI (hide-don't-block), so that the web honors the same
   data-driven permissions as mobile.

### Selling loop — POS grid & cart

7. As an Operator, I want to see the live product grid with categories and price
   tiers (Retailer / Wholesaler), so that I can build a sale the same way as on
   mobile.
8. As an Operator, I want out-of-stock products shown as unavailable using the live
   stock count, so that I don't add something that isn't there.
9. As an Operator, I want to tap/click a product to add it to the cart, adjust its
   quantity, and remove it, so that I can assemble the order.
10. As an Operator, I want the cart to show line totals and an order total in the
    business currency, so that I can see what the customer owes.
11. As an Operator, I want to apply a discount within the limit my role allows (and be
    capped if I exceed it), so that discounting stays governed by permissions.
12. As an Operator, I want to attach a registered customer to the cart, so that the
    sale posts to their credit history and wallet.
13. As an Operator, I want the cart to persist within my session while I look something
    up, so that I don't lose an in-progress sale on navigation.

### Checkout (server-authoritative `checkout_order` RPC, ADR 0008)

14. As an Operator, I want to check out with Cash/Transfer by entering the amount paid,
    so that I can settle a normal sale.
15. As an Operator, I want to check out as Pay-with-Credit against a registered
    customer's wallet, so that a known customer can pay from their balance.
16. As an Operator, I want to register a sale as a Credit Sale, so that a customer can
    take goods now and owe the balance.
17. As an Operator, I want a sale that would push a customer past their debt limit to be
    blocked at checkout, so that credit rules are enforced.
18. As an Operator, I want checkout to reject if the live stock is insufficient at the
    moment of commit, so that two concurrent tills can't oversell the same units.
19. As the business, I want checkout to draw down FIFO Cost Batches oldest-first and
    snapshot per-line COGS server-side, so that web sales value inventory exactly like
    mobile sales.
20. As the business, I want checkout to write the wallet ledger legs (debit the order,
    credit the amount paid) as append-only rows, so that the customer balance stays the
    single source of truth.
21. As the business, I want checkout to post crate ledger movements for crate-eligible
    businesses, so that empties are tracked when a web sale involves deposit-bearing
    product.
22. As the business, I want the order number minted server-side in a way that can never
    collide with a mobile device's offline order number, so that numbering stays unique
    across clients.
23. As the business, I want revenue recognized at Checkout (order `pending`), not at
    Confirm, so that web sales count as recognized Sales identically to mobile.
24. As an Operator, I want the whole checkout to be atomic — order, items, ledgers, stock,
    COGS all commit together or not at all — so that a failure never leaves a half-written
    sale.

### Receipt

25. As an Operator, I want a receipt to open after checkout, so that I can confirm the
    sale and give the customer a record.
26. As an Operator, I want to print the receipt from the browser, so that a customer with
    a paper preference gets one.
27. As an Operator, I want to share/download the receipt (PDF or link), so that a customer
    can get it digitally.
28. As an Operator, I want a "Done — back to POS" action that clears the cart, so that I'm
    ready for the next sale.

### Live consistency (Realtime)

29. As an Operator, I want a price edited on mobile to appear in the web grid without a
    manual refresh, so that the two clients agree.
30. As an Operator, I want a web sale to appear on the mobile devices' orders/stock, so
    that everyone sees a consistent picture.
31. As an Operator, I want stock counts in the grid to update live as other tills sell, so
    that I don't try to sell stock that just ran out.

### Inventory management (Phase 1)

32. As a manager, I want to add a product (name, per-tier prices, opening stock, store) on
    web, so that I can build the catalogue on a keyboard and big screen.
33. As a manager, I want to edit a product's prices and details on web, so that pricing is
    maintainable from a desk.
34. As a manager, I want to Receive Stock (log a supplier delivery) on web, so that a
    delivery can be recorded from the office — creating the Cost Batch at the delivery cost.
35. As a manager, I want to adjust stock on web, so that counts can be corrected.
36. As a stock keeper, I want my stock adjustment on web to create a pending request rather
    than change inventory directly, so that the approval gate that exists on mobile is
    honored on web too.
37. As a manager, I want to approve or reject a stock adjustment request on web, so that the
    approval loop can be completed from a computer.

### Reports & dashboards (Phase 1)

38. As a CEO/manager, I want a sales/revenue dashboard on web, so that I can see how the
    business is doing on a big screen.
39. As a CEO/manager, I want a profit report that excludes Uncosted units transparently, so
    that the web report matches the mobile report's costing rules.
40. As a CEO/manager, I want to view activity logs on web, so that I can audit who did what.
41. As a CEO/manager, I want reports scoped to the active store or all stores, so that a
    multi-store business can slice its numbers.

### Correctness guardrail

42. As the business, I want the web money-writes verified against the same fixtures as the
    mobile money-writes, so that FIFO/ledger/order-number logic can never silently diverge
    between the two clients.

### Responsiveness & theming (cross-cutting)

43. As an Operator on a phone browser, I want the Web POS to lay out in a single, touch-
    friendly column, so that I can use it on a small screen.
44. As an Operator on a tablet, I want a layout that uses the extra width (e.g. product
    grid beside the cart), so that the tablet form factor is well used.
45. As an Operator on a PC/laptop, I want a full multi-pane desktop layout with keyboard
    support, so that ringing up and back-office work are efficient on a big screen.
46. As an Operator on a very large/wide monitor, I want the content to stay well
    proportioned (max widths, denser grids) rather than stretch awkwardly, so that big
    screens are orchestrated, not just scaled.
47. As a CEO, I want the business colour I set (the synced `business_design_system`
    choice: blue / amber / purple / green / b&w) to be applied across the Web POS, so
    that the web matches my brand exactly like the mobile app.
48. As an Operator, I want a change the CEO makes to the business colour to apply on web
    live (on the next load / reactively), so that branding stays consistent across
    clients without a redeploy.
49. As an Operator, I want business settings that affect what I see (currency, empty-crate
    tracking on/off, store scope) honored on web, so that the web behaves like the same
    business, not a generic app.

## Implementation Decisions

- **Online-first web client (ADR 0007).** No Drift, no outbox, no offline mode on web.
  Reads are live PostgREST queries + Realtime subscriptions; the offline invariants
  (#1, #4) are mobile-scoped, not app-wide.
- **RPC Write API (ADR 0008).** Every money-write is a `SECURITY DEFINER` Postgres RPC,
  one atomic transaction, behind RLS. Phase-1 RPC surface (new unless noted):
  - `checkout_order(...)` — the keystone. In one transaction: insert the Order at
    `pending` + line items; draw down FIFO Cost Batches oldest-first under a row lock
    and snapshot per-line `buying_price_kobo`; **reject if live stock is insufficient at
    commit**; post wallet ledger legs; post crate ledger movements for crate-eligible
    businesses; enforce the customer debt limit; mint a **server-side order number** that
    cannot collide with the mobile device-tag scheme; recognize revenue at checkout.
  - `receive_stock(...)` — increases stock, posts the supplier invoice/payment/crate
    returns, pushes a new Cost Batch at the delivery cost.
  - `add_product(...)` / `update_product(...)` — catalogue writes incl. the opening Cost
    Batch (costed or Uncosted).
  - `request_stock_adjustment(...)` / `approve_stock_adjustment(...)` — honor the
    approval gate (stock keeper → pending request; manager/CEO → apply).
  - Reuse existing RPCs where they already encode the rule (e.g. the recost family
    0133) rather than duplicating.
  - Each RPC **enforces the caller's permission server-side** (defense in depth) in
    addition to the client hiding the action.
- **Amounts stay in `*_kobo` bigint** end to end (per the cloud kobo-must-be-bigint
  rule); the web formats with the business currency, never hard-coding ₦.
- **Two implementations, one contract (ADR 0009).** The Dart DAO path and the SQL RPC
  path are independent implementations of the same rules, pinned identical by the
  Golden-Scenario Suite.
- **Client stack (ADR 0010).** Next.js/React + `supabase-js`; RLS-scoped reads,
  `rpc()` writes, Realtime channels. No Flutter Web, no shared client code with mobile.
- **Auth (ADR 0011).** Per-user Supabase session = Operator; no PIN, no "Who's working?"
  picker. Business scope resolves server-side from `profiles.business_id`
  (`current_user_business_ids()`); no custom JWT claims needed.
- **Permissions.** The web reads the same `role_permissions` / override rows and applies
  hide-don't-block, mirroring the mobile Gate Registry's *decisions* (not its Dart code).
- **Responsive/adaptive layout.** The web is designed for four breakpoint bands — phone,
  tablet, desktop, and large/wide — with orchestrated layouts, not a single scaled view:
  a single touch column on phones; grid-beside-cart on tablets; multi-pane + keyboard
  affordances on desktop; max-width/denser composition on very wide screens. Responsive
  behavior is a **cross-cutting acceptance criterion on every UI slice**, plus a
  responsive app shell established in the walking skeleton.
- **Theming parity (CEO business colour).** The web reproduces the five named palettes
  (blue / amber / purple / green / b&w, with light/dark) as web theme tokens matching the
  mobile `AppTheme` palettes, applied at the app root. The active palette is read **live
  from the synced `business_design_system` setting** (value = the `DesignSystem.name`
  the CEO set) — the same source mobile reads via `businessDesignSystemProvider` — so the
  CEO's colour applies on web and reacts to changes without a redeploy. Light/dark mode
  may follow the browser/device preference; the business *colour* is the synced,
  CEO-authoritative axis. Currency continues to be formatted from the business currency
  setting, never hard-coded.
- **Monorepo (ADR 0012).** New `web-pos/` directory beside `supabase/migrations/`;
  contract change + web caller land in one PR; deploy on Vercel with root `web-pos/`.
  The pre-existing `web/` dir is Flutter's build output and is left alone.
- **Cross-client propagation.** Web writes land as ordinary cloud rows with normal
  `last_updated_at`; mobile picks them up through its existing Realtime-signalled pull.
  Mobile writes reach web through the web's Realtime subscriptions. No new sync engine.

## Testing Decisions

- **A good test asserts external behavior, not implementation.** For the RPCs, that means
  asserting the *rows produced* (order, items, ledger legs, batch consumption, stock
  level, order number shape) from a given starting state — never the internal query plan.
- **Single primary seam: the RPC contract boundary.** The **Golden-Scenario Suite** is a
  set of fixtures (input state → expected resulting rows) run in CI against **both** the
  SQL RPC (web money-writes) and the Dart DAO (mobile money-writes). Drift on either side
  fails the build. This is the one seam that guarantees parity of the money math.
- **Web UI** is tested with lighter component tests over a **mocked `supabase-js`** — the
  UI's job is to call the right RPC with the right args and render the response, not to
  re-derive money math.
- **Prior art in this repo:** `test/integration/rpcs/pos_recost_batches_test.dart` (Dart
  integration test driving a Postgres RPC), the costing suites under `test/costing/`
  (pure-function + DAO behavior), and the existing v2 sale RPCs (`pos_record_sale_v2`,
  `pos_recost_pairs`, `pos_recost_product_store`) as models for a transactional
  `SECURITY DEFINER` write RPC.

## Out of Scope

- **Offline mode on web.** The web is online-first by decision (ADR 0007); a browser with
  no connection simply cannot operate.
- **PIN / "Who's working?" shared-till picker on web** (ADR 0011). No cloud-verifiable
  PIN exists (invariant #2). A server-side "quick-switch operator" factor is a possible
  later phase.
- **Migrating the mobile app onto the RPCs.** Mobile stays offline-first with its Dart
  write path; only web uses the RPCs (ADR 0009).
- **Later full-parity phases** (this PRD is Phase 1 only): staff/roles management,
  supplier ledgers & payments, expenses & approvals, crate-management screens, settings /
  business info, onboarding on web (create-business, join-with-invite — which also need a
  no-PIN variant of the flow), deliveries. These become their own PRDs.
- **A separate operator Admin Hub.** The existing subscription console is unchanged.

## Further Notes

- **Full-parity roadmap.** North star is the entire app on web. Suggested phase order after
  Phase 1: (2) staff/roles + activity, (3) suppliers & wallets, (4) expenses, (5) crate
  management, (6) settings & business info, (7) onboarding (create-business / join-invite,
  no-PIN). Each is a live-read screen set plus, where it writes money, a new RPC + its
  golden fixtures.
- **Concurrency is a new problem web introduces.** Offline mobile resolved conflicts with
  LWW after the fact; web sells against live stock, so `checkout_order` must decrement
  under a row lock and reject at commit. This is why the write path is an RPC (one atomic
  transaction), not client-side PostgREST writes.
- **Order numbering.** Mobile uses `ORD-NNNNNN-XXXXXX` with a per-device tag to avoid
  offline collisions. The web RPC mints server-side with a distinct strategy (server tag
  or sequence) that is collision-proof against every mobile device tag.
- **Deployment.** Vercel, project root `web-pos/`. Same Supabase project as mobile; no new
  backend infrastructure — the "backend" for web is the RPC surface + RLS that already
  exist plus the new Phase-1 RPCs.
