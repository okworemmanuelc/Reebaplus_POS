-- 0257_payment_van_driver_parent.sql
--
-- #787 — a driver payment recorded on the driver's own page, with no trip.
-- Debt sits with the driver, never a van, so a driver who owes with no trip at
-- all (an old customer account brought in, #783) must still be able to pay, and
-- that cash must still reach "Cash from drivers".
--
--   1. public.payment_transactions.van_driver_id — the EIGHTH parent. Nullable,
--      additive. Set on `van_remittance` rows that have no trip; null on every
--      other row (a payment against a trip keeps van_trip_id as its one parent).
--   2. the exactly-one-parent CHECK widened to count it. A WIDENING: every
--      existing row stays valid.
--   3. the append-only trigger re-baked so the new column is guarded.
--
-- No type or method CHECK changes, no new *_kobo column. pos_pull_snapshot is
-- not re-declared: a new COLUMN rides along in to_jsonb(t).
--
-- Mirrors Drift schemaVersion 110. DEPLOY ORDER: land this BEFORE any v110
-- client pushes. An OLDER app that pulls a no-trip driver payment cannot store
-- it (its local CHECK still wants one of seven parents), so raise the minimum
-- build when v110 ships.
-- POS PARITY: the web console's "Cash from drivers" must count van_remittance
-- rows with van_driver_id set and no van_trip_id.

BEGIN;

ALTER TABLE public.payment_transactions
  ADD COLUMN IF NOT EXISTS van_driver_id uuid
    REFERENCES public.van_drivers(id);

CREATE INDEX IF NOT EXISTS idx_payment_txn_van_driver
  ON public.payment_transactions (business_id, van_driver_id);

COMMENT ON COLUMN public.payment_transactions.van_driver_id IS
  '#787: the driver a no-trip van_remittance was taken from. The eighth parent.';

DO $$
DECLARE
  v_conname text;
  v_def     text;
  v_orphans bigint;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%wallet_txn_id%'
   LIMIT 1;

  -- Already widened (idempotent re-run).
  IF v_def IS NOT NULL AND v_def ILIKE '%van_driver_id%' THEN
    RETURN;
  END IF;

  -- Check BEFORE dropping (the 0172 rule): never abort the deploy on a row
  -- that should be impossible.
  SELECT count(*) INTO v_orphans
    FROM public.payment_transactions
   WHERE ((order_id         IS NOT NULL)::int +
          (shipment_id      IS NOT NULL)::int +
          (expense_id       IS NOT NULL)::int +
          (wallet_txn_id    IS NOT NULL)::int +
          (delivery_id      IS NOT NULL)::int +
          (van_trip_id      IS NOT NULL)::int +
          (crate_deposit_id IS NOT NULL)::int) <> 1;

  IF v_orphans > 0 THEN
    RAISE WARNING
      '0257: % payment_transactions row(s) do not satisfy exactly-one-parent; '
      'leaving the seven-way CHECK in place rather than aborting the deploy. '
      'No-trip driver payments cannot be recorded until those rows are fixed.',
      v_orphans;
    RETURN;
  END IF;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_conname
    );
  END IF;

  ALTER TABLE public.payment_transactions
    ADD CONSTRAINT payment_transactions_one_parent_check
    CHECK (
      (order_id         IS NOT NULL)::int +
      (shipment_id      IS NOT NULL)::int +
      (expense_id       IS NOT NULL)::int +
      (wallet_txn_id    IS NOT NULL)::int +
      (delivery_id      IS NOT NULL)::int +
      (van_trip_id      IS NOT NULL)::int +
      (crate_deposit_id IS NOT NULL)::int +
      (van_driver_id    IS NOT NULL)::int = 1
    );
END $$;

-- Re-bake the append-only trigger so van_driver_id is guarded (0110 recipe).
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

  EXECUTE 'DROP TRIGGER IF EXISTS trg_payment_transactions_append_only '
          'ON public.payment_transactions';
  EXECUTE format(
    'CREATE TRIGGER trg_payment_transactions_append_only '
    'BEFORE UPDATE ON public.payment_transactions '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

COMMIT;
