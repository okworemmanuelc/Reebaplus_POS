-- 0059_funds_account_number.sql
-- Funds Register: optional account number / terminal id on POS and Bank
-- accounts (Cash Till leaves it null). Mirrors the local Drift v20 → v21 bump.
ALTER TABLE public.funds_accounts
  ADD COLUMN IF NOT EXISTS account_number text;
