# Receive Stock — Junior-Agent Build Prompts (5 units)

Feature: a POS-style **Receive Stock** flow — the POS screen in reverse. The
business buys from a supplier: tap a product grid to add lines, check out to
post an **Invoice Total** to the supplier's ledger, and increment stock on
confirm. One invoice = one supplier. Source spec: `receive_stock_verification_list_v2.md`
(122 checks, 17 sections). Build it to pass that list.

> **Extra requirement (beyond the 122-check list):** on the checkout/invoice
> screen, for every line whose product is `unit == 'bottle' && trackEmpties == true`,
> capture an optional **"empty crates returned to supplier"** count. On confirm,
> record those empties as a *return to the supplier* (reduces what we owe), in
> addition to recording the *full crates received* (increases what we owe).

---

## Ground rules for EVERY unit (read before each prompt)

1. **Read context first, every unit** (order from `CLAUDE.md`):
   `CONTEXT/project-overview.md` → `architecture.md` → `ui-context.md` →
   `code-standards.md` → `ai-workflow-rules.md` → `progress-tracker.md`.
   Re-read `architecture.md` **Invariants** every unit.
2. **One unit at a time.** Do not start the next prompt until the current one
   passes `flutter analyze lib` (clean) and `flutter test` (no new failures).
   The user runs on an **Android emulator** — never propose `flutter build apk`;
   verify with `flutter run`. Do **not** run `dart format` (house style is old
   dartfmt, unenforced).
3. **Standards (hard):** `ConsumerWidget`/`ConsumerStatefulWidget`; no `dynamic`;
   no raw hex/px — use `Theme.of(context).colorScheme.*`,
   `AppSemanticColors`, `context.getRSize(n)`, `context.getRFontSize(n)`,
   `AppRadius.*`; icons via `FontAwesomeIcons.*`; feedback via `AppNotification`
   (never raw `SnackBar`); money is **kobo (`int`)**, format with `formatCurrency`
   from `lib/core/utils/number_format.dart`.
4. **Architecture invariants:** read Drift first (offline-first); **every cloud
   write goes through the DAO → `sync_queue` outbox** (the existing DAOs/services
   already do this — call them, never call Supabase directly from a feature);
   **wallet/supplier ledgers are append-only** (corrections are new rows, never
   UPDATE/DELETE); **permissions are data** — gate with `hasPermission(ref, '<key>')`,
   hide-don't-block (omit the widget entirely, never show a disabled version).
5. **Bottom insets:** pushed full-screen sub-screens use `context.deviceBottomPadding`
   for sticky footers; modal sheets use `context.deviceBottomInset`. Never stack a
   `viewInsets.bottom` wrapper with `deviceBottomInset`.
6. **After each unit:** add a dated entry to `BUILD_LOG.md`, update
   `CONTEXT/progress-tracker.md`, and update any other context file the unit
   changed (new screen/flow → `project-overview.md`; new token/pattern →
   `ui-context.md`).
7. **Verify your own output** — run `flutter analyze` and read the real diff;
   don't trust a self-report.

### Shared API / provider reference (use these exactly)
- DB: `ref.read(databaseProvider)` → `AppDatabase`.
- Active staff id: `ref.read(authProvider).currentUser?.id`.
- Active store (single source, §12.1): `ref.watch(lockedStoreProvider).value`
  (a `String?`; `null` = "All Stores"). Selectable stores:
  `ref.watch(selectableStoresProvider)` (`List<StoreData>`). Store label:
  `ref.watch(activeStoreLabelProvider)`.
- Suppliers (canonical, DB-backed): `ref.watch(allSuppliersProvider)` →
  `AsyncValue<List<SupplierData>>`. **Use this, not** the legacy
  `supplierServiceProvider`/`Supplier` model used by the old delivery sheet.
- Supplier ledger write: `ref.read(supplierAccountServiceProvider).recordInvoice(
  supplierId:, amountKobo:, dateReceived:, staffId:, storeId:, note:)`
  (in `lib/shared/services/supplier_account_service.dart`).
