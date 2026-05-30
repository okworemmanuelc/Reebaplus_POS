-- 0056_product_expiry.sql
-- Reebaplus pivot step 15 (master plan §16.5). Mirrors the local Drift schema
-- bump v18 → v19 in lib/core/database/app_database.dart.
--
-- Adds one optional product expiry date. Not per-batch/FIFO (that stays
-- Phase 2) — a single nullable date used to flag and sell-down the stock
-- closest to expiry. Available for all business types; businesses that don't
-- track expiry leave it null.

-- -----------------------------------------------------------------------------
-- 1. products table: one nullable timestamptz. No backfill.
-- -----------------------------------------------------------------------------
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS expiry_date timestamptz;

-- -----------------------------------------------------------------------------
-- 2. pos_create_product_v2 — add p_expiry_date (DEFAULT NULL) + the INSERT
--    column. Body is otherwise unchanged from 0055. DROP the old overload
--    first (its signature changed: +1 param).
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb, bool
);

CREATE OR REPLACE FUNCTION public.pos_create_product_v2(
  p_business_id              uuid,
  p_actor_id                 uuid,
  p_product_id               uuid,
  p_name                     text,
  p_unit                     text     DEFAULT 'Bottle',
  p_subtitle                 text     DEFAULT NULL,
  p_sku                      text     DEFAULT NULL,
  p_size                     text     DEFAULT NULL,
  p_retailer_price_kobo      int      DEFAULT 0,
  p_wholesaler_price_kobo    int      DEFAULT 0,
  p_buying_price_kobo        int      DEFAULT 0,
  p_category_id              uuid     DEFAULT NULL,
  p_crate_size_group_id      uuid     DEFAULT NULL,
  p_manufacturer_id          uuid     DEFAULT NULL,
  p_supplier_id              uuid     DEFAULT NULL,
  p_low_stock_threshold      int      DEFAULT 5,
  p_track_empties            bool     DEFAULT false,
  p_image_path               text     DEFAULT NULL,
  p_initial_stock            jsonb    DEFAULT NULL,  -- {store_id, quantity}
  p_allow_fractional_sales   bool     DEFAULT false,
  p_expiry_date              timestamptz DEFAULT NULL
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
  v_store_id      uuid;
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
    v_qty      := COALESCE((p_initial_stock->>'quantity')::int, 0);
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
$$;

REVOKE ALL ON FUNCTION public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb, bool, timestamptz
) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb, bool, timestamptz
) TO authenticated, service_role;
