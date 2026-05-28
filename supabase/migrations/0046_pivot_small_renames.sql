-- =============================================================================
-- 0046_pivot_small_renames.sql — Reebaplus POS pivot step 4 (cloud mirror).
--
-- Mirrors the Drift v15 migration block in
-- lib/core/database/app_database.dart. Two of step 4's four slices touch
-- the cloud schema; the other two are deferred (see below).
--
--   (a) customers.customer_group → price_tier
--   (b) purchases → shipments (table) and the two permanent ledger
--       tables' FK column  purchase_id → shipment_id
--       (stock_transactions, payment_transactions).
--
-- DEFERRED — intentionally NOT in this migration:
--   (c) drop purchase_items — deferred to step 25 (Track Shipments
--       rebuild). It still backs the product-detail "Last Delivery" card
--       client-side; dropping it now orphans that feature.
--   (d) crate_groups → crate_size_groups — deferred to its own focused
--       session (≈196 client refs + several RPC rewrites).
--
-- No behavioural changes. Pure rename. Postgres auto-updates CHECK
-- constraints, FKs, and indexes through ALTER ... RENAME, but it does
-- NOT rewrite plpgsql function bodies (they bind column names at run
-- time), so every live function referencing the renamed identifiers is
-- re-created below. The authoritative list of affected functions was
-- taken from pg_proc on the live database:
--   * pos_create_customer      (references customer_group)
--   * pos_inventory_delta_v2    (references purchase_id)
--   * pos_pull_snapshot         (references the 'purchases' table name)
--   * pos_inventory_delta       (v1 — references purchase_id AND the
--                                already-renamed warehouse_id; dead since
--                                0045 broke it, client only calls _v2 —
--                                DROPPED here rather than resurrected)
--
-- DEPLOY ORDERING — READ BEFORE RUNNING:
--   Same shape as 0045. The v15 Dart client renames its local columns and
--   rewrites pending sync_queue payload keys (customer_group → price_tier,
--   p_customer_group → p_price_tier, purchase_id → shipment_id for
--   stock_transactions / payment_transactions upserts, and forwards
--   purchases:* action types to shipments:*). Until this migration
--   commits, v15 clients push the new keys to a cloud that still expects
--   the old ones → those writes 42703 and stay queued (no data loss).
--   Run this right after the v15 client ships to close the window.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. (a) customers.customer_group → price_tier, and tighten the CHECK to
--    the two values the master plan defines (§16/§21: Retailer /
--    Wholesaler only). RENAME COLUMN auto-rewrites the CHECK *expression*
--    but keeps the old constraint NAME, so migrate the two legacy values
--    off, then drop the auto-named constraint and add the tightened one.
-- -----------------------------------------------------------------------------
ALTER TABLE public.customers RENAME COLUMN customer_group TO price_tier;

UPDATE public.customers SET price_tier = 'wholesaler' WHERE price_tier = 'distributor';
UPDATE public.customers SET price_tier = 'retailer'   WHERE price_tier = 'walk_in';

ALTER TABLE public.customers DROP CONSTRAINT customers_customer_group_check;
ALTER TABLE public.customers
  ADD CONSTRAINT customers_price_tier_check CHECK (price_tier IN ('retailer','wholesaler'));

-- -----------------------------------------------------------------------------
-- 2. (b) purchases → shipments + index rename (cosmetic / grep hygiene).
--    FK references from purchase_items, stock_transactions and
--    payment_transactions auto-follow the table rename.
-- -----------------------------------------------------------------------------
ALTER TABLE public.purchases RENAME TO shipments;
ALTER INDEX public.idx_purchases_business_lua RENAME TO idx_shipments_business_lua;

-- -----------------------------------------------------------------------------
-- 3. (b) purchase_id → shipment_id on the two permanent ledger tables.
--    purchase_items KEEPS purchase_id (that table is dropped in step 25).
--    Each table's exactly-one-FK CHECK constraint expression is rewritten
--    automatically by RENAME COLUMN.
-- -----------------------------------------------------------------------------
ALTER TABLE public.stock_transactions   RENAME COLUMN purchase_id TO shipment_id;
ALTER TABLE public.payment_transactions RENAME COLUMN purchase_id TO shipment_id;

-- -----------------------------------------------------------------------------
-- 4. DROP dead v1 pos_inventory_delta. Superseded by pos_inventory_delta_v2
--    (the only one the client enqueues, as domain:pos_inventory_delta_v2).
--    Already non-functional since 0045 renamed inventory.warehouse_id →
--    store_id without updating this body; it also references the now-
--    renamed purchase_id. Remove rather than repair.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pos_inventory_delta(uuid, jsonb);

-- -----------------------------------------------------------------------------
-- 5. pos_inventory_delta_v2 — body from 0045 §6c. Sole change vs 0045:
--    the stock_transactions INSERT column purchase_id → shipment_id.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_inventory_delta_v2(
  p_business_id uuid,
  p_actor_id    uuid,
  p_movements   jsonb   -- [{movement_id, product_id, store_id, quantity_delta, movement_type, ref_type?, ref_id?, reason?}]
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

    -- For movement_type='adjustment' with no ref, mint a stock_adjustments
    -- row to satisfy the ledger's exactly-one-FK CHECK.
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
      order_id, transfer_id, adjustment_id, shipment_id,
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

-- -----------------------------------------------------------------------------
-- 6. pos_pull_snapshot — body from 0045 §3. Sole change vs 0045: the
--    v_tenant_tables array literal 'purchases' → 'shipments'.
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
    'profiles','users','stores','manufacturers','crate_groups',
    'categories','products','inventory','customers','suppliers',
    'orders','order_items','shipments','purchase_items',
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
-- 7. pos_create_customer — body from 0045 §6g. Parameter p_customer_group
--    is RENAMED to p_price_tier (the client now sends p_price_tier as the
--    named RPC argument key); the INSERT column customer_group → price_tier.
--    DROP first — Postgres won't rename a parameter via CREATE OR REPLACE.
--    Function identity (arg TYPES) is unchanged, so the signature list is
--    identical to 0045.
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
  p_price_tier           text DEFAULT 'retailer',
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
      google_maps_location, price_tier, wallet_limit_kobo,
      is_deleted, created_at, last_updated_at
    )
    VALUES (
      p_customer_id, p_business_id, p_store_id, p_name, p_phone, p_email, p_address,
      p_google_maps_location, p_price_tier, p_wallet_limit_kobo,
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

COMMIT;

-- =============================================================================
-- Verification (run after deploy; all should return zero rows / expected):
--
--   -- No function still references the old identifiers:
--   SELECT p.proname
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public' AND p.prokind='f'
--      AND (pg_get_functiondef(p.oid) ~ '\mcustomer_group\M'
--        OR pg_get_functiondef(p.oid) ~ '\mpurchase_id\M'
--        OR pg_get_functiondef(p.oid) ~ '\mpurchases\M');
--
--   -- Renamed columns exist, old ones gone:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='customers' AND column_name IN ('price_tier','customer_group');
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name IN ('stock_transactions','payment_transactions')
--      AND column_name IN ('shipment_id','purchase_id');
--
--   -- Table renamed:
--   SELECT to_regclass('public.shipments'), to_regclass('public.purchases');
-- =============================================================================
