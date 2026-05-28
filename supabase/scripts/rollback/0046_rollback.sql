-- 0046_rollback.sql — rollback for migration 0046_pivot_small_renames.sql
--
-- WHEN TO USE
--   * 0046 deployed but a client / RPC consumer is still hard-coded to the
--     pre-rename names (customer_group, purchase_id, purchases) and can't
--     be fixed quickly.
--   * 0046 caused unexpected fallout you need to revert before the next
--     deploy window.
--
-- WHAT THIS DOES (reverse order of 0046)
--   1. CREATE OR REPLACE each RPC 0046 rewrote, back to its pre-rename
--      (0045 / 0006) body: pos_create_customer (p_customer_group),
--      pos_pull_snapshot ('purchases'), pos_inventory_delta_v2
--      (purchase_id). Sources verbatim from 0045.
--   2. Re-create the dead v1 pos_inventory_delta that 0046 dropped, from
--      its 0006 body (references warehouse_id + purchase_id — it was
--      already broken pre-0046; this restores the exact prior state, not
--      a working function). plpgsql is late-bound so the CREATE succeeds.
--   3. Reverse-rename the ledger FK columns shipment_id → purchase_id.
--   4. Rename the table back: public.shipments → public.purchases (+ index).
--   5. Reverse-rename customers.price_tier → customer_group.
--
-- WHAT THIS DOES NOT DO
--   * Does not touch client code. Roll back the Drift v15 schema via the
--     Drift downgrade path separately if needed.
--   * Does not roll back data writes between 0046 and now; renamed
--     columns/table hold the same rows — this just relabels them.
--
-- VERIFY BEFORE RUNNING
--   SELECT to_regclass('public.shipments');   -- expect 'shipments' (0046 applied)
--   SELECT to_regclass('public.purchases');   -- expect NULL
--   -- If those don't match, 0046 wasn't applied; do nothing.

BEGIN;

-- =========================================================================
-- 1. pos_create_customer — restore 0045 body (p_customer_group / customer_group).
-- =========================================================================
DROP FUNCTION IF EXISTS public.pos_create_customer(
  uuid, uuid, uuid, text, text, text, text, text, text, int, uuid
);

