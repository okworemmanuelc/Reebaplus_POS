# Barcode scanning ships now: camera scanner, an optional product barcode, soft uniqueness

**Status:** accepted (2026-07-11)

Barcode scanning was explicitly deferred (project-overview Out of Scope; ADR
0015 also defers "barcode/IMEI scanning"). Two things changed: Pharmacy is now
one of the three offered industries (ADR 0015 amendment), and Pharmacy is the
canonical barcode use case; and the product owner asked to replace the POS cart
FAB with a scan button. So the deferral is lifted for a **basic** cut.

Today there is nothing to build on: products carry **no** barcode/SKU field, and
the only barcode dependency (`barcode_widget`) *renders* barcodes — there is no
camera scanner. The cart FAB (`_buildCartFab`, phone-only, shown only when the
cart is non-empty) is *not* the sole cart entry point — the bottom-nav cart tab
already reaches the cart — so removing the FAB strands no one.

Decisions locked (grilled 2026-07-11):

- **Build one-shot scanning now; defer continuous.** The first cut is one-shot:
  tap scan → camera opens → decode one barcode → the matching product is added to
  the cart → camera closes. Continuous/rapid scanning (camera stays open,
  many items in a row, with double-read debounce) is a later slice. Rationale:
  ships sooner, de-risks the native camera integration, and covers the common
  case; rapid scanning is a throughput optimisation on top.

- **Add `products.barcode` — nullable text, optional, synced.** One optional
  barcode per product, on the shared products model (client Drift column + cloud
  migration + one sync-registry entry). Populated on the add/edit product form,
  by typing or scan-to-fill.

- **Soft uniqueness, no hard DB constraint.** A `UNIQUE (business_id, barcode)`
  constraint is **rejected**: two offline tills could assign the same barcode
  independently, and the constraint would raise `23505` on push and jam the
  outbox (invariant #12 / the kobo-column and order-number lessons). Instead the
  add/edit form *warns* if the barcode already exists on another product, and POS
  lookup takes the first match. Determinism is a UX nicety here, not a money
  invariant, so soft handling is the right trade.

- **Scanner = `mobile_scanner`.** A camera-based scanner (MLKit / AVFoundation)
  with a runtime camera permission and manifest entries on Android/iOS. This is a
  real native dependency, accepted as the cost of the feature. No other product
  behaviour depends on the camera.

- **POS: replace the cart FAB with an always-visible scan button.** The scan
  button is *not* gated on a non-empty cart (unlike the old FAB) because scanning
  is an input method used *before* the cart has items. Cart access remains the
  bottom-nav cart tab. On scan: look up the barcode among the active store's
  sellable products; **found** ⇒ reuse the existing `_addToCart` so stock,
  out-of-stock, and price-tier rules apply unchanged; **not found** ⇒ a toast plus
  an offer to open Add Product with the barcode pre-filled.

- **No new permission.** Scanning is just another path to add to cart, available
  to anyone who can use the POS; assigning a barcode rides the existing
  product-edit gate. Rejected: a dedicated scan permission (nothing to protect
  beyond what POS/product-edit already gate).

## Amendment (2026-10-01, PRD #316)

The scan-to-cart loop (PRD #316, slices #317–#321) revisits four decisions
above. The rest of this ADR (the optional synced `products.barcode`, soft
uniqueness with no `UNIQUE (business_id, barcode)`, `mobile_scanner`, no new
permission for scanning itself) stands.

- **Continuous scanning is no longer deferred.** The scanner stays open until
  the cashier closes it. Each read freezes the camera and opens the tap-and-hold
  "Add to Cart" quantity sheet over it; confirming or cancelling resumes the
  camera, and the same code is ignored for about 1.5 s after resuming. The
  first slice (#317) keeps the one-shot camera but already routes every found
  product through the quantity sheet instead of adding 1, and gives a clear
  message instead of a sheet when the product can't be sold here (out of stock
  at this store, all of it already in the cart, or switched off for sale — the
  lookup ignores `isAvailable`, so the resolver checks it).
- **Duplicates show "Which one?" instead of taking the first match (#318).**
  Barcodes stay softly unique, but when more than one product carries the
  scanned code the cashier picks from a short list (name, price at the active
  tier, stock in this store). POS lookup uses `findProductsByBarcode` (every
  match); the single-match `findProductByBarcode` (first business-scoped,
  non-deleted match) stays for the add/edit collision warning.
- **Unknown-barcode routing is permission-aware.** Someone holding neither
  gate (e.g. a Cashier) gets "No product has this barcode. Ask a manager to add
  it." Otherwise the choice offers **Add as new product** (`Gates.addProduct`)
  and/or **Link to an existing product** (`Gates.editProductPrice`, which
  saves only the barcode). Each option shows only with its gate; with just
  one gate the choice still shows with that single option. Add as new (#320)
  opens Add Product pre-filled; Link (#321) searches the business's products
  by name, asks "This replaces barcode ‹old› on ‹name›. Continue?" before
  overwriting a different barcode, and writes through a dedicated
  barcode-only DAO write (`setProductBarcode`, full-row enqueue) — never the
  general product update, which would clear the manufacturer and category.
  Either way the product then goes straight to the quantity sheet when this
  store has stock. Linking a code that another product also carries is
  allowed (soft uniqueness); the "Which one?" list handles it on the next
  scan.
- **Scanning is for all business types**, not only Pharmacy and Supermarket.
