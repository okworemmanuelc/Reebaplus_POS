# Old-POS payroll importer (#672)

Turns the old POS's payroll (`Staff`, `StaffPayrollEntry`, `StaffLoanEntry`,
`StaffPayrollStatement`) into `import.sql`, `checks.sql` and `report.md`. It
writes files only and refuses an output folder inside a git checkout. It never
touches sales, customers or stock.

**The config, the export and all three outputs hold personal pay data. None of
them go in this repo.** Tests use invented data only.

## Run

```sh
dart run tool/payroll_import/main.dart \
  --export <export dir> \
  --config <private config.json> \
  --out <dir outside the repo>
# optional: --business-id <uuid>  (default: the id the #623 import derived)

psql "$DB_URL" -v ON_ERROR_STOP=1 -f <out>/import.sql
psql "$DB_URL" -f <out>/checks.sql
```

Run `import.sql` a second time and `checks.sql` again: nothing changes. The
#623 import must already be on the database (the business, its stores and
users). Run as `postgres`.

## Config

```json
{
  "workers": ["<old Staff.id>"],
  "names": {"<old Staff.id>": "<name to save, if not the export's>"},
  "salaryMonths": {"<old salary entry id>": "YYYY-MM"},
  "loanDates": {"<old loan entry id>": "YYYY-MM-DD"},
  "paymentMethods": {"<old entry id>": "cash | transfer | other"},
  "expected": {
    "workers": 0, "statements": 0, "salaryKobo": 0, "cashOutKobo": 0,
    "loanEntries": 0, "loansOwedKobo": {"<old Staff.id>": 0}
  }
}
```

- Staff not listed stay archived with all their rows.
- Salary Month defaults to the month before payday.
- A loan's date: `loanDates`, else a dd/mm/yy date in its note, else the day it
  was typed in. `report.md` shows which rule each loan used.
- Payment method defaults to `cash`. A repayment on the worker's payday is the
  salary deduction and is always `other` (as the app records it).
- `expected` is the private plan's "Checks after import"; `checks.sql` compares
  the database with it.

## Choices worth knowing

- Salary entries, payday repayments, statements and the combined
  `staff_pay_totals` lines use the app's own deterministic ids, so a phone that
  pays, corrects or refreshes them never makes a second row.
- The import writes the combined lines itself (same rules as
  `_refreshSalaryTotals` / `_refreshMoneyTotals`), so reports on every phone are
  right before a Payroll phone pulls. A line that already exists is left alone;
  the next Payroll pull recomputes it from all rows.
- An old cancelled entry and its ADJUSTMENT become the entry plus a correction
  (`corrects_entry_id`), so the history nets to zero.
- No daily allowances: they start in the app, never backdated.
- Anything without a faithful mapping (a cancelled salary or loan, an
  adjustment that offsets nothing, an unknown type) stops the build.