CREATE OR REPLACE FUNCTION public.pos_create_customer(
  p_business_id          uuid,
  p_customer_id          uuid,
  p_wallet_id            uuid,
  p_name                 text,
  p_phone                text DEFAULT NULL,
  p_email                text DEFAULT NULL,
  p_address              text DEFAULT NULL,
  p_google_maps_location text DEFAULT NULL,
  p_customer_group       text DEFAULT 'retailer',
  p_wallet_limit_kobo    int  DEFAULT 0,
  p_store_id             uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now           timestamptz := now();
  v_inserted      bool;
  v_customer_row  jsonb;
  v_wallet_row    jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  WITH ins AS (
    INSERT INTO public.customers (
      id, business_id, store_id, name, phone, email, address,
      google_maps_location, customer_group, wallet_limit_kobo,
      is_deleted, created_at, last_updated_at
    )
    VALUES (
      p_customer_id, p_business_id, p_store_id, p_name, p_phone, p_email, p_address,
      p_google_maps_location, p_customer_group, p_wallet_limit_kobo,
      false, v_now, v_now
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;

  INSERT INTO public.customer_wallets (
    id, business_id, customer_id, currency, is_active, is_deleted, created_at, last_updated_at
  )
  VALUES (
    p_wallet_id, p_business_id, p_customer_id, 'NGN', true, false, v_now, v_now
  )
  ON CONFLICT (business_id, customer_id) DO NOTHING;

  SELECT to_jsonb(c.*)  INTO v_customer_row FROM public.customers c        WHERE c.id = p_customer_id;
  SELECT to_jsonb(cw.*) INTO v_wallet_row   FROM public.customer_wallets cw WHERE cw.customer_id = p_customer_id AND cw.business_id = p_business_id;

  RETURN jsonb_build_object(
    'customer',         v_customer_row,
    'customer_wallet',  v_wallet_row,
    'replayed',         NOT v_inserted
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_create_customer(uuid, uuid, uuid, text, text, text, text, text, text, int, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_create_customer(uuid, uuid, uuid, text, text, text, text, text, text, int, uuid)
  TO authenticated, service_role;

-- =========================================================================
-- 2. pos_pull_snapshot — restore 0045 body (v_tenant_tables has 'purchases').
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pos_pull_snapshot(
  p_business_id uuid,
  p_since       timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid;
  v_result          jsonb := '{}'::jsonb;
  v_table           text;
  v_rows            jsonb;
  v_query           text;
  v_tenant_tables   text[] := ARRAY[
    'profiles','users','stores','manufacturers','crate_groups',
    'categories','products','inventory','customers','suppliers',
    'orders','order_items','purchases','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'notifications','stock_transactions',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    'price_lists','payment_transactions','sessions','settings'
  ];
BEGIN
  v_caller_business := public.business_id();
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'no_business_for_caller'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_caller_business <> p_business_id THEN
    RAISE EXCEPTION 'tenant_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    INTO v_rows
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND (p_since IS NULL OR b.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('businesses', v_rows);

  FOREACH v_table IN ARRAY v_tenant_tables LOOP
    v_query := format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)
         FROM public.%I t
         WHERE t.business_id = $1
           AND ($2::timestamptz IS NULL OR t.last_updated_at > $2)',
      v_table
    );
    EXECUTE v_query INTO v_rows USING p_business_id, p_since;
    v_result := v_result || jsonb_build_object(v_table, v_rows);
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
    INTO v_rows
    FROM public.system_config s
    WHERE (p_since IS NULL OR s.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('system_config', v_rows);

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz)
  TO authenticated;

-- =========================================================================
-- 3. pos_inventory_delta_v2 — restore 0045 body (stock_transactions.purchase_id).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pos_inventory_delta_v2(
  p_business_id uuid,
  p_actor_id    uuid,
  p_movements   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now           timestamptz := now();
  v_mv            jsonb;
  v_mv_id         uuid;
  v_movement_type text;
  v_ref_type      text;
  v_ref_id        uuid;
  v_adjustment_id uuid;
  v_new_qty       int;
  v_stx_id        uuid;
  v_inv_after     jsonb := '[]'::jsonb;
  v_stock_txns    jsonb := '[]'::jsonb;
  v_adjustments   jsonb := '[]'::jsonb;
  v_already_done  bool;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF jsonb_typeof(p_movements) <> 'array' THEN
    RAISE EXCEPTION 'movements_must_be_array' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_mv IN SELECT * FROM jsonb_array_elements(p_movements) LOOP
    v_mv_id         := (v_mv->>'movement_id')::uuid;
    v_movement_type := v_mv->>'movement_type';
    v_ref_type      := v_mv->>'ref_type';
    v_ref_id        := NULLIF(v_mv->>'ref_id', '')::uuid;

    IF v_mv_id IS NULL THEN
      RAISE EXCEPTION 'movement_id_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_movement_type = 'sale' THEN
      RAISE EXCEPTION 'sale_must_use_pos_record_sale_v2' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_movement_type NOT IN ('return','damage','transfer_out','transfer_in','purchase_received','adjustment') THEN
      RAISE EXCEPTION 'invalid_movement_type: %', v_movement_type USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT EXISTS(SELECT 1 FROM public.stock_transactions WHERE id = v_mv_id) INTO v_already_done;
    IF v_already_done THEN
      v_stock_txns := v_stock_txns || to_jsonb(
        (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_mv_id));
      CONTINUE;
    END IF;

    IF (v_mv->>'quantity_delta')::int < 0 THEN
      UPDATE public.inventory
         SET quantity = quantity + (v_mv->>'quantity_delta')::int
       WHERE business_id = p_business_id
         AND product_id  = (v_mv->>'product_id')::uuid
         AND store_id    = (v_mv->>'store_id')::uuid
         AND quantity + (v_mv->>'quantity_delta')::int >= 0
      RETURNING quantity INTO v_new_qty;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient_stock'
          USING ERRCODE = 'P0001',
                HINT = jsonb_build_object(
                  'product_id',      v_mv->>'product_id',
                  'store_id',        v_mv->>'store_id',
                  'requested_delta', (v_mv->>'quantity_delta')::int
                )::text;
      END IF;
    ELSE
      INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
      VALUES (
        gen_random_uuid(), p_business_id,
        (v_mv->>'product_id')::uuid, (v_mv->>'store_id')::uuid,
        (v_mv->>'quantity_delta')::int, v_now, v_now
      )
      ON CONFLICT (business_id, product_id, store_id)
        DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
      RETURNING quantity INTO v_new_qty;
    END IF;

    IF v_movement_type = 'adjustment' AND v_ref_type IS NULL THEN
      v_adjustment_id := gen_random_uuid();
      INSERT INTO public.stock_adjustments (
        id, business_id, product_id, store_id, quantity_diff, reason,
        performed_by, created_at, last_updated_at
      )
      VALUES (
        v_adjustment_id, p_business_id,
        (v_mv->>'product_id')::uuid, (v_mv->>'store_id')::uuid,
        (v_mv->>'quantity_delta')::int,
        COALESCE(v_mv->>'reason', 'manual_adjustment'),
        p_actor_id, v_now, v_now
      );
      v_ref_type := 'adjustment';
      v_ref_id   := v_adjustment_id;
      v_adjustments := v_adjustments || to_jsonb(
        (SELECT sa FROM public.stock_adjustments sa WHERE sa.id = v_adjustment_id));
    END IF;

    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, transfer_id, adjustment_id, purchase_id,
      performed_by, created_at, last_updated_at
    )
    VALUES (
      v_mv_id, p_business_id,
      (v_mv->>'product_id')::uuid, (v_mv->>'store_id')::uuid,
      (v_mv->>'quantity_delta')::int, v_movement_type,
      CASE WHEN v_ref_type = 'order'      THEN v_ref_id END,
      CASE WHEN v_ref_type = 'transfer'   THEN v_ref_id END,
      CASE WHEN v_ref_type = 'adjustment' THEN v_ref_id END,
      CASE WHEN v_ref_type = 'purchase'   THEN v_ref_id END,
      p_actor_id, v_now, v_now
    );

    v_stock_txns := v_stock_txns || to_jsonb(
      (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_mv_id));
    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      (v_mv->>'product_id')::uuid,
      'store_id',        (v_mv->>'store_id')::uuid,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );
  END LOOP;

  RETURN jsonb_build_object(
    'stock_transactions', v_stock_txns,
    'stock_adjustments',  v_adjustments,
    'inventory_after',    v_inv_after
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_inventory_delta_v2(uuid, uuid, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_inventory_delta_v2(uuid, uuid, jsonb)
  TO authenticated, service_role;

-- =========================================================================
-- 4. Re-create dead v1 pos_inventory_delta from its 0006 body (verbatim).
--    NOTE: references warehouse_id / purchase_id — it was already broken
--    pre-0046 (0045 renamed inventory.warehouse_id). This restores the
--    exact prior state, not a working function. plpgsql late-binds, so
--    CREATE succeeds regardless.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pos_inventory_delta(
  p_business_id uuid,
  p_movements   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid;
  v_mv              jsonb;
  v_new_qty         int;
  v_inv_after       jsonb := '[]'::jsonb;
  v_stx_ids         jsonb := '[]'::jsonb;
  v_movement_type   text;
  v_ref_type        text;
  v_ref_id          uuid;
BEGIN
  v_caller_business := public.business_id();
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'no_business_for_caller' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_caller_business <> p_business_id THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR v_mv IN SELECT * FROM jsonb_array_elements(p_movements) LOOP
    v_movement_type := v_mv->>'movement_type';
    v_ref_type      := v_mv->>'ref_type';
    v_ref_id        := NULLIF(v_mv->>'ref_id', '')::uuid;

    IF v_movement_type = 'sale' THEN
      RAISE EXCEPTION 'sale_must_use_pos_record_sale'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_movement_type NOT IN ('return','damage','transfer_out','transfer_in','purchase_received','adjustment') THEN
      RAISE EXCEPTION 'invalid_movement_type: %', v_movement_type
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF (v_mv->>'quantity_delta')::int < 0 THEN
      UPDATE public.inventory
         SET quantity = quantity + (v_mv->>'quantity_delta')::int
       WHERE business_id  = p_business_id
         AND product_id   = (v_mv->>'product_id')::uuid
         AND warehouse_id = (v_mv->>'warehouse_id')::uuid
         AND quantity + (v_mv->>'quantity_delta')::int >= 0
      RETURNING quantity INTO v_new_qty;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient_stock'
          USING ERRCODE = 'P0001',
                HINT = jsonb_build_object(
                  'product_id',      v_mv->>'product_id',
                  'warehouse_id',    v_mv->>'warehouse_id',
                  'requested_delta', (v_mv->>'quantity_delta')::int
                )::text;
      END IF;
    ELSE
      INSERT INTO public.inventory (id, business_id, product_id, warehouse_id, quantity)
      VALUES (
        gen_random_uuid(),
        p_business_id,
        (v_mv->>'product_id')::uuid,
        (v_mv->>'warehouse_id')::uuid,
        (v_mv->>'quantity_delta')::int
      )
      ON CONFLICT (business_id, product_id, warehouse_id)
        DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
      RETURNING quantity INTO v_new_qty;
    END IF;

    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, transfer_id, adjustment_id, purchase_id,
      performed_by, created_at, last_updated_at
    )
    VALUES (
      COALESCE((v_mv->>'id')::uuid, gen_random_uuid()),
      p_business_id,
      (v_mv->>'product_id')::uuid,
      (v_mv->>'warehouse_id')::uuid,
      (v_mv->>'quantity_delta')::int,
      v_movement_type,
      CASE WHEN v_ref_type = 'order'      THEN v_ref_id END,
      CASE WHEN v_ref_type = 'transfer'   THEN v_ref_id END,
      CASE WHEN v_ref_type = 'adjustment' THEN v_ref_id END,
      CASE WHEN v_ref_type = 'purchase'   THEN v_ref_id END,
      NULLIF(v_mv->>'performed_by','')::uuid,
      now(), now()
    )
    ON CONFLICT (id) DO NOTHING;

    v_stx_ids := v_stx_ids || jsonb_build_array(COALESCE((v_mv->>'id')::uuid, NULL));
    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      (v_mv->>'product_id')::uuid,
      'warehouse_id',    (v_mv->>'warehouse_id')::uuid,
      'quantity',        v_new_qty,
      'last_updated_at', now()
    );
  END LOOP;

  RETURN jsonb_build_object(
    'inventory_after',       v_inv_after,
    'stock_transaction_ids', v_stx_ids
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_inventory_delta(uuid, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_inventory_delta(uuid, jsonb)
  TO authenticated, service_role;

-- =========================================================================
-- 5. Reverse-rename ledger FK columns shipment_id → purchase_id.
-- =========================================================================
ALTER TABLE public.stock_transactions   RENAME COLUMN shipment_id TO purchase_id;
ALTER TABLE public.payment_transactions RENAME COLUMN shipment_id TO purchase_id;

-- =========================================================================
-- 6. Rename the table back: public.shipments → public.purchases (+ index).
-- =========================================================================
ALTER TABLE public.shipments RENAME TO purchases;
ALTER INDEX public.idx_shipments_business_lua RENAME TO idx_purchases_business_lua;

-- =========================================================================
-- 7. Reverse-rename customers.price_tier → customer_group and restore the
--    original 4-value CHECK. NOTE: the distributor→wholesaler /
--    walk_in→retailer data migration is NOT reversed (the original values
--    are unrecoverable) — this restores the schema, not the old data.
-- =========================================================================
ALTER TABLE public.customers DROP CONSTRAINT customers_price_tier_check;
ALTER TABLE public.customers RENAME COLUMN price_tier TO customer_group;
ALTER TABLE public.customers
  ADD CONSTRAINT customers_customer_group_check
  CHECK (customer_group IN ('retailer','wholesaler','distributor','walk_in'));

COMMIT;