- Supplier crate writes (in `lib/shared/services/supplier_crate_service.dart`):
  `recordReceipt(...)` = full crates arrived (we owe supplier N empties);
  `recordReturn(...)` = empties handed back (reduces what we owe). Access via
  `ref.read(supplierCrateServiceProvider)`.
- Stock increment + inventory history: `db.inventoryDao.adjustStock(productId,
  storeId, delta, note, staffId)` — appends a `stock_transactions` row (this IS
  the Inventory → History entry, §11) and updates the inventory cache.
- Activity log: `db.activityLogDao.logActivity(action:, description:, staffId:, storeId:, entityType:, entityId:)` or `ref.read(activityLogProvider).logAction(title, detail)`.
- Permission keys (confirmed present): `products.add` (gates the whole Receive
  Stock flow), `products.edit_buying_price` (gates editing a buying price),
  `products.edit_price`, `stock.view`.
- Product fields on `ProductData`: `id`, `name`, `unit`, `buyingPriceKobo`,
  `retailerPriceKobo`, `wholesalerPriceKobo`, `manufacturerId`,
  `emptyCrateValueKobo`, `trackEmpties`, `categoryId`, `isDeleted`.
- Grid stock stream: `db.inventoryDao.watchProductDatasWithStockByStore(storeId)`
  → `List<ProductDataWithStock>` (`.product`, `.totalStock`).

### Mirror these existing files (copy their patterns, do not reuse for sales)
- POS grid screen: `lib/features/pos/screens/pos_home_screen.dart`
- Grid widget: `lib/features/pos/widgets/product_grid.dart`
- Category chips: `lib/features/pos/widgets/category_filter_bar.dart`
- Grid controller: `lib/features/pos/controllers/pos_controller.dart`
- Cart screen: `lib/features/pos/screens/cart_screen.dart`
- Checkout: `lib/features/pos/screens/checkout_page.dart`
- Old (legacy, single-supplier-per-line) delivery sheet — the thing this
  replaces: `lib/features/deliveries/widgets/receive_delivery_sheet.dart`
- Add Product form + how it's launched: `lib/features/inventory/screens/add_product_screen.dart`,
  and the FAB at `lib/features/inventory/screens/inventory_screen.dart:331`
  (`_showAddProductSheet` at ~:2174, pushed via `Navigator.of(context).push(MaterialPageRoute(...))`).

### Suggested new file locations (new feature slice)
```
lib/features/receiving/
  state/receive_cart.dart                 # transient in-memory cart (Notifier)
  screens/receive_stock_screen.dart       # the grid (Unit 1)
  screens/receive_cart_screen.dart        # cart review (Unit 3)
  screens/receive_checkout_screen.dart    # invoice/checkout + confirm (Unit 4)
  widgets/receive_product_grid.dart       # grid widget (Unit 1, mirror of product_grid)
  widgets/new_product_card.dart           # pinned "+" tile (Unit 1)
lib/shared/services/receive_stock_service.dart   # atomic confirm (Unit 4)
```
(Confirm the folder name against existing conventions before creating; `receiving`
is suggested. Do not put two classes in one file. Test files mirror under `test/`.)

---

## PROMPT 1 — Branch + Receive cart state + Receive Stock grid & entry point

> **Goal (one sentence):** create the working branch and build the POS-style
> Receive Stock grid screen (with a pinned "+" New Product tile, category chips,
> search, tap-to-add) reached from a new split FAB on the Inventory → Products tab.

**Step 0 — branch.** From `main`, run `git checkout -b feat/receive-stock`. Do all
work for every unit on this branch. (Repo carries large uncommitted trees — never
`git checkout` a dirty file to undo; re-edit or stash.)

**Build the transient receive cart** — `lib/features/receiving/state/receive_cart.dart`:
- A Riverpod `Notifier`/`NotifierProvider` (e.g. `receiveCartProvider`) holding an
  in-memory `List<ReceiveCartLine>` (define a small typed `ReceiveCartLine`:
  `productId`, `productName`, `unit`, `qty (int)`, `buyingPriceKobo`,
  `manufacturerId`, `trackEmpties`). **Do NOT reuse `CartService`** — that is the
  sales cart (price tiers, discounts, customers, wallet, store-keyed singleton)
  and none of it applies to a purchase.
