-- 0045_rollback.sql — rollback for migration 0045_rename_warehouses_to_stores.sql
--
-- WHEN TO USE
--   * 0045 deployed but some client / RPC consumer is still hard-coded
--     to the old names and can't be fixed quickly. Roll back to give
--     the client a stable target.
--   * 0045 caused unexpected fallout (FK constraint name collisions,
--     index naming clashes, …) that you need to revert before the next
--     deploy window.
--
-- WHAT THIS DOES (reverse order of 0045)
--   1. Re-issue `complete_onboarding` with its 0044 signature/body
--      (p_warehouse_id, public.warehouses, Main Warehouse, …) FIRST —
--      so any in-flight client that still calls the pre-rename
--      signature keeps working while the rest of the rollback runs.
--   2. CREATE OR REPLACE each RPC that 0045 rewrote (pos_pull_snapshot,
--      pos_record_sale_v2, pos_inventory_delta_v2, pos_create_product_v2,
--      pos_cancel_order, pos_record_expense, pos_create_customer) back
--      to its pre-rename body. Sources: 0020 (snapshot), 0017 (record
--      sale), 0011 (everything else).
--   3. Reverse-rename indexes.
--   4. Reverse-rename FK / UNIQUE constraints.
--   5. Reverse-rename columns (store_id → warehouse_id) on the 10 tables.
--   6. Rename the table back: public.stores → public.warehouses.
--
-- WHAT THIS DOES NOT DO
--   * Does not touch any client code. The Drift schema migration that
--     accompanied 0045 is a separate concern; roll that back via the
--     Drift downgrade path if needed.
--   * Does not roll back any data writes that occurred between 0045
--     and now. The renamed columns / table contain the same rows;
--     this rollback just relabels them.
--
-- VERIFY BEFORE RUNNING
--   psql -c "SELECT to_regclass('public.stores')"          -- expect 'stores'
--   psql -c "SELECT to_regclass('public.warehouses')"      -- expect NULL
--   -- If those don't match, 0045 wasn't applied; do nothing.

BEGIN;

-- =========================================================================
-- 1. Restore `complete_onboarding` to its 0044 body. DROP + recreate
--    so the signature change (p_store_id → p_warehouse_id) lands cleanly.
--    Body is verbatim from migration 0044_complete_onboarding_seeds_roles.sql.
-- =========================================================================

DROP FUNCTION IF EXISTS public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
);

