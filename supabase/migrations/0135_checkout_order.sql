-- 0135_checkout_order.sql
--
-- Reebaplus — Web POS Slice 2 (keystone). The server-authoritative cash/transfer
-- checkout RPC (PRD web-pos, ADR 0008 "RPC Write API", issue #43).
--
-- WHY AN RPC (not client-side PostgREST writes): the offline mobile app resolves
-- stock conflicts with LWW after the fact; the online web client sells against
-- LIVE stock, so a checkout must decrement inventory + draw down the FIFO cost
-- queue UNDER A ROW LOCK and reject at commit if stock is insufficient — two
-- concurrent tills must not oversell the same units. That guarantee only exists
-- inside one atomic SQL transaction, which is exactly what a SECURITY DEFINER
-- RPC gives us.
--
-- SCOPE (Slice 2): the plain cash/transfer path only — no customer credit / wallet
-- (Slice 3) and no crate ledger (Slice 4). One registered-customer-free sale:
--   order (status 'pending') + line items
--   + FIFO draw-down oldest-first with per-line COGS snapshot onto
--     order_items.buying_price_kobo  (reuses public.fifo_assign from 0133)
--   + inventory decrement with the insufficient-stock guard (concurrency)
--   + stock_transactions ledger rows
--   + one payment_transactions row
--   + a SERVER-minted order number that can never collide with the mobile
--     device-tag scheme (distinct 'WEB-' prefix vs mobile 'ORD-')
--   + revenue recognized at Checkout (order 'pending', per orderCountsAsSale)
-- all-or-nothing.
--
-- TWO IMPLEMENTATIONS, ONE CONTRACT (ADR 0009): this RPC is the SQL twin of the
-- mobile Dart checkout (OrdersDao.createOrder + CostBatchesDao.drawDownSale). The
-- money math here is pinned identical to Dart by the Golden-Scenario Suite
-- (test/golden/*), which runs the same fixtures against both. In particular the
-- FIFO per-unit rounding is round(line_total / qty) via public.fifo_assign, byte-
-- for-byte the same rounding the Dart draw-down uses.
--
-- DEFENCE IN DEPTH: the web UI already hides actions the operator's role lacks,
-- but this RPC ALSO enforces `sales.make` server-side and clamps the order
-- discount to the caller's role cap (`max_discount_percent`). Both checks mirror
-- the mobile Gate Registry's *decisions* (not its Dart code, ADR 0009), via two
-- reusable SECURITY DEFINER helpers added here.
--
-- DEPLOY ORDER: after 0133 (public.fifo_assign) and 0132 (cost_batches). No app-
-- schema change — additive server logic; inert until called by the web client.

BEGIN;

-- ─── 1. caller_has_permission — server-side hide-don't-block, mirrored ───────
--
-- Resolves the CURRENT authenticated caller's effective permission for a key,
-- mirroring the mobile permission resolution (role grants ± user overrides, CEO
-- all-on). SECURITY DEFINER so it can read the caller's own role/override rows
-- reliably regardless of RLS (constrained to auth.uid(), so it can only ever
-- answer about the caller — no data-leak from the definer privilege, same
-- pattern as current_user_linked_business, 0128).
--
-- Store-scope overrides (store_role_permissions, §10.2.1 middle layer) are NOT
-- consulted here — the web selling loop is single-store-per-sale and the mobile
-- web permission-read (web-pos/src/lib/permissions.ts) resolves Business ± User
-- for the same reason. Add the store layer here if/when web goes multi-store.
CREATE OR REPLACE FUNCTION public.caller_has_permission(
  p_business_id     uuid,
  p_permission_key  text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id  uuid;
  v_role_id  uuid;
  v_slug     text;
  v_has      boolean := false;
  v_override boolean;
BEGIN
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = auth.uid()
   LIMIT 1;
  IF v_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT ub.role_id, r.slug
    INTO v_role_id, v_slug
    FROM public.user_businesses ub
    JOIN public.roles r ON r.id = ub.role_id
   WHERE ub.user_id = v_user_id
     AND ub.business_id = p_business_id
     AND ub.status = 'active'
   ORDER BY ub.last_login_at DESC NULLS LAST
   LIMIT 1;

  -- CEO is all-on and skips every override layer (mirrors resolveEffectivePermissions).
  IF v_slug = 'ceo' THEN
    RETURN true;
  END IF;

  IF v_role_id IS NOT NULL THEN
    v_has := EXISTS (
      SELECT 1 FROM public.role_permissions
       WHERE role_id = v_role_id
         AND business_id = p_business_id
         AND permission_key = p_permission_key
    );
  END IF;

  -- A user override force-grants (true) or force-revokes (false).
  SELECT is_granted INTO v_override
    FROM public.user_permission_overrides
   WHERE user_id = v_user_id
     AND business_id = p_business_id
     AND permission_key = p_permission_key
   LIMIT 1;
  IF v_override IS NOT NULL THEN
    v_has := v_override;
  END IF;

  RETURN v_has;
END;
$$;

REVOKE ALL ON FUNCTION public.caller_has_permission(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.caller_has_permission(uuid, text)
  TO authenticated, service_role;


-- ─── 2. caller_max_discount_percent — the role discount cap, mirrored ────────
--
-- The max discount % the caller's role may apply (§12.6/§13.2), from
-- role_settings.max_discount_percent with the same seed defaults the mobile
-- currentUserMaxDiscountPercentProvider uses (CEO 100, Manager 10, else 0).
CREATE OR REPLACE FUNCTION public.caller_max_discount_percent(
  p_business_id uuid
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid;
  v_role_id uuid;
  v_slug    text;
  v_val     text;
BEGIN
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = auth.uid()
   LIMIT 1;
  IF v_user_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT ub.role_id, r.slug
    INTO v_role_id, v_slug
    FROM public.user_businesses ub
    JOIN public.roles r ON r.id = ub.role_id
   WHERE ub.user_id = v_user_id
     AND ub.business_id = p_business_id
     AND ub.status = 'active'
   ORDER BY ub.last_login_at DESC NULLS LAST
   LIMIT 1;

  IF v_slug = 'ceo' THEN
    RETURN 100;
  END IF;

  IF v_role_id IS NOT NULL THEN
    SELECT setting_value INTO v_val
      FROM public.role_settings
     WHERE role_id = v_role_id
       AND business_id = p_business_id
       AND setting_key = 'max_discount_percent'
     LIMIT 1;
  END IF;

  IF v_val IS NOT NULL AND v_val ~ '^[0-9]+$' THEN
    RETURN v_val::int;
  END IF;

  RETURN CASE v_slug WHEN 'manager' THEN 10 ELSE 0 END;
END;
$$;

REVOKE ALL ON FUNCTION public.caller_max_discount_percent(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.caller_max_discount_percent(uuid)
  TO authenticated, service_role;


-- ─── 3. checkout_order — the keystone cash/transfer checkout ─────────────────
--
-- p_items : [{ "product_id": <uuid>, "quantity": <int>, "unit_price_kobo": <bigint> }, ...]
--           (catalogue lines only — no quick-sale / no-product lines on web yet)
--
-- Idempotent on p_order_id (the client-minted UUIDv7): a replay returns the
-- existing order + items + payment without re-applying any side effect.
CREATE OR REPLACE FUNCTION public.checkout_order(
  p_business_id      uuid,
  p_order_id         uuid,          -- idempotency key (client UUIDv7)
  p_store_id         uuid,
  p_items            jsonb,
  p_payment_method   text,          -- 'cash' | 'transfer'
  p_amount_paid_kobo bigint,
  p_discount_kobo    bigint DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now          timestamptz := now();
  v_actor_id     uuid;
  v_existing     boolean;
  v_gross        bigint;
  v_max_pct      int;
  v_cap          bigint;
  v_discount     bigint;
  v_net          bigint;
  v_order_count  bigint;
  v_order_number text;
  v_item         jsonb;
  v_item_id      uuid;
  v_product_id   uuid;
  v_qty          int;
  v_unit_price   bigint;
  v_line_total   bigint;
  v_new_qty      int;
  v_stx_id       uuid;
  v_payment_id   uuid;
  v_product      uuid;
  v_batches      jsonb;
  v_batch_ids    uuid[];
  v_sales        jsonb;
  v_assigned     jsonb;
  v_rem          jsonb;
  v_line         jsonb;
  v_i            int;
  v_products     uuid[];
  v_oldest_cost  bigint;
  v_order_row    jsonb;
  v_items_out    jsonb;
  v_payment_row  jsonb;
  v_inv_after    jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- Server-side permission enforcement (defence in depth; the web also hides).
  IF NOT public.caller_has_permission(p_business_id, 'sales.make') THEN
    RAISE EXCEPTION 'permission_denied: sales.make'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'store_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer') THEN
    RAISE EXCEPTION 'payment_method_must_be_cash_or_transfer'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotent replay: the order already exists → return its current state.
  SELECT true INTO v_existing FROM public.orders WHERE id = p_order_id;
  IF v_existing THEN
    SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;
    SELECT COALESCE(jsonb_agg(to_jsonb(oi.*) ORDER BY oi.created_at, oi.id), '[]'::jsonb)
      INTO v_items_out FROM public.order_items oi WHERE oi.order_id = p_order_id;
    SELECT to_jsonb(pt.*) INTO v_payment_row
      FROM public.payment_transactions pt
      WHERE pt.order_id = p_order_id AND pt.type = 'sale'
      ORDER BY pt.created_at LIMIT 1;
    RETURN jsonb_build_object(
      'order',               v_order_row,
      'order_items',         v_items_out,
      'payment_transaction', v_payment_row,
      'inventory_after',     '[]'::jsonb,
      'replayed',            true
    );
  END IF;

  -- Attribute the sale to the caller (staff_id). NULL is tolerated (attribution
  -- only) — the sale still commits.
  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  -- Server-computed gross (before discount) from the line prices.
  SELECT COALESCE(SUM((it->>'quantity')::int * (it->>'unit_price_kobo')::bigint), 0)
    INTO v_gross
    FROM jsonb_array_elements(p_items) AS it;

  -- Role discount cap (defence in depth): clamp the requested discount to the
  -- caller's role percentage of gross. A within-cap discount is unchanged.
  v_max_pct  := public.caller_max_discount_percent(p_business_id);
  v_cap      := (v_gross * v_max_pct) / 100;
  v_discount := LEAST(GREATEST(COALESCE(p_discount_kobo, 0), 0), v_cap);
  v_net      := v_gross - v_discount;

  -- Cash/transfer is a fully-settled sale; underpayment is a credit sale (Slice 3).
  IF p_amount_paid_kobo < v_net THEN
    RAISE EXCEPTION 'amount_paid_below_net'
      USING ERRCODE = 'P0001',
            HINT = jsonb_build_object('net_kobo', v_net,
                                      'amount_paid_kobo', p_amount_paid_kobo)::text;
  END IF;

  -- Server-minted order number. 'WEB-' prefix makes collision with a mobile
  -- device-tag number ('ORD-NNNNNN-XXXXXX') impossible regardless of the rest;
  -- the running count is human-friendly and the 6-hex tail from the (globally
  -- unique) order id keeps it unique under (business_id, order_number) even for
  -- two concurrent web tills that computed the same count.
  SELECT count(*) INTO v_order_count FROM public.orders WHERE business_id = p_business_id;
  v_order_number := 'WEB-'
    || lpad((v_order_count + 1)::text, 6, '0')
    || '-' || upper(right(replace(p_order_id::text, '-', ''), 6));

  -- Order header — status 'pending' recognizes revenue at Checkout (matches
  -- mobile: orderCountsAsSale includes 'pending'; completed_at stays NULL until
  -- Confirm). amount_paid is stored as the settled net.
  INSERT INTO public.orders (
    id, business_id, order_number, customer_id,
    total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
    payment_type, status, staff_id, store_id,
    completed_at, cancelled_at, created_at, last_updated_at
  )
  VALUES (
    p_order_id, p_business_id, v_order_number, NULL,
    v_gross, v_discount, v_net, v_net,
    'cash', 'pending', v_actor_id, p_store_id,
    NULL, NULL, v_now, v_now
  );

  -- Items + inventory guard + stock ledger. buying_price_kobo starts 0 and is
  -- overwritten by the FIFO pass below.
  v_items_out := '[]'::jsonb;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty        := (v_item->>'quantity')::int;
    v_unit_price := (v_item->>'unit_price_kobo')::bigint;

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'product_id_required_per_line'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'item_quantity_must_be_positive'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_line_total := v_qty::bigint * v_unit_price;
    v_item_id    := gen_random_uuid();

    INSERT INTO public.order_items (
      id, business_id, order_id, product_id, store_id,
      quantity, unit_price_kobo, buying_price_kobo, total_kobo,
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id, v_product_id, p_store_id,
      v_qty, v_unit_price, 0, v_line_total,
      v_now, v_now
    );

    -- Inventory decrement under the stock guard. The conditional UPDATE takes a
    -- row lock and only succeeds while quantity >= qty, so two concurrent tills
    -- cannot oversell — the loser's UPDATE finds no row and we reject at commit.
    UPDATE public.inventory
       SET quantity = quantity - v_qty
     WHERE business_id = p_business_id
       AND product_id  = v_product_id
       AND store_id    = p_store_id
       AND quantity   >= v_qty
    RETURNING quantity INTO v_new_qty;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id',    v_product_id,
                'store_id',      p_store_id,
                'requested_qty', v_qty
              )::text;
    END IF;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      v_product_id,
      'store_id',        p_store_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );

    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, v_product_id, p_store_id, -v_qty, 'sale',
      p_order_id, v_actor_id, v_now, v_now
    );

    v_items_out := v_items_out || jsonb_build_object(
      'item_id', v_item_id, 'product_id', v_product_id, 'quantity', v_qty);
  END LOOP;

  -- FIFO draw-down per distinct product for this (order, store). Reuses the pure
  -- public.fifo_assign (0133) so the per-unit COGS rounding is byte-for-byte the
  -- same as the recost pass AND the mobile provisional draw-down. Batches are
  -- locked FOR UPDATE (oldest-first) so a concurrent checkout of the same product
  -- serializes on the queue and cannot double-consume a batch.
  v_products := ARRAY(
    SELECT DISTINCT (it->>'product_id')::uuid FROM jsonb_array_elements(p_items) AS it
  );

  FOREACH v_product IN ARRAY v_products LOOP
    -- Lock + load the live queue (qty_remaining > 0), oldest-first.
    SELECT
      COALESCE(jsonb_agg(jsonb_build_object('cost_kobo', cb.cost_kobo, 'qty', cb.qty_remaining)
                         ORDER BY cb.received_at, cb.id), '[]'::jsonb),
      COALESCE(array_agg(cb.id ORDER BY cb.received_at, cb.id), ARRAY[]::uuid[])
    INTO v_batches, v_batch_ids
    FROM (
      SELECT id, cost_kobo, qty_remaining, received_at
        FROM public.cost_batches
       WHERE business_id = p_business_id
         AND product_id  = v_product
         AND store_id    = p_store_id
         AND qty_remaining > 0
       ORDER BY received_at, id
       FOR UPDATE
    ) cb;

    -- This product's sale lines, in insertion order (order_items.created_at then
    -- id — a stable order that continues one draw across repeated lines).
    SELECT COALESCE(jsonb_agg(jsonb_build_object('line_id', oi.id, 'quantity', oi.quantity)
                              ORDER BY oi.created_at, oi.id), '[]'::jsonb)
      INTO v_sales
      FROM public.order_items oi
     WHERE oi.order_id = p_order_id
       AND oi.product_id = v_product;

    v_assigned := public.fifo_assign(v_batches, v_sales);
    v_rem      := v_assigned->'batches_remaining';

    -- Snapshot each line's per-unit COGS.
    FOR v_line IN SELECT * FROM jsonb_array_elements(v_assigned->'lines') LOOP
      UPDATE public.order_items
         SET buying_price_kobo = (v_line->>'cogs_per_unit_kobo')::bigint,
             last_updated_at   = v_now
       WHERE id = (v_line->>'line_id')::uuid;
    END LOOP;

    -- Decrement the consumed batches (only where changed).
    FOR v_i IN 1 .. COALESCE(array_length(v_batch_ids, 1), 0) LOOP
      UPDATE public.cost_batches
         SET qty_remaining = (v_rem->>(v_i - 1))::int
       WHERE id = v_batch_ids[v_i]
         AND qty_remaining IS DISTINCT FROM (v_rem->>(v_i - 1))::int;
    END LOOP;

    -- Re-point the product's scalar buying_price_kobo cache at the oldest
    -- remaining COSTED batch (across stores) — mirrors CostBatchesDao._recompute
    -- ScalarCost: skip uncosted (cost 0) batches, and leave the scalar untouched
    -- when nothing costed remains (never clobber a user-set price to 0).
    SELECT cb.cost_kobo INTO v_oldest_cost
      FROM public.cost_batches cb
     WHERE cb.business_id = p_business_id
       AND cb.product_id  = v_product
       AND cb.qty_remaining > 0
       AND cb.cost_kobo > 0
     ORDER BY cb.received_at, cb.id
     LIMIT 1;
    IF v_oldest_cost IS NOT NULL THEN
      UPDATE public.products
         SET buying_price_kobo = v_oldest_cost, last_updated_at = v_now
       WHERE id = v_product
         AND business_id = p_business_id
         AND buying_price_kobo IS DISTINCT FROM v_oldest_cost;
    END IF;
  END LOOP;

  -- One payment row for the settled amount (type 'sale').
  v_payment_id := gen_random_uuid();
  INSERT INTO public.payment_transactions (
    id, business_id, amount_kobo, method, type,
    order_id, performed_by, created_at, last_updated_at
  )
  VALUES (
    v_payment_id, p_business_id, v_net, p_payment_method, 'sale',
    p_order_id, v_actor_id, v_now, v_now
  );

  -- Compose the response for the receipt.
  SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(oi.*) ORDER BY oi.created_at, oi.id), '[]'::jsonb)
    INTO v_items_out FROM public.order_items oi WHERE oi.order_id = p_order_id;
  SELECT to_jsonb(pt.*) INTO v_payment_row
    FROM public.payment_transactions pt WHERE pt.id = v_payment_id;

  RETURN jsonb_build_object(
    'order',               v_order_row,
    'order_items',         v_items_out,
    'payment_transaction', v_payment_row,
    'inventory_after',     v_inv_after,
    'replayed',            false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint) FROM public;
GRANT EXECUTE ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint)
  TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user):
--
--   1. Helpers + RPC exist:
--        SELECT proname FROM pg_proc
--         WHERE pronamespace = 'public'::regnamespace
--           AND proname IN ('checkout_order','caller_has_permission',
--                           'caller_max_discount_percent')
--         ORDER BY proname;   -- expect 3 rows
--
--   2. Tenant guard fires for another business:
--        SELECT public.checkout_order('<other-biz>', gen_random_uuid(),
--          '<store>', '[]'::jsonb, 'cash', 0);
--        -- expect ERROR: tenant_mismatch
--
--   3. A cash sale writes order(pending) + items + payment + FIFO draw-down, and
--      the order number matches ^WEB-\d{6}-[0-9A-F]{6}$ (never an ORD- number).
--
--   4. Idempotent replay: a second call with the same p_order_id returns
--      replayed=true and applies nothing new.
-- =============================================================================
