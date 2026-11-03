-- 0248 — #723 Payroll redesign: each worker's job, usual payday and a
-- staff loan's monthly repayment plan.
--
--   payroll_workers.job_title           free text ("Driver"), optional.
--                                       Shown under the name; the store name
--                                       stands in when empty.
--
--   payroll_workers.payday_day          1–31, the day of the month the worker
--                                       is usually paid. NULL = the last day
--                                       of the month. Shown only ("pays on
--                                       the 28th"); payday itself may still
--                                       be any date (#696).
--   payroll_entries.monthly_repayment_kobo
--                                       on a 'loan_given' entry only: how much
--                                       is taken back each payday. NULL = no
--                                       plan (every loan before #723). Frozen
--                                       with the rest of the entry
--                                       (`_payroll_freeze_row`, NEW := OLD).
--
-- Both columns are nullable with no default, so every existing row and every
-- older client (which never names them) keeps working.
--
-- DEPLOY ORDER: this must reach a project BEFORE any client on Drift 106
-- pushes a payroll worker or entry (the upsert names the new columns).

BEGIN;

ALTER TABLE public.payroll_workers
  ADD COLUMN IF NOT EXISTS job_title text,
  ADD COLUMN IF NOT EXISTS payday_day smallint;

ALTER TABLE public.payroll_entries
  ADD COLUMN IF NOT EXISTS monthly_repayment_kobo bigint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'payroll_workers_payday_day_check'
       AND conrelid = 'public.payroll_workers'::regclass
  ) THEN
    ALTER TABLE public.payroll_workers
      ADD CONSTRAINT payroll_workers_payday_day_check
      CHECK (payday_day IS NULL OR payday_day BETWEEN 1 AND 31);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'payroll_entries_monthly_repayment_check'
       AND conrelid = 'public.payroll_entries'::regclass
  ) THEN
    ALTER TABLE public.payroll_entries
      ADD CONSTRAINT payroll_entries_monthly_repayment_check
      CHECK (
        monthly_repayment_kobo IS NULL
        OR (type = 'loan_given' AND monthly_repayment_kobo > 0)
      );
  END IF;
END
$$;

COMMIT;
