# Legacy POS importer (#623)

Turns a legacy-POS export into three files. It writes files only: it never
connects to a database, and it refuses an output folder inside a git checkout.

| File | What it is |
|---|---|
| `import.sql` | One transaction that creates the business and loads everything. Safe to run twice. |
| `checks.sql` | Read-only. One PASS/FAIL row per check, then an overall verdict. |
| `report.md` | Counts per table, cost groups, and what was left out and why. |

**All three hold real shop data. They, the export and the accounts file never go
in this repo.** The repo is public, so tests use invented data only.

## Run

```sh
dart run tool/legacy_import/main.dart \
  --export <export dir> \
  --out <dir outside the repo> \
  --accounts <accounts.json> \
  --business-name "<name>" \
  --business-type "Beer distributor" \
  --owner-auth-uid <uuid>
```

`--business-type` takes the stored value, and crate tracking depends on it:
`Beer distributor` is what the app shows as Beverage distributor. Optional:
`--business-phone`, `--business-email` (default: the old settings), and
`--business-id` (default: derived from the old settings row).

The accounts file:

```json
{
  "accounts": [
    {
      "oldProfileId": "<old Profile.id, or null for a login the old app never had>",
      "email": "person@example.test",
      "authUid": "<new auth.users id>",
      "name": "Only needed when there is no old profile",
      "role": "ceo",
      "hidden": false
    }
  ],
  "productTypeCategories": ["<old Category names that are product types>"]
}
```

- Every old Category not listed in `productTypeCategories` becomes a
  manufacturer, so a misspelt name creates a false company. Check
  `manufacturers` in the report.
- An `authUid` starting `00000000-0000-0000-0000-` is a placeholder. The tool
  still builds, for review, but that `import.sql` stops on its first statement.

Then run the SQL as the `postgres` role. `service_role` cannot set
`session_replication_role`.

```sh
psql "$DB_URL" -v ON_ERROR_STOP=1 -f import.sql
psql "$DB_URL" -f checks.sql
```

Run `import.sql` a second time and `checks.sql` again: every count must stay the
same. Do it before any phone signs in.

## Triggers

Listed from `pg_trigger` for every table written. The load has two phases.

**Phase 1, triggers on:** the business, roles, settings, stores and staff. This
is a small set, and the guards here should run for real. Premium goes on the
business row first, because the plan-limit triggers read it.

**Phase 2, `SET LOCAL session_replication_role = replica`:** everything else.

| Trigger | Table | Decision |
|---|---|---|
| `trg_businesses_set_trial_end` | businesses | Fires. Changes nothing for `postgres` with status `active`. |
| `trg_stores_plan_limit` | stores | Fires. Premium has no store limit. |
| `trg_user_businesses_plan_limit` | user_businesses | Fires. Premium has no staff limit. |
| `trg_user_businesses_a_hidden_guard` | user_businesses | Fires. Resets `is_hidden` only for `authenticated` / `anon`, so `postgres` keeps it. |
| `zz_broadcast_sync_signal` | every table | Fires for phase 1 only, as onboarding does. Off in phase 2: one broadcast per row is what we must avoid, and no phone is listening. |
| `trg_share_barcode_photo` | products | Off. The export has no barcodes or photos, so it would do nothing. |
| `enforce_append_only`, `forbid_delete` | ledgers | Never fire: they guard UPDATE and DELETE, and the load only inserts. |
| `trg_orders_reversal_sticky`, `bump_*`, `trg_products_bump_version`, `trg_businesses_enforce_subscription` | various | Never fire, same reason. `ON CONFLICT DO NOTHING` runs no UPDATE triggers. |
| Foreign-key triggers | every table | **Off in phase 2**, a side effect of `replica`. A `DO` block rechecks every foreign key the load writes before `COMMIT` and aborts on any orphan. `checks.sql` repeats it. |

`ALTER TABLE ... DISABLE TRIGGER` would keep foreign keys on, but it holds a
write-blocking lock on about 20 live tables for the whole load, which would
stall every other shop's sync.

Nothing derives rows from an insert (no trigger maintains stock or balances), so
`inventory` and `customer_crate_balances` are written directly and wallet
balances come from their ledger, as in the app.

## FIFO: why deliveries write no cost layers

The issue lists `cost_batches` among the receive-stock records. The importer
deliberately does not write one per delivery. This is the one place it departs
from the issue, and it does so to meet the issue's own risk rule.

The FIFO re-cost is not a trigger. `pos_recost_pairs` runs **after every sale
push**, and replays every live sale line of that product and store through
`cost_batches.qty_original`, oldest first, overwriting
`order_items.buying_price_kobo`. So it will run on the first sale of each product.

With one layer per delivery, that replay would:

- restate past profit, because FIFO takes the oldest unused layer while the cost
  rule takes the latest delivery price;
- run on into the opening layers, because history outsold deliveries (stock also
  arrived through van returns and adjustments);
- cost whatever is still uncovered at 0.

So each product and store gets **history layers** instead (`history_layers.dart`).
They hold exactly the units history sold, in exactly replay order, each at the
cost its lines already carry. The replay then gives every line back the cost it
has and stops at the opening layer. All have `qty_remaining = 0`, so the phone's
draw-down and `_checkout_draw_fifo` never touch them; only the replay reads
`qty_original`. Cancelled lines stay out, because the replay only keeps those
with a fixed-id restore layer, and the import writes none.

The opening layer is dated at the export time, so it always sorts after history.
It holds the stock on hand at the product's current buying price. New sales draw
from it, on the phone and in the replay alike.

`checks.sql` proves this: **a FIFO replay changes no past line cost** runs the real
`fifo_assign` over the imported rows, without writing, and counts differences.

## Choices worth knowing

- **Ledgers are copied row for row, not rebuilt.** A paid sale to a registered
  customer therefore has no wallet legs, unlike a new sale. Balances still match
  to the kobo, which is what was asked for.
- **`voided_at` stays NULL on wallet and supplier rows.** The app sums voided rows
  because a void has a compensating row, but some server readers skip them. An old
  cancelled row and its offset both stay plain rows, so every reader gets the same
  balance. The exception is the cash row of a cancelled customer payment: that one
  is voided, because nothing else takes the cash back out.
- **Cancelled sales keep `amount_paid_kobo = 0`.** The old figure was an artifact,
  not cash.
- **`payment_type` comes from the amounts** (the app's own rule), not the old
  status, which edits could leave stale.
- **An overpaid sale** splits into a `sale` row and a `wallet_topup` row, as the
  app does. The old negative SALE_CREDIT becomes a wallet credit.
- **A cost uses `deliveryDate`,** when the goods arrived, not when the row was
  typed in.
- **Stock movements off the 0.25 grid** cannot pass the #627 CHECK. Split pairs
  fold into one row with the same total. `inventory` is unaffected: it copies the
  old stock figure.
- **A transfer with no dispatcher** names the owner: the column is required.
- **`allow_fractional_sales`** is on for products with fractional history, so the
  shop can keep selling them in halves.
- **CEOs get `user_stores` rows for every branch.**

## Before the first dry run

- #627 must be on the target database. `import.sql` checks the column types and
  stops if not: Postgres would otherwise round 0.5 away without complaint.
- `checks.sql` calls the #627 version of `fifo_assign`. If #627 rounds a line's
  total before dividing by quantity, fractional lines can come back a kobo or two
  off and that check will fail. Fix it there, or accept it, knowingly.
- Apply new migrations to dev one at a time: its baseline differs from prod.
