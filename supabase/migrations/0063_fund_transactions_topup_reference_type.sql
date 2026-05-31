-- 0063_fund_transactions_topup_reference_type.sql
--
-- Reebaplus — allow 'topup' as a fund_transactions.reference_type so a customer
-- wallet top-up (§18 Add Funds) can credit the chosen Funds Register account
-- (Cash Till / POS machine / Bank), keeping the daily expected balance accurate
-- for reconciliation at close (§23 / coding rule 5).
--
-- Background:
--   0057 declared the column with an inline CHECK
--     reference_type text NOT NULL CHECK (reference_type IN ('opening','sale','void'))
--   (0057:64), which Postgres auto-named fund_transactions_reference_type_check.
--   The matching local Drift CHECK is widened in the same release (schema v23,
--   fund_transactions table rebuild in app_database.dart onUpgrade from < 23).
--
-- Fix:
--   Drop the old CHECK and re-add it widened with 'topup'. Additive and
--   backward-compatible — every existing value still validates; only a new
--   value becomes legal. Idempotent (DROP ... IF EXISTS). No data change.

BEGIN;

-- Drop whatever CHECK constraint currently governs reference_type, regardless
-- of its auto-generated name (0057 declared it inline, so Postgres named it
-- fund_transactions_reference_type_check — but match by definition to be safe:
-- a wrong name would silently leave the old constraint and still reject 'topup').
DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.fund_transactions'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%reference_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.fund_transactions DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

ALTER TABLE public.fund_transactions
  ADD CONSTRAINT fund_transactions_reference_type_check
  CHECK (reference_type IN ('opening','sale','void','topup'));

COMMIT;
