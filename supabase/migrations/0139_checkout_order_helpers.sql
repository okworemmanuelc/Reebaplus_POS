-- 0139_checkout_order_helpers.sql
--
-- Reebaplus — Web POS checkout follow-up #53. Extract the INVARIANT legs of the
-- `checkout_order` RPC (grown inline across 0135 cash → 0136 credit → 0137 crate)
-- into SECURITY DEFINER helper functions, and CREATE OR REPLACE `checkout_order`
-- (same 8-arg signature) to CALL them. From here a new slice grows only its own
-- dispatch, never another copy of the shared legs (Standards #2 — one source of
-- truth per behavior). The three helpers are:
--   • _checkout_mint_order_number  — the 'WEB-NNNNNN-XXXXXX' number (0137:285-288)
--   • _checkout_insert_lines       — item + inventory-guard + stock-ledger loop
--                                    (0137:306-377), returns inventory_after
--   • _checkout_draw_fifo          — FIFO draw-down + scalar re-point (0137:379-453)
--
-- BEHAVIOR-IDENTICAL to 0137: this is a pure internal refactor. The extracted
-- blocks are copied verbatim (only the dead v_items_out accumulation the loop
-- built and 0137 immediately overwrote from the DB is dropped). Same signature →
-- plain CREATE OR REPLACE, no overload, no drop ([[project_rpc_param_add_overload_trap]]).
-- The helpers run in the caller's transaction, so the FOR UPDATE batch locks, the
-- stock-guard row locks, gen_random_uuid()s and the passed-in v_now timestamps all
-- behave exactly as inline. cash/credit/crate branches stay in checkout_order.
--
-- ⚠️ NOT YET VERIFIED / DO NOT DEPLOY BLIND. The parity guarantee is the Golden
-- Scenario Suite's RPC arm (test/integration/rpcs/checkout_order_golden_test.dart,
-- Tier-2). Deploy this ONLY after that arm is GREEN against dev (it needs a fresh
-- TEST_USER_REFRESH_TOKEN — the committed token is expired). A behavior-identical
-- rewrite of the live money path must be proven, not assumed.
--
-- DEPLOY ORDER: after 0137 (it replaces 0137's checkout_order). Additive helpers +
-- a function-body swap; no schema/data change.

BEGIN;

-- ─── _checkout_mint_order_number — the server 'WEB-…' number, extracted ───────
--
-- 'WEB-' prefix makes collision with a mobile device-tag number
-- ('ORD-NNNNNN-XXXXXX') impossible regardless of the rest; the running count is
-- human-friendly and the 6-hex tail from the (globally unique) order id keeps it
-- unique under (business_id, order_number) even for two concurrent web tills that
-- computed the same count. Must be called BEFORE the order row is inserted (the
-- count is of pre-existing orders), exactly as inline.
CREATE OR REPLACE FUNCTION public._checkout_mint_order_number(
  p_business_id uuid,
  p_order_id    uuid
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT 'WEB-'
    || lpad((count(*) + 1)::text, 6, '0')
    || '-' || upper(right(replace(p_order_id::text, '-', ''), 6))
    FROM public.orders
   WHERE business_id = p_business_id;
$$;

REVOKE ALL ON FUNCTION public._checkout_mint_order_number(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public._checkout_mint_order_number(uuid, uuid)
  TO authenticated, service_role;


-- ─── _checkout_insert_lines — items + inventory guard + stock ledger, extracted ─
--
-- Per line: insert order_items (buying_price_kobo starts 0; the FIFO pass
-- overwrites it), decrement inventory under the stock guard (conditional UPDATE
-- takes a row lock and only succeeds while quantity >= qty, so two concurrent
-- tills cannot oversell), and append the 'sale' stock_transactions row. Returns
-- the accumulated inventory_after array for the receipt. Raises the same guards.
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
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id, v_product_id, p_store_id,
      v_qty, v_unit_price, 0, v_line_total,
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


-- ─── _checkout_draw_fifo — FIFO draw-down + scalar re-point, extracted ────────
--
-- Per distinct product for this (order, store): lock the live queue oldest-first
-- (FOR UPDATE so a concurrent checkout of the same product serializes and cannot
-- double-consume), run the pure public.fifo_assign (0133 — byte-for-byte COGS
-- rounding shared with the recost pass + the mobile provisional draw), snapshot
-- each line's per-unit COGS onto order_items.buying_price_kobo, decrement the
-- consumed batches, and re-point the product's scalar buying_price_kobo cache at
-- the oldest remaining COSTED batch (skip cost-0 batches; never clobber to 0).
CREATE OR REPLACE FUNCTION public._checkout_draw_fifo(
  p_business_id uuid,
  p_order_id    uuid,
  p_store_id    uuid,
  p_items       jsonb,
  p_now         timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_products    uuid[];
  v_product     uuid;
  v_batches     jsonb;
  v_batch_ids   uuid[];
  v_sales       jsonb;
  v_assigned    jsonb;
  v_rem         jsonb;
  v_line        jsonb;
  v_i           int;
  v_oldest_cost bigint;
BEGIN
  v_products := ARRAY(
    SELECT DISTINCT (it->>'product_id')::uuid FROM jsonb_array_elements(p_items) AS it
  );

  FOREACH v_product IN ARRAY v_products LOOP
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

    SELECT COALESCE(jsonb_agg(jsonb_build_object('line_id', oi.id, 'quantity', oi.quantity)
                              ORDER BY oi.created_at, oi.id), '[]'::jsonb)
      INTO v_sales
      FROM public.order_items oi
     WHERE oi.order_id = p_order_id
       AND oi.product_id = v_product;

    v_assigned := public.fifo_assign(v_batches, v_sales);
    v_rem      := v_assigned->'batches_remaining';

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_assigned->'lines') LOOP
      UPDATE public.order_items
         SET buying_price_kobo = (v_line->>'cogs_per_unit_kobo')::bigint,
             last_updated_at   = p_now
       WHERE id = (v_line->>'line_id')::uuid;
    END LOOP;

    FOR v_i IN 1 .. COALESCE(array_length(v_batch_ids, 1), 0) LOOP
      UPDATE public.cost_batches
         SET qty_remaining = (v_rem->>(v_i - 1))::int
       WHERE id = v_batch_ids[v_i]
         AND qty_remaining IS DISTINCT FROM (v_rem->>(v_i - 1))::int;
    END LOOP;

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
         SET buying_price_kobo = v_oldest_cost, last_updated_at = p_now
       WHERE id = v_product
         AND business_id = p_business_id
         AND buying_price_kobo IS DISTINCT FROM v_oldest_cost;
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public._checkout_draw_fifo(uuid, uuid, uuid, jsonb, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public._checkout_draw_fifo(uuid, uuid, uuid, jsonb, timestamptz)
  TO authenticated, service_role;


-- ─── checkout_order — same contract, now dispatching through the helpers ──────
--
-- Signature + return shape + every guard, timestamp and side effect unchanged
-- from 0137; the shared legs simply moved into the three helpers above. See 0137
-- for the full behavioral contract (idempotency, revenue-at-checkout, §14.3
-- wallet legs, §13.4 crate-track dispatch, no double-count).
CREATE OR REPLACE FUNCTION public.checkout_order(
  p_business_id      uuid,
  p_order_id         uuid,          -- idempotency key (client UUIDv7)
  p_store_id         uuid,
  p_items            jsonb,
  p_payment_method   text,          -- 'cash' | 'transfer' | 'credit' | 'wallet'
  p_amount_paid_kobo bigint,
  p_discount_kobo    bigint DEFAULT 0,
  p_customer_id      uuid   DEFAULT NULL   -- registered customer (credit/wallet/crate)
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
  v_registered   boolean := p_customer_id IS NOT NULL;
  v_gross        bigint;
  v_max_pct      int;
  v_cap          bigint;
  v_discount     bigint;
  v_net          bigint;
  v_cash_paid    bigint;
  v_wallet_id    uuid;
  v_balance      bigint;
  v_projected    bigint;
  v_limit        bigint;
  v_credit_ref   text;
  v_order_number text;
  v_payment_id   uuid;
  v_wtx_id       uuid;
  -- crate (§13.4) locals
  v_biz_type     text;
  v_tracks       boolean;
  v_crate        record;
  v_rate         bigint;
  v_crl_id       uuid;
  -- response locals
  v_order_row    jsonb;
  v_items_out    jsonb;
  v_payment_row  jsonb;
  v_wallet_rows  jsonb;
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
  IF p_payment_method IS NULL
     OR p_payment_method NOT IN ('cash', 'transfer', 'credit', 'wallet') THEN
    RAISE EXCEPTION 'payment_method_must_be_cash_transfer_credit_or_wallet'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  -- The credit paths need a wallet to post to; a walk-in has none (rule #14).
  IF NOT v_registered AND p_payment_method IN ('credit', 'wallet') THEN
    RAISE EXCEPTION 'credit_requires_customer'
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
    SELECT COALESCE(jsonb_agg(to_jsonb(wt.*) ORDER BY wt.created_at, wt.id), '[]'::jsonb)
      INTO v_wallet_rows FROM public.wallet_transactions wt WHERE wt.order_id = p_order_id;
    RETURN jsonb_build_object(
      'order',               v_order_row,
      'order_items',         v_items_out,
      'payment_transaction', v_payment_row,
      'wallet_transactions', v_wallet_rows,
      'customer_balance_kobo',
        CASE WHEN v_registered
             THEN public._customer_wallet_balance(p_business_id, p_customer_id)
             ELSE NULL END,
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

  -- The cash actually settled at checkout, by path:
  --   cash/transfer → fully settled at net (any over-tender is change, not stored)
  --   credit        → the tendered amount, clamped to [0, net]; the rest is debt
  --   wallet        → 0 (drawn from the existing balance)
  v_cash_paid := CASE p_payment_method
    WHEN 'wallet' THEN 0
    WHEN 'credit' THEN LEAST(GREATEST(COALESCE(p_amount_paid_kobo, 0), 0), v_net)
    ELSE v_net
  END;

  -- A fully-settled cash/transfer sale must actually cover the net (a walk-in
  -- has nowhere to book a shortfall; a registered under-payment goes via 'credit').
  IF p_payment_method IN ('cash', 'transfer') AND p_amount_paid_kobo < v_net THEN
    RAISE EXCEPTION 'amount_paid_below_net'
      USING ERRCODE = 'P0001',
            HINT = jsonb_build_object('net_kobo', v_net,
                                      'amount_paid_kobo', p_amount_paid_kobo)::text;
  END IF;

  -- Registered sale: resolve the wallet + enforce the debt limit BEFORE any write.
  IF v_registered THEN
    SELECT id INTO v_wallet_id
      FROM public.customer_wallets
     WHERE business_id = p_business_id
       AND customer_id = p_customer_id
       AND is_deleted = false
     LIMIT 1;
    IF v_wallet_id IS NULL THEN
      RAISE EXCEPTION 'customer_wallet_missing'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object('customer_id', p_customer_id)::text;
    END IF;

    -- Only a sale that books NEW debt is subject to the limit; a fully-settled
    -- sale never adds debt so it is never gated (matches mobile _overDebtLimit).
    IF v_cash_paid < v_net THEN
      v_balance   := public._customer_wallet_balance(p_business_id, p_customer_id);
      v_projected := v_balance + v_cash_paid - v_net;
      IF v_projected < 0 THEN
        SELECT wallet_limit_kobo INTO v_limit
          FROM public.customers
         WHERE id = p_customer_id AND business_id = p_business_id;
        IF COALESCE(v_limit, 0) <= 0 OR v_projected < -v_limit THEN
          RAISE EXCEPTION 'debt_limit_exceeded'
            USING ERRCODE = 'P0001',
                  HINT = jsonb_build_object(
                    'customer_id',    p_customer_id,
                    'limit_kobo',     COALESCE(v_limit, 0),
                    'projected_kobo', v_projected
                  )::text;
        END IF;
      END IF;
    END IF;
  END IF;

  -- Server-minted order number (helper: 'WEB-NNNNNN-XXXXXX'), before the insert.
  v_order_number := public._checkout_mint_order_number(p_business_id, p_order_id);

  -- Order header — status 'pending' recognizes revenue at Checkout (matches
  -- mobile: orderCountsAsSale includes 'pending'; completed_at stays NULL until
  -- Confirm). amount_paid is the CASH actually settled (0 on a pay-with-credit).
  INSERT INTO public.orders (
    id, business_id, order_number, customer_id,
    total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
    payment_type, status, staff_id, store_id,
    completed_at, cancelled_at, created_at, last_updated_at
  )
  VALUES (
    p_order_id, p_business_id, v_order_number, p_customer_id,
    v_gross, v_discount, v_net, v_cash_paid,
    'cash', 'pending', v_actor_id, p_store_id,
    NULL, NULL, v_now, v_now
  );

  -- Items + inventory guard + stock ledger (helper), then FIFO draw-down + scalar
  -- re-point (helper). buying_price_kobo starts 0 and is overwritten by the FIFO pass.
  v_inv_after := public._checkout_insert_lines(
    p_business_id, p_order_id, p_store_id, p_items, v_actor_id, v_now);
  PERFORM public._checkout_draw_fifo(
    p_business_id, p_order_id, p_store_id, p_items, v_now);

  -- One payment row for the cash actually settled (type 'sale'). Skipped when
  -- nothing was paid in cash (pure credit sale or pay-with-credit).
  IF v_cash_paid > 0 THEN
    v_payment_id := gen_random_uuid();
    INSERT INTO public.payment_transactions (
      id, business_id, amount_kobo, method, type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_payment_id, p_business_id, v_cash_paid,
      CASE WHEN p_payment_method = 'transfer' THEN 'transfer' ELSE 'cash' END,
      'sale', p_order_id, v_actor_id, v_now, v_now
    );
  END IF;

  -- §14.3 wallet ledger (invariant #3, registered customers only). Two
  -- append-only legs, same event so same created_at: debit the order NET (goods
  -- leave) and credit the cash paid (money in). The net (cash − net) is the
  -- customer's position. Mirrors mobile OrdersDao.createOrder. The deposit
  -- carve-out (a held 'crate_deposit' leg) belongs to the money-track path,
  -- which the web does not exercise (crate-track only) — see 0137 header.
  IF v_registered THEN
    -- Leg 1 — debit the order net.
    v_wtx_id := gen_random_uuid();
    INSERT INTO public.wallet_transactions (
      id, business_id, wallet_id, customer_id, type,
      amount_kobo, signed_amount_kobo, reference_type, order_id,
      performed_by, customer_verified, created_at, last_updated_at
    )
    VALUES (
      v_wtx_id, p_business_id, v_wallet_id, p_customer_id, 'debit',
      v_net, -v_net, 'order_payment', p_order_id,
      v_actor_id, false, v_now, v_now
    );

    -- Leg 2 — credit the cash applied (money into the wallet). Skipped for a
    -- pay-with-credit / pure credit sale (nothing paid in cash).
    IF v_cash_paid > 0 THEN
      v_credit_ref := CASE WHEN p_payment_method = 'transfer'
                           THEN 'topup_transfer' ELSE 'topup_cash' END;
      v_wtx_id := gen_random_uuid();
      INSERT INTO public.wallet_transactions (
        id, business_id, wallet_id, customer_id, type,
        amount_kobo, signed_amount_kobo, reference_type, order_id,
        performed_by, customer_verified, created_at, last_updated_at
      )
      VALUES (
        v_wtx_id, p_business_id, v_wallet_id, p_customer_id, 'credit',
        v_cash_paid, v_cash_paid, v_credit_ref, p_order_id,
        v_actor_id, false, v_now, v_now
      );
    END IF;
  END IF;

  -- §13.4 empty-crate dispatch (registered customers only). For a crate-eligible
  -- business that tracks empties, record the crates taken per manufacturer and
  -- (crate-track path — no deposit collected) post an 'issued' crate_ledger row
  -- + increment customer_crate_balances so a later return nets to zero. Mirrors
  -- mobile OrdersDao.createOrder + CrateLedgerDao.recordCrateIssueByCustomer.
  -- Wholly separate from the drink cost/stock/wallet legs — no double-count.
  IF v_registered THEN
    SELECT type, tracks_empty_crates INTO v_biz_type, v_tracks
      FROM public.businesses WHERE id = p_business_id;

    IF public._is_crate_business(v_biz_type) AND COALESCE(v_tracks, true) THEN
      FOR v_crate IN
        SELECT p.manufacturer_id AS mfr_id, SUM(oi.quantity)::int AS crates
          FROM public.order_items oi
          JOIN public.products p ON p.id = oi.product_id
         WHERE oi.order_id = p_order_id
           AND p.manufacturer_id IS NOT NULL
           AND lower(p.unit) = 'bottle'
           AND p.track_empties = true
         GROUP BY p.manufacturer_id
      LOOP
        SELECT deposit_amount_kobo INTO v_rate
          FROM public.manufacturers
         WHERE id = v_crate.mfr_id AND business_id = p_business_id;
        v_rate := COALESCE(v_rate, 0);

        INSERT INTO public.order_crate_lines (
          id, business_id, order_id, manufacturer_id,
          crates_taken, deposit_rate_kobo, deposit_paid_kobo,
          created_at, last_updated_at
        )
        VALUES (
          gen_random_uuid(), p_business_id, p_order_id, v_crate.mfr_id,
          v_crate.crates, v_rate, 0, v_now, v_now
        );

        v_crl_id := gen_random_uuid();
        INSERT INTO public.crate_ledger (
          id, business_id, customer_id, manufacturer_id,
          quantity_delta, movement_type, reference_order_id, performed_by,
          created_at, last_updated_at
        )
        VALUES (
          v_crl_id, p_business_id, p_customer_id, v_crate.mfr_id,
          v_crate.crates, 'issued', p_order_id, v_actor_id, v_now, v_now
        );

        INSERT INTO public.customer_crate_balances (
          id, business_id, customer_id, manufacturer_id, balance,
          created_at, last_updated_at
        )
        VALUES (
          gen_random_uuid(), p_business_id, p_customer_id, v_crate.mfr_id,
          v_crate.crates, v_now, v_now
        )
        ON CONFLICT (business_id, customer_id, manufacturer_id) DO UPDATE
          SET balance = customer_crate_balances.balance + EXCLUDED.balance,
              last_updated_at = v_now;
      END LOOP;
    END IF;
  END IF;

  -- Compose the response for the receipt.
  SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(oi.*) ORDER BY oi.created_at, oi.id), '[]'::jsonb)
    INTO v_items_out FROM public.order_items oi WHERE oi.order_id = p_order_id;
  SELECT to_jsonb(pt.*) INTO v_payment_row
    FROM public.payment_transactions pt
    WHERE pt.order_id = p_order_id AND pt.type = 'sale'
    ORDER BY pt.created_at LIMIT 1;
  SELECT COALESCE(jsonb_agg(to_jsonb(wt.*) ORDER BY wt.created_at, wt.id), '[]'::jsonb)
    INTO v_wallet_rows FROM public.wallet_transactions wt WHERE wt.order_id = p_order_id;

  RETURN jsonb_build_object(
    'order',               v_order_row,
    'order_items',         v_items_out,
    'payment_transaction', v_payment_row,
    'wallet_transactions', v_wallet_rows,
    'customer_balance_kobo',
      CASE WHEN v_registered
           THEN public._customer_wallet_balance(p_business_id, p_customer_id)
           ELSE NULL END,
    'inventory_after',     v_inv_after,
    'replayed',            false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid)
  TO authenticated, service_role;

COMMIT;
