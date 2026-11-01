-- 0241_selling_in_parts.sql  (#628, slice S3 of PRD #620)
--
-- Selling in parts. Every product in every shop can be sold in parts unless its
-- switch is turned off (owner decision 4), and the daily close can freeze a
-- part quantity:
--
--   A. products.allow_fractional_sales defaults to true; every existing product
--      is set to true;
--   B. pos_create_product_v2's p_allow_fractional_sales defaults to true, so a
--      caller that leaves it out gets the same answer as the column;
--   C. daily_closings.items_sold becomes double precision with a quarter CHECK.
--
-- The sale RPCs (pos_record_sale_v2, checkout_order, pos_cancel_order,
-- fifo_assign, pos_recost_pairs) need no change: 0239 already carries fractions
-- through them and rounds money through public.line_total_kobo. Checked against
-- the production definitions on 2026-11-01: the only functions left that read a
-- quantity as an integer are the retired pos_record_sale / pos_create_product
-- (no current client calls them) and the switched-off online-order and van
-- paths, which stay whole numbers (owner decision 11).
--
-- !! RELEASE GATE. DO NOT DEPLOY AHEAD OF THE MINIMUM-VERSION RAISE. !!
-- The UPDATE below goes through the products triggers, so last_updated_at moves
-- and EVERY phone pulls the new value. A phone on an old app version would then
-- show the -0.5 / +0.5 buttons and truncate 0.5 to 0 at checkout, leaving a
-- zero-quantity line the cloud rejects. Order (owner decision 12):
--   1. the new app version is live on Play;
--   2. app_config.min_android_build is raised;
--   3. this migration is pushed. This is the moment shops can sell parts: the
--      new app keeps a product whole until this value reaches it.
--
-- Part B and C are safe on their own, but they ship in this one file on purpose
-- so nothing writes a fractional items_sold before the column can hold it.
-- Whole values still reach any client as JSON integers (see 0239).
--
-- LOCKING: the ALTER rewrites daily_closings under ACCESS EXCLUSIVE (a small
-- table). The UPDATE touches each product row once (172 on 2026-11-01) and sends
-- one broadcast signal per row, which coalesces into a pull on each device.

BEGIN;

-- ===========================================================================
-- A. Every product can sell in parts
-- ===========================================================================
ALTER TABLE public.products
  ALTER COLUMN allow_fractional_sales SET DEFAULT true;

UPDATE public.products
   SET allow_fractional_sales = true
 WHERE allow_fractional_sales IS DISTINCT FROM true;

-- ===========================================================================
-- B. pos_create_product_v2: default matches the column
-- ===========================================================================
-- Body is the production definition of 2026-11-01; only the default of
-- p_allow_fractional_sales changes. Same signature, so no overload and the
-- existing grants stay.
CREATE OR REPLACE FUNCTION public.pos_create_product_v2(p_business_id uuid, p_actor_id uuid, p_product_id uuid, p_name text, p_unit text DEFAULT 'Bottle'::text, p_subtitle text DEFAULT NULL::text, p_sku text DEFAULT NULL::text, p_size text DEFAULT NULL::text, p_retailer_price_kobo integer DEFAULT 0, p_wholesaler_price_kobo integer DEFAULT 0, p_buying_price_kobo integer DEFAULT 0, p_category_id uuid DEFAULT NULL::uuid, p_crate_size_group_id uuid DEFAULT NULL::uuid, p_manufacturer_id uuid DEFAULT NULL::uuid, p_supplier_id uuid DEFAULT NULL::uuid, p_low_stock_threshold integer DEFAULT 5, p_track_empties boolean DEFAULT false, p_image_path text DEFAULT NULL::text, p_initial_stock jsonb DEFAULT NULL::jsonb, p_allow_fractional_sales boolean DEFAULT true, p_expiry_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_now           timestamptz := now();
  v_inserted      bool := false;
  v_product_row   jsonb;
  v_store_id      uuid;
  v_qty           double precision;
  v_adjustment_id uuid;
  v_stx_id        uuid;
  v_new_qty       double precision;
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
      id, business_id, category_id, crate_size_group_id, manufacturer_id, supplier_id,
      name, subtitle, sku, size, unit,
      retailer_price_kobo, wholesaler_price_kobo, buying_price_kobo,
      is_available, is_deleted, low_stock_threshold,
      track_empties, allow_fractional_sales, image_path, expiry_date,
      created_at, last_updated_at
    )
    VALUES (
      p_product_id, p_business_id, p_category_id, p_crate_size_group_id, p_manufacturer_id, p_supplier_id,
      p_name, p_subtitle, p_sku, p_size, p_unit,
      p_retailer_price_kobo, p_wholesaler_price_kobo, p_buying_price_kobo,
      true, false, p_low_stock_threshold,
      p_track_empties, p_allow_fractional_sales, p_image_path, p_expiry_date,
      v_now, v_now
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;

  SELECT to_jsonb(p.*) INTO v_product_row FROM public.products p WHERE p.id = p_product_id;

  IF v_inserted AND p_initial_stock IS NOT NULL THEN
    v_qty      := COALESCE((p_initial_stock->>'quantity')::double precision, 0);
    v_store_id := (p_initial_stock->>'store_id')::uuid;

    IF v_qty > 0 AND v_store_id IS NOT NULL THEN
      v_adjustment_id := gen_random_uuid();
      INSERT INTO public.stock_adjustments (
        id, business_id, product_id, store_id, quantity_diff, reason,
        performed_by, created_at, last_updated_at
      )
      VALUES (
        v_adjustment_id, p_business_id, p_product_id, v_store_id,
        v_qty, 'initial_stock', p_actor_id, v_now, v_now
      );
      v_adjustments := v_adjustments || to_jsonb(
        (SELECT sa FROM public.stock_adjustments sa WHERE sa.id = v_adjustment_id));

      INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
      VALUES (gen_random_uuid(), p_business_id, p_product_id, v_store_id, v_qty, v_now, v_now)
      ON CONFLICT (business_id, product_id, store_id)
        DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
      RETURNING quantity INTO v_new_qty;

      v_inv_after := jsonb_build_array(jsonb_build_object(
        'product_id',      p_product_id,
        'store_id',        v_store_id,
        'quantity',        v_new_qty,
        'last_updated_at', v_now
      ));

      v_stx_id := gen_random_uuid();
      INSERT INTO public.stock_transactions (
        id, business_id, product_id, location_id, quantity_delta, movement_type,
        adjustment_id, performed_by, created_at, last_updated_at
      )
      VALUES (
        v_stx_id, p_business_id, p_product_id, v_store_id,
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
$function$;

-- ===========================================================================
-- C. daily_closings.items_sold carries parts
-- ===========================================================================
-- No view, index or function depends on this column (checked on production,
-- 2026-11-01). The sign is free: a day of returns can net below zero.
ALTER TABLE public.daily_closings
  ALTER COLUMN items_sold TYPE double precision USING items_sold::double precision;
ALTER TABLE public.daily_closings
  ADD CONSTRAINT daily_closings_items_sold_quarter_step CHECK (public.qty_is_quarter(items_sold));

COMMIT;
