-- 0094_wallet_reference_type_crate.sql
--
-- Reebaplus — crate deposit accounting (master plan §13.4). Widen the
-- wallet_transactions.reference_type CHECK to allow the crate-deposit family:
--   'crate_deposit'            — a credit: refundable deposit the business HOLDS
--                                for the customer (excluded from spendable balance)
--   'crate_deposit_refunded'   — a debit that drops "held" (cash refund, or the
--                                deposit-out leg when converting to wallet credit)
--   'crate_deposit_forfeited'  — a debit that drops "held"; crates kept = income
--   'crate_refund'             — a spendable credit (the general leg when a
--                                deposit is converted to wallet credit)
-- "Deposits held" = SUM(signed) over the first three; "spendable balance" =
-- SUM(signed) over everything NOT in those three. Mirrors the local Drift
-- WalletTransactions CHECK widen (schema v37).
--
-- Additive (widens an existing CHECK). DEPLOY ORDER: push this BEFORE the
-- crate-deposit app build reaches a device, or wallet upserts carrying the new
-- reference_type values would be rejected by the old CHECK (23514).
--
-- SQLite can't ALTER a CHECK in place (handled by the Drift table rebuild); in
-- Postgres the inline CHECK is auto-named, so drop it by definition lookup (not
-- by name) then re-add the widened constraint. Mirrors 0063.

BEGIN;

DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.wallet_transactions'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%reference_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.wallet_transactions DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

ALTER TABLE public.wallet_transactions
  ADD CONSTRAINT wallet_transactions_reference_type_check
  CHECK (reference_type IN (
    'topup_cash','topup_transfer','order_payment','refund','reward','fee','adjustment','void',
    'crate_deposit','crate_deposit_refunded','crate_deposit_forfeited','crate_refund'
  ));

COMMIT;
