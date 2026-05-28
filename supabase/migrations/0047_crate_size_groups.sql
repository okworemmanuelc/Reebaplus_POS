-- =============================================================================
-- 0047_crate_size_groups.sql — Reebaplus POS pivot (Crate Size Groups).
--
-- Mirrors the Drift v16 migration block in
-- lib/core/database/app_database.dart.
--
--   1. crate_groups → crate_size_groups (table + indexes)
--   2. crate_group_id → crate_size_group_id on the 6 FK dependents
--      (suppliers, products, customer_crate_balances,
--      manufacturer_crate_balances, crate_ledger, pending_crate_returns)
--   3. size int (12/20/24) → crate_size_label text (big/medium/small).
--      The numeric size was display-only and fed no crate math.
--
-- CLOUD SCHEMA NOTE (verified 2026-05-28 against the migration history):
--   crate_groups was created in 0001_initial.sql with `size int CHECK
--   (size IN (12,20,24))` PLUS empty_crate_stock / deposit_amount_kobo, and
--   no migration ever altered it. There is NO crate_size_label column today
--   — so this migration converts size→crate_size_label cloud-side exactly
--   like the local Drift side (an earlier brief that said "cloud already has
--   crate_size_label" was wrong). The user confirmed the cloud crate table
--   holds zero rows, so the data UPDATE below is a no-op in practice; it is
--   written for completeness. Mapping matches the local v16 migration:
--   12→small, 20→medium, 24→big (anything else → medium).
--
-- Postgres auto-updates FK / UNIQUE constraint definitions and dependent
-- index column references through ALTER ... RENAME COLUMN, but it does NOT
-- rewrite plpgsql function bodies, so every live function that references
-- the renamed identifiers is re-created below. Affected functions:
--   * pos_pull_snapshot       (references the 'crate_groups' table name)
--   * pos_create_product_v2    (param p_crate_group_id + products column)
--   * pos_record_crate_return  (param p_crate_group_id + columns)
--   * pos_approve_crate_return (column refs only — no param change)
--
-- DEPLOY ORDERING — READ BEFORE RUNNING:
--   Deploy AFTER 0045 and 0046 (this builds on their RPC bodies — store_id,
--   shipments, price_tier). Deploy right after the v16 client ships: until
--   this commits, v16 clients push crate_size_group_id / p_crate_size_group_id
--   / crate_size_groups:* to a cloud that still expects the old names → those
--   writes 42703 and stay queued (no data loss; the v16 client also forwards
--   any pre-v16 queued rows to the new keys).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Rename the table + its two sync/soft-delete indexes.
-- -----------------------------------------------------------------------------
ALTER TABLE public.crate_groups RENAME TO crate_size_groups;
ALTER INDEX IF EXISTS public.idx_crate_groups_business_lua
  RENAME TO idx_crate_size_groups_business_lua;
ALTER INDEX IF EXISTS public.idx_crate_groups_business_deleted
  RENAME TO idx_crate_size_groups_business_deleted;

-- -----------------------------------------------------------------------------
-- 2. Rename the FK column on each dependent. RENAME COLUMN auto-updates that
--    table's FK + UNIQUE constraint definitions and any index that references
--    the column (so crate_ledger's idx_crate_ledger_owner_group follows).
-- -----------------------------------------------------------------------------
ALTER TABLE public.suppliers                   RENAME COLUMN crate_group_id TO crate_size_group_id;
ALTER TABLE public.products                    RENAME COLUMN crate_group_id TO crate_size_group_id;
ALTER TABLE public.customer_crate_balances     RENAME COLUMN crate_group_id TO crate_size_group_id;
ALTER TABLE public.manufacturer_crate_balances RENAME COLUMN crate_group_id TO crate_size_group_id;
ALTER TABLE public.crate_ledger                RENAME COLUMN crate_group_id TO crate_size_group_id;
ALTER TABLE public.pending_crate_returns       RENAME COLUMN crate_group_id TO crate_size_group_id;

-- -----------------------------------------------------------------------------
-- 3. Convert size int → crate_size_label text. Add the new column, map any
--    existing rows (none in practice), constrain it, then drop the old column
--    (DROP COLUMN size also removes the size CHECK constraint).
-- -----------------------------------------------------------------------------
ALTER TABLE public.crate_size_groups ADD COLUMN crate_size_label text;
UPDATE public.crate_size_groups
   SET crate_size_label = CASE size
     WHEN 12 THEN 'small'
     WHEN 20 THEN 'medium'
     WHEN 24 THEN 'big'
     ELSE 'medium'
   END;
ALTER TABLE public.crate_size_groups
  ALTER COLUMN crate_size_label SET DEFAULT 'medium';
ALTER TABLE public.crate_size_groups
  ALTER COLUMN crate_size_label SET NOT NULL;
ALTER TABLE public.crate_size_groups
  ADD CONSTRAINT crate_size_groups_crate_size_label_check
  CHECK (crate_size_label IN ('big','medium','small'));
ALTER TABLE public.crate_size_groups DROP COLUMN size;

-- -----------------------------------------------------------------------------
-- 4. pos_pull_snapshot — body from 0046 §6. Sole change: the v_tenant_tables
--    array literal 'crate_groups' → 'crate_size_groups'.
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
    'profiles','users','stores','manufacturers','crate_size_groups',
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
-- 5. pos_create_product_v2 — body from 0045. Sole changes: param
--    p_crate_group_id → p_crate_size_group_id and the products INSERT column
--    crate_group_id → crate_size_group_id. DROP first — Postgres won't rename
--    a parameter via CREATE OR REPLACE. Arg TYPES (the identity) are unchanged.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb
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
  p_retail_price_kobo        int      DEFAULT 0,
  p_selling_price_kobo       int      DEFAULT 0,
  p_buying_price_kobo        int      DEFAULT 0,
  p_bulk_breaker_price_kobo  int      DEFAULT NULL,
  p_distributor_price_kobo   int      DEFAULT NULL,
  p_category_id              uuid     DEFAULT NULL,
  p_crate_size_group_id      uuid     DEFAULT NULL,
  p_manufacturer_id          uuid     DEFAULT NULL,
  p_supplier_id              uuid     DEFAULT NULL,
  p_low_stock_threshold      int      DEFAULT 5,
  p_track_empties            bool     DEFAULT false,
  p_image_path               text     DEFAULT NULL,
  p_initial_stock            jsonb    DEFAULT NULL  -- {store_id, quantity}
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
      retail_price_kobo, bulk_breaker_price_kobo, distributor_price_kobo,
      selling_price_kobo, buying_price_kobo,
      is_available, is_deleted, low_stock_threshold,
      track_empties, image_path,
      created_at, last_updated_at
    )
    VALUES (
      p_product_id, p_business_id, p_category_id, p_crate_size_group_id, p_manufacturer_id, p_supplier_id,
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
  int, int, int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb
) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_create_product_v2(
  uuid, uuid, uuid, text, text, text, text, text,
  int, int, int, int, int, uuid, uuid, uuid, uuid,
  int, bool, text, jsonb
) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. pos_record_crate_return — body from 0011. Changes: param
--    p_crate_group_id → p_crate_size_group_id and every crate_group_id column
--    reference → crate_size_group_id. DROP first (parameter rename).
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pos_record_crate_return(
  uuid, uuid, uuid, text, uuid, uuid, int, text, uuid, uuid
);

CREATE OR REPLACE FUNCTION public.pos_record_crate_return(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_ledger_id            uuid,
  p_owner_kind           text,        -- 'customer' | 'manufacturer'
  p_owner_id             uuid,
  p_crate_size_group_id  uuid,
  p_quantity_delta       int,
  p_movement_type        text,        -- one of crate_ledger.movement_type allowed values
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

  -- Replay detection on ledger id.
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
    CASE WHEN p_owner_kind = 'customer'     THEN p_owner_id END,
    CASE WHEN p_owner_kind = 'manufacturer' THEN p_owner_id END,
    p_crate_size_group_id, p_quantity_delta, p_movement_type,
    p_reference_order_id, p_reference_return_id,
    p_actor_id, v_now, v_now
  );

  IF p_owner_kind = 'customer' THEN
    INSERT INTO public.customer_crate_balances (
      id, business_id, customer_id, crate_size_group_id, balance, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_owner_id, p_crate_size_group_id,
      p_quantity_delta, v_now, v_now
    )
    ON CONFLICT (business_id, customer_id, crate_size_group_id)
      DO UPDATE SET balance = public.customer_crate_balances.balance + EXCLUDED.balance,
                    last_updated_at = v_now
    RETURNING * INTO v_balance_row;
  ELSE
    INSERT INTO public.manufacturer_crate_balances (
      id, business_id, manufacturer_id, crate_size_group_id, balance, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_owner_id, p_crate_size_group_id,
      p_quantity_delta, v_now, v_now
    )
    ON CONFLICT (business_id, manufacturer_id, crate_size_group_id)
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

-- -----------------------------------------------------------------------------
-- 7. pos_approve_crate_return — body from 0015. Sole change: crate_group_id
--    column references → crate_size_group_id. No parameter rename, so
--    CREATE OR REPLACE (no DROP needed).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_approve_crate_return(
  p_business_id        uuid,
  p_actor_id           uuid,
  p_pending_return_id  uuid,
  p_ledger_id          uuid   -- idempotency key for crate_ledger row
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
        AND ccb.crate_size_group_id = v_pending.crate_size_group_id;
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

  -- Returns reduce what the customer owes. pending.quantity is positive
  -- (CHECK quantity > 0); negate for the ledger + balance increment.
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
    p_ledger_id, p_business_id, v_pending.customer_id, NULL, v_pending.crate_size_group_id,
    v_delta, 'returned', NULL, p_pending_return_id,
    p_actor_id, v_now, v_now
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.customer_crate_balances (
    id, business_id, customer_id, crate_size_group_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_pending.customer_id, v_pending.crate_size_group_id,
    v_delta, v_now, v_now
  )
  ON CONFLICT (business_id, customer_id, crate_size_group_id)
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

-- =============================================================================
-- Verification (run after deploy; all should return zero rows / expected):
--
--   -- No function still references the old identifiers:
--   SELECT p.proname
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public' AND p.prokind='f'
--      AND (pg_get_functiondef(p.oid) ~ '\mcrate_group_id\M'
--        OR pg_get_functiondef(p.oid) ~ '\mcrate_groups\M');
--
--   -- Table renamed, size gone, label present + constrained:
--   SELECT to_regclass('public.crate_size_groups'), to_regclass('public.crate_groups');
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='crate_size_groups'
--      AND column_name IN ('crate_size_label','size');
--
--   -- FK columns renamed on all six dependents:
--   SELECT table_name, column_name FROM information_schema.columns
--    WHERE table_schema='public' AND column_name IN ('crate_size_group_id','crate_group_id')
--      AND table_name IN ('suppliers','products','customer_crate_balances',
--                         'manufacturer_crate_balances','crate_ledger','pending_crate_returns')
--    ORDER BY table_name;
-- =============================================================================
