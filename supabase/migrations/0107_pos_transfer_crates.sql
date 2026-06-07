-- 0107_pos_transfer_crates.sql
--
-- New domain RPC: pos_transfer_crates (master plan §16.9 Phase 3).
-- Moves N empty crates from one store to another atomically:
--   • writes two store-stamped crate_ledger rows
--       – transferred_out at source  (store_id = p_from_store_id)
--       – transferred_in  at dest    (store_id = p_to_store_id)
--   • UPSERTs both store_crate_balances rows
--   • guards source balance ≥ 0 (raises insufficient_crates if violated)
--   • manufacturers.empty_crate_stock and manufacturer_crate_balances are
--     NOT touched — an inter-store crate move has no effect on the business
--     total; only the store-level distribution changes.
-- Idempotent via p_out_ledger_id (replay detection on the out-leg id).
-- Additive-only: no schema changes.

CREATE OR REPLACE FUNCTION public.pos_transfer_crates(
  p_business_id    uuid,
  p_actor_id       uuid,
  p_transfer_id    uuid,       -- parent stock_transfers row (for reference)
  p_from_store_id  uuid,
  p_to_store_id    uuid,
  p_manufacturer_id uuid,
  p_quantity       int,        -- positive; crates leaving source, arriving dest
  p_out_ledger_id  uuid,       -- idempotency key for the transferred_out row
  p_in_ledger_id   uuid        -- idempotency key for the transferred_in  row
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now          timestamptz := now();
  v_already      bool;
  v_src_balance  int;
  v_out_row      jsonb;
  v_in_row       jsonb;
  v_src_scb      jsonb;
  v_dst_scb      jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_from_store_id = p_to_store_id THEN
    RAISE EXCEPTION 'same_store_transfer' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotency: if the out-leg already landed, return the existing rows.
  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_out_ledger_id)
    INTO v_already;
  IF v_already THEN
    SELECT to_jsonb(cl.*) INTO v_out_row FROM public.crate_ledger cl WHERE id = p_out_ledger_id;
    SELECT to_jsonb(cl.*) INTO v_in_row  FROM public.crate_ledger cl WHERE id = p_in_ledger_id;
    SELECT to_jsonb(b.*)  INTO v_src_scb FROM public.store_crate_balances b
      WHERE b.business_id = p_business_id AND b.store_id = p_from_store_id AND b.manufacturer_id = p_manufacturer_id;
    SELECT to_jsonb(b.*)  INTO v_dst_scb FROM public.store_crate_balances b
      WHERE b.business_id = p_business_id AND b.store_id = p_to_store_id   AND b.manufacturer_id = p_manufacturer_id;
    RETURN jsonb_build_object(
      'out_ledger_row',      v_out_row,
      'in_ledger_row',       v_in_row,
      'src_store_balance',   v_src_scb,
      'dst_store_balance',   v_dst_scb,
      'replayed',            true
    );
  END IF;

  -- Guard: source must have enough crates.
  SELECT COALESCE(balance, 0)
    INTO v_src_balance
    FROM public.store_crate_balances
   WHERE business_id = p_business_id
     AND store_id    = p_from_store_id
     AND manufacturer_id = p_manufacturer_id;
  IF COALESCE(v_src_balance, 0) < p_quantity THEN
    RAISE EXCEPTION 'insufficient_crates: have %, need %',
      COALESCE(v_src_balance, 0), p_quantity
      USING ERRCODE = 'insufficient_privilege';  -- maps to the InsufficientStockException in client
  END IF;

  -- Source ledger row: transferred_out (negative delta = crates leaving).
  INSERT INTO public.crate_ledger (
    id, business_id, store_id, manufacturer_id,
    quantity_delta, movement_type,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_out_ledger_id, p_business_id, p_from_store_id, p_manufacturer_id,
    -p_quantity, 'transferred_out',
    p_actor_id, v_now, v_now
  );

  -- Destination ledger row: transferred_in (positive delta = crates arriving).
  INSERT INTO public.crate_ledger (
    id, business_id, store_id, manufacturer_id,
    quantity_delta, movement_type,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_in_ledger_id, p_business_id, p_to_store_id, p_manufacturer_id,
    p_quantity, 'transferred_in',
    p_actor_id, v_now, v_now
  );

  -- Decrement source store_crate_balances.
  INSERT INTO public.store_crate_balances (
    id, business_id, store_id, manufacturer_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_from_store_id, p_manufacturer_id,
    -p_quantity, v_now, v_now
  )
  ON CONFLICT (business_id, store_id, manufacturer_id)
    DO UPDATE SET balance         = public.store_crate_balances.balance - p_quantity,
                  last_updated_at = v_now;

  -- Increment destination store_crate_balances.
  INSERT INTO public.store_crate_balances (
    id, business_id, store_id, manufacturer_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_to_store_id, p_manufacturer_id,
    p_quantity, v_now, v_now
  )
  ON CONFLICT (business_id, store_id, manufacturer_id)
    DO UPDATE SET balance         = public.store_crate_balances.balance + p_quantity,
                  last_updated_at = v_now;

  SELECT to_jsonb(cl.*) INTO v_out_row FROM public.crate_ledger cl WHERE id = p_out_ledger_id;
  SELECT to_jsonb(cl.*) INTO v_in_row  FROM public.crate_ledger cl WHERE id = p_in_ledger_id;
  SELECT to_jsonb(b.*)  INTO v_src_scb FROM public.store_crate_balances b
    WHERE b.business_id = p_business_id AND b.store_id = p_from_store_id AND b.manufacturer_id = p_manufacturer_id;
  SELECT to_jsonb(b.*)  INTO v_dst_scb FROM public.store_crate_balances b
    WHERE b.business_id = p_business_id AND b.store_id = p_to_store_id   AND b.manufacturer_id = p_manufacturer_id;

  RETURN jsonb_build_object(
    'out_ledger_row',    v_out_row,
    'in_ledger_row',     v_in_row,
    'src_store_balance', v_src_scb,
    'dst_store_balance', v_dst_scb,
    'replayed',          false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_transfer_crates(uuid,uuid,uuid,uuid,uuid,uuid,int,uuid,uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_transfer_crates(uuid,uuid,uuid,uuid,uuid,uuid,int,uuid,uuid)
  TO authenticated, service_role;