CREATE OR REPLACE FUNCTION public.complete_onboarding(
  p_business_id     uuid,
  p_warehouse_id    uuid,
  p_owner_name      text,
  p_business_name   text,
  p_business_type   text,
  p_business_phone  text,
  p_business_email  text,
  p_location        jsonb,
  p_settings        jsonb,
  p_user_id         uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid          uuid := auth.uid();
  v_loc_name     text;
  v_loc_combined text;
  v_currency     text;
  v_timezone     text;
  v_tax          text;
  v_user_id      uuid;
  v_seed_row     RECORD;
  v_ceo_role_id  uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'complete_onboarding requires an authenticated session';
  END IF;

  IF p_business_id IS NULL OR p_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'complete_onboarding requires non-null p_business_id and p_warehouse_id';
  END IF;

  IF p_owner_name IS NULL OR length(trim(p_owner_name)) = 0
     OR p_business_name IS NULL OR length(trim(p_business_name)) = 0 THEN
    RAISE EXCEPTION 'complete_onboarding requires non-empty p_owner_name and p_business_name';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.businesses
    WHERE id = p_business_id AND owner_id IS NOT NULL AND owner_id <> v_uid
  ) THEN
    RAISE EXCEPTION 'complete_onboarding: business % is owned by a different user', p_business_id;
  END IF;

  -- 1. businesses.
  INSERT INTO public.businesses (id, owner_id, onboarding_complete, name, type, phone, email)
    VALUES (p_business_id, v_uid, true, p_business_name, p_business_type, p_business_phone, p_business_email)
  ON CONFLICT (id) DO UPDATE
    SET name                = EXCLUDED.name,
        type                = EXCLUDED.type,
        phone               = EXCLUDED.phone,
        email               = EXCLUDED.email,
        onboarding_complete = true;

  -- 2. profiles — identity only.
  INSERT INTO public.profiles (id, business_id, name)
    VALUES (v_uid, p_business_id, p_owner_name)
  ON CONFLICT (id) DO UPDATE
    SET business_id = EXCLUDED.business_id,
        name        = EXCLUDED.name;

  -- 3. warehouses.
  v_loc_name := COALESCE(NULLIF(trim(p_location ->> 'name'), ''), 'Main Warehouse');
  v_loc_combined := concat_ws(', ',
    NULLIF(trim(coalesce(p_location ->> 'street', '')), ''),
    NULLIF(trim(coalesce(p_location ->> 'city',   '')), ''),
    NULLIF(trim(coalesce(p_location ->> 'country',''))  , '')
  );

  INSERT INTO public.warehouses (id, business_id, name, location, is_deleted)
    VALUES (p_warehouse_id, p_business_id, v_loc_name, NULLIF(v_loc_combined, ''), false)
  ON CONFLICT (id) DO UPDATE
    SET name     = EXCLUDED.name,
        location = EXCLUDED.location;

  -- 4. settings.
  v_currency := COALESCE(NULLIF(trim(p_settings ->> 'currency'), ''), 'NGN');
  v_timezone := COALESCE(NULLIF(trim(p_settings ->> 'timezone'), ''), 'Africa/Lagos');
  v_tax      := NULLIF(trim(coalesce(p_settings ->> 'tax_reg_number', '')), '');

  INSERT INTO public.settings (business_id, key, value)
    VALUES (p_business_id, 'default_currency', v_currency)
  ON CONFLICT (business_id, key) DO UPDATE SET value = EXCLUDED.value;

  INSERT INTO public.settings (business_id, key, value)
    VALUES (p_business_id, 'timezone', v_timezone)
  ON CONFLICT (business_id, key) DO UPDATE SET value = EXCLUDED.value;

  IF v_tax IS NOT NULL THEN
    INSERT INTO public.settings (business_id, key, value)
      VALUES (p_business_id, 'tax_registration_number', v_tax)
    ON CONFLICT (business_id, key) DO UPDATE SET value = EXCLUDED.value;
  END IF;

  -- 5. users — identity only. find-or-create by (auth_user_id, business_id).
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = v_uid AND business_id = p_business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      id, auth_user_id, business_id, name, email
    ) VALUES (
      COALESCE(p_user_id, gen_random_uuid()),
      v_uid, p_business_id, p_owner_name, p_business_email
    )
    ON CONFLICT (business_id, email) DO UPDATE
      SET auth_user_id    = EXCLUDED.auth_user_id,
          name            = EXCLUDED.name,
          last_updated_at = now()
    RETURNING id INTO v_user_id;
  END IF;

  -- 6. (v13 / master plan §2.4): seed default roles + permissions +
  --    settings for the new business. Idempotent helper from
  --    migration 0043 — re-running on retry is a no-op.
  SELECT * INTO v_seed_row
    FROM public.seed_default_roles_for_business(p_business_id);
  v_ceo_role_id := v_seed_row.ceo_role_id;

  -- 7. Bind the new CEO to their business with role=CEO.
  INSERT INTO public.user_businesses (
    business_id, user_id, role_id, status
  ) VALUES (
    p_business_id, v_user_id, v_ceo_role_id, 'active'
  )
  ON CONFLICT (user_id, business_id) DO UPDATE
    SET role_id = EXCLUDED.role_id,
        status  = 'active';

  -- 8. Bind the new CEO to their first store.
  INSERT INTO public.user_stores (
    business_id, user_id, warehouse_id
  ) VALUES (
    p_business_id, v_user_id, p_warehouse_id
  )
  ON CONFLICT (user_id, warehouse_id) DO NOTHING;
END;
$function$;

REVOKE ALL    ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
) FROM public;
GRANT EXECUTE ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
) TO authenticated, service_role;


-- =========================================================================
-- 2. CREATE OR REPLACE each RPC 0045 rewrote, back to its pre-rename body.
-- =========================================================================

-- -----------------------------------------------------------------------------
-- 2a. pos_pull_snapshot — body restored to a 0020-shape version. The
--     'business_members' and 'invites' entries from the original 0020
--     array are intentionally OMITTED — those tables were dropped by
--     0041 and the function has been broken on a missing-table error
--     since then. 0045 fixed this in the forward direction; the
--     rollback preserves the fix rather than re-introducing the bug.
--     The rename back to 'warehouses' is the only true rollback action
--     in this body.
-- -----------------------------------------------------------------------------

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
    'profiles','users','warehouses','manufacturers','crate_groups',
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


-- -----------------------------------------------------------------------------
-- 2b. pos_record_sale_v2 — body from 0017. DROP first because 0045
--     renamed the parameter p_warehouse_id → p_store_id, and Postgres
--     won't rename a parameter via CREATE OR REPLACE.
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text, text, text, int, bool
);

