-- 0160_money_integrity_rpc_catalogue_price.sql
--
-- #183 / PRD #155 (money-integrity report-truth) — WEB/V2 PARITY WITH #176.
--
-- #176 (migration 0158) added `order_items.catalogue_price_kobo` and the Flutter
-- checkout snapshots the product's TIER LIST price at sale time so a custom-price
-- concession (`catalogue − charged` per unit, deposit-exclusive) is derivable in
-- margin review. But the CLOUD sale RPCs never set the column — the only migration
-- that referenced it was 0158 (the column def). Every cloud RPC that INSERTs
-- order_items did so WITHOUT catalogue_price_kobo, so a sale recorded through a
-- cloud RPC path left it NULL and could not record a concession, breaking parity
-- with the mobile Dart path (ADR 0009 "two implementations, one contract").
--
-- Two cloud sale RPCs INSERT order_items and are fixed here:
--   • public._checkout_insert_lines  — the line-insert helper the WEB POS
--       `checkout_order` (0139) dispatches to. checkout_order itself is unchanged
--       (it calls this helper by name; the response builder already emits the new
--       column via to_jsonb(oi.*)).
--   • public.pos_record_sale_v2      — the mobile "v2 envelope" record-sale RPC
--       (feature.domain_rpcs_v2.record_sale; currently flag-OFF). Patched now,
--       ahead of the flag, exactly as 0091 defensively patched it — a latent
--       landmine otherwise.
--
-- The live MOBILE v1 per-row-upsert path is unaffected: it pushes the order_items
-- row directly with catalogue_price_kobo already set by _buildOrderItems, and
-- 0158 guarantees the column exists cloud-side.
--
-- THE RULE (SQL twin of lib/shared/services/orders/order_commands.dart:597-618):
-- record the catalogue price ONLY when it differs from the charged unit price (a
-- real concession); NULL otherwise — i.e. NULL for a full-price line (charged ==
-- catalogue) and NULL for a product-less quick-sale line (no catalogue at all).
-- Extracted into ONE pure helper `_catalogue_price_snapshot(catalogue, charged)`
-- so both RPCs (and the mobile Dart path they mirror) apply an identical rule
-- (Standards §2 — one source of truth per behaviour).
--
-- SOURCE OF THE CATALOGUE PRICE (no web-client contract change): each p_items
-- element may now carry an OPTIONAL `catalogue_price_kobo` (the product's tier
-- list price the line was quoted at). Adding an optional JSON key is NOT a
-- function-signature change, so both RPCs are a plain CREATE OR REPLACE — no new
-- parameter, no overload, no DROP ([[project_rpc_param_add_overload_trap]]).
--   • The WEB omits the key → NULL. Correct: the web has no set-custom-price
--     surface, so every web line is charged at the tier list price (no concession)
--     and NULL is the same value the Flutter path records for a full-price line.
--   • The mobile v2 envelope (daos_orders.dart `thinItems`) forwards the key, so
--     a custom-priced v2 sale carries the concession end-to-end (companion PR).
-- A product-tier-column heuristic is deliberately NOT used: products carry TWO
-- tier prices (retailer/wholesaler) and the tier a concession deviated from is not
-- reconstructable server-side from a charged price alone — guessing would
-- fabricate an incorrect concession, violating the report-truth this restores.
--
-- Money-column rule (0130): catalogue_price_kobo is bigint. The helper takes and
-- returns bigint; the 0158 column is bigint and is left untouched.
--
-- BEHAVIOR-IDENTICAL otherwise: each function body below is copied VERBATIM from
-- its current definition (_checkout_insert_lines from 0139, pos_record_sale_v2
-- from 0091); the ONLY delta is the added catalogue_price_kobo column + helper
-- call on the order_items INSERT. No money math, FIFO draw-down, stock guard,
-- wallet/crate leg, idempotency or order-numbering behaviour changes.
--
-- DEPLOY ORDER: after 0158 (the column) and after 0139/0091 (the functions being
-- replaced). Additive server logic + a function-body swap; no schema/data change.
-- (0159 is reserved for the parked push-notifications migration on branch
-- feat/push-notifications-fcm — this is 0160.)

