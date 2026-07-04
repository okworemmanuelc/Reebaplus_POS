# Add Product and Receive Stock are two acts: opening stock never posts a supplier invoice

**Status:** accepted (2026-07-04)

First-time users could not add their first product without hand-holding
because the app conflated two distinct acts under one visible path. **Add
Product** — *create something you sell and record what's already on your
shelf* — writes stock straight to inventory with no supplier, no invoice, no
payable, and no cost-batch ceremony beyond an optional buying price. **Receive
Stock** — *log a supplier delivery of things you already sell* — increases
stock and posts the supplier invoice, payment, and crate returns. The direct
path existed (`AddProductScreen(receiveMode: false)`) but was orphaned after a
one-shot post-onboarding auto-push; the only discoverable affordance was the
Receive Stock FAB, which routed catalogue-building through the delivery-invoice
ceremony. We make the two acts separately discoverable and keep both labels
("Receive Stock" is locked — no rename). Opening stock recording **no supplier
payable and (optionally) no cost** is correct by definition — "what's already
on my shelf" is not a new purchase — and blank cost is a transparent,
recoverable state (the existing "uncosted items" reporting now; the prompted
backfill once ADR 0005 lands).

Decisions locked for the redesign (Epic 1, ships on the current scalar cost
model — nothing here depends on ADR 0005):

- **Speed-dial with permission-aware collapse** on the Inventory Products tab:
  one "+" FAB expands to two labeled choices (*Add Product — "Create a product
  and set what's on your shelf"* / *Receive Stock — "Log a delivery from a
  supplier"*), each citing its own gate (`Gates.addProduct` /
  `Gates.receiveStock`); when only one gate passes the dial collapses to a
  direct single FAB. The labeled expansion doubles as a teaching surface.
- **Adaptive fast-add form.** Required: Name (helper: include the size),
  Selling Price, Quantity. Visible-but-skippable: Buying Price (nudge: "Add
  what you paid so profit shows correctly. You can add it later."). Visible
  optional: Category (examples helper). **Crate-tracking businesses only**
  additionally surface Manufacturer (required — the crate deposit rate lives
  on it; hiding it would aim validation errors at a collapsed field or
  silently disable the flagship crate feature). Everything else collapses
  under "More details": Description, Wholesaler Price (copy-from-selling-price
  on save when blank; the mirror may go stale — accepted), Unit, track-empties
  toggle + crate value, Low Stock (default 5), Supplier, Expiry, Store (hidden
  entirely for single-store businesses).
- **Unit default is business-type-aware:** `businessTracksCrates(business) ?
  'Bottle' : 'Pack'` — a flat Pack default would silently disable crate
  tracking (auto-enables only on unit == Bottle) for the one live business
  type. The expression extends per-type as later phases unlock.
- **Persona-aware first-run surfaces.** POS/Inventory empty states get a
  primary "Add your first product" CTA, rendered only when the first pull has
  settled AND the catalogue is genuinely zero (never during the initial
  stream-in), and only behind `Gates.addProduct` (others see a neutral empty
  state). A **Get-started checklist** (Home tab only, CEO only) with
  completion **derived from data** — products > 0, orders > 0, staff > 1 —
  cross-device correct for free, self-dismissing, device-local manual
  dismissal. Coach tips stay on the existing `UiHintService` pattern.
- **The post-onboarding auto-push of the full form is deleted**
  (`requestAutoShowAddProductSheet`, both call sites, the MainLayout
  consumer). Onboarding lands on POS with the empty-state CTA — the user has
  seen where products will appear before being asked to describe one.
- **Receive Stock's own flow is untouched** in this epic: its ceremony is
  correct for its act; the pain was first-timers being routed through it.

## Considered Options

- **One FAB + app-bar "+" icon for Add Product** — rejected: a top-right
  icon-only affordance is near-invisible to this product's low-tech-literacy
  audience; it half-recreates the discoverability problem being fixed.
- **Two stacked labeled FABs** — rejected: two 165px-min pills of permanent
  chrome; visually noisy, non-standard.
- **Always default unit to Pack** (the original literal request) — rejected
  for crate businesses: first-timers rushing a trimmed form would save bottled
  drinks as Pack and crate tracking would silently never engage.
- **Auto-open the trimmed form once after onboarding** — rejected: the
  empty-state CTA and checklist must exist anyway (joining staff, dismissals,
  reinstalls), so auto-open adds only an interruption before the user has any
  spatial context.
- **Require buying price in the fast add** — rejected: the person keying in
  legacy shelf stock may genuinely not know it; blank cost is transparent and
  recoverable, and requiring it is first-run friction paid for a problem the
  backfill already solves.
