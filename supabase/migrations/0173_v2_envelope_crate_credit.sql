-- 0173_v2_envelope_crate_credit.sql
--
-- #209 / PRD #155 close-out — THE v2 SALE ENVELOPE STOPS DROPPING THE
-- CUSTOMER'S CRATE CREDIT.
--
-- `pos_record_sale_v2` is server-authoritative on totals: it recomputes the
-- gross from `p_items` and derives the payable itself. Until now it derived it
-- from ONE client-sent reduction — `p_discount_kobo`, the per-line discount sum.
-- The cart's goods total is `gross − discount − customerCrateCredit`, so the
-- credit had nowhere to ride and simply vanished on the wire. `v_net_amount`
-- then came out HIGHER than the header the client had already written locally,
-- by exactly the credit, and two numbers went wrong at once:
--
--   1. THE ORDER HEADER. The RPC writes `orders.total_amount_kobo` /
--      `net_amount_kobo` from its own figures and the response overwrites the
--      local mirror (`_applyDomainResponse` → `_restoreTableData('orders', …)`),
--      so a crate-credit sale recorded a payable the customer was never charged.
--      This half predates #175.
--
--   2. THE TENDER SPLIT (0170 / #201). The split is computed from
--      `v_net_amount − depositHeld`, so an over-stated goods payable books up to
--      `credit` MORE of the tender as goods `sale` and correspondingly less as
--      `wallet_topup` than the v1 path books for the same sale. 0170's header
--      recorded this as "the only self-consistent choice available without a
--      signature change" and filed #209 for the signature change. This is it.
--
-- Both symptoms are the SAME dropped term, so ONE forwarded value fixes both.
--
-- ── WHAT CHANGES ──────────────────────────────────────────────────────────
-- ONE new parameter, `p_crate_credit_kobo int DEFAULT 0`, and ONE line of math:
--
--     v_net_amount := v_total_amount - p_discount_kobo + p_crate_deposit_paid_kobo
--                                    - p_crate_credit_kobo;   -- #209 delta
--
-- Nothing else in the function moves. The stock guard, FIFO, wallet leg, crate
-- leg, van suppression, idempotency/replay, order numbering, catalogue-price
-- capture, the #201 three-way tender split and every response key are copied
-- VERBATIM from 0170 (the current definition); the delta lines are marked
-- `-- #209 delta`.
--
-- ── WHY A SEPARATE TERM AND NOT "JUST FOLD IT INTO p_discount_kobo" ────────
-- Because `p_discount_kobo` is STORED, as `orders.discount_kobo`, and read back
-- as a discount: the receipt rebuilds Subtotal → Discount → Total from it
-- (`receiptTotalsFromOrder`, #200 / US 33) and margin review treats it as
-- revenue given away. A crate credit is neither — it is the customer's own
-- deposit money coming back to them. Folding the two together would have made
-- `v_net_amount` right and the discount column wrong, trading a visible defect
-- for an invisible one. The credit therefore reduces the PAYABLE without being
-- recorded as a discount, which is exactly what the v1 path does today.
--
-- It is deliberately NOT given an `orders` column. The credit is fully expressed
-- by `net_amount_kobo` (its whole effect), and a column would need a Drift
-- schema bump, a sync-registry entry and a pull-restore case for a figure the
-- client can re-derive. When a real credit ships and the owner needs it itemised
-- on the receipt, that is the change to make — with its own printed line, as
-- `ReceiptTotals.totalKobo` already notes.
--
-- ── THE VALUE IS DERIVED, NOT PLUMBED (the companion client change) ────────
-- `OrdersDao.createOrder` does not take a credit argument and no caller supplies
-- one. It computes the term as "the part of the payable the header does not
-- otherwise explain":
--
--     credit = Σ(quantity × unit_price_kobo)          -- the same gross this RPC computes
--              − orders.discount_kobo
--              − (orders.total_amount_kobo − orders.crate_deposit_paid_kobo)
--
-- so ANY future reduction the cart applies rides the envelope automatically and
-- cannot be forgotten at this seam again. That also makes the term a signed
-- reconciliation figure rather than a client-asserted total: the client never
-- sends the payable, so this function stays the authority on gross and on every
-- line's price — the credit can only move the payable by the amount the client's
-- own header already moved it.
--
-- ── WHY THIS IS A NO-OP TODAY (and must be deployed anyway) ────────────────
-- #202 deleted the cart block that computed the credit at all: the field it read
-- (`Customer.emptyCratesBalance`) was hardcoded `const {}` at every construction
-- site, so the figure is ₦0 and the derived term is exactly 0. The companion
-- client OMITS the key when it is 0, so today's envelope is byte-identical to
-- the pre-#209 one. On top of that `feature.domain_rpcs_v2.record_sale` is still
-- HELD OFF (gated on #121), so no envelope is produced at all. This is a
-- CONTRACT fix for a latent gap — the same reason 0091, 0160, 0164 and 0170 each
-- patched this function while its flag was off.
--
-- ── DEPLOY ORDER ──────────────────────────────────────────────────────────
-- Free in both directions, today.
--   * This migration AHEAD of the client: the new parameter has a DEFAULT, and
--     a client that never sends it gets identical behaviour.
--   * The client AHEAD of this migration: the key is omitted whenever the credit
--     is 0, which is always, so nothing sends an unknown parameter (PGRST202).
-- That second guarantee expires the moment a real crate credit is wired up: from
-- then on a credit sale against a cloud that predates 0173 would be rejected and
-- would jam the outbox. Deploy this BEFORE shipping any client that can produce
-- a non-zero credit — and note that such a client also cannot flip the v2 flag
-- until #121 clears, which is the same checklist.
--
-- ── THE OVERLOAD TRAP ─────────────────────────────────────────────────────
-- Adding a parameter to a function with `CREATE OR REPLACE` mints an OVERLOAD
-- rather than replacing it, and PostgREST then fails every call with PGRST203.
-- The 18-argument signature is therefore DROPPED first — the same dance 0164
-- and 0045 did — and re-GRANTed after the CREATE, because `DROP FUNCTION` takes
-- the grants with it.
--
-- MIGRATION-NUMBER LANE: 0173 is #209's. 0171/0172 belong to PRD #203's crate
-- deposit outflow slices and touch no RPC.

BEGIN;

-- DROP the 18-argument signature FIRST (see "the overload trap" above).
DROP FUNCTION IF EXISTS public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text,
  text, text, int, bool, uuid
);

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
  p_customer_verified       bool DEFAULT false,
  p_van_trip_id             uuid DEFAULT NULL,   -- #142: the trip tag
  -- #209 delta — the customer's empty-crate CREDIT, taken off the goods payable
  -- but NOT a discount (it is their own deposit money coming back). Derived
  -- client-side as "the part of the payable the header does not otherwise
  -- explain", so it is signed: a future cart term that RAISES the payable rides
  -- here as a negative. 0 (the default) reproduces the pre-#209 arithmetic
  -- exactly, and the client omits the key whenever it is 0 — which is always,
  -- until a real credit is wired up (#202 deleted the cart block that computed
  -- one). Deliberately not stored: `net_amount_kobo` is its whole effect.
  p_crate_credit_kobo       int  DEFAULT 0
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
  v_is_van_sale        bool := false;   -- #142
  v_deposit_held_kobo  bigint;                  -- #201 delta
  v_goods_grand_kobo   bigint;                  -- #201 delta
  v_goods_paid_kobo    bigint;                  -- #201 delta
  v_topup_kobo         bigint;                  -- #201 delta
  v_leg                record;                  -- #201 delta
  v_payment_rows       jsonb := '[]'::jsonb;    -- #201 delta
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

  -- #142 — is this a ROAD sale? (ADR 0019 decision 2, spec §5.3.)
  -- Two independent signals, either of which is enough:
  --   · the STORE is a van — the physical fact, and the same thing the Flutter
  --     client keys its own suppression on (`VanTripsDao.saleContextForStore`);
  --   · the order carries a TRIP TAG — bookkeeping, forwarded by the envelope.
  -- Suppression must fail SAFE, so a sale that has either signal is stripped: a
  -- road sale that somehow lost its tag must still not write cash the business
  -- does not hold.
  v_is_van_sale := p_van_trip_id IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.stores s
       WHERE s.id = p_store_id AND s.kind = 'van'
    );

  -- Server-computed totals.
  SELECT COALESCE(SUM((it->>'quantity')::int * (it->>'unit_price_kobo')::int), 0)
    INTO v_total_amount
    FROM jsonb_array_elements(p_items) AS it;

  -- #209 delta — the crate credit joins the discount as a reduction of the
  -- payable. `v_net_amount` is the quantity the client calls `totalAmountKobo`
  -- (goods + deposit held), and it is what the #201 tender split below divides,
  -- so forwarding the credit here is what makes BOTH the header and the split
  -- agree with the v1 path. COALESCE because the parameter is nullable on the
  -- wire even though it defaults to 0.
  v_net_amount := v_total_amount
                    - p_discount_kobo
                    - COALESCE(p_crate_credit_kobo, 0)
                    + p_crate_deposit_paid_kobo;

  -- Idempotent order insert.
  WITH ins AS (
    INSERT INTO public.orders (
      id, business_id, order_number, customer_id,
      total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
      payment_type, status, rider_name, barcode,
      staff_id, store_id, crate_deposit_paid_kobo,
      van_trip_id,                                                 -- #142
      completed_at, cancelled_at, created_at, last_updated_at
    )
    VALUES (
      p_order_id, p_business_id, p_order_number, p_customer_id,
      v_total_amount, p_discount_kobo, v_net_amount, p_amount_paid_kobo,
      p_payment_type, p_status, p_rider_name, p_barcode,
      p_actor_id, p_store_id, p_crate_deposit_paid_kobo,
      p_van_trip_id,                                               -- #142
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

    -- #201 delta — the singular key now resolves to the GOODS row (the sale may
    -- have written up to three), keeping the shipped client handler and the
    -- Tier-2 contract stable; the plural key carries the whole tender. The type
    -- ordering is the INSERT order of the fresh path below, so a replay answers
    -- with the same row the original call did — including for a deposit-only
    -- tender, which has no `sale` leg at all.
    --
    -- Both reads are `business_id`-scoped. This function is SECURITY DEFINER, so
    -- RLS is off inside it and the predicate is the only tenant boundary
    -- (architecture.md invariant #5); the pre-#201 lookup filtered on
    -- `order_id` alone, and the plural key would have widened that to every
    -- payment row on a foreign order.
    SELECT to_jsonb(pt.*) INTO v_payment_row
      FROM public.payment_transactions pt
      WHERE pt.order_id    = p_order_id
        AND pt.business_id = p_business_id
        AND pt.voided_at IS NULL
      ORDER BY CASE pt.type WHEN 'sale'          THEN 0
                            WHEN 'crate_deposit' THEN 1
                            WHEN 'wallet_topup'  THEN 2
                            ELSE 3 END,
               pt.created_at, pt.id
      LIMIT 1;

    SELECT COALESCE(jsonb_agg(to_jsonb(pt.*) ORDER BY pt.created_at, pt.id),
                    '[]'::jsonb)                                   -- #201 delta
      INTO v_payment_rows
      FROM public.payment_transactions pt
      WHERE pt.order_id    = p_order_id
        AND pt.business_id = p_business_id
        AND pt.voided_at IS NULL;

    -- #201 delta — `business_id` added for the same reason as the two reads
    -- above: DEFINER means the predicate is the only tenant boundary, and this
    -- read was already here filtering on `order_id` alone.
    SELECT to_jsonb(wt.*) INTO v_wallet_txn_row
      FROM public.wallet_transactions wt
      WHERE wt.order_id    = p_order_id
        AND wt.business_id = p_business_id
        AND wt.voided_at IS NULL
      ORDER BY wt.created_at LIMIT 1;

    RETURN jsonb_build_object(
      'order',                v_order_row,
      'order_items',          v_order_items,
      'stock_transactions',   v_stock_txns,
      'payment_transaction',  v_payment_row,
      'payment_transactions', v_payment_rows,                      -- #201 delta
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
      catalogue_price_kobo,                                        -- #183
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
      public._catalogue_price_snapshot(                             -- #183
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
  -- #142 — NOT on the road. A van sale writes no payment row on EITHER sync
  -- path: the Flutter client skips its own three-way tender split
  -- (`OrdersDao.createOrder`) and the server skips this one. The order still
  -- records `amount_paid_kobo` — the driver really was paid — but the money is in
  -- their custody, not the business's, so it must not reach the cash books until
  -- a manager records the remittance (#144, type 'van_remittance').
  --
  -- #201 delta — the tender is SPLIT BY MONEY TYPE and store-stamped, the SQL
  -- twin of the client's `_insertCheckoutPaymentRow` block (#175 + #169 US 36):
  --   sale          = goods actually paid  (paid − deposit, capped at goods payable)
  --   crate_deposit = the refundable deposit HELD (excluded from Cash sales)
  --   wallet_topup  = the OVERPAYMENT beyond goods + deposit (debts collected)
  -- `v_net_amount` is the payable INCLUDING the deposit — the same quantity the
  -- client calls `totalAmountKobo` — so the goods payable is `v_net_amount −
  -- depositHeld`. The legs always sum to `p_amount_paid_kobo`; a zero leg writes
  -- no row, so a goods-only sale still writes exactly one `sale` row. The
  -- checkout guards paid ≥ deposit, so `depositHeld ≤ paid`; clamp anyway.
  IF p_amount_paid_kobo > 0 AND NOT v_is_van_sale THEN
    v_deposit_held_kobo := LEAST(
      GREATEST(COALESCE(p_crate_deposit_paid_kobo, 0)::bigint, 0),
      p_amount_paid_kobo::bigint
    );
    v_goods_grand_kobo  := GREATEST(v_net_amount::bigint - v_deposit_held_kobo, 0);
    v_goods_paid_kobo   := LEAST(
      GREATEST(p_amount_paid_kobo::bigint - v_deposit_held_kobo, 0),
      v_goods_grand_kobo
    );
    v_topup_kobo        := p_amount_paid_kobo::bigint
                             - v_deposit_held_kobo - v_goods_paid_kobo;

    FOR v_leg IN
      SELECT * FROM (VALUES
        (v_goods_paid_kobo,   'sale'::text),
        (v_deposit_held_kobo, 'crate_deposit'::text),
        (v_topup_kobo,        'wallet_topup'::text)
      ) AS legs(amount_kobo, pay_type)
    LOOP
      CONTINUE WHEN v_leg.amount_kobo <= 0;

      v_payment_id := gen_random_uuid();
      INSERT INTO public.payment_transactions (
        id, business_id, store_id, amount_kobo, method, type,
        order_id, performed_by, created_at, last_updated_at
      )
      VALUES (
        v_payment_id, p_business_id, p_store_id, v_leg.amount_kobo,
        p_payment_method, v_leg.pay_type,
        p_order_id, p_actor_id, v_now, v_now
      );

      v_payment_rows := v_payment_rows || to_jsonb(
        (SELECT pt FROM public.payment_transactions pt WHERE pt.id = v_payment_id));

      -- The singular response key stays the GOODS row (the shipped client
      -- handler and the Tier-2 contract both read it).
      IF v_leg.pay_type = 'sale' THEN
        SELECT to_jsonb(pt.*) INTO v_payment_row
          FROM public.payment_transactions pt WHERE pt.id = v_payment_id;
      END IF;
    END LOOP;

    -- A tender with NO goods leg (a deposit-only order, whose overpayment then
    -- becomes a top-up) would leave the singular key NULL while the replay path
    -- above answers with its first row. Fall back to the same row the replay
    -- picks — the array is built in the loop's insert order, which is exactly
    -- that ordering — so one sale never has two answers.
    IF v_payment_row IS NULL AND jsonb_array_length(v_payment_rows) > 0 THEN
      v_payment_row := v_payment_rows->0;
    END IF;
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
    'payment_transactions', v_payment_rows,                        -- #201 delta
    'wallet_transaction',   v_wallet_txn_row,
    'inventory_after',      v_inv_after,
    'replayed',             false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text,
  text, text, int, bool, uuid, int
) TO authenticated, service_role;

COMMIT;