CREATE OR REPLACE FUNCTION public.pos_record_sale_v2(
  p_business_id             uuid,
  p_actor_id                uuid,
  p_order_id                uuid,           -- idempotency key
  p_order_number            text,
  p_warehouse_id            uuid,
  p_payment_type            text,
  p_items                   jsonb,          -- [{product_id, quantity, unit_price_kobo, buying_price_kobo?, price_snapshot?}]
  p_status                  text DEFAULT 'completed',
  p_customer_id             uuid DEFAULT NULL,
  p_discount_kobo           int  DEFAULT 0,
  p_amount_paid_kobo        int  DEFAULT 0,
  p_crate_deposit_paid_kobo int  DEFAULT 0,
  p_rider_name              text DEFAULT 'Pick-up Order',
  p_barcode                 text DEFAULT NULL,
  p_payment_method          text DEFAULT NULL,   -- required if amount_paid > 0
  p_wallet_amount_kobo      int  DEFAULT 0,      -- portion of amount_paid drawn from wallet
  p_customer_verified       bool DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_total_amount       int;
  v_net_amount         int;
  v_now                timestamptz := now();
  v_inserted           bool := false;
  v_order_lua          timestamptz;
  v_order_row          jsonb;
  v_item               jsonb;
  v_item_id            uuid;
  v_total_kobo         int;
  v_existing_qty       int;
  v_new_qty            int;
  v_stx_id             uuid;
  v_inv_after          jsonb := '[]'::jsonb;
  v_order_items        jsonb := '[]'::jsonb;
  v_stock_txns         jsonb := '[]'::jsonb;
  v_payment_id         uuid;
  v_payment_row        jsonb;
  v_wallet_id          uuid;
  v_wallet_balance     int;
  v_wallet_txn_id      uuid;
  v_wallet_txn_row     jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_amount_paid_kobo > 0 AND p_payment_method IS NULL THEN
    RAISE EXCEPTION 'payment_method_required_when_paid' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_wallet_amount_kobo > 0 AND p_customer_id IS NULL THEN
    RAISE EXCEPTION 'wallet_payment_requires_customer' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Server-computed totals.
  SELECT COALESCE(SUM((it->>'quantity')::int * (it->>'unit_price_kobo')::int), 0)
    INTO v_total_amount
    FROM jsonb_array_elements(p_items) AS it;

  v_net_amount := v_total_amount - p_discount_kobo + p_crate_deposit_paid_kobo;

  -- Idempotent order insert.
  WITH ins AS (
    INSERT INTO public.orders (
      id, business_id, order_number, customer_id,
      total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
      payment_type, status, rider_name, barcode,
      staff_id, warehouse_id, crate_deposit_paid_kobo,
      completed_at, cancelled_at, created_at, last_updated_at
    )
    VALUES (
      p_order_id, p_business_id, p_order_number, p_customer_id,
      v_total_amount, p_discount_kobo, v_net_amount, p_amount_paid_kobo,
      p_payment_type, p_status, p_rider_name, p_barcode,
      p_actor_id, p_warehouse_id, p_crate_deposit_paid_kobo,
      CASE WHEN p_status = 'completed' THEN v_now ELSE NULL END,
      NULL, v_now, v_now
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;

  IF NOT v_inserted THEN
    -- Replay path. Compose the response from existing state.
    SELECT to_jsonb(o.*), o.last_updated_at INTO v_order_row, v_order_lua
      FROM public.orders o WHERE o.id = p_order_id;

    SELECT COALESCE(jsonb_agg(to_jsonb(oi.*)), '[]'::jsonb) INTO v_order_items
      FROM public.order_items oi WHERE oi.order_id = p_order_id;

    SELECT COALESCE(jsonb_agg(to_jsonb(stx.*)), '[]'::jsonb) INTO v_stock_txns
      FROM public.stock_transactions stx WHERE stx.order_id = p_order_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'product_id',      i.product_id,
             'warehouse_id',    i.warehouse_id,
             'quantity',        i.quantity,
             'last_updated_at', i.last_updated_at)), '[]'::jsonb)
      INTO v_inv_after
      FROM public.inventory i
      WHERE i.business_id  = p_business_id
        AND i.warehouse_id = p_warehouse_id
        AND i.product_id IN (
          SELECT (it->>'product_id')::uuid FROM jsonb_array_elements(p_items) it
        );

    SELECT to_jsonb(pt.*) INTO v_payment_row
      FROM public.payment_transactions pt
      WHERE pt.order_id = p_order_id AND pt.voided_at IS NULL
      ORDER BY pt.created_at LIMIT 1;

    SELECT to_jsonb(wt.*) INTO v_wallet_txn_row
      FROM public.wallet_transactions wt
      WHERE wt.order_id = p_order_id AND wt.voided_at IS NULL
      ORDER BY wt.created_at LIMIT 1;

    RETURN jsonb_build_object(
      'order',                v_order_row,
      'order_items',          v_order_items,
      'stock_transactions',   v_stock_txns,
      'payment_transaction',  v_payment_row,
      'wallet_transaction',   v_wallet_txn_row,
      'inventory_after',      v_inv_after,
      'replayed',             true
    );
  END IF;

  -- Items + inventory deltas + stock_transactions.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF (v_item->>'quantity')::int <= 0 THEN
      RAISE EXCEPTION 'item_quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_item_id    := gen_random_uuid();
    v_total_kobo := (v_item->>'quantity')::int * (v_item->>'unit_price_kobo')::int;

    INSERT INTO public.order_items (
      id, business_id, order_id, product_id, warehouse_id,
      quantity, unit_price_kobo, buying_price_kobo, total_kobo, price_snapshot,
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id,
      (v_item->>'product_id')::uuid, p_warehouse_id,
      (v_item->>'quantity')::int,
      (v_item->>'unit_price_kobo')::int,
      COALESCE((v_item->>'buying_price_kobo')::int, 0),
      v_total_kobo,
      CASE WHEN v_item ? 'price_snapshot' THEN v_item->'price_snapshot' ELSE NULL END,
      v_now, v_now
    );

    v_order_items := v_order_items || to_jsonb((SELECT oi FROM public.order_items oi WHERE oi.id = v_item_id));

    -- Lock the inventory row so we can distinguish "no row exists" from
    -- "row exists but qty too low". FOR UPDATE matches the wallet pattern
    -- in 0014; concurrent sales for the same product+warehouse serialize
    -- here.
    SELECT quantity INTO v_existing_qty
      FROM public.inventory
     WHERE business_id  = p_business_id
       AND product_id   = (v_item->>'product_id')::uuid
       AND warehouse_id = p_warehouse_id
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'inventory_row_missing'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id',   v_item->>'product_id',
                'warehouse_id', p_warehouse_id
              )::text;
    END IF;

    IF v_existing_qty < (v_item->>'quantity')::int THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id',      v_item->>'product_id',
                'warehouse_id',    p_warehouse_id,
                'requested_qty',   (v_item->>'quantity')::int,
                'available_qty',   v_existing_qty
              )::text;
    END IF;

    UPDATE public.inventory
       SET quantity = quantity - (v_item->>'quantity')::int
     WHERE business_id  = p_business_id
       AND product_id   = (v_item->>'product_id')::uuid
       AND warehouse_id = p_warehouse_id
    RETURNING quantity INTO v_new_qty;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      (v_item->>'product_id')::uuid,
      'warehouse_id',    p_warehouse_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );

    -- Ledger row.
    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, (v_item->>'product_id')::uuid, p_warehouse_id,
      -(v_item->>'quantity')::int, 'sale',
      p_order_id, p_actor_id, v_now, v_now
    );

    v_stock_txns := v_stock_txns || to_jsonb((SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_stx_id));
  END LOOP;

  -- Payment (optional).
  IF p_amount_paid_kobo > 0 THEN
    v_payment_id := gen_random_uuid();
    INSERT INTO public.payment_transactions (
      id, business_id, amount_kobo, method, type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_payment_id, p_business_id, p_amount_paid_kobo, p_payment_method, 'sale',
      p_order_id, p_actor_id, v_now, v_now
    );
    SELECT to_jsonb(pt.*) INTO v_payment_row
      FROM public.payment_transactions pt WHERE pt.id = v_payment_id;
  END IF;

  -- Wallet portion (optional). FOR UPDATE serializes concurrent debits;
  -- see 0014 for the rationale.
  IF p_wallet_amount_kobo > 0 THEN
    SELECT id INTO v_wallet_id
      FROM public.customer_wallets
      WHERE business_id = p_business_id AND customer_id = p_customer_id
      LIMIT 1
      FOR UPDATE;

    IF v_wallet_id IS NULL THEN
      RAISE EXCEPTION 'customer_wallet_missing' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(SUM(signed_amount_kobo), 0) INTO v_wallet_balance
      FROM public.wallet_transactions
      WHERE wallet_id = v_wallet_id;
    IF v_wallet_balance < p_wallet_amount_kobo THEN
      RAISE EXCEPTION 'insufficient_wallet_balance'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'wallet_id',      v_wallet_id,
                'available_kobo', v_wallet_balance,
                'requested_kobo', p_wallet_amount_kobo
              )::text;
    END IF;

    v_wallet_txn_id := gen_random_uuid();
    INSERT INTO public.wallet_transactions (
      id, business_id, wallet_id, customer_id, type,
      amount_kobo, signed_amount_kobo, reference_type, order_id,
      performed_by, customer_verified, created_at, last_updated_at
    )
    VALUES (
      v_wallet_txn_id, p_business_id, v_wallet_id, p_customer_id, 'debit',
      p_wallet_amount_kobo, -p_wallet_amount_kobo, 'order_payment', p_order_id,
      p_actor_id, p_customer_verified, v_now, v_now
    );
    SELECT to_jsonb(wt.*) INTO v_wallet_txn_row
      FROM public.wallet_transactions wt WHERE wt.id = v_wallet_txn_id;
  END IF;

  SELECT to_jsonb(o.*), o.last_updated_at INTO v_order_row, v_order_lua
    FROM public.orders o WHERE o.id = p_order_id;

  RETURN jsonb_build_object(
    'order',                v_order_row,
    'order_items',          v_order_items,
    'stock_transactions',   v_stock_txns,
    'payment_transaction',  v_payment_row,
    'wallet_transaction',   v_wallet_txn_row,
    'inventory_after',      v_inv_after,
    'replayed',             false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text, text, text, int, bool
) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text, text, text, int, bool
) TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 2c. pos_inventory_delta_v2 — body from 0011 §2.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pos_inventory_delta_v2(
  p_business_id uuid,
  p_actor_id    uuid,
  p_movements   jsonb   -- [{movement_id, product_id, warehouse_id, quantity_delta, movement_type, ref_type?, ref_id?, reason?}]
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

    -- Replay detection on the ledger row's idempotency id.
    SELECT EXISTS(SELECT 1 FROM public.stock_transactions WHERE id = v_mv_id) INTO v_already_done;
    IF v_already_done THEN
      v_stock_txns := v_stock_txns || to_jsonb(
        (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_mv_id));
      CONTINUE;
    END IF;

    -- Apply inventory delta.
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
      INSERT INTO public.inventory (id, business_id, product_id, warehouse_id, quantity, created_at, last_updated_at)
      VALUES (
        gen_random_uuid(), p_business_id,
        (v_mv->>'product_id')::uuid, (v_mv->>'warehouse_id')::uuid,
        (v_mv->>'quantity_delta')::int, v_now, v_now
      )
      ON CONFLICT (business_id, product_id, warehouse_id)
        DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
      RETURNING quantity INTO v_new_qty;
    END IF;

    -- For movement_type='adjustment' with no ref, mint a stock_adjustments
    -- row to satisfy the ledger's exactly-one-FK CHECK.
    IF v_movement_type = 'adjustment' AND v_ref_type IS NULL THEN
      v_adjustment_id := gen_random_uuid();
      INSERT INTO public.stock_adjustments (
        id, business_id, product_id, warehouse_id, quantity_diff, reason,
        performed_by, created_at, last_updated_at
      )
      VALUES (
        v_adjustment_id, p_business_id,
        (v_mv->>'product_id')::uuid, (v_mv->>'warehouse_id')::uuid,
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
      (v_mv->>'product_id')::uuid, (v_mv->>'warehouse_id')::uuid,
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
      'warehouse_id',    (v_mv->>'warehouse_id')::uuid,
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


-- -----------------------------------------------------------------------------
-- 2d. pos_create_product_v2 — body from 0011 §3.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pos_create_product_v2(
  p_business_id              uuid,
  p_actor_id                 uuid,
  p_product_id               uuid,
  p_name                     text,
  p_unit                     text     DEFAULT 'Bottle',
  p_subtitle                 text     DEFAULT NULL,
  p_sku                      text     DEFAULT NULL,
  p_size                     text     DEFAULT NULL,
  p_retail_price_kobo        int      DEFAULT 0,
  p_selling_price_kobo       int      DEFAULT 0,
  p_buying_price_kobo        int      DEFAULT 0,
  p_bulk_breaker_price_kobo  int      DEFAULT NULL,
  p_distributor_price_kobo   int      DEFAULT NULL,
  p_category_id              uuid     DEFAULT NULL,
  p_crate_group_id           uuid     DEFAULT NULL,
  p_manufacturer_id          uuid     DEFAULT NULL,
  p_supplier_id              uuid     DEFAULT NULL,
  p_low_stock_threshold      int      DEFAULT 5,
  p_track_empties            bool     DEFAULT false,
  p_image_path               text     DEFAULT NULL,
  p_initial_stock            jsonb    DEFAULT NULL  -- {warehouse_id, quantity}
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now           timestamptz := now();
  v_inserted      bool := false;
  v_product_row   jsonb;
  v_warehouse_id  uuid;
  v_qty           int;
  v_adjustment_id uuid;
  v_stx_id        uuid;
  v_new_qty       int;
  v_inv_after     jsonb := '[]'::jsonb;
  v_adjustments   jsonb := '[]'::jsonb;
  v_stock_txns    jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  WITH ins AS (
    INSERT INTO public.products (
      id, business_id, category_id, crate_group_id, manufacturer_id, supplier_id,
      name, subtitle, sku, size, unit,
      retail_price_kobo, bulk_breaker_price_kobo, distributor_price_kobo,
      selling_price_kobo, buying_price_kobo,
      is_available, is_deleted, low_stock_threshold,
      track_empties, image_path,
      created_at, last_updated_at
    )
    VALUES (
      p_product_id, p_business_id, p_category_id, p_crate_group_id, p_manufacturer_id, p_supplier_id,
      p_name, p_subtitle, p_sku, p_size, p_unit,
      p_retail_price_kobo, p_bulk_breaker_price_kobo, p_distributor_price_kobo,
      p_selling_price_kobo, p_buying_price_kobo,
      true, false, p_low_stock_threshold,
      p_track_empties, p_image_path,
      v_now, v_now
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;

  SELECT to_jsonb(p.*) INTO v_product_row FROM public.products p WHERE p.id = p_product_id;

  IF v_inserted AND p_initial_stock IS NOT NULL THEN
    v_qty          := COALESCE((p_initial_stock->>'quantity')::int, 0);
    v_warehouse_id := (p_initial_stock->>'warehouse_id')::uuid;

    IF v_qty > 0 AND v_warehouse_id IS NOT NULL THEN
      v_adjustment_id := gen_random_uuid();
      INSERT INTO public.stock_adjustments (
        id, business_id, product_id, warehouse_id, quantity_diff, reason,
        performed_by, created_at, last_updated_at
      )
      VALUES (
        v_adjustment_id, p_business_id, p_product_id, v_warehouse_id,
        v_qty, 'initial_stock', p_actor_id, v_now, v_now
      );
      v_adjustments := v_adjustments || to_jsonb(
        (SELECT sa FROM public.stock_adjustments sa WHERE sa.id = v_adjustment_id));

      INSERT INTO public.inventory (id, business_id, product_id, warehouse_id, quantity, created_at, last_updated_at)
      VALUES (gen_random_uuid(), p_business_id, p_product_id, v_warehouse_id, v_qty, v_now, v_now)
      ON CONFLICT (business_id, product_id, warehouse_id)
        DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
      RETURNING quantity INTO v_new_qty;

      v_inv_after := jsonb_build_array(jsonb_build_object(
        'product_id',      p_product_id,
        'warehouse_id',    v_warehouse_id,
        'quantity',        v_new_qty,
        'last_updated_at', v_now
      ));

      v_stx_id := gen_random_uuid();
      INSERT INTO public.stock_transactions (
        id, business_id, product_id, location_id, quantity_delta, movement_type,
        adjustment_id, performed_by, created_at, last_updated_at
      )
      VALUES (
        v_stx_id, p_business_id, p_product_id, v_warehouse_id,
        v_qty, 'adjustment', v_adjustment_id, p_actor_id, v_now, v_now
      );
      v_stock_txns := jsonb_build_array(to_jsonb(
        (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_stx_id)));
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'product',            v_product_row,
    'stock_adjustments',  v_adjustments,
    'stock_transactions', v_stock_txns,
    'inventory_after',    v_inv_after,
    'replayed',           NOT v_inserted
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb
) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb
) TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 2e. pos_cancel_order — body from 0011 §4.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pos_cancel_order(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_order_id             uuid,
  p_cancellation_reason  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now            timestamptz := now();
  v_existing       record;
  v_oi             record;
  v_pt             record;
  v_wt             record;
  v_stx_id         uuid;
  v_refund_id      uuid;
  v_compensate_id  uuid;
  v_new_qty        int;
  v_order_row      jsonb;
  v_stock_txns     jsonb := '[]'::jsonb;
  v_inv_after      jsonb := '[]'::jsonb;
  v_voided_payments jsonb := '[]'::jsonb;
  v_refund_payments jsonb := '[]'::jsonb;
  v_wallet_compens  jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- Lock and read existing.
  SELECT * INTO v_existing FROM public.orders
   WHERE id = p_order_id AND business_id = p_business_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Replay: already cancelled, return existing state.
  IF v_existing.status = 'cancelled' THEN
    SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;
    RETURN jsonb_build_object(
      'order',                v_order_row,
      'stock_transactions',   '[]'::jsonb,
      'inventory_after',      '[]'::jsonb,
      'voided_payments',      '[]'::jsonb,
      'refund_payments',      '[]'::jsonb,
      'wallet_compensations', '[]'::jsonb,
      'replayed',             true
    );
  END IF;

  IF v_existing.status NOT IN ('pending','completed') THEN
    RAISE EXCEPTION 'cannot_cancel_status_%', v_existing.status USING ERRCODE = 'P0001';
  END IF;

  -- Update order header.
  UPDATE public.orders
     SET status              = 'cancelled',
         cancelled_at        = v_now,
         cancellation_reason = p_cancellation_reason
   WHERE id = p_order_id;

  -- Restore inventory + stock_transactions(return) per item.
  FOR v_oi IN
    SELECT id, product_id, warehouse_id, quantity
      FROM public.order_items WHERE order_id = p_order_id
  LOOP
    INSERT INTO public.inventory (id, business_id, product_id, warehouse_id, quantity, created_at, last_updated_at)
    VALUES (gen_random_uuid(), p_business_id, v_oi.product_id, v_oi.warehouse_id, v_oi.quantity, v_now, v_now)
    ON CONFLICT (business_id, product_id, warehouse_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_new_qty;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      v_oi.product_id,
      'warehouse_id',    v_oi.warehouse_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );

    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, v_oi.product_id, v_oi.warehouse_id,
      v_oi.quantity, 'return', p_order_id, p_actor_id, v_now, v_now
    );
    v_stock_txns := v_stock_txns || to_jsonb(
      (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_stx_id));
  END LOOP;

  -- Void existing non-voided payments + write a compensating refund row each.
  FOR v_pt IN
    SELECT * FROM public.payment_transactions
     WHERE order_id = p_order_id AND voided_at IS NULL
  LOOP
    UPDATE public.payment_transactions
       SET voided_at = v_now, voided_by = p_actor_id, void_reason = COALESCE(p_cancellation_reason, 'order_cancelled')
     WHERE id = v_pt.id;
    v_voided_payments := v_voided_payments || to_jsonb(
      (SELECT pt FROM public.payment_transactions pt WHERE pt.id = v_pt.id));

    v_refund_id := gen_random_uuid();
    INSERT INTO public.payment_transactions (
      id, business_id, amount_kobo, method, type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_refund_id, p_business_id, v_pt.amount_kobo, v_pt.method, 'refund',
      p_order_id, p_actor_id, v_now, v_now
    );
    v_refund_payments := v_refund_payments || to_jsonb(
      (SELECT pt FROM public.payment_transactions pt WHERE pt.id = v_refund_id));
  END LOOP;

  -- Compensate each non-voided wallet debit on this order with a credit.
  FOR v_wt IN
    SELECT * FROM public.wallet_transactions
     WHERE order_id = p_order_id AND voided_at IS NULL AND type = 'debit'
  LOOP
    UPDATE public.wallet_transactions
       SET voided_at = v_now, voided_by = p_actor_id, void_reason = COALESCE(p_cancellation_reason, 'order_cancelled')
     WHERE id = v_wt.id;

    v_compensate_id := gen_random_uuid();
    INSERT INTO public.wallet_transactions (
      id, business_id, wallet_id, customer_id, type,
      amount_kobo, signed_amount_kobo, reference_type, order_id,
      performed_by, customer_verified, created_at, last_updated_at
    )
    VALUES (
      v_compensate_id, p_business_id, v_wt.wallet_id, v_wt.customer_id, 'credit',
      v_wt.amount_kobo, v_wt.amount_kobo, 'refund', p_order_id,
      p_actor_id, false, v_now, v_now
    );
    v_wallet_compens := v_wallet_compens || to_jsonb(
      (SELECT wt FROM public.wallet_transactions wt WHERE wt.id = v_compensate_id));
  END LOOP;

  SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;

  RETURN jsonb_build_object(
    'order',                v_order_row,
    'stock_transactions',   v_stock_txns,
    'inventory_after',      v_inv_after,
    'voided_payments',      v_voided_payments,
    'refund_payments',      v_refund_payments,
    'wallet_compensations', v_wallet_compens,
    'replayed',             false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_cancel_order(uuid, uuid, uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_cancel_order(uuid, uuid, uuid, text)
  TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 2f. pos_record_expense — body from 0011 §9. DROP first because 0045
--     renamed the parameter p_warehouse_id → p_store_id.
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.pos_record_expense(
  uuid, uuid, uuid, uuid, uuid, int, text, uuid, text, text, uuid
);

CREATE OR REPLACE FUNCTION public.pos_record_expense(
  p_business_id     uuid,
  p_actor_id        uuid,
  p_expense_id      uuid,
  p_payment_id      uuid,
  p_activity_log_id uuid,
  p_amount_kobo     int,
  p_description     text,
  p_category_id     uuid DEFAULT NULL,
  p_payment_method  text DEFAULT NULL,    -- 'cash'|'transfer'|'card'|'pos'|'other'
  p_reference       text DEFAULT NULL,
  p_warehouse_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now            timestamptz := now();
  v_already        bool;
  v_expense_row    jsonb;
  v_activity_row   jsonb;
  v_payment_row    jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_amount_kobo <= 0 THEN
    RAISE EXCEPTION 'amount_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.expenses WHERE id = p_expense_id) INTO v_already;

  IF NOT v_already THEN
    INSERT INTO public.expenses (
      id, business_id, category_id, amount_kobo, description, payment_method,
      recorded_by, reference, warehouse_id, is_deleted, created_at, last_updated_at
    )
    VALUES (
      p_expense_id, p_business_id, p_category_id, p_amount_kobo, p_description, p_payment_method,
      p_actor_id, p_reference, p_warehouse_id, false, v_now, v_now
    );

    INSERT INTO public.activity_logs (
      id, business_id, user_id, action, description, expense_id,
      created_at, last_updated_at
    )
    VALUES (
      p_activity_log_id, p_business_id, p_actor_id,
      'expense_recorded', p_description, p_expense_id, v_now, v_now
    );

    IF p_payment_method IS NOT NULL THEN
      INSERT INTO public.payment_transactions (
        id, business_id, amount_kobo, method, type,
        expense_id, performed_by, created_at, last_updated_at
      )
      VALUES (
        p_payment_id, p_business_id, p_amount_kobo, p_payment_method, 'expense',
        p_expense_id, p_actor_id, v_now, v_now
      );
    END IF;
  END IF;

  SELECT to_jsonb(e.*)  INTO v_expense_row  FROM public.expenses e        WHERE e.id = p_expense_id;
  SELECT to_jsonb(a.*)  INTO v_activity_row FROM public.activity_logs a   WHERE a.id = p_activity_log_id;
  SELECT to_jsonb(pt.*) INTO v_payment_row  FROM public.payment_transactions pt WHERE pt.id = p_payment_id;

  RETURN jsonb_build_object(
    'expense',             v_expense_row,
    'activity_log',        v_activity_row,
    'payment_transaction', v_payment_row,
    'replayed',            v_already
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_record_expense(uuid, uuid, uuid, uuid, uuid, int, text, uuid, text, text, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_record_expense(uuid, uuid, uuid, uuid, uuid, int, text, uuid, text, text, uuid)
  TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 2g. pos_create_customer — body from 0011 §10. DROP first because 0045
--     renamed the parameter p_warehouse_id → p_store_id.
-- -----------------------------------------------------------------------------

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
  p_warehouse_id         uuid DEFAULT NULL
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
      id, business_id, warehouse_id, name, phone, email, address,
      google_maps_location, customer_group, wallet_limit_kobo,
      is_deleted, created_at, last_updated_at
    )
    VALUES (
      p_customer_id, p_business_id, p_warehouse_id, p_name, p_phone, p_email, p_address,
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
-- 3. Reverse-rename indexes.
-- =========================================================================

ALTER INDEX public.idx_inventory_business_ps    RENAME TO idx_inventory_business_pw;
ALTER INDEX public.idx_stores_business_deleted  RENAME TO idx_warehouses_business_deleted;
ALTER INDEX public.idx_stores_business_lua      RENAME TO idx_warehouses_business_lua;


-- =========================================================================
-- 4. Reverse-rename FK / UNIQUE constraints.
-- =========================================================================

-- Inverse of the default-name FK constraint renames added by 0045.
ALTER TABLE public.user_stores
  RENAME CONSTRAINT user_stores_store_id_fkey
                 TO user_stores_warehouse_id_fkey;

ALTER TABLE public.invite_codes
  RENAME CONSTRAINT invite_codes_store_id_fkey
                 TO invite_codes_warehouse_id_fkey;

ALTER TABLE public.user_stores
  RENAME CONSTRAINT user_stores_user_id_store_id_key
                 TO user_stores_user_id_warehouse_id_key;

ALTER TABLE public.inventory
  RENAME CONSTRAINT inventory_business_id_product_id_store_id_key
                 TO inventory_business_id_product_id_warehouse_id_key;

ALTER TABLE public.users RENAME CONSTRAINT users_store_fk TO users_warehouse_fk;


-- =========================================================================
-- 5. Reverse-rename columns (store_id → warehouse_id) on all ten tables.
-- =========================================================================

ALTER TABLE public.user_stores       RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.invite_codes      RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.activity_logs     RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.expenses          RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.order_items       RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.orders            RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.stock_adjustments RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.inventory         RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.customers         RENAME COLUMN store_id TO warehouse_id;
ALTER TABLE public.users             RENAME COLUMN store_id TO warehouse_id;


-- =========================================================================
-- 6. Rename the table back.
-- =========================================================================

ALTER TABLE public.stores RENAME TO warehouses;

COMMIT;

-- =============================================================================
-- Verify rollback (inverse of 0045's verification block):
--
--   -- 1. Table rename undone:
--   SELECT to_regclass('public.stores');      -- expect NULL
--   SELECT to_regclass('public.warehouses');  -- expect 'warehouses'
--
--   -- 2. Columns reverted — every row should show 'warehouse_id',
--   --    none 'store_id':
--   SELECT table_name, column_name
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND column_name IN ('warehouse_id','store_id')
--      AND table_name IN ('users','customers','inventory','stock_adjustments',
--                         'orders','order_items','expenses','activity_logs',
--                         'invite_codes','user_stores')
--    ORDER BY table_name, column_name;
--   -- expect 10 rows, all column_name='warehouse_id', none 'store_id'.
--
--   -- 3. Snapshot RPC: 'warehouses' key present, 'stores' absent.
--   SELECT k FROM jsonb_object_keys(
--     public.pos_pull_snapshot(public.business_id(), NULL)
--   ) AS k
--    WHERE k IN ('stores','warehouses');
--   -- expect one row: 'warehouses'.
--
--   -- 4. Realtime publication tracks warehouses again:
--   SELECT tablename FROM pg_publication_tables
--    WHERE pubname='supabase_realtime' AND tablename='warehouses';
--   -- expect 1 row.
--
--   -- 5. Pre-rename indexes exist:
--   SELECT indexname FROM pg_indexes
--    WHERE schemaname='public'
--      AND indexname IN ('idx_warehouses_business_lua',
--                        'idx_warehouses_business_deleted',
--                        'idx_inventory_business_pw');
--   -- expect 3 rows.
--
--   -- 6. Pre-rename constraints exist:
--   SELECT conname FROM pg_constraint
--    WHERE conname IN ('users_warehouse_fk',
--                      'inventory_business_id_product_id_warehouse_id_key',
--                      'user_stores_user_id_warehouse_id_key');
--   -- expect 3 rows.
-- =============================================================================
