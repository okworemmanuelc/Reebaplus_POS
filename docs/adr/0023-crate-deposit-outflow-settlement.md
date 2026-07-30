# Crate deposits have two ends: money moves only when money moved

**Status:** accepted (2026-07-29)

PRD #155 built the crate deposit **inflow** leg properly. A customer pays a
deposit, it is held as its own money family, and it is released on Confirm or
Cancel or forfeited when crates never come back. That leg is sound.

The **outflow** leg — the deposit *we* pay a supplier for *their* crates, and its
settlement when we hand the empties back — was carved out of #155 and never
filed. Issue #203 files it. Both `MONEY_FLOW_AUDIT.md` (Stage 0) and
`CRATE_TRACKING_AUDIT.md` (§6.7) flag it as unmodelled app-wide.

What "unmodelled" understates, and what the #203 investigation found:

1. **The money never leaves the books.** `_appendSupplierMovement` writes a crate
   ledger row and a local balance cache. No `payment_transactions` row, no
   expense, no supplier-wallet entry. Hand a depot ₦180,000 and every money
   figure in the app reads exactly the same afterwards.
2. **The debt can only fall.** Receive Stock posts the *return* leg
   (`recordReturnToSupplier`) but there is no automated receipt leg —
   `recordReceiveFromSupplier` has exactly one call site in the app, a manual
   form on the supplier screen. Normal operation therefore drives
   `SUM(quantity_delta)` negative, and because `businessNetPositionKobo`
   *subtracts* `supplierCrateDebtKobo`, a negative debt **inflates** net worth.
3. **Two numbers that never meet.** Business worth uses a notional
   `qty × today's manufacturer rate`; the supplier screen uses actual money paid
   (`deposit_paid_kobo`, hand-typed). Nothing reconciles them and nothing
   notices when they disagree.