- Methods: `addOrIncrement(ProductData)` (qty +1, combine by productId — see
  §3.2, §17.2), `setQty(productId, qty)` (qty 0 removes — §6.7), `remove`,
  `clear`, derived `lineCount`, `totalUnits`, `invoiceTotalKobo` = Σ(buyingPriceKobo×qty).
- It is transient: cleared on confirm and when the flow is abandoned. (§17.3 —
  preserving across app-leave is optional; a reset is acceptable.)

**Build the grid screen** — `lib/features/receiving/screens/receive_stock_screen.dart`
(mirror `pos_home_screen.dart` + `pos_controller.dart`, simplified):
- Scope products to the **active store** via `watchProductDatasWithStockByStore(
  ref.watch(lockedStoreProvider).value ?? selectable.first.id)` (§2.6). If there
  is no product, still render the "+" tile (§2.7, no crash).
- Category chips (reuse `CategoryFilterBar`) + a search field (mirror POS). Filter
  by category AND search together (§2.8–2.15). The "+" tile stays pinned at
  position 0 through every filter/search/scroll state (§2.2, §2.9, §2.13).
- Grid widget — `lib/features/receiving/widgets/receive_product_grid.dart`
  (mirror `product_grid.dart`): each tile shows **name, current stock qty, unit**
  (§2.3). **Out-of-stock products are visible AND tappable here** (the opposite of
  POS, which greys them out — §2.4, §2.5). A live qty **badge** on each tile
  reflects its quantity in the receive cart (§3.1, §3.4).
- Pinned first tile — `lib/features/receiving/widgets/new_product_card.dart`:
  a "+" New Product card (Unit 2 wires its action; for now it can be a stub that
  no-ops or shows a TODO — but it must render at index 0).
- **Tap behaviour:** tap a tile → `receiveCart.addOrIncrement(product)`; tapping
  again increments with **no ceiling** (§3.2, §3.3, §17.1 — receiving is not
  capped by stock). A bottom bar / FAB shows the running cart count and routes to
  the cart screen (Unit 3 builds the cart; here just wire the button — it can be a
  stub until Unit 3). Cart persists across chip/search changes (§3.7, §3.8).

**Entry point — split FAB on Inventory → Products tab**
(`lib/features/inventory/screens/inventory_screen.dart` ~:331):
- Replace the single `AppFAB('Add Product')` with a **split/expandable FAB** that
  offers two actions: **"Add New Product"** (existing behaviour — `_showAddProductSheet`)
  and **"Receive Stock"** (push `ReceiveStockScreen` via `Navigator.of(context).push(
  MaterialPageRoute(...))`, same pattern as `_showAddProductSheet`). No legacy
  single-action Add Product button may remain (§1.6–1.8).
- Gate the whole split FAB on `hasPermission(ref, 'products.add')` AND the
  products tab being active (it already checks `onProductsTab && canAddProduct`).
  So: CEO + Manager-with-`products.add` see it; Manager-without, Cashier, Stock
  keeper see **no FAB at all** (§1.1–1.5, §14). Hide, don't disable.

**Acceptance (map to list):** Section 1 (entry/FAB), Section 2 (grid layout),
Section 3 (tap-to-add). **Defer to later units:** the "+" card action (Unit 2),
the cart screen itself (Unit 3).

**Done-gate:** `flutter analyze lib` clean; `flutter test` no new failures;
BUILD_LOG + progress-tracker updated; new screen noted in `project-overview.md`.

---

## PROMPT 2 — Long-press to edit + "+" New Product card

> **Goal:** long-pressing a grid tile opens the product form prefilled (edit,
> incl. buying-price gated), and the pinned "+" tile opens a blank product form;
> on save the product drops into the receive cart.

