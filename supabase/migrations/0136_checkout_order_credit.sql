-- 0136_checkout_order_credit.sql
--
-- Reebaplus — Web POS Slice 3. Extend the server-authoritative `checkout_order`
-- RPC (0135, ADR 0008) to handle REGISTERED-CUSTOMER CREDIT and the wallet
-- ledger (PRD web-pos, issue #44).
--
-- SCOPE (Slice 3): attach a registered customer to the sale and post the
-- append-only wallet ledger legs (§14.3, invariant #3), for the two credit
-- paths the mobile checkout also offers:
--   • Pay-with-Credit     (p_payment_method = 'wallet') — draw the whole order
--                          from the customer's existing wallet balance; no cash
--                          lands. The balance absorbs the debit.
--   • Register-as-Credit-Sale (p_payment_method = 'credit') — the customer takes
--                          the goods now and owes the balance; any cash tendered
--                          part-pays it.
-- Plus: a registered Cash/Transfer sale now also posts its wallet legs (debit
-- the order, credit the cash) so the wallet history is complete, exactly like
-- mobile OrdersDao.createOrder.
--
-- WALLET LEDGER LEGS (mirrors mobile createOrder, deposit carve-out is Slice 4):
--   Leg 1 — debit  the order NET  (goods leave)  → reference 'order_payment'
--   Leg 2 — credit the cash paid  (money in)     → reference 'topup_cash' /
--           'topup_transfer'  (skipped when nothing was paid in cash)
-- The customer balance stays the DERIVED single source of truth:
--   balance = SUM(signed_amount_kobo) over the customer's non-deposit legs.
-- Net position change of a sale = cash_paid − net: 0 when fully settled,
-- negative when the customer owes.
--
-- DEBT LIMIT (server-side enforcement, defence in depth — the web also blocks in
-- the UI): a sale that books NEW debt is rejected when it would push the
-- customer's balance below −wallet_limit_kobo, mirroring the mobile checkout's
-- `_overDebtLimit`:
--   • a fully-settled sale (cash_paid ≥ net) never books debt → never gated,
--     even if the customer is already in the red;
--   • otherwise the projected balance (current + cash_paid − net) must not go
--     below zero UNLESS a positive limit allows it AND it stays ≥ −limit.
--   • wallet_limit_kobo = 0 means "no credit allowed" (any debt is rejected).
--
-- TWO IMPLEMENTATIONS, ONE CONTRACT (ADR 0009): the wallet legs + resulting
-- balance are pinned identical to the mobile Dart path by the Golden-Scenario
-- Suite's new credit fixtures (test/golden/*), which run the same fixtures
-- against both this RPC and OrdersDao.createOrder.
--
-- OVERLOAD TRAP (see [[project_rpc_param_add_overload_trap]]): adding
-- p_customer_id via CREATE OR REPLACE would leave the old 7-arg signature in
-- place as a second overload → PGRST203 ambiguity for older callers. So DROP the
-- 0135 signature first, then create the widened one.
--
-- DEPLOY ORDER: after 0135 (checkout_order), 0133 (fifo_assign), 0132
-- (cost_batches). Additive server logic; inert until called by the web client.

BEGIN;

DROP FUNCTION IF EXISTS public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint);

-- ─── _customer_wallet_balance — the derived spendable balance, mirrored ──────
--
-- The customer's SPENDABLE wallet balance (kobo) = SUM(signed_amount_kobo) over
-- the customer's ledger EXCLUDING the crate-deposit family (a refundable deposit
-- is money held, never spendable credit nor debt). Byte-for-byte the mobile
-- CustomersDao.getBalanceKobo derivation — the single source of truth for both
-- the debt-limit check and the balance the receipt shows. Positive = credit we
-- hold; negative = the customer owes us.
--
-- SECURITY DEFINER + constrained to (business_id, customer_id): no data leak
-- beyond the caller's tenant, which _assert_caller_owns_business already gates.
CREATE OR REPLACE FUNCTION public._customer_wallet_balance(
  p_business_id uuid,
  p_customer_id uuid
)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(SUM(signed_amount_kobo), 0)::bigint
    FROM public.wallet_transactions
   WHERE business_id = p_business_id
     AND customer_id = p_customer_id
     AND reference_type NOT IN
         ('crate_deposit', 'crate_deposit_refunded', 'crate_deposit_forfeited');
$$;

REVOKE ALL ON FUNCTION public._customer_wallet_balance(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public._customer_wallet_balance(uuid, uuid)
  TO authenticated, service_role;


-- ─── checkout_order — cash / transfer / credit / wallet, with the wallet ledger ─
--
-- p_items : [{ "product_id": <uuid>, "quantity": <int>, "unit_price_kobo": <bigint> }, ...]
-- p_payment_method :
--   'cash' | 'transfer'  — fully-settled sale (walk-in or registered).
--   'credit'             — Register-as-Credit-Sale: cash_paid may be 0..net; the
--                          rest is booked as debt (requires p_customer_id).
--   'wallet'             — Pay-with-Credit: cash_paid = 0, drawn from the balance
--                          (requires p_customer_id).
-- p_customer_id : the registered customer (NULL = walk-in). credit/wallet require
--                 a customer; a walk-in can only pay cash/transfer in full.
--
-- Idempotent on p_order_id (client-minted UUIDv7): a replay returns the existing
-- order + items + payment + wallet legs + balance without re-applying anything.
CREATE OR REPLACE FUNCTION public.checkout_order(
  p_business_id      uuid,
  p_order_id         uuid,          -- idempotency key (client UUIDv7)
  p_store_id         uuid,
  p_items            jsonb,
  p_payment_method   text,          -- 'cash' | 'transfer' | 'credit' | 'wallet'
  p_amount_paid_kobo bigint,
  p_discount_kobo    bigint DEFAULT 0,
  p_customer_id      uuid   DEFAULT NULL   -- registered customer (credit/wallet)
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
  v_wtx_id       uuid;
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
  -- customer's position. Mirrors mobile OrdersDao.createOrder; the deposit
  -- carve-out (Leg 3) arrives with crate checkout in Slice 4.
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

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user):
--
--   1. The 7-arg overload is gone; only the 8-arg version remains:
--        SELECT pg_get_function_identity_arguments(oid)
--          FROM pg_proc
--         WHERE pronamespace = 'public'::regnamespace AND proname = 'checkout_order';
--        -- expect ONE row ending in ", p_customer_id uuid"
--
--   2. Register-as-Credit-Sale (no cash) posts one 'order_payment' debit, no
--      credit leg, and the derived balance drops by net:
--        SELECT public.checkout_order('<biz>', gen_random_uuid(), '<store>',
--          '[{"product_id":"<p>","quantity":1,"unit_price_kobo":100000}]'::jsonb,
--          'credit', 0, 0, '<customer>');
--        -- then SUM(signed_amount_kobo) for that customer = old − 100000.
--
--   3. A sale past the debt limit is rejected:
--        -- with wallet_limit_kobo below the projected debt →
--        -- ERROR: debt_limit_exceeded
--
--   4. Pay-with-Credit ('wallet') draws from an existing balance; the credit
--      customer's balance drops by net, no cash payment_transactions row.
-- =============================================================================
