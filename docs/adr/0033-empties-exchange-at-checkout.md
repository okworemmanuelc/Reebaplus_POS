# Empties handed over at Checkout are netted inside the sale

**Status: accepted** (#649, closes audit item B4 in `CRATE_TRACKING_AUDIT.md`,
2026-11-01).

A customer who swaps empties for full crates at the counter used to be booked as
owing them, and the sale sat in Pending until someone ran Confirm. A walk-in's
swap left no record at all until then.

## Decision

Checkout takes an **Empties Exchange**: per brand, the empties returned now.
`outstanding = crates in this sale − empties returned` (`crate_exchange.dart`).
Every brand at 0 and the order is born `completed` with no confirmer. Any brand
above 0 and it is born `pending`. Nothing entered is the old behaviour.

**Netted, not issue + return.** `createOrder` credits the Empties Pool with the
returned crates and writes `order_crate_lines` and the `issued` row for the
outstanding count only; a brand at 0 gets neither. The alternative was to issue
everything and immediately run a return, which would need a Confirm-shaped
settlement inside Checkout, a deposit charged and refunded in one breath, and a
crate-debt alert for debt that never existed. Netting is one atomic write that
works offline, and Confirm, deposit settlement and crate debt need no change
because they only ever see the outstanding crates.

The deposit is charged on outstanding crates only. Returned counts cannot exceed
this sale's crates per brand: old empties go through Record Crate Return, and
"nothing left" means this order, not the customer's overall crate balance.

**The exchange row is an ordinary pool row.** `adjusted`, store-stamped,
customer-less, `reason = checkout_exchange`, with its own deterministic id
(`crate_pool:<order>:<mfr>:checkout_exchange`) so a later Confirm's `adjusted`
credit cannot collide with it. It needs no Drift or cloud migration:
`pos_record_sale_v2` already takes `p_status`, `crate_ledger.reason` has no
CHECK, and the v2 before/after queue diff already holds the row with the sale.

**A sale now writes a pool row, so reversals undo one.** `reverseExchangeEmpties`
appends a negative `checkout_exchange_reversal` row: enqueued for a Pending
refund, local-only for a rejected sale. The reversal row keeps a fresh id, unlike
the exchange row: a refund that loses the first-reversal race (ADR 0032) is
withdrawn, and a shared id would delete the winner's row on the losing phone.
`withdrawRejectedReversalRows` moves the pool projections back for these rows.

The exchange writes no `manufacturers` outbox row, unlike `addEmptiesToPool`. The
scalar is off the push set, and a row held behind the sale could swallow a real
manufacturer edit that coalesced into it.

## Consequences

**A crate-bearing sale that completes at checkout cannot be refunded** (and,
since #656, that is every walk-in crate sale). Pending
refund needs `pending`, and Return (`returnRefusal`) refuses anything with crate
history. That matches every Confirmed crate sale today, except that this sale
never sits in Pending first. Kept on purpose.

A walk-in has no crate line, so Confirm's modal subtracts
`exchangeEmptiesForOrder` from the quantity it rebuilds out of the order's items.

A crate-tracked bottle with no manufacturer has no crate line and cannot be
counted, so it does not stop a sale completing.

The flag-held v2 `pos_cancel_order` path still writes no crate rows, so that hold
(ADR 0020 follow-up in `markCancelled`) now covers the exchange too.

## Walk-ins return everything (#656), 2026-11-02

A walk-in has no one to chase for the empties, and a Pending walk-in sale has no
customer to hold the debt against. So a walk-in crate-bearing sale must return
ALL empties per brand at Checkout. A blank count is 0 entered. If any brand is
short, Confirm Payment refuses with `A walk-in must return all 5 Star empties
(3 entered).` (first short brand; `walkInExchangeShortfall` in
`crate_exchange.dart`). A walk-in crate sale is therefore always born
`completed` and never reaches Pending. Registered customers are unchanged: a
part exchange still goes to Pending.

The write boundary enforces it too: `OrderCommands.checkout` throws a
`StateError` with the same text before any write, so no other caller can book a
Pending walk-in. A walk-in whose crate-tracked bottles have no manufacturer has
nothing countable (rule above) and is born `completed`, not refused. Walk-in
orders already in Pending keep working through Confirm.

Consequence: every walk-in crate sale now completes at checkout, so none can be
refunded (the Pending refund path needs `pending`, and Return refuses crate
history).
