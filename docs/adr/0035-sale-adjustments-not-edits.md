# Sale adjustments, not edits

**Status: accepted** (#712, PRD #707 slice 5, 2026-11-03). Builds on ADR 0005
(append-only costing) and ADR 0032 (first reversal wins).

A customer brings back 10 of 40 crates. The sale cannot be reversed (30 stayed)
and it must not be edited: its ledgers are append-only, the owner may already
have reviewed its day, and the cloud has accepted it.

## Decision

A part return is a NEW `orders` row, a **sale adjustment**:

- `orders.kind = 'adjustment'` (default `sale`, CHECK) and
  `orders.adjusts_order_id` = the sale (cloud FK; plain id locally, so a pulled
  adjustment never waits on its parent). Drift v105, cloud `0247`.
- Born `completed`, `created_at` = today, same customer / store, its own
  `ORD-…` number from the usual generator. Totals and discount are NEGATIVE
  (goods returned); `amount_paid_kobo` is `-paidShare`; the return reason rides
  in `cancellation_reason` (the table's only free-text slot, never "cancelled"
  on an adjustment).
- Its lines are `order_items` with MINUS quantities at the original unit price
  and cost, so `order_items.quantity` is now `CHECK (quantity <> 0)`. The sale
  line they return units of is named in the minus line's `price_snapshot`
  (`adjusts_line_id`); no extra column.
- Stock (`return`), cost layer, payment, wallet and crate rows all reference the
  ADJUSTMENT's id. The sale and everything already written for it stay as they
  were.

**Returnable** per line = the sale line's quantity minus every adjustment's
minus lines pointing at it. A return can never exceed it.

**Reports** need no new rule: `saleDayEntries` counts the adjustment +1 on its
own day, its lines are already negative, and `computeSalesSplitKobo` files a
negative `kind = 'adjustment'` entry under **Returns** (the sale day is
unchanged). Lists, counts and stats filter `kind = 'adjustment'` out: the
adjustment shows inside its parent ("Returned: …"), never as its own row.

**Money** (proportional to what was paid; goods value G, discount shared pro rata
over what is still standing, the last return takes the rest):
- G is reversed on the customer's account in full (`refund` credit).
- The paid share `G × paid-standing / goods-standing` leaves as a `refund` row
  (method picked) plus a `void` of the payment credit leg, or stays as credit
  ("Add to balance"). The unpaid rest just cancels debt.
- `paid-standing` = tendered `sale` rows minus `-amount_paid_kobo` of earlier
  adjustments, so two phones agree from rows alone.
- Deposit still held is released pro rata by crates in the deposit family.

**Crates** (`CratePoolDao.returnCratesForAdjustment`): returned crates of a
crate-tracked bottle first cancel what the customer still owes for the sale
(`adjusted`, `reason = order_part_returned`), any remainder hands empties back
(negative pool rows, exchange credits first, then Confirm's), never more than
was credited.

**Safety.** One transaction behind the #550 guard, but the claim is its own
cloud RPC: `pos_claim_sale_adjustment` locks the sale, sums every accepted
claim per sale line (cloud-only `sale_adjustment_claims`) and refuses a return
that exceeds what was sold (`adjustment_exceeds_returnable`) or a sale that is
no longer `completed` (`order_not_returnable`). It does not touch the sale's
header and it is not unique per sale, unlike `pos_claim_order_reversal`. The
full cancel's claim now refuses a sale that already has an adjustment, so a
phone that has not seen the part return cannot refund its goods twice. A refused
adjustment is withdrawn on the losing phone (`undoRejectedReversal` with the
adjustment id, which also removes the adjustment's own header and lines) and the
CEO and Managers are alerted.

**Full cancel is unchanged.** A full return of a sale with no adjustment stays
`markCancelled` (`cancelled`, ±1 days). Only a sale that already has an
adjustment finishes with a final adjustment.

The cloud cost recost (`pos_recost_product_store`) ignores adjustment orders in
its sale ledger: the parent's lines keep consuming their layers and the returned
units come back as their own restore layer (id derived from the minus line).

## Consequences

- Every phone must be on v105 before it pushes (`kind` / `adjusts_order_id`
  ride every `orders` upsert); deploy `0247` first.
- The web console must count adjustments in its sales figures (pos-parity).
- Editing a completed sale (slice 6) is the same record with plus lines.
