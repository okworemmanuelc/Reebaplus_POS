-- 0070_rollback.sql — reverse 0070_crate_tracking_by_manufacturer.sql
--
-- Restores crate tracking to the crate-size-group keying (the 0047 shape).
-- NOTE: lossy — the forward migration cleared the two balance caches +
-- pending_crate_returns (they rehydrate from activity, not from this script),
-- and new crate_ledger rows written under v29 carry crate_size_group_id = NULL,
-- so restoring crate_ledger.crate_size_group_id to NOT NULL is only safe if no
-- such rows exist. Run only on a DB with no post-0070 crate activity.

BEGIN;

-- ── RPCs back to the 0047 (crate_size_group) bodies ─────────────────────────
DROP FUNCTION IF EXISTS public.pos_record_crate_return(
  uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid
);

CREATE OR REPLACE FUNCTION public.pos_record_crate_return(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_ledger_id            uuid,
  p_owner_kind           text,
  p_owner_id             uuid,
  p_crate_size_group_id  uuid,
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
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_owner_kind NOT IN ('customer','manufacturer') THEN
    RAISE EXCEPTION 'invalid_owner_kind: %', p_owner_kind USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_movement_type NOT IN ('issued','returned','damaged','adjusted','transferred_in','transferred_out') THEN
    RAISE EXCEPTION 'invalid_movement_type: %', p_movement_type USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_ledger_id) INTO v_already;
  IF v_already THEN
    SELECT to_jsonb(cl.*) INTO v_ledger_row FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
    IF p_owner_kind = 'customer' THEN
      SELECT to_jsonb(b.*) INTO v_balance_jsonb FROM public.customer_crate_balances b
       WHERE b.business_id = p_business_id AND b.customer_id = p_owner_id AND b.crate_size_group_id = p_crate_size_group_id;
    ELSE
      SELECT to_jsonb(b.*) INTO v_balance_jsonb FROM public.manufacturer_crate_balances b
       WHERE b.business_id = p_business_id AND b.manufacturer_id = p_owner_id AND b.crate_size_group_id = p_crate_size_group_id;
    END IF;
    RETURN jsonb_build_object('crate_ledger_row', v_ledger_row, 'balance_row', v_balance_jsonb, 'replayed', true);
  END IF;

  INSERT INTO public.crate_ledger (
    id, business_id, customer_id, manufacturer_id, crate_size_group_id,
    quantity_delta, movement_type, reference_order_id, reference_return_id,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_ledger_id, p_business_id,
    CASE WHEN p_owner_kind = 'customer'     THEN p_owner_id END,
    CASE WHEN p_owner_kind = 'manufacturer' THEN p_owner_id END,
    p_crate_size_group_id, p_quantity_delta, p_movement_type,
    p_reference_order_id, p_reference_return_id, p_actor_id, v_now, v_now
  );

  IF p_owner_kind = 'customer' THEN
    INSERT INTO public.customer_crate_balances (id, business_id, customer_id, crate_size_group_id, balance, created_at, last_updated_at)
    VALUES (gen_random_uuid(), p_business_id, p_owner_id, p_crate_size_group_id, p_quantity_delta, v_now, v_now)
    ON CONFLICT (business_id, customer_id, crate_size_group_id)
      DO UPDATE SET balance = public.customer_crate_balances.balance + EXCLUDED.balance, last_updated_at = v_now
    RETURNING * INTO v_balance_row;
  ELSE
    INSERT INTO public.manufacturer_crate_balances (id, business_id, manufacturer_id, crate_size_group_id, balance, created_at, last_updated_at)
    VALUES (gen_random_uuid(), p_business_id, p_owner_id, p_crate_size_group_id, p_quantity_delta, v_now, v_now)
    ON CONFLICT (business_id, manufacturer_id, crate_size_group_id)
      DO UPDATE SET balance = public.manufacturer_crate_balances.balance + EXCLUDED.balance, last_updated_at = v_now
    RETURNING * INTO v_balance_row;
  END IF;

  SELECT to_jsonb(cl.*) INTO v_ledger_row FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
  RETURN jsonb_build_object('crate_ledger_row', v_ledger_row, 'balance_row', to_jsonb(v_balance_row), 'replayed', false);
END;
$$;