4. **A forfeit is reported as profit it isn't.** A kept customer deposit books
   as income (#176), but the crate belonged to a manufacturer and the app charges
   the customer the *same* `manufacturers.deposit_amount_kobo` it would owe the
   supplier. For any brand where a deposit was genuinely placed, a forfeit nets
   to **zero** — yet it is reported as a full gain.

## Decision

**Six rules. The spine of all of them is: a book entry appears only when money
genuinely moved; everything else is a shortfall figure.**

### 1. A Placed Deposit is the mirror of a Held Deposit — an asset, never an expense

Paying a supplier a crate deposit drops cash (it really left the drawer — the
reconciliation cash card means "what could I count right now") and raises a
**Placed Deposit** asset by the same amount. Business worth is unchanged, because
the money is still ours. It never touches profit, because it is refundable.

This is the exact opposite sign of the customer leg, which raises cash and
raises a liability. Booking it as an expense was rejected: profit would sag on
delivery days and spike inexplicably on the day a supplier relationship ends.

### 2. The rate is the manufacturer's; the balance is the supplier's

`manufacturers.deposit_amount_kobo` stays the single canonical per-crate rate —
it already is, and `crate_size_groups.deposit_amount_kobo` is a dead column with
zero readers that must not be revived. But the money is held per
`(supplier, manufacturer)` pair, which is how `supplier_crate_balances` is
already keyed, because only the supplier you actually paid can pay you back.

### 3. Crate money is per-manufacturer opt-in, defaulting to off

A **Crate Money Arrangement** lives on each manufacturer: `none` (swap only),
`per_delivery`, or `standing_float`. Every existing manufacturer defaults to
`none`, so no live tenant's figures move until an owner deliberately switches a
brand on. Real distributors run all three arrangements simultaneously across
their brands, so a single global model was never viable.

### 4. Losses are unattributed until settlement

Crates are fungible. When one goes missing the app does **not** guess which
supplier's it was — that would invent a fact and then argue with the supplier's
own records. Instead the loss becomes a brand-level **Crate Shortfall**: crates
owed minus empties on hand, valued at the manufacturer rate. It attaches to a
specific supplier only when you settle with them and come up short.

The same rule makes a `standing_float` coherent: lost crates eat float headroom
and raise the Shortfall, but move no money, because the supplier has not taken
anything yet. Money moves on real top-ups and payouts only.

### 5. A Shortfall is a warning until it is written off

A Shortfall is a *suspicion* — crates turn up behind the store, a driver returns
late, a count was wrong. Writing it off is the deliberate act of accepting the
loss, and **that** is when it hits profit, on that day, with a dated record of
who accepted it. Same reasoning ADR 0019 used to make van write-offs a persisted
decision rather than a screen calculation.

Consequently, for a brand with a Placed Deposit, a customer forfeit nets to zero:
the customer's money is kept, and the matching Shortfall it creates is what
cancels it out.

### 6. Counts are physical, money is financial — and they are gated differently

The crate count is typed on the Receive Stock screen, beside the empties box that
is already there. Both legs recorded in one action is what kills the drift in
finding #2: neither leg can be forgotten without the other. Crate size is a
*category* in this app, never a bottle count, so a crate figure can never be
derived from delivered quantity — it is always typed.

But `Gates.receiveStock` is `stock.add` OR `products.add`, so a **stock keeper**
can receive. The count lands immediately on their say-so; the *money* waits for
a manager, reusing the approval pattern stock adjustments already use. Crate
records are never stale, and no one without money permission moves cash.

## Rejected alternatives

**Book the deposit as an expense when paid.** The obvious simple move, and wrong:
the money is refundable, so calling it a cost misstates profit in both directions
and makes delivery days look bad for no reason.

**Attribute every lost crate to a supplier (FIFO, or split pro-rata).** Rejected:
it manufactures a number no supplier agrees with, and a pro-rata split moves one
supplier's balance whenever an unrelated supplier's count changes. Fungible goods
should stay fungible until settlement forces a choice.

**Restate history when a brand's arrangement is switched on.** Rejected on the
authority of ADR 0021: a setting changed today must never rewrite a closed day.
Past forfeits were correct under the arrangement the app knew about. The new
treatment applies from switch-on forward, and the persisted day-close snapshots
exist precisely to make that guarantee hold.

**Let the stock keeper record the money too.** Faster, and it matches who is
physically standing at the delivery. Rejected: it hands cash-movement power to
the one role the permission model has always kept away from money, and it does so
on a screen that writes straight through with no approval queue.

**Add a bottles-per-crate number to products so crate counts derive themselves.**
Genuinely attractive long-term — no typing, ever. Rejected for this pass: it
requires backfilling every existing product before it works at all, part crates
and mixed loads still would not reconcile, and the app deliberately models crate
size as a category (Big/Medium/Small) rather than a count.

**Fix the van (#207) in the same pass.** Rejected: van v1 reached production on
2026-07-27 and reopening two-day-old money code multiplies risk, #207 is already
filed with its own scope, and the van crate pass has a hard prerequisite this PRD
should not swallow — the walk-in same-time-exchange question (crate audit B4),
still unresolved, and every van customer is a walk-in. This ADR defines the seam;
#207 calls it.

## Consequences

- **This amends ADR 0014.** The Daily Reconciliation was deliberately cut from
  nine cards to five, and this adds a sixth for crate money. That is an explicit,
  owner-chosen exception, not an oversight — anyone re-tightening the card count
  must read this first.
- The new card is **business-wide and labelled as such**, even under a locked
  store. Supplier crate money is a company obligation; splitting it per store
  would repeat exactly the defect `CRATE_TRACKING_AUDIT` C4 already names. Each
  supplier's own screen carries that supplier's figure.
- The forfeit-income line (#176) changes meaning for opted-in brands only.
  Reports spanning the switch-on date will show both treatments, by design.
- `supplier_crate_ledger` gains the receipt leg it never had automatically.
  Existing tenants carry historically-negative balances that this does **not**
  retroactively repair — rule 3's default-off keeps them out of the new money
  figures, but the drift is still visible in the crate counts.
- A Shortfall that is never written off never hits profit. That is deliberate
  (rule 5), and it means an owner who ignores the card keeps a silently
  overstated profit. The card exists to make ignoring it a choice.
- `crate_size_groups.deposit_amount_kobo` should be deleted by the next sweep.
  Leaving a plausible second rate column in the schema invites someone to wire
  per-crate-size deposits and quietly fork the canonical rate.

Product record: issue #203. Van follow-on: #207.