**Investigate first:** read `lib/features/inventory/screens/add_product_screen.dart`
and `lib/features/inventory/widgets/update_product_sheet.dart`. Decide which form
supports an **edit/prefill mode** for an existing product. Reuse the existing edit
form for long-press (do not build a third product form). If neither cleanly
supports "open prefilled for product X and return the saved product," extend the
existing one minimally (add an optional `ProductData? existing` / prefill param +
an `onSaved(ProductData)` callback) — **do not duplicate** the form.

**Long-press a tile** (§4) — wire `onLongPress` in the grid widget from Unit 1:
- Opens the product form **prefilled** with that product's current values
  (name, buying/retailer/wholesaler prices, category, manufacturer, unit,
  low-stock alert, etc. — §4.3), whether or not it's already in the cart
  (§4.1, §4.2). Same validation as the normal form (§4.9).
- On save: persist the edits to the product, then add the product to the receive
  cart (or +1 if already present — §4.4–4.7). Cancel returns to the grid with the
  cart and product record unchanged (§4.8).
- **Buying-price edits are gated on `hasPermission(ref, 'products.edit_buying_price')`
  (§4.10, §14.6):** if the user lacks it, the buying-price field is hidden/read-only
  and a buying-price change can never be saved from this path (render-gate + a
  write-boundary re-check in the save handler). A buying-price change must persist
  to `buyingPriceKobo` (§12.1) and write an **Activity Log** entry with before/after
  values (§4.12, §12.4). No spurious write when the price is unchanged
  (§4.7, §12.5). Past orders are **not** retro-changed (§12.3 — buying price is
  snapshotted on order lines; just don't touch historical rows).

**"+" New Product card** (§5):
- Tapping the pinned "+" tile opens the **blank** `AddProductScreen`. On save the
  new product appears in the grid immediately (streams; §5.3) and drops into the
  receive cart with qty 1 (§5.2, §5.4). Cancel creates nothing (§5.5). All Add
  Product validation applies (§5.6). A new Bottle + "Track empty crate returns"
  product works and is immediately tappable to increment (§5.7, §5.8).

**Acceptance:** Section 4, Section 5, Section 12 (buying-price persistence/logging).

**Done-gate:** analyze clean; tests pass; BUILD_LOG + progress-tracker updated.

---

## PROMPT 3 — Receive cart review screen

> **Goal:** build the cart-review screen (a mirror of the POS cart) for the
> receive flow: line items at buying price, an auto Invoice Total, qty edit,
> remove, clear — **no discount, no customer**.

**Build** `lib/features/receiving/screens/receive_cart_screen.dart` (mirror the
structure/components of `lib/features/pos/screens/cart_screen.dart`, but read from
`receiveCartProvider`, not `CartService`):
- One row per line showing **product name, quantity, buying price per unit, line
  total** (§6.2). Subtotal = Σ line totals (§6.3). **Invoice Total = Σ(buying ×
  qty)**, auto-calculated, no manual entry (§6.4).
- Increase/decrease qty inline → line total + Invoice Total update immediately
  (§6.5, §6.6). Decreasing to 0 removes the line (§6.7). Explicit remove (§6.8).
  **Clear Cart** action behind a confirmation prompt (§6.9). Empty-state message
  when no lines, and **block "Proceed to Checkout" when empty** (§6.10).
- **No discount field** anywhere (§6.11). **No customer card** — the supplier is
  chosen at checkout, not here (§6.12).
- "Proceed to Checkout" pushes the checkout screen (Unit 4 builds it; here wire the
  button — it can route to a stub until Unit 4 lands).
- Wire the Unit 1 grid's cart button/FAB to push this screen.

**Acceptance:** Section 6.

**Done-gate:** analyze clean; tests pass; BUILD_LOG + progress-tracker updated.

---

## PROMPT 4 — Checkout/Invoice screen + crate capture + atomic confirm (core write)

> **Goal:** build the invoice/checkout screen (supplier picker, read-only invoice
> total, date, note, store label, empties-returned capture) and an **atomic**
> confirm that increments stock, posts the supplier invoice, records crate
> movements, and writes the activity log — all-or-nothing.

**Checkout screen** — `lib/features/receiving/screens/receive_checkout_screen.dart`
(mirror `checkout_page.dart` shape; this is a purchase, not a sale):
- Header reads **"Invoice"** (not "Checkout"/"Receipt") (§7.2).
- **Supplier picker, required and searchable** over `ref.watch(allSuppliersProvider)`,
  **single-select**, **excluding soft-deleted suppliers** (`isDeleted`/active filter)
  (§7.3–7.6, §13.4, §17.8). Cannot confirm without one (§6.6/§7.6 validation).
- **Invoice Total** shown prominently and **read-only** (§7.7, §7.8) — value from
  `receiveCart.invoiceTotalKobo`.
- **Date** field defaulting to today, editable for backdating (§7.9, §7.10).
- **Note** field, optional (§7.11).
- Read-only **"Receiving for: [Store Name]"** label from `activeStoreLabelProvider`
  — not editable here (§7.12, §15.6).
- Line-items summary (§7.13). **No payment-method picker** (§7.14) and **no
  "supplier payment recorded" notification** (§16.1, §16.2) — this posts an
  invoice (debt), not a payment.
- **Empty-crates-returned capture (the extra requirement):** for each line where
  `product.unit == 'bottle' && product.trackEmpties == true`, show an optional
  numeric "Empty crates returned to supplier" field (default 0, max = sensible).
  Lines without bottle tracking show no such field (gate on the same flag the rest
  of the app uses — compare `unit` case-insensitively; do **not** invent new crate
  semantics, mirror `supplier_crate_service.dart` / `receive_delivery_sheet.dart`).

**Confirmation dialog** (§8): on "Confirm", show a dialog before any write listing
supplier name, product count + total units, Invoice Total to be posted, the store
being stocked, and a clear warning that the total posts to the supplier's account.
Cancel = no writes, data intact (§8.7). Confirm = run the atomic commit (§8.8).

**Atomic confirm** — `lib/shared/services/receive_stock_service.dart`, one method
`confirmReceipt(...)` wrapping **all** writes in a single `db.transaction()` so it
is all-or-nothing (§9.8, §9.9). Drift nested transactions are savepoints, so it's
safe to call the existing DAO primitives inside one outer transaction. Per the
spec, for the chosen supplier + active store + chosen date + note:
1. **Increment stock per line:** `db.inventoryDao.adjustStock(productId, storeId,
   qty, 'Stock received', staffId)` — this also appends the `stock_transactions`
   row that IS the Inventory → History entry (§9.1, §9.2, §11). New products from
   the "+" card already exist; just increment (§9.2).
2. **Post one supplier Invoice Total** to the ledger:
   `supplierAccountServiceProvider.recordInvoice(supplierId:, amountKobo:
   invoiceTotalKobo, dateReceived: chosenDate, staffId:, storeId: activeStore,
   note:)` — append-only, store-stamped, dated, note-carrying (§9.3–9.6, §10).
   This is **cost of goods, not an expense** (it lives only on the supplier ledger
   — §10.4; do not also write an expense row).
3. **For each bottle+trackEmpties line:**
   - record **full crates received** = qty: `supplierCrateServiceProvider.recordReceipt(
     supplierId:, supplierName:, manufacturerId:, manufacturerName:, quantity: qty,
     staffId:, storeId:)` (we now owe supplier N empties — mirrors the old delivery
     sheet's supplier-crate receipt).
   - if "empties returned" > 0, record the **return**:
     `supplierCrateServiceProvider.recordReturn(... quantity: emptiesReturned ...)`
     (reduces what we owe). Both are append-only and net on the Supplier Details →
     Empty Crates tab.
4. **Activity Log** entry (§9.7): who, store, supplier, products/quantities,
   invoice total, timestamp. (The supplier services already log their own
   sub-actions; add one summary "Stock received" action for the whole receipt.)
5. **Do NOT** route through the Stock-keeper approval queue — this is a direct
   CEO/Manager action; stock updates immediately (§17.11).

**After confirm** (§9.10, §9.11): clear the receive cart, pop back to the Inventory
screen, show an `AppNotification` success banner. Updated quantities are visible
immediately (streams). Offline: every write above is a DAO/outbox write, so the
whole thing queues locally and syncs atomically when back online (§17.6, §9.12).
A large receipt (50+ lines, ₦50,000,000) must commit without overflow — totals are
`int` kobo (§17.4, §17.9).

**Acceptance:** Sections 7, 8, 9, 10, 11, 13, 16 + the crate-return requirement.

**Done-gate:** analyze clean; add a unit test for `ReceiveStockService.confirmReceipt`
(stock incremented, one invoice posted, crate receipt + return netted, atomicity
on a forced mid-write failure — §9.9); `flutter test` green; BUILD_LOG +
progress-tracker updated; document the new service/flow in `architecture.md`
(storage/write path) and `project-overview.md`.

---

## PROMPT 5 — Role guards, multi-store, edge cases, legacy cleanup, verification

> **Goal:** harden access + multi-store behaviour, cover the edge cases, remove
> legacy delivery remnants, and run the feature against the full verification list.

**Route/flow guards (§14):**
- The Receive Stock screen must self-guard: render an access-denied body if
  `!hasPermission(ref, 'products.add')` so deep-link/back-stack navigation can't
  reach it for Cashier/Stock keeper/Manager-without-`products.add` (§14.4, §14.5,
  §14.7) — defense-in-depth on top of the hidden FAB. All gated elements are
  **hidden, not greyed** (§14.8).
- Re-confirm the buying-price write-boundary re-check from Unit 2 (§14.6).

**Multi-store (§15):**
- Confirm a receipt stocks only the active store and stamps that store on the
  invoice + history (§15.1–15.5). The "Receiving for: [Store]" label is correct
  grid→checkout (§15.6).
- **Store lock for the duration of the flow:** if the active store changes
  mid-flow (nav drawer), either warn the user or lock the store so the in-flight
  receipt can't silently change its store assignment (§15.7). Pick the simpler
  safe option (capture the store id when the flow starts; if `lockedStoreProvider`
  differs at confirm, warn/abort) — do not silently re-stamp.

**Edge cases (§17):** rapid 20× tap = qty 20 (§17.1); tap-then-long-press combines
into one line, not a duplicate (§17.2); duplicate product name handled by the
existing Add Product uniqueness rule (§17.5); soft-deleted supplier never in the
picker (§17.8); flow does not enter the Stock-keeper approval queue (§17.11);
expiry date untouched by a receipt (§17.10).

**Legacy cleanup (§17.12):** there must be **no Track Shipments / legacy delivery
remnants** in this flow — no Pending/Received tabs, no "expected delivery"
fields, no "Mark Received" buttons. Audit `lib/features/deliveries/` and the old
`receive_delivery_sheet.dart`: if it is the superseded single-supplier-per-line
delivery entry and nothing else routes to it, remove it and its now-dead wiring
(grep for `ReceiveDeliverySheet`, `deliveryServiceProvider`, the `setIndex(9)`
"Deliveries" tab). **Before deleting anything**, grep all call sites and confirm
it's truly dead — if it's still reachable from another live screen, report that
instead of deleting. Delete dead code; don't leave it commented out.

**Verification & docs:**
- Walk the full `receive_stock_verification_list_v2.md` (122 checks) on the
  emulator via `flutter run`; record pass/fail per section in BUILD_LOG.
- `flutter analyze lib` clean; `flutter test` green (note any pre-existing
  unrelated failures, e.g. `invite_staff_sheet_test`).
- Update `CONTEXT/progress-tracker.md` (move Receive Stock to Completed with the
  section coverage), `project-overview.md` (feature in scope), and `ui-context.md`
  if the split FAB / receive grid introduced a reusable pattern.
- Open a PR from `feat/receive-stock` summarising the 5 units and the
  verification results.

**Acceptance:** Sections 14, 15, 17 + full-list verification + docs.

**Done-gate:** all of the above true; PR opened.
