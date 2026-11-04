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

## Addendum: Edit a completed sale (#713, PRD #707 slice 6)

CEO/Manager only (`Gates.editSale`, on the existing `sales.cancel` key; checked
at render and again in `OrderCommands.editCompletedSale`). Saving writes ONE
adjustment (`OrdersDao.editCompletedSale`) holding the DIFFERENCE:
- lowered/removed lines = minus lines, exactly a part return (same rows, same
  claim); raised/added lines = plus lines (positive quantity) at TODAY's price for
  the customer's tier, written like checkout (stock `sale` out, FIFO draw-down,
  crate issue / deposit, payment + wallet legs), all referencing the adjustment.
- Header total/net = added - returned goods; `amount_paid_kobo` stays
  `-paidShare` released from the sale (so paid-standing stays derivable). Plus
  lines are not returnable through the sale.
- Money (A added, G returned, P paid share of G): freed paid money covers A
  first, so only `R = max(0, P - A)` leaves via the #710 refund choice; net due
  (A - G) is collected (cash/transfer) with the rest charged to a named
  customer's balance; a walk-in must pay in full.
- Claim: only minus lines ride `p_lines`; an add-only edit sends an empty claim
  (the cloud RPC accepts it and still checks the sale is `completed`).
- Reports: `computeSalesSplitKobo` files an adjustment's plus lines under Sales
  and minus lines (+ discount share) under Returns, on the adjustment's day.
- Cloud `0249` makes the recost replay count adjustment PLUS lines (0247 skipped
  all adjustments). Not deployed.
- Edit slip: `buildReceiptLines(slipTitle:)` stamps "EDIT SLIP - ORD-..." (text
  print only). Out of scope: price edits, customer/store change, van sales adds.
- Refused edit (#732): the plus lines drew units from layers that already existed,
  so those layers are never withdrawn. The claim keeps the units per batch in
  phone-only notes (`_local`, removed before the RPC) and the undo adds them back;
  only the restore layers the edit created are withdrawn.
