# A driver brings in their old customer account

**Status: accepted** (#783, owner decisions 2026-11-11). Builds on ADR 0019 (van
money model) and ADR 0035 (append-only, nothing edited).

Before Van Sales, a shop sold to its van drivers as ordinary customers
("Johnson Kim (Beer Van Driver)"). Those past sales and payments must be seen
under the van, and what the old account still owes must carry on as the
driver's debt.

## Decision

1. **No new van.** Existing vans and their names stay.
2. **Show the past records, change nothing.** Old sales and payments stay exactly
   as recorded: no reversal, no re-entry, no change to past reports, stock or
   totals.
3. **The driver carries the debt from now on.** A manager action on the driver's
   page, "Bring in old customer account", links the driver to a customer
   (`van_drivers.customer_id`, nullable, one customer per driver and one driver
   per customer, set once, never cleared; Drift v109, cloud 0256).
4. **The money move is two entries in one local transaction**, both through the
   existing write paths, nothing existing edited or voided:
   - `wallet_transactions`: `type = credit`, `reference_type = adjustment`,
     amount = what the customer owed (brings the balance to exactly zero). No
     `payment_transactions` row, so it is not cash received.
   - `driver_ledger_entries`: `type = restatement`, `reference_type =
     driver_ledger_entry`, no trip, a debit of the same kobo, on the driver's
     assigned van (else the van of their latest trip; refused if neither).
   A customer at zero or in credit is linked with no money entry.
5. **No new CHECK values.** Widening `driver_ledger_entries.type` would be a
   rebuild of an append-only table, and an older app pulling an unknown value
   would fail its CHECK. A `restatement` with no trip is the marker (the trip
   restatement always has a trip) and is labelled "Moved from the old customer
   account".
6. **The driver's balance is the driver ledger only.** The old account's sales
   and top-up payments are listed read-only, tagged "Old customer account", on
   the driver's Sales tab and Ledger tab; they never enter the balance or the
   period totals (the debt was moved, so counting the wallet again would double
   it).
7. **The old customer is kept for history** and is no longer offered when
   choosing a customer for a sale; its page says "Now a van driver: <name>".
8. **Not done here:** crates the old account holds (stay on the customer), turning
   past sales into van loads, undo.

## Consequences

- "Customers owe" on the daily close is a point-in-time wallet balance, so it
  drops by the moved amount on the link. Every flow figure (sales, payments,
  cash, expenses) is unchanged for every day.
- The web console must show the link and read the same two entries (pos-parity).
