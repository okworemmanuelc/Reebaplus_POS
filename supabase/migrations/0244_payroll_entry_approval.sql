-- 0244_payroll_entry_approval.sql — #670 (PRD #666, ADR 0034)
--
-- CEO approval for a Manager's bonus, advance or staff loan above their
-- expense limit (role_settings.max_expense_approval_kobo, the Expenses limit).
-- Mirrors Drift v102.
--
--   1. payroll_entries gains status ('approved' | 'pending' | 'rejected',
--      default 'approved' so every existing entry stays counted), approved_by,
--      approved_at and rejection_reason.
--   2. The append-only freeze (0243 `_payroll_freeze_row`) now lets exactly
--      one thing change after insert: a 'pending' entry moving to 'approved'
--      or 'rejected' (with approved_by / approved_at / rejection_reason), and
--      only when the caller is the business's CEO (or a service-role session,
--      auth.uid() IS NULL). Every other column stays frozen, and a decided
--      entry never moves again — so a Manager's phone replaying its 'pending'
--      upsert after the CEO decided keeps the decision (first decision wins,
--      last_updated_at moves on so the replaying phone converges on its pull).
--
-- DEPLOY ORDER: this must reach a project BEFORE any client on Drift 102
-- pushes a payroll entry (the upsert names the new columns).

BEGIN;

ALTER TABLE public.payroll_entries
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'approved',
  ADD COLUMN IF NOT EXISTS approved_by uuid
    REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS rejection_reason text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'payroll_entries_status_check'
       AND conrelid = 'public.payroll_entries'::regclass
  ) THEN
    ALTER TABLE public.payroll_entries
      ADD CONSTRAINT payroll_entries_status_check
      CHECK (status IN ('approved', 'pending', 'rejected'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_payroll_entries_pending
  ON public.payroll_entries (business_id)
  WHERE status = 'pending';

-- Same name and signature as 0243, so the existing triggers on
-- payroll_entries and payroll_statements pick up the new body. Statements
-- have no status column: the decision branch only runs for payroll_entries.
CREATE OR REPLACE FUNCTION public._payroll_freeze_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_decided boolean := false;
  v_status  text;
  v_by      uuid;
  v_at      timestamptz;
  v_reason  text;
BEGIN
  -- Nested IFs: payroll_statements has no status field, so the entries-only
  -- expressions must never be evaluated for it.
  IF TG_TABLE_NAME = 'payroll_entries' THEN
    IF OLD.status = 'pending'
       AND NEW.status IN ('approved', 'rejected')
       AND (auth.uid() IS NULL
            OR public.caller_role_slug(OLD.business_id) = 'ceo') THEN
      v_decided := true;
      v_status  := NEW.status;
      v_by      := NEW.approved_by;
      v_at      := COALESCE(NEW.approved_at, now());
      v_reason  := CASE WHEN NEW.status = 'rejected'
                        THEN NEW.rejection_reason END;
    END IF;
  END IF;

  NEW := OLD;
  IF v_decided THEN
    NEW.status           := v_status;
    NEW.approved_by      := v_by;
    NEW.approved_at      := v_at;
    NEW.rejection_reason := v_reason;
  END IF;
  NEW.last_updated_at := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._payroll_freeze_row() FROM public;

COMMIT;
