-- 0226_checkout_order_pending_rule.sql
--
-- Web checkout_order follows the Pending rule (#548, PRD #337 slice b).
-- Until now the web till created EVERY order 'pending'. Pending now holds only
-- sales that are waiting for empty crates, so both tills agree with the phone:
--   status = 'pending'   iff the business is a crate business that tracks empties
--                        (_is_crate_business(type) AND COALESCE(tracks_empty_crates,true),
--                        the same gate as the crate block below) AND any submitted
--                        line's product is lower(unit)='bottle' AND track_empties=true
--   otherwise            'completed' with completed_at = now().
-- Re-issued verbatim from the LIVE definition (0222; no later migration touches
-- checkout_order or the _checkout_* helpers). SAME 9-arg signature, so CREATE OR
-- REPLACE (no DROP, no overload). Only delta: the v_pending computation and the
-- status / completed_at values of the orders INSERT. Grants unchanged.
-- Existing Pending orders are left alone.

BEGIN;

CREATE OR REPLACE FUNCTION public.checkout_order(
  p_business_id uuid, p_order_id uuid, p_store_id uuid, p_items jsonb,
  p_payment_method text, p_amount_paid_kobo bigint,
  p_discount_kobo bigint DEFAULT 0, p_customer_id uuid DEFAULT NULL::uuid,
  p_crate_deposit_by_manufacturer jsonb DEFAULT '{}'::jsonb)
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
  v_pay_type     text;     -- orders.payment_type (mobile _resolvePaymentType)
  v_method       text;     -- the real tender on every payment row
  v_deposit      bigint := 0;  -- crate deposit held (sum of the per-brand map)
  v_payable      bigint;       -- net + deposit: what the customer settles
  v_goods_paid   bigint;       -- goods part of the cash tender -> 'sale' row
  v_topup        bigint;       -- over-tender -> 'wallet_topup' row
  v_dep_entry    record;
  v_dep_mfr      uuid;
  v_dep_paid     bigint;
  -- crate (§13.4) locals
  v_biz_type     text;
  v_tracks       boolean;
  v_pending      boolean := false;  -- crate-bearing sale waits in Pending (0226)
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
  -- Money-track crate deposit (0222): { "<manufacturer_id>": kobo, ... }.
  IF p_crate_deposit_by_manufacturer IS NULL
     OR jsonb_typeof(p_crate_deposit_by_manufacturer) <> 'object' THEN
    p_crate_deposit_by_manufacturer := '{}'::jsonb;
  END IF;
  SELECT COALESCE(SUM(GREATEST((e.value)::bigint, 0)), 0) INTO v_deposit
    FROM jsonb_each_text(p_crate_deposit_by_manufacturer) e(key, value);
  IF v_deposit > 0 AND NOT v_registered THEN
    -- Mobile holds no crate balance for a walk-in (rule #14).
    RAISE EXCEPTION 'crate_deposit_requires_customer'
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
  -- The payable the customer settles = goods net + deposit held (0177: the
  -- order header's net IS the payable). Deposit 0 => payable = net, unchanged.
  v_payable  := v_net + v_deposit;

  -- The cash actually settled at checkout, by path:
  --   cash/transfer → fully settled at net (any over-tender is change, not stored)
  --   credit        → the tendered amount, clamped to [0, net]; the rest is debt
  --   wallet        → 0 (drawn from the existing balance)
  -- Over-tender handling mirrors mobile (checkout_page.dart): a walk-in pays
  -- exactly the payable (change is never stored); a registered customer pays
  -- what was entered and any excess becomes their credit (wallet_topup).
  v_cash_paid := CASE p_payment_method
    WHEN 'wallet' THEN 0
    WHEN 'credit' THEN LEAST(GREATEST(COALESCE(p_amount_paid_kobo, 0), 0), v_payable)
    ELSE CASE WHEN v_registered THEN COALESCE(p_amount_paid_kobo, 0) ELSE v_payable END
  END;

  -- A fully-settled cash/transfer sale must actually cover the net (a walk-in
  -- has nowhere to book a shortfall; a registered under-payment goes via 'credit').
  IF p_payment_method IN ('cash', 'transfer')
     AND COALESCE(p_amount_paid_kobo, 0) < v_payable THEN
    RAISE EXCEPTION 'amount_paid_below_net'
      USING ERRCODE = 'P0001',
            HINT = jsonb_build_object('net_kobo', v_payable,
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

    -- Mobile guards paid >= deposit (daos_orders.dart:1093, 1275 "checkout guards paid >= deposit"): the
    -- deposit is cash HELD, never put on credit.
    IF v_deposit > v_cash_paid THEN
      RAISE EXCEPTION 'crate_deposit_exceeds_paid'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object('deposit_kobo', v_deposit,
                                        'amount_paid_kobo', v_cash_paid)::text;
    END IF;

    -- Only a sale that books NEW debt is subject to the limit; a fully-settled
    -- sale never adds debt so it is never gated (matches mobile _overDebtLimit).
    IF v_cash_paid < v_payable THEN
      v_balance   := public._customer_wallet_balance(p_business_id, p_customer_id);
      v_projected := v_balance + (v_cash_paid - v_deposit) - v_net;
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

  -- orders.payment_type: the mobile OrderCommands._resolvePaymentType
  -- (lib/shared/services/orders/order_commands.dart:19-34; called at :102 with
  -- totalAmountKobo = the payable incl. deposit). The tender (cash vs transfer)
  -- lives on the payment rows' method, not here.
  v_pay_type := CASE
    WHEN p_payment_method = 'wallet' THEN 'wallet'
    WHEN v_cash_paid <= 0 THEN
      CASE WHEN COALESCE(v_balance, 0) >= v_payable THEN 'wallet' ELSE 'credit' END
    WHEN v_cash_paid < v_payable THEN 'mixed'
    ELSE 'cash'
  END;

  -- Server-minted order number (helper: 'WEB-NNNNNN-XXXXXX'), before the insert.
  v_order_number := public._checkout_mint_order_number(p_business_id, p_order_id);

  -- Pending rule (0226, #548): pending only for a crate-bearing sale.
  SELECT type, tracks_empty_crates INTO v_biz_type, v_tracks
    FROM public.businesses WHERE id = p_business_id;
  IF public._is_crate_business(v_biz_type) AND COALESCE(v_tracks, true) THEN
    SELECT EXISTS (
      SELECT 1 FROM public.products p
       WHERE p.business_id = p_business_id
         AND p.id IN (SELECT (it->>'product_id')::uuid FROM jsonb_array_elements(p_items) it)
         AND lower(p.unit) = 'bottle'
         AND p.track_empties = true
    ) INTO v_pending;
  END IF;

  -- Order header. A crate-bearing sale is 'pending' (revenue still recognized at
  -- Checkout; completed_at NULL until Confirm); every other sale is 'completed'
  -- straight away. amount_paid is the CASH actually settled (0 on pay-with-credit).
  INSERT INTO public.orders (
    id, business_id, order_number, customer_id,
    total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
    payment_type, status, staff_id, store_id, crate_deposit_paid_kobo,
    completed_at, cancelled_at, created_at, last_updated_at
  )
  VALUES (
    p_order_id, p_business_id, v_order_number, p_customer_id,
    v_gross + v_deposit, v_discount, v_payable, v_cash_paid,
    v_pay_type, CASE WHEN v_pending THEN 'pending' ELSE 'completed' END,
    v_actor_id, p_store_id, v_deposit,
    CASE WHEN v_pending THEN NULL ELSE v_now END, NULL, v_now, v_now
  );

  -- Items + inventory guard + stock ledger (helper), then FIFO draw-down + scalar
  -- re-point (helper). buying_price_kobo starts 0 and is overwritten by the FIFO pass.
  v_inv_after := public._checkout_insert_lines(
    p_business_id, p_order_id, p_store_id, p_items, v_actor_id, v_now);
  PERFORM public._checkout_draw_fifo(
    p_business_id, p_order_id, p_store_id, p_items, v_now);

  -- The cash tender split exactly like the mobile checkout (#175,
  -- daos_orders.dart:1118-1160; pos_record_sale_v2 since 0170/0177): goods
  -- `sale` (paid - deposit, capped at the goods payable), `crate_deposit`
  -- (held), `wallet_topup` (over-tender). They always sum to the cash paid; a
  -- zero leg writes no row (_insertCheckoutPaymentRow, daos_orders.dart:1186).
  -- Every row carries the real method and the sale's store_id (#169).
  IF v_cash_paid > 0 THEN
    v_method     := CASE WHEN p_payment_method = 'transfer' THEN 'transfer' ELSE 'cash' END;
    v_goods_paid := LEAST(GREATEST(v_cash_paid - v_deposit, 0), v_net);
    v_topup      := v_cash_paid - v_deposit - v_goods_paid;

    IF v_goods_paid > 0 THEN
      INSERT INTO public.payment_transactions (
        id, business_id, amount_kobo, method, type,
        order_id, store_id, performed_by, created_at, last_updated_at)
      VALUES (gen_random_uuid(), p_business_id, v_goods_paid, v_method,
              'sale', p_order_id, p_store_id, v_actor_id, v_now, v_now);
    END IF;
    IF v_deposit > 0 THEN
      INSERT INTO public.payment_transactions (
        id, business_id, amount_kobo, method, type,
        order_id, store_id, performed_by, created_at, last_updated_at)
      VALUES (gen_random_uuid(), p_business_id, v_deposit, v_method,
              'crate_deposit', p_order_id, p_store_id, v_actor_id, v_now, v_now);
    END IF;
    IF v_topup > 0 THEN
      INSERT INTO public.payment_transactions (
        id, business_id, amount_kobo, method, type,
        order_id, store_id, performed_by, created_at, last_updated_at)
      VALUES (gen_random_uuid(), p_business_id, v_topup, v_method,
              'wallet_topup', p_order_id, p_store_id, v_actor_id, v_now, v_now);
    END IF;
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
    IF v_cash_paid - v_deposit > 0 THEN
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
        v_cash_paid - v_deposit, v_cash_paid - v_deposit, v_credit_ref, p_order_id,
        v_actor_id, false, v_now, v_now
      );
    END IF;

    -- Leg 3 - the held deposit (Ring 6, daos_orders.dart:1328-1346): one
    -- 'crate_deposit' credit, excluded from the spendable balance.
    IF v_deposit > 0 THEN
      INSERT INTO public.wallet_transactions (
        id, business_id, wallet_id, customer_id, type,
        amount_kobo, signed_amount_kobo, reference_type, order_id,
        performed_by, customer_verified, created_at, last_updated_at
      )
      VALUES (
        gen_random_uuid(), p_business_id, v_wallet_id, p_customer_id, 'credit',
        v_deposit, v_deposit, 'crate_deposit', p_order_id,
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
        v_dep_paid := COALESCE((p_crate_deposit_by_manufacturer ->> v_crate.mfr_id::text)::bigint, 0);

        INSERT INTO public.order_crate_lines (
          id, business_id, order_id, manufacturer_id,
          crates_taken, deposit_rate_kobo, deposit_paid_kobo,
          created_at, last_updated_at
        )
        VALUES (
          gen_random_uuid(), p_business_id, p_order_id, v_crate.mfr_id,
          v_crate.crates, v_rate, v_dep_paid, v_now, v_now
        );

        -- Money-track brand (deposit paid): no issued row / balance (decision 5).
        -- Crate-track (deposit 0) is unchanged.
        IF v_dep_paid = 0 THEN
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
        END IF;
      END LOOP;
    END IF;
  END IF;

  -- Every deposit entry must have landed on a crate line (otherwise the held
  -- money would have no brand to settle against). Rolls the whole sale back.
  IF v_deposit > 0 THEN
    FOR v_dep_entry IN
      SELECT e.key FROM jsonb_each_text(p_crate_deposit_by_manufacturer) e(key, value)
       WHERE (e.value)::bigint > 0
    LOOP
      v_dep_mfr := v_dep_entry.key::uuid;
      IF NOT EXISTS (SELECT 1 FROM public.order_crate_lines
                      WHERE order_id = p_order_id AND manufacturer_id = v_dep_mfr) THEN
        RAISE EXCEPTION 'crate_deposit_unknown_manufacturer'
          USING ERRCODE = 'invalid_parameter_value',
                HINT = jsonb_build_object('manufacturer_id', v_dep_mfr)::text;
      END IF;
    END LOOP;
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
$function$;

REVOKE ALL ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.checkout_order(uuid, uuid, uuid, jsonb, text, bigint, bigint, uuid, jsonb)
  TO authenticated, service_role;

COMMIT;
