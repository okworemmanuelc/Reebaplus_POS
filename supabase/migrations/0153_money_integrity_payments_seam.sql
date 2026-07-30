-- 0153_money_integrity_payments_seam.sql
--
-- #169 / PRD #155 — money-integrity prefactor (compensating-row seam +
-- sync/schema plumbing). Behavior-preserving: adds columns and widens a CHECK;
-- no data is rewritten, no flow changes. Mirrors the Drift schemaVersion 64
-- upgrade step in lib/core/database/app_database.dart.
--
-- Deploy-ordering: this must land on the cloud BEFORE any client on Drift
-- schema v64 pushes a payment_transactions row carrying `store_id`, an orders
-- row carrying `confirmed_by`, or a payment row of the new `crate_deposit`
-- type — otherwise the upsert references an unknown column / trips the old
-- CHECK and jams the outbox.
--
-- All `*_kobo` columns are untouched here and remain bigint (0130).

-- =========================================================================
-- 1. payment_transactions.store_id — nullable store where the tender happened.
--    Stamped on all NEW rows (client v64); legacy rows stay NULL and report
--    business-wide exactly as today. Additive + nullable, so existing rows are
--    untouched.
-- =========================================================================
ALTER TABLE public.payment_transactions
  ADD COLUMN IF NOT EXISTS store_id uuid REFERENCES public.stores(id);

-- =========================================================================
-- 2. orders.confirmed_by — who tapped Confirm, recorded separately from the
--    seller (staff_id). Nullable, unused until #171. Additive + nullable.
-- =========================================================================
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS confirmed_by uuid REFERENCES public.users(id);

-- =========================================================================
-- 3. Widen the payment_transactions.type CHECK to admit the deposit-distinct
--    `crate_deposit` type (unused until #175): a refundable crate deposit is
--    its own money type, so it can be excluded from "Cash sales". Postgres
--    alters a CHECK in place (no table rebuild), so there are no index/trigger
--    concerns. The constraint is unnamed (inline in 0001), so drop it by its
--    system-generated name via a catalog lookup, then re-add the widened form
--    under a stable name. Idempotent: if a CHECK already admits `crate_deposit`,
--    do nothing. (Same pattern as 0149's status-CHECK widening.)
-- =========================================================================
DO $$
DECLARE
  v_conname text;
  v_def     text;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%type%'
     AND pg_get_constraintdef(c.oid) ILIKE '%sale%'
   LIMIT 1;

  -- Already widened (idempotent re-run) — nothing to do.
  IF v_def IS NOT NULL AND v_def ILIKE '%crate_deposit%' THEN
    RETURN;
  END IF;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_conname
    );
  END IF;

  ALTER TABLE public.payment_transactions
    ADD CONSTRAINT payment_transactions_type_check
    CHECK (type IN
      ('sale','purchase','expense','refund','wallet_topup','crate_deposit'));
END $$;

-- =========================================================================
-- 4. Re-bake the payment_transactions append-only trigger so `store_id` joins
--    the immutable-column set (it is set at insert and never changes), matching
--    the local ledger-immutability trigger. The guard bakes its column list
--    into TG_ARGV at CREATE time (0110), so a newly-added column is otherwise
--    unguarded. Rebuild from information_schema minus the void columns — the
--    exact 0110 recipe, scoped to this one table. Idempotent.
-- =========================================================================
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(quote_literal(column_name), ',' ORDER BY ordinal_position)
    INTO cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'payment_transactions'
     AND column_name NOT IN
         ('voided_at','voided_by','void_reason','last_updated_at');

  EXECUTE format(
    'DROP TRIGGER IF EXISTS trg_payment_transactions_append_only '
    'ON public.payment_transactions'
  );
  EXECUTE format(
    'CREATE TRIGGER trg_payment_transactions_append_only '
    'BEFORE UPDATE ON public.payment_transactions '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

-- =========================================================================
-- Verification (manual):
--   \d public.payment_transactions   -- store_id present; type CHECK 6 values
--   \d public.orders                 -- confirmed_by present
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conname = 'payment_transactions_type_check';
--     -- expect: CHECK (type IN ('sale','purchase','expense','refund',
--     --                         'wallet_topup','crate_deposit'))
-- =========================================================================
