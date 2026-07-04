# The Order Module: one facade over command/query surfaces, owning lifecycle orchestration

**Status:** accepted (2026-07-03)

Order-lifecycle logic is scattered: `OrderService.addOrder` (payment-type and
wallet-debit resolution, quick-sale audit, crate-debt notify, server flush +
local compensation), `OrdersDao.createOrder / markCompleted / markCancelled`
(the atomic DB transactions), the `pos_record_sale_v2` RPC (authoritative cloud
settlement), and — most tellingly — the **Confirm ceremony orchestrated by the
UI** in `orders_screen._executeMarkDelivered` (crate-return settle via a modal →
`markAsCompleted` → delivery receipt). Two screens also read orders straight
from `OrdersDao`, bypassing the service. We consolidate every **order-shaped**
write and read behind a single **`OrderService` facade** in
`lib/shared/services/orders/`, split *internally* into an **`OrderCommands`**
surface (**Checkout / Confirm / Cancel** + reject-compensation) and an
**`OrderQueries`** surface (`watch*` / paging / stats). The facade sits *on top
of* `OrdersDao` — which stays the persistence seam, unchanged — rather than
absorbing it. Server-rejection **compensation is domain logic and lives in the
module**, next to `Cancel` (both are reversals); the **flush mechanism stays
transport**, reached through a narrow **`SaleFlusher`** seam (real impl adapts
`SupabaseSyncService`, a fake stands in for tests) so `OrderCommands` is
unit-testable without the network. **Confirm** absorbs the crate-return
settlement the UI used to coordinate — `CrateReturnModal` drops to input
collection only. Explicit **no-s**: saved **Carts** (pre-checkout drafts) and
**delivery receipts** (downstream artifacts) are *not* in the module, and the
DAO is *not* absorbed. This is a pure extraction — **no behavior change** —
guarded by characterization tests on the reject→compensate and
Confirm-ordering paths plus the existing suite.

## Considered Options

- **Absorb `OrdersDao` into the module** — rejected: `createOrder` is a
  hard-won atomic transaction (wallet + inventory + crate legs), and the DAO is
  already a clean persistence/testing seam used directly by 5+ call sites
  (carts, crate settlement, customer/product reads). Re-homing all of them onto
  the module buys nothing and risks the transaction.
- **Put compensation in the Sync Engine** — rejected: "a rejected sale must be
  reversed" is domain *meaning* (cancel the order, refund the inventory cache),
  the same reversal family as `Cancel`. The transport layer must not know what a
  sale means; it only knows how to push and detect rejection.
- **Two public providers (`orderCommandsProvider` + `orderQueriesProvider`)** —
  rejected: turns an internal organisational split into a public API and churns
  call sites for no interface benefit. The module is *one* front door with two
  *internal* surfaces.
- **Carts / delivery receipts in the module** — rejected: a Cart has no revenue,
  status, or invariants (it is a draft that becomes an Order at Checkout); a
  receipt is a downstream document. Both dilute the module's cohesion and pull
  it back toward the grab-bag we are escaping.
- **A full observer/event system for post-checkout side-effects** — rejected as
  speculative generality: two best-effort reactions (quick-sale audit,
  crate-debt notify) get one isolated private side-effects step, not an event
  bus. Revisit only if the reaction list grows (receipts, loyalty, webhooks).
