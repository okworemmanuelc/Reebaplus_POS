-- 0137_checkout_order_crate.sql
--
-- Reebaplus — Web POS Slice 4. Extend the server-authoritative `checkout_order`
-- RPC (0135 → widened by 0136) to post EMPTY-CRATE ledger movements for
-- crate-eligible businesses (PRD web-pos, ADR 0008, issue #45).
--
-- SCOPE (Slice 4): the empties-tracking ("crate-track") path. For a REGISTERED
-- customer at a crate-eligible business that opts into empty-crate tracking, a
-- sale of deposit-bearing product now records, per manufacturer:
--   • one order_crate_lines row  — crates taken + the deposit RATE snapshot
--     (from manufacturers.deposit_amount_kobo, frozen at sale time so a later
--     CEO rate edit never rewrites historic settlements) + deposit PAID (0 on
--     the crate-track path — no cash deposit is collected at web checkout);
--   • one 'issued' crate_ledger row (+crates) and a customer_crate_balances
--     increment — so the existing return path can net the balance back to zero
--     (the fix for "returned everything but still shows owing").
--
-- COMBINED CRATE GATE (mirrors mobile isCrateBusiness(type) AND
-- businesses.tracks_empty_crates, §13.4 / rule #13): the whole block is a no-op
-- unless the business type is Bar / Beer|Beverage distributor AND
-- tracks_empty_crates is on — even a legacy bottle+track_empties product at a
-- non-crate business accrues NO crate rows. Crate eligibility per line mirrors
-- the mobile basis exactly: unit ILIKE 'bottle' AND track_empties AND a
-- manufacturer. Walk-ins (no customer) hold no crate balance (rule #14).
--
-- NO DOUBLE-COUNT (issue AC): the crate legs are wholly separate from the drink
-- cost/stock legs — they never touch inventory, cost_batches, order_items COGS,
-- payment_transactions, or the wallet. A crate is an EMPTY the customer owes
-- back; the drink it held is already priced/stocked/costed by the sale legs.
--
-- TWO IMPLEMENTATIONS, ONE CONTRACT (ADR 0009): this crate posting is the SQL
-- twin of mobile OrdersDao.createOrder's §13.4 crate dispatch (crate-track
-- branch: depositPaid == 0 → order_crate_lines + recordCrateIssueByCustomer).
-- The Golden-Scenario Suite's new crate fixtures (test/golden/crate_sale_
-- scenarios.json) run the SAME fixtures against both this RPC and the Dart DAO;
-- any drift on the crate rows fails the build.
--
-- MONEY-TRACK DEPOSIT CARVE-OUT (paid-in-cash deposit → held 'crate_deposit'
-- wallet leg, mobile createOrder Ring 6) is deliberately out of Slice 4's scope:
-- the web collects no deposit money at checkout (no deposit-collection UI, and
-- the customer-attach UI is Slice 3 / #44), so every web crate sale is
-- crate-track. When a deposit-collection surface arrives it extends this RPC.
--
-- SIGNATURE UNCHANGED: this is a plain CREATE OR REPLACE of the 8-arg 0136
-- function (same argument list) with the crate block added — no new parameter,
-- so no overload and no drop is needed (see [[project_rpc_param_add_overload_trap]]).
--
-- DEPLOY ORDER: after 0136 (checkout_order + p_customer_id), 0133 (fifo_assign),
-- 0132 (cost_batches). Additive server logic; inert until called by the web
-- client with a registered customer at a crate-eligible business.

BEGIN;

-- ─── _is_crate_business — the crate-feature gate, mirrored ───────────────────
--
-- Byte-for-byte the mobile isCrateBusiness(type) (lib/core/data/business_types.dart):
-- case-insensitive + trimmed, Bar / Beer distributor / Beverage distributor only.
-- Normalising here keeps the gate correct for tenants onboarded by older builds
-- that stored non-canonical casings (e.g. 'Beer Distributor'). NULL type → false.
CREATE OR REPLACE FUNCTION public._is_crate_business(p_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(lower(btrim(p_type)) IN
                    ('bar', 'beer distributor', 'beverage distributor'), false);
$$;

REVOKE ALL ON FUNCTION public._is_crate_business(text) FROM public;
GRANT EXECUTE ON FUNCTION public._is_crate_business(text)
  TO authenticated, service_role;


-- ─── checkout_order — cash / transfer / credit / wallet + wallet ledger + crate ─
--
-- p_items : [{ "product_id": <uuid>, "quantity": <int>, "unit_price_kobo": <bigint> }, ...]
-- p_payment_method :
--   'cash' | 'transfer'  — fully-settled sale (walk-in or registered).
--   'credit'             — Register-as-Credit-Sale: cash_paid may be 0..net; the
--                          rest is booked as debt (requires p_customer_id).
--   'wallet'             — Pay-with-Credit: cash_paid = 0, drawn from the balance
--                          (requires p_customer_id).
-- p_customer_id : the registered customer (NULL = walk-in). credit/wallet require
--                 a customer; a walk-in can only pay cash/transfer in full. A
--                 registered sale at a crate-eligible business also posts the
--                 empties (crate) legs for deposit-bearing product.
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
  -- crate (§13.4) locals
  v_biz_type     text;
  v_tracks       boolean;
  v_crate        record;
  v_rate         bigint;
  v_crl_id       uuid;
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
  -- customer's position. Mirrors mobile OrdersDao.createOrder. The deposit
  -- carve-out (a held 'crate_deposit' leg) belongs to the money-track path,
  -- which the web does not exercise (Slice 4 is crate-track only) — see header.
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
      -- Crate-eligible lines grouped by manufacturer: unit ILIKE 'bottle' AND
      -- track_empties AND a manufacturer (mobile's exact basis).
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
        -- Deposit RATE snapshot (per manufacturer, frozen at sale time).
        SELECT deposit_amount_kobo INTO v_rate
          FROM public.manufacturers
         WHERE id = v_crate.mfr_id AND business_id = p_business_id;
        v_rate := COALESCE(v_rate, 0);

        -- One order_crate_lines row per manufacturer (deposit_paid 0 =
        -- crate-track). UNIQUE (business_id, order_id, manufacturer_id) — one
        -- row per manufacturer per order, so a plain INSERT never conflicts.
        INSERT INTO public.order_crate_lines (
          id, business_id, order_id, manufacturer_id,
          crates_taken, deposit_rate_kobo, deposit_paid_kobo,
          created_at, last_updated_at
        )
        VALUES (
          gen_random_uuid(), p_business_id, p_order_id, v_crate.mfr_id,
          v_crate.crates, v_rate, 0, v_now, v_now
        );

        -- Crate-track: the customer owes the empties. Append an 'issued' ledger
        -- row (+crates) and increment the per-manufacturer balance.
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

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user
-- at a crate-eligible business — type Bar / Beverage distributor, tracks_empty_
-- crates on — with a registered customer + wallet + a bottle/track_empties
-- product that has a manufacturer):
--
--   1. A registered crate sale posts one order_crate_lines row (deposit rate
--      snapshot, deposit_paid 0), one 'issued' crate_ledger row (+crates), and
--      bumps customer_crate_balances by the crates taken:
--        SELECT public.checkout_order('<biz>', gen_random_uuid(), '<store>',
--          '[{"product_id":"<bottle-p>","quantity":3,"unit_price_kobo":100000}]'::jsonb,
--          'cash', 300000, 0, '<customer>');
--        SELECT crates_taken, deposit_rate_kobo, deposit_paid_kobo
--          FROM public.order_crate_lines WHERE order_id = '<that-order>';
--        SELECT quantity_delta, movement_type FROM public.crate_ledger
--          WHERE reference_order_id = '<that-order>';   -- +3, 'issued'
--        SELECT balance FROM public.customer_crate_balances
--          WHERE customer_id = '<customer>' AND manufacturer_id = '<mfr>';
--
--   2. The same sale at a NON-crate business (or with tracks_empty_crates off)
--      posts NO order_crate_lines / crate_ledger rows.
--
--   3. A walk-in (p_customer_id NULL) never posts crate rows.
-- =============================================================================