BEGIN;

-- ─── _catalogue_price_snapshot — the "record only a real concession" rule ─────
--
-- Byte-for-byte the mobile _buildOrderItems rule: return the catalogue (tier
-- list) price only when it is present AND differs from the charged unit price;
-- NULL otherwise. A NULL catalogue argument (key absent, or a product-less
-- quick-sale line) → NULL, matching 0158's contract. Pure/IMMUTABLE.
CREATE OR REPLACE FUNCTION public._catalogue_price_snapshot(
  p_catalogue_kobo bigint,
  p_charged_kobo   bigint
)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_catalogue_kobo IS NOT NULL AND p_catalogue_kobo <> p_charged_kobo
    THEN p_catalogue_kobo
    ELSE NULL
  END;
$$;

REVOKE ALL ON FUNCTION public._catalogue_price_snapshot(bigint, bigint) FROM public;
GRANT EXECUTE ON FUNCTION public._catalogue_price_snapshot(bigint, bigint)
  TO authenticated, service_role;


-- ─── _checkout_insert_lines — WEB checkout_order line insert + catalogue price ─
--
-- Verbatim from 0139; the ONLY delta is the catalogue_price_kobo column + helper
-- call on the order_items INSERT (see the marked line). Signature unchanged →
-- plain CREATE OR REPLACE, no overload.
CREATE OR REPLACE FUNCTION public._checkout_insert_lines(
  p_business_id uuid,
  p_order_id    uuid,
  p_store_id    uuid,
  p_items       jsonb,
  p_actor_id    uuid,
  p_now         timestamptz
)
RETURNS jsonb          -- inventory_after
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_item       jsonb;
  v_item_id    uuid;
  v_product_id uuid;
  v_qty        int;
  v_unit_price bigint;
  v_line_total bigint;
  v_new_qty    int;
  v_stx_id     uuid;
  v_inv_after  jsonb := '[]'::jsonb;
BEGIN
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
      catalogue_price_kobo,                                        -- #183 delta
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id, v_product_id, p_store_id,
      v_qty, v_unit_price, 0, v_line_total,
      public._catalogue_price_snapshot(                            -- #183 delta
        (v_item->>'catalogue_price_kobo')::bigint, v_unit_price),
      p_now, p_now
    );

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
      'last_updated_at', p_now
    );

    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, v_product_id, p_store_id, -v_qty, 'sale',
      p_order_id, p_actor_id, p_now, p_now
    );
  END LOOP;

  RETURN v_inv_after;
END;
$$;