REVOKE ALL ON FUNCTION public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.pos_approve_crate_return(
  p_business_id uuid, p_actor_id uuid, p_pending_return_id uuid, p_ledger_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := now();
  v_pending record; v_already bool; v_balance_row record;
  v_ledger_row jsonb; v_pending_row jsonb; v_balance_jsonb jsonb; v_delta int;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);
  SELECT * INTO v_pending FROM public.pending_crate_returns WHERE id = p_pending_return_id AND business_id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pending_return_not_found' USING ERRCODE = 'P0001'; END IF;
  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_ledger_id) INTO v_already;
  IF v_already AND v_pending.status = 'approved' THEN
    SELECT to_jsonb(pcr.*) INTO v_pending_row FROM public.pending_crate_returns pcr WHERE pcr.id = p_pending_return_id;
    SELECT to_jsonb(cl.*)  INTO v_ledger_row  FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
    SELECT to_jsonb(ccb.*) INTO v_balance_jsonb FROM public.customer_crate_balances ccb
      WHERE ccb.business_id = p_business_id AND ccb.customer_id = v_pending.customer_id AND ccb.crate_size_group_id = v_pending.crate_size_group_id;
    RETURN jsonb_build_object('pending_return', v_pending_row, 'crate_ledger_row', v_ledger_row, 'balance_row', v_balance_jsonb, 'replayed', true);
  END IF;
  IF v_pending.status <> 'pending' THEN RAISE EXCEPTION 'cannot_approve_status_%', v_pending.status USING ERRCODE = 'P0001'; END IF;
  v_delta := -v_pending.quantity;
  UPDATE public.pending_crate_returns SET status = 'approved', approved_by = p_actor_id, approved_at = v_now WHERE id = p_pending_return_id;
  INSERT INTO public.crate_ledger (id, business_id, customer_id, manufacturer_id, crate_size_group_id, quantity_delta, movement_type, reference_order_id, reference_return_id, performed_by, created_at, last_updated_at)
  VALUES (p_ledger_id, p_business_id, v_pending.customer_id, NULL, v_pending.crate_size_group_id, v_delta, 'returned', NULL, p_pending_return_id, p_actor_id, v_now, v_now)
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.customer_crate_balances (id, business_id, customer_id, crate_size_group_id, balance, created_at, last_updated_at)
  VALUES (gen_random_uuid(), p_business_id, v_pending.customer_id, v_pending.crate_size_group_id, v_delta, v_now, v_now)
  ON CONFLICT (business_id, customer_id, crate_size_group_id)
    DO UPDATE SET balance = public.customer_crate_balances.balance + EXCLUDED.balance, last_updated_at = v_now
  RETURNING * INTO v_balance_row;
  SELECT to_jsonb(pcr.*) INTO v_pending_row FROM public.pending_crate_returns pcr WHERE pcr.id = p_pending_return_id;
  SELECT to_jsonb(cl.*)  INTO v_ledger_row  FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
  RETURN jsonb_build_object('pending_return', v_pending_row, 'crate_ledger_row', v_ledger_row, 'balance_row', to_jsonb(v_balance_row), 'replayed', false);
END;
$$;

REVOKE ALL ON FUNCTION public.pos_approve_crate_return(uuid, uuid, uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_approve_crate_return(uuid, uuid, uuid, uuid) TO authenticated, service_role;

-- ── Schema back to crate-size keying ────────────────────────────────────────
ALTER TABLE public.crate_ledger DROP CONSTRAINT IF EXISTS crate_ledger_owner_present;
ALTER TABLE public.crate_ledger
  ADD CONSTRAINT crate_ledger_owner_xor
  CHECK ((CASE WHEN customer_id IS NOT NULL THEN 1 ELSE 0 END)
       + (CASE WHEN manufacturer_id IS NOT NULL THEN 1 ELSE 0 END) = 1);

ALTER TABLE public.customer_crate_balances DROP CONSTRAINT IF EXISTS customer_crate_balances_business_customer_mfr_key;
ALTER TABLE public.customer_crate_balances DROP COLUMN IF EXISTS manufacturer_id;
ALTER TABLE public.customer_crate_balances
  ADD CONSTRAINT customer_crate_balances_business_id_customer_id_csg_key
  UNIQUE (business_id, customer_id, crate_size_group_id);

ALTER TABLE public.manufacturer_crate_balances DROP CONSTRAINT IF EXISTS manufacturer_crate_balances_business_mfr_key;
ALTER TABLE public.manufacturer_crate_balances
  ADD CONSTRAINT manufacturer_crate_balances_business_id_manufacturer_id_csg_key
  UNIQUE (business_id, manufacturer_id, crate_size_group_id);

ALTER TABLE public.pending_crate_returns DROP COLUMN IF EXISTS manufacturer_id;

COMMIT;
