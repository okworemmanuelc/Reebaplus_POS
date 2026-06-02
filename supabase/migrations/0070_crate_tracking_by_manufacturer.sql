-- 0070_crate_tracking_by_manufacturer.sql
--
-- Re-key empty-crate CUSTOMER tracking from crate size group to MANUFACTURER
-- (master plan §13.4). Mirrors the local Drift v29 migration.
--
-- Products were never assigned a crate size group, so the §19.5 crate-return
-- confirmation modal listed nothing. Crate balances + the ledger now key by
-- manufacturer:
--   * customer_crate_balances    : + manufacturer_id, UNIQUE(business, customer, manufacturer)
--   * manufacturer_crate_balances: UNIQUE(business, manufacturer) (size dim dropped)
--   * pending_crate_returns      : + manufacturer_id
--   * crate_ledger               : crate_size_group_id nullable; owner CHECK
--                                  relaxed from customer⊕manufacturer to
--                                  "at least one set" so a CUSTOMER row can also
--                                  name the manufacturer whose crates it holds.
--   * pos_record_crate_return / pos_approve_crate_return rewritten to match.
--
-- The crate_size_groups TABLE itself is untouched (it still powers the Empty
-- Crates inventory tab, deliveries, and supplier crate-group mapping).
--
-- Additive where possible (new columns are nullable; old columns kept-nullable)
-- so a not-yet-updated client can still pull these tables. The two balance
-- tables are RPC-maintained CACHES — their rows are cleared and rehydrate on
-- the next crate return. pending_crate_returns rows (transient requests) are
-- cleared too. crate_ledger history is preserved (existing rows satisfy the
-- relaxed CHECK).
--
-- DEPLOY ORDER: this is the third of three pending migrations — push after
-- 0068 (fund_day_closings) and 0069 (customers.wallet.totals.view). It must be
-- live before the v29 app build reaches a device.

BEGIN;

-- ── 1. customer_crate_balances → manufacturer-keyed ─────────────────────────
DELETE FROM public.customer_crate_balances;  -- cache; rehydrates from the RPC

ALTER TABLE public.customer_crate_balances
  ADD COLUMN IF NOT EXISTS manufacturer_id uuid REFERENCES public.manufacturers(id);

ALTER TABLE public.customer_crate_balances
  ALTER COLUMN crate_size_group_id DROP NOT NULL;

-- Drop the old size-group UNIQUE (anonymous name → look it up by definition).
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
   WHERE conrelid = 'public.customer_crate_balances'::regclass
     AND contype = 'u'
     AND pg_get_constraintdef(oid) ILIKE '%crate_size_group_id%';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.customer_crate_balances DROP CONSTRAINT %I', c);
  END IF;
END $$;

ALTER TABLE public.customer_crate_balances
  ADD CONSTRAINT customer_crate_balances_business_customer_mfr_key
  UNIQUE (business_id, customer_id, manufacturer_id);

-- ── 2. manufacturer_crate_balances → drop the size dimension ────────────────
DELETE FROM public.manufacturer_crate_balances;  -- cache; rehydrates from the RPC

ALTER TABLE public.manufacturer_crate_balances
  ALTER COLUMN crate_size_group_id DROP NOT NULL;

DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
   WHERE conrelid = 'public.manufacturer_crate_balances'::regclass
     AND contype = 'u'
     AND pg_get_constraintdef(oid) ILIKE '%crate_size_group_id%';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.manufacturer_crate_balances DROP CONSTRAINT %I', c);
  END IF;
END $$;

ALTER TABLE public.manufacturer_crate_balances
  ADD CONSTRAINT manufacturer_crate_balances_business_mfr_key
  UNIQUE (business_id, manufacturer_id);

-- ── 3. pending_crate_returns → manufacturer-keyed ───────────────────────────
DELETE FROM public.pending_crate_returns;  -- transient approval requests

ALTER TABLE public.pending_crate_returns
  ADD COLUMN IF NOT EXISTS manufacturer_id uuid REFERENCES public.manufacturers(id);

ALTER TABLE public.pending_crate_returns
  ALTER COLUMN crate_size_group_id DROP NOT NULL;