REVOKE ALL ON FUNCTION public._checkout_insert_lines(uuid, uuid, uuid, jsonb, uuid, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public._checkout_insert_lines(uuid, uuid, uuid, jsonb, uuid, timestamptz)
  TO authenticated, service_role;


-- ─── pos_record_sale_v2 — mobile v2 envelope record-sale + catalogue price ────
--
-- Verbatim from 0091; the ONLY delta is the catalogue_price_kobo column + helper
-- call on the order_items INSERT (see the marked line). Signature unchanged →
-- plain CREATE OR REPLACE, no overload. The replay path returns existing
-- order_items via to_jsonb(oi.*), which now includes the column automatically.
CREATE OR REPLACE FUNCTION public.pos_record_sale_v2(
  p_business_id             uuid,
  p_actor_id                uuid,
  p_order_id                uuid,           -- idempotency key
  p_order_number            text,
  p_store_id                uuid,
  p_payment_type            text,
  p_items                   jsonb,          -- [{product_id, quantity, unit_price_kobo, buying_price_kobo?, price_snapshot?, catalogue_price_kobo?}]
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
      staff_id, store_id, crate_deposit_paid_kobo,
      completed_at, cancelled_at, created_at, last_updated_at
    )
    VALUES (
      p_order_id, p_business_id, p_order_number, p_customer_id,
      v_total_amount, p_discount_kobo, v_net_amount, p_amount_paid_kobo,
      p_payment_type, p_status, p_rider_name, p_barcode,
      p_actor_id, p_store_id, p_crate_deposit_paid_kobo,
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
             'store_id',        i.store_id,
             'quantity',        i.quantity,
             'last_updated_at', i.last_updated_at)), '[]'::jsonb)
      INTO v_inv_after
      FROM public.inventory i
      WHERE i.business_id = p_business_id
        AND i.store_id    = p_store_id
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
      id, business_id, order_id, product_id, store_id,
      quantity, unit_price_kobo, buying_price_kobo, total_kobo, price_snapshot,
      catalogue_price_kobo,                                        -- #183 delta
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id,
      (v_item->>'product_id')::uuid, p_store_id,
      (v_item->>'quantity')::int,
      (v_item->>'unit_price_kobo')::int,
      COALESCE((v_item->>'buying_price_kobo')::int, 0),
      v_total_kobo,
      CASE WHEN v_item ? 'price_snapshot' THEN v_item->'price_snapshot' ELSE NULL END,
      public._catalogue_price_snapshot(                            -- #183 delta
        (v_item->>'catalogue_price_kobo')::bigint,
        (v_item->>'unit_price_kobo')::bigint),
      v_now, v_now
    );

    v_order_items := v_order_items || to_jsonb((SELECT oi FROM public.order_items oi WHERE oi.id = v_item_id));

    -- §12.3/§26.4: a Quick Sale line has no product_id → it bypasses inventory
    -- entirely (no lock/check/deduction, no stock_transactions row).
    CONTINUE WHEN (v_item->>'product_id') IS NULL;

    -- Lock the inventory row so we can distinguish "no row exists" from
    -- "row exists but qty too low". FOR UPDATE matches the wallet pattern
    -- in 0014; concurrent sales for the same product+store serialize
    -- here.
    SELECT quantity INTO v_existing_qty
      FROM public.inventory
     WHERE business_id = p_business_id
       AND product_id  = (v_item->>'product_id')::uuid
       AND store_id    = p_store_id
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'inventory_row_missing'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id', v_item->>'product_id',
                'store_id',   p_store_id
              )::text;
    END IF;

    IF v_existing_qty < (v_item->>'quantity')::int THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id',    v_item->>'product_id',
                'store_id',      p_store_id,
                'requested_qty', (v_item->>'quantity')::int,
                'available_qty', v_existing_qty
              )::text;
    END IF;

    UPDATE public.inventory
       SET quantity = quantity - (v_item->>'quantity')::int
     WHERE business_id = p_business_id
       AND product_id  = (v_item->>'product_id')::uuid
       AND store_id    = p_store_id
    RETURNING quantity INTO v_new_qty;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      (v_item->>'product_id')::uuid,
      'store_id',        p_store_id,
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
      v_stx_id, p_business_id, (v_item->>'product_id')::uuid, p_store_id,
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

GRANT EXECUTE ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text, text, text, int, bool
) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user):
--
--   1. The helper + both RPCs exist with the expected shapes:
--        SELECT proname FROM pg_proc
--         WHERE pronamespace = 'public'::regnamespace
--           AND proname IN ('_catalogue_price_snapshot','_checkout_insert_lines',
--                           'pos_record_sale_v2')
--         ORDER BY proname;   -- expect 3 rows
--
--   2. The rule matches the Flutter path:
--        SELECT public._catalogue_price_snapshot(120000, 100000);  -- 120000 (concession)
--        SELECT public._catalogue_price_snapshot(100000, 100000);  -- NULL   (full price)
--        SELECT public._catalogue_price_snapshot(NULL,   100000);  -- NULL   (no catalogue)
--
--   3. A web checkout with no catalogue key leaves catalogue_price_kobo NULL
--      (no concession); a checkout whose p_items line carries a differing
--      catalogue_price_kobo records it. Confirm via:
--        SELECT unit_price_kobo, catalogue_price_kobo
--          FROM public.order_items WHERE order_id = '<that-order>';
-- =============================================================================
