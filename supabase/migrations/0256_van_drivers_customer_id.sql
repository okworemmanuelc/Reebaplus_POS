-- 0256_van_drivers_customer_id.sql
--
-- #783 / ADR 0036 — "Bring in old customer account". A van driver can be linked,
-- once, to the CUSTOMER account the shop sold to before Van Sales existed.
--
--   · public.van_drivers.customer_id  uuid, NULLABLE, FK customers(id).
--     One driver per customer per business (partial unique index). The app
--     also refuses a second customer for one driver (write path), and never
--     clears the link.
--
-- No other cloud change is needed:
--   · van_drivers is pushed by plain upsert under the existing RLS policy
--     (van_drivers_tenant_rw, current_user_business_ids()); an older app that
--     does not send the column leaves it untouched / null.
--   · pos_pull_snapshot reads each tenant table through to_jsonb(t), so the new
--     column reaches every device with no change to the function.
--   · the move's two ledger rows use EXISTING values only:
--       wallet_transactions  type 'credit', reference_type 'adjustment'
--       driver_ledger_entries type 'restatement', reference_type
--                             'driver_ledger_entry', no trip.
--     No CHECK is widened and no *_kobo column is added (0130 rule unchanged).
--
-- Mirrors Drift schemaVersion 109. DEPLOY ORDER: land this BEFORE any v109
-- client pushes (the van_drivers upsert then carries customer_id).
-- POS PARITY: web console must show a linked driver's old customer account.

BEGIN;

ALTER TABLE public.van_drivers
  ADD COLUMN IF NOT EXISTS customer_id uuid
    REFERENCES public.customers(id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_van_drivers_business_customer
  ON public.van_drivers (business_id, customer_id)
  WHERE customer_id IS NOT NULL;

COMMENT ON COLUMN public.van_drivers.customer_id IS
  '#783: the old customer account brought in under this driver. Set once, never cleared; one driver per customer per business.';

COMMIT;
