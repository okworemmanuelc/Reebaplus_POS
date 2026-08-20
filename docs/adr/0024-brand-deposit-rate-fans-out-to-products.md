# The brand deposit rate is the only rate; the product column is a fallback

**Status:** accepted (2026-08-20)

Confirms ADR 0023 rule 2 — `manufacturers.deposit_amount_kobo` is the single
canonical per-crate rate — and records what the #186 Manage-sheet rebuild must
therefore *not* do.

For most of this codebase's life the rule was true of the supplier end and false
of the customer end. What a sale **recorded** was the manufacturer rate,
snapshotted onto `order_crate_lines.deposit_rate_kobo` (`daos_orders.dart`).
What the customer was **charged** was `SUM(products.empty_crate_value_kobo ×
qty)` off the cart's line snapshots. Nothing held the two together, so editing a
brand's deposit changed every later sale's recorded rate without changing what
POS collected, and the resulting `paid < rate × crates` reads as a **part
deposit** in `crate_return_modal.dart` — sending a full-deposit sale down the
partial settlement path.

`CartCrateSync` + `CatalogDao.resolveCrateConfig` / `watchCrateConfig` close
that gap at the read side: a cart line's deposit resolves to the brand's
`depositAmountKobo`, live, re-stamped whenever `products` or `manufacturers` is
written. `products.empty_crate_value_kobo` is read **only** for a product with
no manufacturer, which has no brand rate to read.

## Decision

**A brand's deposit rate is written in exactly one place —
`manufacturers.deposit_amount_kobo` — and read live from there. Nothing fans it
out to product rows.** The rebuilt Manage sheet writes that column and stops.
`products.empty_crate_value_kobo` is a **fallback for manufacturer-less
products**, not a mirror to maintain; a stale value in it is harmless because
nothing reads it while a manufacturer exists.

A rate of `0` on a brand means "not configured yet" and is never a reason to
fall back to the product column. The cart says so, and checkout names the
unrated brands before the sale completes.

## Considered and rejected

**Fan the rate out to every product of the brand on save.** This was the
standing recommendation until the live-resolution work landed, and it is now
the wrong shape: it writes a column the read path has deliberately demoted,
multiplies sync traffic by the brand's product count, and re-creates the
two-writers problem it was meant to solve — a product edit and a brand edit
would once again race for the same meaning.

**Leave the Manage sheet read-only and edit rates per product.** Rejected: with
live resolution the per-product value no longer even reaches the customer, so
this makes the brand rate unreachable rather than safe.

## Consequences

* The rebuilt Manage sheet's deposit field is a **one-column write**
  (`updateManufacturerDeposit`). It must not call
  `updateManufacturerEmptyCrateValue` "as well" — despite the name, that method
  writes the same manufacturer column, and having two entry points for one value
  is what produced the deleted sheet's two-boxes-one-column bug.
* A deposit change is still not free. Crates owed to suppliers and the daily
  reconciliation's crate figures are valued at *today's* rate, live and
  deliberately (`watchSupplierCrateDebt`, `recon_data.dart`), so raising a rate
  moves what the app says a supplier owes back by `crates × delta` the instant
  it saves. The sheet states that in the owner's own numbers and confirms before
  writing. Past sales are untouched — they hold the rate snapshotted at sale
  time.
* Retiring `products.empty_crate_value_kobo` altogether now needs only a rule
  that every crate-bearing product has a manufacturer. That is a separate issue
  and is not required by this one.
