-- 0246_staff_pay_totals_kinds.sql
--
-- #696 (PRD #666, ADR 0034): bonus, advance and staff loan lines.
-- Cloud twin of Drift schemaVersion 104 (app_database.dart, `from < 104`).
--
-- WHY
--   Bonuses, advances and staff loans paid in till cash leave the drawer, and
--   a loan repaid in cash at the till (outside payday) comes back into it.
--   Daily Reconciliation on EVERY phone must count that cash, but the payroll
--   rows reach only phones with `payroll.manage`. Like the Daily allowances
--   and Salaries lines (0245), each kind gets one combined line per store and
--   day, with no worker named, written as the full recomputed figure by a
--   Payroll phone:
--     bonuses       amount = approved bonuses (a cost: Expenses + Profit),
--                   cash   = the part paid in till cash (cash out)
--     advances      cash out only (payday already counts the full salary)
--     loans_given   cash out only (the money is owed back)
--     loans_repaid  cash in only (repayments at the till; a payday
--                   repayment is kept back from the salary and is excluded)
--   Pending and rejected entries never count. Transfer / Other never touch
--   the drawer (they are in amount, never in cash).
--
-- WHAT THIS DOES
--   Drops the kind CHECK on staff_pay_totals (found by definition, not by a
--   guessed name) and re-adds it with the four new kinds. No column, policy,
--   trigger or pos_pull_snapshot change.
--
-- DEPLOY ORDER: after 0245 and BEFORE any client on Drift 104 pushes one of
-- the new kinds (an older cloud rejects the push and jams that outbox row).
-- Never together with 0193.

BEGIN;

DO $$
DECLARE
  v_name text;
BEGIN
  FOR v_name IN
    SELECT c.conname
      FROM pg_constraint c
     WHERE c.conrelid = 'public.staff_pay_totals'::regclass
       AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) ILIKE '%kind%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.staff_pay_totals DROP CONSTRAINT %I', v_name
    );
  END LOOP;
END $$;

ALTER TABLE public.staff_pay_totals
  ADD CONSTRAINT staff_pay_totals_kind_check
  CHECK (kind IN (
    'daily_allowances', 'salaries',
    'bonuses', 'advances', 'loans_given', 'loans_repaid'
  ));

COMMIT;