-- ── 4. crate_ledger → nullable size + relaxed owner CHECK ───────────────────
ALTER TABLE public.crate_ledger
  ALTER COLUMN crate_size_group_id DROP NOT NULL;

-- Replace the owner XOR (exactly-one of customer/manufacturer) with
-- "at least one set" so a customer row can also carry the manufacturer.
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
   WHERE conrelid = 'public.crate_ledger'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%customer_id%'
     AND pg_get_constraintdef(oid) ILIKE '%manufacturer_id%'
     AND pg_get_constraintdef(oid) ILIKE '%= 1%';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.crate_ledger DROP CONSTRAINT %I', c);
  END IF;
END $$;

ALTER TABLE public.crate_ledger
  ADD CONSTRAINT crate_ledger_owner_present
  CHECK (customer_id IS NOT NULL OR manufacturer_id IS NOT NULL);

-- ── 5. pos_record_crate_return — re-keyed to manufacturer ───────────────────
-- Param p_crate_size_group_id → p_manufacturer_id (the manufacturer whose
-- crates move). For owner_kind='customer' the ledger row now sets BOTH
-- customer_id (owner) and manufacturer_id; balances key by manufacturer.
DROP FUNCTION IF EXISTS public.pos_record_crate_return(
  uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid
);

CREATE OR REPLACE FUNCTION public.pos_record_crate_return(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_ledger_id            uuid,
  p_owner_kind           text,        -- 'customer' | 'manufacturer'
  p_owner_id             uuid,
  p_manufacturer_id      uuid,        -- whose crates (customer path); == owner for manufacturer path
  p_quantity_delta       int,
  p_movement_type        text,
  p_reference_order_id   uuid DEFAULT NULL,
  p_reference_return_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now           timestamptz := now();
  v_already       bool;
  v_balance_row   record;
  v_ledger_row    jsonb;
  v_balance_jsonb jsonb;
  v_mfr           uuid := COALESCE(p_manufacturer_id,
                          CASE WHEN p_owner_kind = 'manufacturer' THEN p_owner_id END);
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_owner_kind NOT IN ('customer','manufacturer') THEN
    RAISE EXCEPTION 'invalid_owner_kind: %', p_owner_kind USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_movement_type NOT IN ('issued','returned','damaged','adjusted','transferred_in','transferred_out') THEN
    RAISE EXCEPTION 'invalid_movement_type: %', p_movement_type USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_mfr IS NULL THEN
    RAISE EXCEPTION 'manufacturer_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Replay detection on ledger id.
  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_ledger_id) INTO v_already;
  IF v_already THEN
    SELECT to_jsonb(cl.*) INTO v_ledger_row FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
    IF p_owner_kind = 'customer' THEN
      SELECT to_jsonb(b.*) INTO v_balance_jsonb FROM public.customer_crate_balances b
       WHERE b.business_id = p_business_id AND b.customer_id = p_owner_id AND b.manufacturer_id = v_mfr;
    ELSE
      SELECT to_jsonb(b.*) INTO v_balance_jsonb FROM public.manufacturer_crate_balances b
       WHERE b.business_id = p_business_id AND b.manufacturer_id = v_mfr;
    END IF;
    RETURN jsonb_build_object(
      'crate_ledger_row', v_ledger_row,
      'balance_row',      v_balance_jsonb,
      'replayed',         true
    );
  END IF;

  INSERT INTO public.crate_ledger (
    id, business_id, customer_id, manufacturer_id, crate_size_group_id,
    quantity_delta, movement_type, reference_order_id, reference_return_id,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_ledger_id, p_business_id,
    CASE WHEN p_owner_kind = 'customer' THEN p_owner_id END,
    v_mfr, NULL, p_quantity_delta, p_movement_type,
    p_reference_order_id, p_reference_return_id,
    p_actor_id, v_now, v_now
  );

  IF p_owner_kind = 'customer' THEN
    INSERT INTO public.customer_crate_balances (
      id, business_id, customer_id, manufacturer_id, balance, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_owner_id, v_mfr,
      p_quantity_delta, v_now, v_now
    )
    ON CONFLICT (business_id, customer_id, manufacturer_id)
      DO UPDATE SET balance = public.customer_crate_balances.balance + EXCLUDED.balance,
                    last_updated_at = v_now
    RETURNING * INTO v_balance_row;
  ELSE
    INSERT INTO public.manufacturer_crate_balances (
      id, business_id, manufacturer_id, balance, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_mfr,
      p_quantity_delta, v_now, v_now
    )
    ON CONFLICT (business_id, manufacturer_id)
      DO UPDATE SET balance = public.manufacturer_crate_balances.balance + EXCLUDED.balance,
                    last_updated_at = v_now
    RETURNING * INTO v_balance_row;
  END IF;

  SELECT to_jsonb(cl.*) INTO v_ledger_row FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;

  RETURN jsonb_build_object(
    'crate_ledger_row', v_ledger_row,
    'balance_row',      to_jsonb(v_balance_row),
    'replayed',         false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid)
  TO authenticated, service_role;

