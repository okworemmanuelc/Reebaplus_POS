# Payroll data reaches only permitted phones

Until now every phone in a business has received all of that business's data, and permissions only hid screens. Payroll breaks that rule: salaries, allowances, bonuses and staff loans sync only to people with the Payroll permission (CEO and Manager by default). A hidden screen was rejected because the figures would still sit on cashiers' phones, which can be lost, shared or tampered with. The owner chose this on 2026-11-02.

## Consequences

- This is the first table access rule to depend on a permission rather than only on the business, using `caller_has_permission`.
- `pos_pull_snapshot` is `SECURITY DEFINER`, so it skips those rules. Payroll tables must stay out of it, or it must apply the same check.
- Daily Allowances can only be created on a phone that holds Payroll. A day with no such phone open is filled in later under its own date, and until then that day's reports leave those allowances out.
- Daily Reconciliation and Expenses still need the cash. They receive one combined line per store and day, such as "Daily allowances", and one "Salaries" total per payday. Those lines name no worker and sync as normal.
- Losing the Payroll permission must remove payroll rows from that phone, not just stop new ones arriving.
