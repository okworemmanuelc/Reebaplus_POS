# Brief — Custom price floor at the CEO-allotted discount cap

> Executor prompt. Read `context/architecture.md` (Invariant #4 outbox, #6
> permissions-are-data) and `context/code-standards.md` before writing code.
> This touches one feature folder only (`lib/features/pos/`) + the cart service.
> Update `context/progress-tracker.md` when done.

## Goal (one sentence)

When a user sets a **custom price** on a cart line (`sales.set_custom_price`),
the price may not drop below what the role's CEO-allotted **maximum discount**
would already permit — i.e. a custom price can never be a back-door to a deeper
discount than the role is allowed.

## Background — current behaviour

- `lib/features/pos/widgets/edit_item_modal.dart` already supports a custom unit
  price (`_customPriceCtrl`, gated on `hasPermission(ref, 'sales.set_custom_price')`)
  and a separate role-capped discount (`currentUserMaxDiscountPercentProvider`,
  via `_resolveDiscount` which clamps to `maxPercent`).
- **The gap:** the custom price field accepts *any* positive value (see
  `effectiveUnitPriceKobo` at ~line 236). A user can type a custom price far
  below `catalog × (1 − maxDiscount)` and bypass the discount cap entirely.
- The discount cap already auto-snaps the percent input back to the cap
  (`resolved.cappedByRole`, ~line 246) and the qty field auto-snaps to stock
  (~line 225). **Mirror those patterns** for the custom-price floor.

## The rule

Define the per-unit floor:

```
floorKobo = round(catalogUnitPriceKobo * (100 - maxPercent) / 100)
```

- `catalogUnitPriceKobo` = the line's designated/catalog price
  (`widget.item['catalogPriceKobo']`, already read in build()).
- `maxPercent` = `ref.watch(currentUserMaxDiscountPercentProvider)` (already read).
- If `maxPercent == 0` (role gets no discount), `floorKobo == catalogUnitPriceKobo`
  → a custom price may not go below the designated price at all. Correct.

A custom price below `floorKobo` is clamped up to `floorKobo`.

> Decision to confirm with requester (record in progress-tracker, recommend
> option A): **double-dip** — discount applied *on top of* a custom price. With
> the floor on the custom price alone, custom=floor + max-discount could still
> dip below the role allowance.
> - **Option A (recommended):** the floor governs the **effective unit price
>   after line discount**, not just the typed custom price. Compute the
>   post-discount effective unit price and clamp the whole thing to `floorKobo`.
>   Simplest robust guarantee: total effective price ≥ floor.
> - **Option B:** floor the typed custom price only; leave discount independent.
>   Lighter, but allows the combined back-door.
> Implement A unless the requester chooses B.

## Implementation steps

### Step 1 — Compute and enforce the floor in the modal
- [ ] In `_EditItemModalState.build` compute `floorKobo` from `catalogUnitPriceKobo`
      and `maxPercent`.
- [ ] When `hasCustomPrice` and `customKobo < floorKobo`, auto-snap the field to
      `floorKobo` using the exact post-frame pattern already used for the discount
      cap (`WidgetsBinding.instance.addPostFrameCallback`, guard `mounted` and
      "already at cap" to avoid loops). Format with `_trimNum(floorKobo / 100.0)`.
- [ ] Clamp `customKobo`/`effectiveUnitPriceKobo` to `>= floorKobo` for the live
      line-total math so the displayed total never reflects a sub-floor price even
      for the frame before the snap lands.
- [ ] (Option A) After computing `resolved.discountKobo`, ensure the effective
      unit price after discount (`effectiveUnitPriceKobo - discountPerUnit`) is
      `>= floorKobo`; if not, reduce the discount so the line bottoms out exactly
      at `floorKobo`. Reuse `_resolveDiscount`'s clamp style.

### Step 2 — Add a clear hint
- [ ] In `_customPriceSection`, when a snap occurs (custom price was below floor)
      show a one-line note in the warning style already used by the discount cap
      ("Maximum discount is X%. Capped."), e.g.
      `'Lowest allowed price is <floor> (max discount X%).'`. Use existing
      token-based text styling — no raw hex/sizes (see code-standards "Styling").

### Step 3 — Re-check at the write boundary (defense in depth)
- [ ] In `lib/shared/services/cart_service.dart` `setCustomPrice`, re-clamp the
      incoming `customPriceKobo` to the same floor before persisting, so a future
      caller (or a stale frame) can never store a sub-floor price. The floor needs
      `catalogPriceKobo` (already on the line) and `maxPercent` — pass `maxPercent`
      into `setCustomPrice` (the modal already has it) rather than reading
      permissions inside the service (services don't read Riverpod;
      see architecture layer rules). Document the parameter.
- [ ] Confirm the existing discount re-clamp on the line still runs after the
      custom price changes (it does today via `setLineDiscount`); ensure ordering
      keeps the line ≥ floor.

### Step 4 — Tests
- [ ] Add cases to `test/pos/cart_custom_price_test.dart`:
  - custom price below floor is clamped to floor (maxPercent > 0).
  - maxPercent == 0 → floor == catalog → any below-catalog custom price clamps to
    catalog.
  - (Option A) custom price at floor + attempted max discount does not dip below
    floor (combined back-door blocked).
  - custom price above catalog is allowed unchanged (overpricing is fine).

### Step 5 — Docs
- [ ] Note the rule in `progress-tracker.md` (under the §13.4 custom-price entry)
      and add a dated `BUILD_LOG` entry.

## Acceptance criteria
- With role max discount = 10% and a ₦1,000 item, the custom-price field will not
  accept (snaps up from) anything below ₦900; the hint explains why.
- With role max discount = 0%, the custom price cannot go below the designated
  price.
- (Option A) No combination of custom price + discount yields an effective unit
  price below `catalog × (1 − maxDiscount)`.
- `flutter analyze` clean; `flutter test` (pos suite) green.

## Out of scope
- Changing how `max_discount_percent` is configured (role settings screen).
- The `sales.set_custom_price` permission itself (already shipped).
- Quantity / fractional-sales logic.
