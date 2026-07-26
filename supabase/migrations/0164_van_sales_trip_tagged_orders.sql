-- 0164_van_sales_trip_tagged_orders.sql
--
-- #142 / PRD #139 as amended by #161, ADR 0019 — Van Sales 3/8: the driver
-- terminal. Design record: docs/design/van-sales-spec.md §4.6, §5.3, §5.6.
--
-- The cloud half of Drift schema v73. This is the money-critical slice: it is
-- where road sales STOP writing cash the business does not hold.
--
-- Three passes:
--   1. orders.van_trip_id — the trip tag (§4.6).
--   2. pos_record_sale_v2 — a road sale mints NO payment row server-side, and
--      the RPC learns the tag (§5.3). This CHANGES THE SIGNATURE, so the old
--      one is DROPPED, not merely replaced (see the overload note below).
--   3. pos_recost_product_store — the replay SKIPS van stores (§5.6).
--
-- ── Why a road sale writes no payment row (ADR 0019 decision 2) ─────────────
--
-- Before this slice a van sale was an ordinary order, so it wrote a
-- `payment_transactions` row the moment the driver rang it. "Cash sales" rose
-- while the money sat in a pocket on a route, and the remittance days later
-- landed only in the driver ledger — which the Daily Reconciliation never reads.
-- Recorded cash was overstated forever by every unremitted naira.
--
-- Cash follows CUSTODY. The trip, not the payment ledger, carries road takings;
-- the manager-recorded remittance (#144, migration 0163) is the one moment van
-- money enters the cash books, store-stamped to the source warehouse on the day
-- it physically arrived. That leg shipped FIRST, deliberately — otherwise this
-- migration would open a window in which road cash entered the books nowhere at
-- all.
--
-- ── THE OVERLOAD TRAP — why this migration DROPs a function ─────────────────
--
-- `pos_record_sale_v2` gains `p_van_trip_id`. Unlike 0160 (which added an
-- OPTIONAL KEY inside the existing `p_items` jsonb — not a signature change),
-- this is a real new PARAMETER, so `CREATE OR REPLACE` alone would leave TWO
-- functions named `pos_record_sale_v2`: the old 17-argument one and the new
-- 18-argument one. Every existing 17-argument call then matches BOTH (the new
-- parameter has a DEFAULT), and PostgREST refuses to guess — PGRST203,
-- "Could not choose the best candidate function". Every sale on the v2 path
-- would fail. See [[project_rpc_param_add_overload_trap]].
--
-- So: DROP the exact old signature FIRST, then CREATE the new one. The DROP is
-- `IF EXISTS` and names the full argument list, so it cannot take out anything
-- else and the migration is re-runnable.
--
-- The v2 flag (`feature.domain_rpcs_v2.record_sale`) is currently OFF, so this
-- is patched ahead of the flag exactly as 0091 and 0160 did — a latent landmine
-- otherwise.
--
-- BEHAVIOR-IDENTICAL otherwise: the `pos_record_sale_v2` body below is copied
-- VERBATIM from 0160 (the current definition); the only deltas are marked
-- `-- #142 delta`. No money math, stock guard, wallet leg, idempotency,
-- order-numbering or catalogue-price behaviour changes for a NON-van sale.
--
-- ── The recost fence, and what it deliberately does NOT fix ────────────────
--
-- `pos_recost_product_store` (0133) replays a (product, store) FIFO queue and
-- writes authoritative per-line COGS back. Van cost truth is the LOT SNAPSHOT
-- (`van_trip_lots.unit_cost_kobo`), taken when the goods physically left the
-- warehouse — the batch queue must not be allowed a second opinion, so the
-- replay now returns early for a van store.
--
-- KNOWN, OUT OF SCOPE: issue #187 (P0) flags this same function for a DIFFERENT
-- defect — the replay reconstructs `qty_remaining` from sale lines only, so it
-- resurrects every NON-sale batch draw #170 introduced (damages, shortages,
-- transfer dispatches — and a van dispatch, which draws the SOURCE WAREHOUSE's
-- batches through the same primitive). This migration does not fix that and does
-- not make it worse: it only adds an early return for stores that have no cost
-- batches at all (ADR 0019: no batch is ever created on a van). The source
-- warehouse's van-drawn batches remain exposed to #187 until #187 lands.
--
-- ── Ordering ───────────────────────────────────────────────────────────────
-- DEPLOY ORDER: after 0163 (#144's remittance leg — the cash must have a home
-- before road sales stop writing payment rows) and before any v73 client pushes
-- an order carrying `van_trip_id`, or the upsert references an unknown column
-- and jams the outbox (the land-the-migration-first rule).
--
-- MIGRATION-NUMBER LANE: 0164 is #142's. 0161 (#140), 0162 (#141) and 0163
-- (#144) precede it; #143 owns 0165.
--
-- All *_kobo columns are untouched here and remain BIGINT (0130).
--
-- pos_pull_snapshot is deliberately NOT re-declared: `orders` is already in its
-- tenant-table array and the RPC ships whole rows, so a new COLUMN rides along.
-- Only a new TABLE needs the array edit.

BEGIN;

-- ═══ 1. orders.van_trip_id — the trip tag (spec §4.6) ═══════════════════════
--
-- Nullable + additive: every existing order stays NULL, which is exactly right
-- — they were rung in a shop.
--
-- The tag is ATTRIBUTION: #145's close artifact and #147's aggregated "Van
-- Sales" line read it. The EXCLUSION of van orders from per-store figures keys
-- on the store being a van, not on this column, because the store is the
-- physical fact and the tag is bookkeeping.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS van_trip_id uuid REFERENCES public.van_trips(id);

-- A trip's road sales: #145 sums them at close, #147 scans them by period.
-- Mirrors the client's idx_orders_van_trip.
CREATE INDEX IF NOT EXISTS idx_orders_van_trip
  ON public.orders (business_id, van_trip_id);


-- ═══ 2. pos_record_sale_v2 — trip-tagged, and no payment row on the road ════
--
-- DROP the 17-argument signature FIRST. Without this the CREATE below mints an
-- OVERLOAD and PostgREST returns PGRST203 on every v2 sale.
DROP FUNCTION IF EXISTS public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text,
  text, text, int, bool
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
  p_van_trip_id             uuid DEFAULT NULL    -- #142 delta: the trip tag
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
  v_is_van_sale        bool := false;   -- #142 delta
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

  -- #142 delta — is this a ROAD sale? (ADR 0019 decision 2, spec §5.3.)
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

  v_net_amount := v_total_amount - p_discount_kobo + p_crate_deposit_paid_kobo;

  -- Idempotent order insert.
  WITH ins AS (
    INSERT INTO public.orders (
      id, business_id, order_number, customer_id,
      total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
      payment_type, status, rider_name, barcode,
      staff_id, store_id, crate_deposit_paid_kobo,
      van_trip_id,                                                 -- #142 delta
      completed_at, cancelled_at, created_at, last_updated_at
    )
    VALUES (
      p_order_id, p_business_id, p_order_number, p_customer_id,
      v_total_amount, p_discount_kobo, v_net_amount, p_amount_paid_kobo,
      p_payment_type, p_status, p_rider_name, p_barcode,
      p_actor_id, p_store_id, p_crate_deposit_paid_kobo,
      p_van_trip_id,                                               -- #142 delta
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
  -- #142 delta — NOT on the road. A van sale writes no payment row on EITHER
  -- sync path: the Flutter client skips its own three-way tender split
  -- (`OrdersDao.createOrder`) and the server skips this one. The order still
  -- records `amount_paid_kobo` — the driver really was paid — but the money is
  -- in their custody, not the business's, so it must not reach the cash books
  -- until a manager records the remittance (#144, type 'van_remittance').
  IF p_amount_paid_kobo > 0 AND NOT v_is_van_sale THEN
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
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text,
  text, text, int, bool, uuid
) TO authenticated, service_role;


-- ═══ 3. pos_recost_product_store — skip van stores (spec §5.6, fence 2) ═════
--
-- Verbatim from 0133; the ONLY delta is the early return marked `#142 delta`.
-- Signature unchanged (uuid, uuid, uuid) → plain CREATE OR REPLACE, no overload,
-- no DROP. `pos_recost_pairs` calls it by name and is untouched.
--
-- WHY: van cost truth is the LOT SNAPSHOT taken at dispatch
-- (`van_trip_lots.unit_cost_kobo`), and ADR 0019 deliberately creates NO cost
-- batch on the van. So for a van store this replay reads an empty queue and
-- would write `buying_price_kobo = 0` back over every road line — which is what
-- they already are — while `pos_recost_pairs` counted them as "re-costed" and
-- bumped their `last_updated_at`, pushing pointless churn to every peer device.
-- More importantly it establishes the batch queue as *an authority* over van
-- lines, which is the seam a future change would extend into a real
-- double-count against close-time profit. Fence it now, with the reason
-- attached (ADR 0019: "anyone extending the backfill or the recost RPC must
-- preserve the van fence").
--
-- SCOPE NOTE (#187): this does NOT address the P0 defect in this same function
-- — the replay rebuilds `qty_remaining` from SALE LINES ONLY and so resurrects
-- non-sale batch draws (damages, shortages, transfer dispatches, and the van
-- dispatch draw on the SOURCE WAREHOUSE). That is #187's to fix and is
-- deliberately untouched here. The early return can only reduce what this
-- function writes, so it cannot make #187 worse.
CREATE OR REPLACE FUNCTION public.pos_recost_product_store(
  p_business_id uuid,
  p_product_id  uuid,
  p_store_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now        timestamptz := now();
  v_batches    jsonb;
  v_batch_ids  uuid[];
  v_sales      jsonb;
  v_assigned   jsonb;
  v_rem        jsonb;
  v_line       jsonb;
  v_recount    int := 0;
  v_recosted   jsonb := '[]'::jsonb;
  v_i          int;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- #142 delta — a VAN is fenced out of the batch/recost machinery entirely
  -- (ADR 0019 decision 1, spec §5.6 fence 2). Returns the same response shape
  -- with a zero count, plus a `skipped` marker so a caller (or an operator
  -- reading `pos_recost_pairs`' per-pair breakdown) can tell "nothing changed"
  -- from "deliberately not attempted".
  IF EXISTS (
    SELECT 1 FROM public.stores s
     WHERE s.id = p_store_id AND s.kind = 'van'
  ) THEN
    RETURN jsonb_build_object(
      'product_id',     p_product_id,
      'store_id',       p_store_id,
      'recosted_count', 0,
      'recosted_lines', '[]'::jsonb,
      'skipped',        'van_store'
    );
  END IF;

  -- FIFO queue: oldest-first by received_at, id a stable tiebreak. qty_original
  -- (not qty_remaining) is the replay input — we re-derive remainders here.
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object('cost_kobo', cb.cost_kobo, 'qty', cb.qty_original)
                       ORDER BY cb.received_at, cb.id), '[]'::jsonb),
    COALESCE(array_agg(cb.id ORDER BY cb.received_at, cb.id), ARRAY[]::uuid[])
  INTO v_batches, v_batch_ids
  FROM public.cost_batches cb
  WHERE cb.business_id = p_business_id
    AND cb.product_id  = p_product_id
    AND cb.store_id    = p_store_id;

  -- Sale ledger: recognized (non-reversed) sale lines for this (product, store),
  -- ordered by the SALE's own recorded timestamp (orders.created_at) — the same
  -- field period attribution uses; then order id, then line id, a stable,
  -- connectivity-independent order. status IN ('pending','completed') mirrors
  -- the client's orderRevenueStatuses; a cancelled/refunded order's line is a
  -- reversed sale and must not consume a batch. Quick Sale lines (product_id
  -- NULL) never reach here (filtered by product_id = p_product_id).
  --
  -- #142 delta — trip-tagged (road) lines are excluded as well. For a normal
  -- store this changes nothing (every order there has van_trip_id NULL); it is
  -- the belt to the store-kind braces above, for a road line that somehow
  -- carries a non-van store id.
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object('line_id', oi.id, 'quantity', oi.quantity)
                       ORDER BY o.created_at, o.id, oi.id), '[]'::jsonb)
  INTO v_sales
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.business_id = p_business_id
    AND oi.product_id  = p_product_id
    AND oi.store_id    = p_store_id
    AND o.status IN ('pending', 'completed')
    AND o.van_trip_id IS NULL;                                     -- #142 delta

  -- Pure re-derivation.
  v_assigned := public.fifo_assign(v_batches, v_sales);
  v_rem      := v_assigned->'batches_remaining';

  -- Write back per-line COGS — only where it changed (the derivation is
  -- authoritative and unconditional; the <> filter is an optimisation, not a
  -- semantic guard, so replay stays a pure function of the ledger).
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_assigned->'lines') LOOP
    UPDATE public.order_items
       SET buying_price_kobo = (v_line->>'cogs_per_unit_kobo')::bigint,
           last_updated_at   = v_now
     WHERE id = (v_line->>'line_id')::uuid
       AND buying_price_kobo IS DISTINCT FROM (v_line->>'cogs_per_unit_kobo')::bigint;
    IF FOUND THEN
      v_recount  := v_recount + 1;
      v_recosted := v_recosted || jsonb_build_object(
        'line_id',            v_line->>'line_id',
        'cogs_per_unit_kobo', (v_line->>'cogs_per_unit_kobo')::bigint,
        'uncosted_units',     (v_line->>'uncosted_units')::int
      );
    END IF;
  END LOOP;

  -- Write back derived batch qty_remaining — only where changed. (The
  -- cost_batches bump trigger from 0132 stamps last_updated_at.)
  FOR v_i IN 1 .. COALESCE(array_length(v_batch_ids, 1), 0) LOOP
    UPDATE public.cost_batches
       SET qty_remaining = (v_rem->>(v_i - 1))::int
     WHERE id = v_batch_ids[v_i]
       AND qty_remaining IS DISTINCT FROM (v_rem->>(v_i - 1))::int;
  END LOOP;

  RETURN jsonb_build_object(
    'product_id',     p_product_id,
    'store_id',       p_store_id,
    'recosted_count', v_recount,
    'recosted_lines', v_recosted
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_recost_product_store(uuid, uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_recost_product_store(uuid, uuid, uuid)
  TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user):
--
--   1. The column and its index exist:
--        SELECT column_name FROM information_schema.columns
--         WHERE table_schema = 'public' AND table_name = 'orders'
--           AND column_name = 'van_trip_id';                     -- expect 1 row
--        SELECT indexname FROM pg_indexes
--         WHERE schemaname = 'public' AND indexname = 'idx_orders_van_trip';
--
--   2. THE OVERLOAD IS GONE — this is the check that matters most. Exactly ONE
--      pos_record_sale_v2 must exist, with 18 arguments. Two rows here means
--      PGRST203 on every v2 sale:
--        SELECT proname, pronargs
--          FROM pg_proc
--         WHERE pronamespace = 'public'::regnamespace
--           AND proname = 'pos_record_sale_v2';              -- expect 1 row, 18
--
--   3. The recost fence answers for a van store without touching anything:
--        SELECT public.pos_recost_product_store(
--          '<business>', '<product>', '<a van store id>');
--        -- expect {"recosted_count": 0, ..., "skipped": "van_store"}
--
--   4. A road sale writes no payment row. After a v2 sale on a van store:
--        SELECT count(*) FROM public.payment_transactions
--         WHERE order_id = '<that order>';                        -- expect 0
--        SELECT van_trip_id FROM public.orders
--         WHERE id = '<that order>';                       -- expect the trip id
-- =============================================================================
