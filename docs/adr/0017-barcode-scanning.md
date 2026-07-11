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
