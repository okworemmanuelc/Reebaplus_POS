-- ROLLBACK for migration 0222. Captured from the LIVE database on 2026-10-26
-- (pg_get_functiondef('public.checkout_order'::regproc), pre-apply; live ACL was
-- {postgres, service_role, authenticated} EXECUTE). Run in one transaction.
-- Safe at any time: it only swaps the function; no data is touched. Rows written
-- by 0222 (split payment rows, deposits) stay valid and are read by the same
-- clients, so no data rollback is needed.
BEGIN;
DROP FUNCTION IF EXISTS public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid, jsonb);
CREATE OR REPLACE FUNCTION public.checkout_order(p_business_id uuid, p_order_id uuid, p_store_id uuid, p_items jsonb, p_payment_method text, p_amount_paid_kobo bigint, p_discount_kobo bigint DEFAULT 0, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
$function$
;
REVOKE ALL ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid) TO authenticated, service_role;
COMMIT;