-- ── 6. pos_approve_crate_return — re-keyed to manufacturer ──────────────────
-- Reads v_pending.manufacturer_id; the ledger row + balance upsert key by it.
CREATE OR REPLACE FUNCTION public.pos_approve_crate_return(
  p_business_id        uuid,
  p_actor_id           uuid,
  p_pending_return_id  uuid,
  p_ledger_id          uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now           timestamptz := now();
  v_pending       record;
  v_already       bool;
  v_balance_row   record;
  v_ledger_row    jsonb;
  v_pending_row   jsonb;
  v_balance_jsonb jsonb;
  v_delta         int;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  SELECT * INTO v_pending FROM public.pending_crate_returns
   WHERE id = p_pending_return_id AND business_id = p_business_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pending_return_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Replay path.
  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_ledger_id) INTO v_already;
  IF v_already AND v_pending.status = 'approved' THEN
    SELECT to_jsonb(pcr.*) INTO v_pending_row FROM public.pending_crate_returns pcr WHERE pcr.id = p_pending_return_id;
    SELECT to_jsonb(cl.*)  INTO v_ledger_row  FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
    SELECT to_jsonb(ccb.*) INTO v_balance_jsonb
      FROM public.customer_crate_balances ccb
      WHERE ccb.business_id = p_business_id
        AND ccb.customer_id = v_pending.customer_id
        AND ccb.manufacturer_id = v_pending.manufacturer_id;
    RETURN jsonb_build_object(
      'pending_return',    v_pending_row,
      'crate_ledger_row',  v_ledger_row,
      'balance_row',       v_balance_jsonb,
      'replayed',          true
    );
  END IF;

  IF v_pending.status <> 'pending' THEN
    RAISE EXCEPTION 'cannot_approve_status_%', v_pending.status USING ERRCODE = 'P0001';
  END IF;

  v_delta := -v_pending.quantity;

  UPDATE public.pending_crate_returns
     SET status      = 'approved',
         approved_by = p_actor_id,
         approved_at = v_now
   WHERE id = p_pending_return_id;

  INSERT INTO public.crate_ledger (
    id, business_id, customer_id, manufacturer_id, crate_size_group_id,
    quantity_delta, movement_type, reference_order_id, reference_return_id,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_ledger_id, p_business_id, v_pending.customer_id, v_pending.manufacturer_id, NULL,
    v_delta, 'returned', NULL, p_pending_return_id,
    p_actor_id, v_now, v_now
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.customer_crate_balances (
    id, business_id, customer_id, manufacturer_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_pending.customer_id, v_pending.manufacturer_id,
    v_delta, v_now, v_now
  )
  ON CONFLICT (business_id, customer_id, manufacturer_id)
    DO UPDATE SET balance = public.customer_crate_balances.balance + EXCLUDED.balance,
                  last_updated_at = v_now
  RETURNING * INTO v_balance_row;

  SELECT to_jsonb(pcr.*) INTO v_pending_row FROM public.pending_crate_returns pcr WHERE pcr.id = p_pending_return_id;
  SELECT to_jsonb(cl.*)  INTO v_ledger_row  FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;

  RETURN jsonb_build_object(
    'pending_return',   v_pending_row,
    'crate_ledger_row', v_ledger_row,
    'balance_row',      to_jsonb(v_balance_row),
    'replayed',         false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_approve_crate_return(uuid, uuid, uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_approve_crate_return(uuid, uuid, uuid, uuid)
  TO authenticated, service_role;

COMMIT;
