-- 0239_quarter_quantities.sql  (#627, slice S2 of PRD #620)
--
-- Quarter quantities (0.25 steps) become storable end to end. Shops sell half
-- crates every day; every quantity column was a whole number, so a 0.5 sale
-- could not be saved or synced. This migration:
--
--   A. adds two shared helpers (SQL twins of lib/shared/utils/quantity.dart):
--        public.qty_is_quarter(double precision)            -> boolean
--        public.line_total_kobo(bigint, double precision)   -> bigint
--   B. converts 22 quantity columns (20 tables) from integer/bigint to
--      `double precision` (data kept) and adds a CHECK per column that the
--      value is a multiple of 0.25 (the existing > 0 / >= 0 checks stay);
--   C. recreates every function that handled these quantities as int so a
--      fractional value is no longer truncated or rejected. Whole-number
--      behaviour is unchanged.
--
-- NOT converted (stay whole numbers while switched off, owner decision 11):
-- every van_* table and every online_order_* table.
--
-- Old-client safety (verified 2026-11-01 on the production PostgreSQL 17 with
-- to_json / row_to_json, the encoders PostgREST uses for its JSON bodies):
--   select 5::float8            -> 5      (not 5.0)
--   to_json(5::float8)          -> 5
--   to_json(0.25::float8)       -> 0.25
-- so whole values still reach older app versions as JSON integers and their
-- `as int` casts keep working. Only a fractional value (which no old client
-- can create) is a JSON decimal. The new app also pushes whole values as
-- integers (CloudValueSerializer), so it works against this schema AND the
-- pre-0239 one.
--
-- No view, index, policy, trigger or generated column depends on these
-- columns' integer type (checked via pg_depend / pg_indexes / pg_policies on
-- 2026-11-01), so no object needs recreating beyond the functions in part C.
--
-- Functions whose PARAMETER type changes are DROPped first (CREATE OR REPLACE
-- with a new parameter type would leave an overload next to the old one) and
-- re-GRANTed exactly as before.
--
-- LOCKING: each ALTER COLUMN TYPE rewrites its table under ACCESS EXCLUSIVE
-- (order_items, stock_transactions, inventory, crate_ledger are the big ones).
-- Deploy in a quiet window.
--
-- DEPLOY GATE: do NOT deploy until the supervisor decides the release order
-- (new app on Play -> minimum version raised -> cloud). Part C also rewrites
-- functions that originate in the reebaplus-web migrations (console_*,
-- pos_stock_transfer, pos_cancel_transfer, pos_receive_transfer, add_product,
-- receive_stock, console_revenue, console_platform_revenue,
-- console_orders_summary); their bodies are the production definitions of 2026-11-01
-- with only the quantity types changed.

BEGIN;

-- ===========================================================================
-- A. Shared helpers
-- ===========================================================================

-- True when v is finite and an exact multiple of 0.25 (negative multiples are
-- fine: deltas). NULL passes (a NOT NULL column handles NULL itself).
CREATE OR REPLACE FUNCTION public.qty_is_quarter(v double precision)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT v IS NULL
      OR (v > '-Infinity'::double precision      -- also excludes -Infinity
          AND v < 'Infinity'::double precision   -- excludes +Infinity and NaN
          AND v * 4 = trunc(v * 4));
$$;

-- Line total in whole kobo: unit price x quantity, rounded to the nearest kobo,
-- halves away from zero (half-up for sales). Quarter quantities are exact in
-- float8 and in numeric, so the only rounding is the final round().
-- Dart twin: lineTotalKobo() in lib/shared/utils/quantity.dart.
CREATE OR REPLACE FUNCTION public.line_total_kobo(p_unit_kobo bigint, p_qty double precision)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, public
AS $$
  SELECT round(p_unit_kobo::numeric * p_qty::numeric)::bigint;
$$;

REVOKE ALL ON FUNCTION public.qty_is_quarter(double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qty_is_quarter(double precision) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.line_total_kobo(bigint, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.line_total_kobo(bigint, double precision) TO authenticated, service_role;

-- ===========================================================================
-- B. Column types + quarter-step CHECKs
-- ===========================================================================
ALTER TABLE public.order_items
  ALTER COLUMN quantity TYPE double precision USING quantity::double precision;
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_quantity_quarter_step CHECK (public.qty_is_quarter(quantity));

ALTER TABLE public.inventory
  ALTER COLUMN quantity TYPE double precision USING quantity::double precision;
ALTER TABLE public.inventory
  ADD CONSTRAINT inventory_quantity_quarter_step CHECK (public.qty_is_quarter(quantity));

ALTER TABLE public.stock_transactions
  ALTER COLUMN quantity_delta TYPE double precision USING quantity_delta::double precision;
ALTER TABLE public.stock_transactions
  ADD CONSTRAINT stock_transactions_quantity_delta_quarter_step CHECK (public.qty_is_quarter(quantity_delta));

ALTER TABLE public.stock_adjustments
  ALTER COLUMN quantity_diff TYPE double precision USING quantity_diff::double precision;
ALTER TABLE public.stock_adjustments
  ADD CONSTRAINT stock_adjustments_quantity_diff_quarter_step CHECK (public.qty_is_quarter(quantity_diff));

ALTER TABLE public.stock_adjustment_requests
  ALTER COLUMN quantity_diff TYPE double precision USING quantity_diff::double precision;
ALTER TABLE public.stock_adjustment_requests
  ADD CONSTRAINT stock_adjustment_requests_quantity_diff_quarter_step CHECK (public.qty_is_quarter(quantity_diff));

ALTER TABLE public.stock_transfers
  ALTER COLUMN quantity TYPE double precision USING quantity::double precision;
ALTER TABLE public.stock_transfers
  ADD CONSTRAINT stock_transfers_quantity_quarter_step CHECK (public.qty_is_quarter(quantity));

ALTER TABLE public.stock_counts
  ALTER COLUMN shortage_units TYPE double precision USING shortage_units::double precision,
  ALTER COLUMN surplus_units TYPE double precision USING surplus_units::double precision;
ALTER TABLE public.stock_counts
  ADD CONSTRAINT stock_counts_shortage_units_quarter_step CHECK (public.qty_is_quarter(shortage_units));
ALTER TABLE public.stock_counts
  ADD CONSTRAINT stock_counts_surplus_units_quarter_step CHECK (public.qty_is_quarter(surplus_units));

ALTER TABLE public.cost_batches
  ALTER COLUMN qty_original TYPE double precision USING qty_original::double precision,
  ALTER COLUMN qty_remaining TYPE double precision USING qty_remaining::double precision;
ALTER TABLE public.cost_batches
  ADD CONSTRAINT cost_batches_qty_original_quarter_step CHECK (public.qty_is_quarter(qty_original));
ALTER TABLE public.cost_batches
  ADD CONSTRAINT cost_batches_qty_remaining_quarter_step CHECK (public.qty_is_quarter(qty_remaining));

ALTER TABLE public.crate_ledger
  ALTER COLUMN quantity_delta TYPE double precision USING quantity_delta::double precision;
ALTER TABLE public.crate_ledger
  ADD CONSTRAINT crate_ledger_quantity_delta_quarter_step CHECK (public.qty_is_quarter(quantity_delta));

ALTER TABLE public.customer_crate_balances
  ALTER COLUMN balance TYPE double precision USING balance::double precision;
ALTER TABLE public.customer_crate_balances
  ADD CONSTRAINT customer_crate_balances_balance_quarter_step CHECK (public.qty_is_quarter(balance));

ALTER TABLE public.manufacturer_crate_balances
  ALTER COLUMN balance TYPE double precision USING balance::double precision;
ALTER TABLE public.manufacturer_crate_balances
  ADD CONSTRAINT manufacturer_crate_balances_balance_quarter_step CHECK (public.qty_is_quarter(balance));

ALTER TABLE public.store_crate_balances
  ALTER COLUMN balance TYPE double precision USING balance::double precision;
ALTER TABLE public.store_crate_balances
  ADD CONSTRAINT store_crate_balances_balance_quarter_step CHECK (public.qty_is_quarter(balance));

ALTER TABLE public.supplier_crate_balances
  ALTER COLUMN balance TYPE double precision USING balance::double precision;
ALTER TABLE public.supplier_crate_balances
  ADD CONSTRAINT supplier_crate_balances_balance_quarter_step CHECK (public.qty_is_quarter(balance));

ALTER TABLE public.supplier_crate_ledger
  ALTER COLUMN quantity_delta TYPE double precision USING quantity_delta::double precision;
ALTER TABLE public.supplier_crate_ledger
  ADD CONSTRAINT supplier_crate_ledger_quantity_delta_quarter_step CHECK (public.qty_is_quarter(quantity_delta));

ALTER TABLE public.manufacturers
  ALTER COLUMN empty_crate_stock TYPE double precision USING empty_crate_stock::double precision;
ALTER TABLE public.manufacturers
  ADD CONSTRAINT manufacturers_empty_crate_stock_quarter_step CHECK (public.qty_is_quarter(empty_crate_stock));

ALTER TABLE public.crate_size_groups
  ALTER COLUMN empty_crate_stock TYPE double precision USING empty_crate_stock::double precision;
ALTER TABLE public.crate_size_groups
  ADD CONSTRAINT crate_size_groups_empty_crate_stock_quarter_step CHECK (public.qty_is_quarter(empty_crate_stock));

ALTER TABLE public.order_crate_lines
  ALTER COLUMN crates_taken TYPE double precision USING crates_taken::double precision;
ALTER TABLE public.order_crate_lines
  ADD CONSTRAINT order_crate_lines_crates_taken_quarter_step CHECK (public.qty_is_quarter(crates_taken));

ALTER TABLE public.pending_crate_returns
  ALTER COLUMN quantity TYPE double precision USING quantity::double precision;
ALTER TABLE public.pending_crate_returns
  ADD CONSTRAINT pending_crate_returns_quantity_quarter_step CHECK (public.qty_is_quarter(quantity));

ALTER TABLE public.purchase_items
  ALTER COLUMN quantity TYPE double precision USING quantity::double precision;
ALTER TABLE public.purchase_items
  ADD CONSTRAINT purchase_items_quantity_quarter_step CHECK (public.qty_is_quarter(quantity));

ALTER TABLE public.daily_closings
  ALTER COLUMN shortage_units TYPE double precision USING shortage_units::double precision;
ALTER TABLE public.daily_closings
  ADD CONSTRAINT daily_closings_shortage_units_quarter_step CHECK (public.qty_is_quarter(shortage_units));

-- ===========================================================================
-- C. Functions: quantity parameters / locals int -> double precision
-- ===========================================================================
-- Bodies are the LATEST definitions (verified byte-equal, whitespace aside,
-- against production on 2026-11-01), changed only where noted in-line:
--   * quantity params / locals / jsonb casts: int -> double precision
--   * line totals go through public.line_total_kobo (round half up)
--   * fifo_assign accumulates line cost in numeric and rounds once per line
--   * _storefront_cards / shopper_place_orders: floor() the stock figure they
--     hand to an integer (online ordering is switched off; whole numbers only)

-- Old signatures that must go before their double-precision replacements.
DROP FUNCTION IF EXISTS public._apply_stock_adjustment(uuid, uuid, uuid, integer, text, uuid, bigint);
DROP FUNCTION IF EXISTS public.request_stock_adjustment(uuid, uuid, uuid, uuid, integer, text, text, bigint);
DROP FUNCTION IF EXISTS public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, integer, text, uuid, uuid);
DROP FUNCTION IF EXISTS public.pos_transfer_crates(uuid, uuid, uuid, uuid, uuid, uuid, integer, uuid, uuid);


-- ===========================================================================
-- C1. Functions defined in this repo
-- ===========================================================================
-- ---- fifo_assign ----
CREATE OR REPLACE FUNCTION public.fifo_assign(
  p_batches jsonb,
  p_sales   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_n_batches   int;
  v_qty         double precision[] := ARRAY[]::double precision[];     -- remaining qty per batch (1-indexed)
  v_cost        bigint[] := ARRAY[]::bigint[];  -- cost_kobo per batch
  v_b           jsonb;
  v_s           jsonb;
  v_i           int;
  v_ptr         int := 1;        -- oldest batch with qty > 0 (persists across sales)
  v_need        double precision;
  v_qty_line    double precision;
  v_take        double precision;
  v_line_cost   numeric;          -- fractional kobo until the line is rounded once
  v_uncosted    double precision;
  v_lines       jsonb := '[]'::jsonb;
  v_rem_out     jsonb := '[]'::jsonb;
BEGIN
  IF p_batches IS NULL OR jsonb_typeof(p_batches) <> 'array' THEN
    RAISE EXCEPTION 'fifo_assign: p_batches must be a json array'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_sales IS NULL OR jsonb_typeof(p_sales) <> 'array' THEN
    RAISE EXCEPTION 'fifo_assign: p_sales must be a json array'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Load batches into working arrays.
  FOR v_b IN SELECT * FROM jsonb_array_elements(p_batches) LOOP
    v_qty  := array_append(v_qty,  COALESCE((v_b->>'qty')::double precision, 0));
    v_cost := array_append(v_cost, COALESCE((v_b->>'cost_kobo')::bigint, 0));
  END LOOP;
  v_n_batches := COALESCE(array_length(v_qty, 1), 0);

  -- Draw each sale down oldest-first. v_ptr is the global consumption cursor:
  -- it never rewinds, so a partially consumed batch continues serving the next
  -- line until it empties.
  FOR v_s IN SELECT * FROM jsonb_array_elements(p_sales) LOOP
    v_qty_line  := COALESCE((v_s->>'quantity')::double precision, 0);
    v_need      := v_qty_line;
    v_line_cost := 0;
    v_uncosted  := 0;

    WHILE v_need > 0 AND v_ptr <= v_n_batches LOOP
      IF v_qty[v_ptr] <= 0 THEN
        v_ptr := v_ptr + 1;
        CONTINUE;
      END IF;
      v_take          := LEAST(v_need, v_qty[v_ptr]);
      v_qty[v_ptr]    := v_qty[v_ptr] - v_take;
      IF v_cost[v_ptr] = 0 THEN
        v_uncosted := v_uncosted + v_take;         -- uncosted batch → excluded from COGS
      ELSE
        v_line_cost := v_line_cost + v_take::numeric * v_cost[v_ptr];
      END IF;
      v_need := v_need - v_take;
    END LOOP;

    -- Queue exhausted before the line was fully covered: the shortfall is
    -- uncosted (sold before enough cost batch existed).
    IF v_need > 0 THEN
      v_uncosted := v_uncosted + v_need;
      v_need := 0;
    END IF;

    v_lines := v_lines || jsonb_build_object(
      'line_id',            v_s->>'line_id',
      'quantity',           v_qty_line,
      'cogs_total_kobo',    round(v_line_cost)::bigint,
      'cogs_per_unit_kobo',
        COALESCE(round(round(v_line_cost) / NULLIF(v_qty_line, 0)::numeric)::bigint, 0),
      'uncosted_units',     v_uncosted
    );
  END LOOP;

  -- Remaining qty per batch, in input order.
  FOR v_i IN 1 .. v_n_batches LOOP
    v_rem_out := v_rem_out || to_jsonb(v_qty[v_i]);
  END LOOP;

  RETURN jsonb_build_object('lines', v_lines, 'batches_remaining', v_rem_out);
END;
$$;

-- ---- _apply_stock_adjustment ----
CREATE OR REPLACE FUNCTION public._apply_stock_adjustment(
  p_business_id     uuid,
  p_product_id      uuid,
  p_store_id        uuid,
  p_delta           double precision,
  p_reason          text,
  p_actor_id        uuid,
  -- #201 delta — what the goods cost per unit, as STATED on the request (#197 /
  -- US 22, `stock_adjustment_requests.unit_cost_kobo`, added by 0168). NULL is
  -- "not stated" and is the ONLY thing that triggers the #189 recorded-price
  -- fallback — a stated 0 stays a deliberate Uncosted layer, exactly as
  -- `adjustStock` keys it on `inflowUnitCostKobo == null`. Ignored on a
  -- DECREASE: a loss is valued by drawing this store's queue, not by assertion.
  p_unit_cost_kobo  bigint DEFAULT NULL
)
RETURNS double precision
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now     timestamptz := now();
  v_new_qty double precision;
  v_adj_id  uuid := gen_random_uuid();
  v_batches       jsonb;                         -- #201 delta
  v_batch_ids     uuid[];                        -- #201 delta
  v_assigned      jsonb;                         -- #201 delta
  v_rem           jsonb;                         -- #201 delta
  v_drawn_kobo    bigint;                        -- #201 delta
  v_unit_cost_kobo bigint;                       -- #201 delta
  v_value_kobo    bigint;                        -- #201 delta
  v_inflow_cost_kobo bigint;                     -- #201 delta
  v_i             int;                           -- #201 delta
BEGIN
  IF p_delta = 0 THEN
    SELECT quantity INTO v_new_qty FROM public.inventory
     WHERE business_id = p_business_id AND product_id = p_product_id AND store_id = p_store_id;
    RETURN COALESCE(v_new_qty, 0);
  END IF;

  IF p_delta > 0 THEN
    INSERT INTO public.inventory (
      id, business_id, product_id, store_id, quantity, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_product_id, p_store_id, p_delta, v_now, v_now
    )
    ON CONFLICT (business_id, product_id, store_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity,
                    last_updated_at = v_now
    RETURNING quantity INTO v_new_qty;
  ELSE
    UPDATE public.inventory
       SET quantity = quantity + p_delta, last_updated_at = v_now
     WHERE business_id = p_business_id AND product_id = p_product_id
       AND store_id = p_store_id AND quantity >= -p_delta
    RETURNING quantity INTO v_new_qty;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object('product_id', p_product_id,
                                        'store_id', p_store_id,
                                        'requested_delta', p_delta)::text;
    END IF;
  END IF;

  -- #201 delta — a DECREASE draws the FIFO queue down oldest-first and snapshots
  -- what it drew, the twin of `CostBatchesDao.drawDownOutflow` (#170 #7a). Runs
  -- only after the guarded decrement above succeeded (a rejected decrement
  -- raised), so a refused Remove never touches the cost queue. The draw-down
  -- itself is `public.fifo_assign` (0133) — the SAME pure function the
  -- authoritative recost replays through, and the twin of the client's
  -- `fifoDrawDown` — fed a single one-line "sale" of |delta| units. Uncosted
  -- (cost-0) batches and units the queue cannot cover contribute 0: that is
  -- "uncosted", NOT "free". No lock is taken on the queue, matching 0133 and the
  -- client; the UPDATE below is the serialization point.
  IF p_delta < 0 THEN
    SELECT
      COALESCE(jsonb_agg(jsonb_build_object('cost_kobo', cb.cost_kobo,
                                           'qty',       cb.qty_remaining)
                         ORDER BY cb.received_at, cb.id), '[]'::jsonb),
      COALESCE(array_agg(cb.id ORDER BY cb.received_at, cb.id), ARRAY[]::uuid[])
    INTO v_batches, v_batch_ids
    FROM public.cost_batches cb
    WHERE cb.business_id   = p_business_id
      AND cb.product_id    = p_product_id
      AND cb.store_id      = p_store_id
      AND cb.qty_remaining > 0;

    v_assigned := public.fifo_assign(
      v_batches,
      jsonb_build_array(jsonb_build_object('line_id',  'outflow',
                                           'quantity', -p_delta))
    );
    v_drawn_kobo := COALESCE(
      ((v_assigned->'lines')->0->>'cogs_total_kobo')::bigint, 0);
    v_rem := v_assigned->'batches_remaining';

    -- Write back the derived remainders (only where changed; the 0132 bump
    -- trigger stamps last_updated_at so peers pull the decrement). Byte-for-byte
    -- the loop 0133's own orchestrator runs, and it relies on the same
    -- invariant: `v_batches` and `v_batch_ids` are built by ONE aggregate over
    -- ONE row set in ONE order, and `fifo_assign` emits exactly one
    -- `batches_remaining` entry per input batch — so the 0-based jsonb index is
    -- always in range and the `::int` can never be NULL against the column's
    -- NOT NULL. A defensive COALESCE here would only hide a broken `fifo_assign`.
    FOR v_i IN 1 .. COALESCE(array_length(v_batch_ids, 1), 0) LOOP
      UPDATE public.cost_batches
         SET qty_remaining = (v_rem->>(v_i - 1))::double precision
       WHERE id = v_batch_ids[v_i]
         AND qty_remaining IS DISTINCT FROM (v_rem->>(v_i - 1))::double precision;
    END LOOP;

    v_value_kobo     := v_drawn_kobo;
    v_unit_cost_kobo := round(v_drawn_kobo::numeric / (-p_delta)::numeric)::bigint;
  END IF;

  INSERT INTO public.stock_adjustments (
    id, business_id, product_id, store_id, quantity_diff, reason, performed_by,
    unit_cost_kobo, value_kobo,                                    -- #201 delta
    created_at, last_updated_at
  )
  VALUES (
    v_adj_id, p_business_id, p_product_id, p_store_id, p_delta,
    COALESCE(p_reason, 'Adjustment'), p_actor_id,
    v_unit_cost_kobo, v_value_kobo,                                -- #201 delta
    v_now, v_now
  );
  INSERT INTO public.stock_transactions (
    id, business_id, product_id, location_id, quantity_delta, movement_type,
    adjustment_id, performed_by, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_product_id, p_store_id, p_delta, 'adjustment',
    v_adj_id, p_actor_id, v_now, v_now
  );

  -- #201 delta — an INCREASE pushes one fresh FIFO layer, the twin of
  -- `CostBatchesDao.recordInflowBatch` and the identical rule 0140 applies to
  -- add-product / receive-stock: one inflow ⇒ one fresh batch, NEVER merged
  -- ({qty_remaining = qty_original = delta, received_at}).
  --
  -- WHAT THE LAYER COSTS — the same three-step ladder the mobile approval walks
  -- (`StockAdjustmentRequestsDao.approveRequest` → `InventoryDao.adjustStock`):
  --   1. `p_unit_cost_kobo` — the cost the REQUEST captured (#197 / US 22, the
  --      0168 column). The person filing the request holds the invoice, so a
  --      stated cost always wins.
  --   2. the product's recorded scalar `buying_price_kobo` — what
  --      `InventoryDao._recordedUnitCostKobo` supplies when the caller states
  --      nothing (#189). Not a guess: it is the derived display cache over this
  --      very queue (ADR 0005).
  --   3. UNCOSTED (0) — only when neither is on file.
  -- The step-2 fallback is keyed on NULL, never on a handed-over 0, so a
  -- requester who deliberately states "no cost" keeps their Uncosted layer.
  -- Batching at 0 with a price on file would instead sell those units at 0 COGS
  -- forever: #41's backfill fires only on a `0 → positive` cost edit, which a
  -- product that already has a price can never make again, and
  -- `_recomputeScalarCost` ignores cost-0 batches, so nothing could ever reach
  -- the layer. A negative stated cost is clamped to 0 rather than trusted.
  IF p_delta > 0 THEN
    IF p_unit_cost_kobo IS NOT NULL THEN
      v_inflow_cost_kobo := GREATEST(p_unit_cost_kobo, 0);
    ELSE
      SELECT GREATEST(COALESCE(p.buying_price_kobo, 0), 0)
        INTO v_inflow_cost_kobo
        FROM public.products p
       WHERE p.id = p_product_id AND p.business_id = p_business_id;
    END IF;

    INSERT INTO public.cost_batches (
      id, business_id, product_id, store_id,
      qty_remaining, qty_original, cost_kobo, received_at, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_product_id, p_store_id,
      p_delta, p_delta, COALESCE(v_inflow_cost_kobo, 0), v_now, v_now, v_now
    );
  END IF;

  RETURN v_new_qty;
END;
$$;

-- ---- request_stock_adjustment ----
CREATE OR REPLACE FUNCTION public.request_stock_adjustment(
  p_business_id    uuid,
  p_request_id     uuid,        -- idempotency key (client UUID)
  p_store_id       uuid,
  p_product_id     uuid,
  p_quantity_diff  double precision,
  p_reason         text,
  p_summary        text DEFAULT NULL,
  -- #201 delta — what the goods cost per unit (#197 / US 22). Trailing and
  -- DEFAULT NULL, so a web caller that predates this keeps working and simply
  -- states nothing, which is the honest legacy answer.
  p_unit_cost_kobo bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now       timestamptz := now();
  v_actor_id  uuid;
  v_slug      text;
  v_existing  text;
  v_summary   text;
  v_new_qty   double precision;
  v_is_approver boolean;
  v_unit_cost_kobo bigint;                       -- #201 delta
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF NOT public.caller_has_permission(p_business_id, 'stock.adjust') THEN
    RAISE EXCEPTION 'permission_denied: stock.adjust'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL OR p_product_id IS NULL THEN
    RAISE EXCEPTION 'store_and_product_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF COALESCE(p_quantity_diff, 0) = 0 THEN
    RAISE EXCEPTION 'quantity_diff_must_be_nonzero' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotent replay.
  SELECT status INTO v_existing FROM public.stock_adjustment_requests WHERE id = p_request_id;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('request_id', p_request_id, 'status', v_existing,
                              'applied', v_existing = 'approved', 'replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;
  v_slug := public.caller_role_slug(p_business_id);
  v_is_approver := v_slug IN ('ceo', 'manager');
  v_summary := COALESCE(NULLIF(btrim(p_summary), ''),
                        CASE WHEN p_quantity_diff > 0 THEN 'Add ' ELSE 'Remove ' END
                          || abs(p_quantity_diff)::text || ' unit(s)');

  -- #201 delta — a stated cost is kept only on an INCREASE, mirroring the
  -- client's `Value(quantityDiff > 0 ? unitCostKobo : null)`. A decrease is
  -- valued by drawing this store's FIFO queue at apply time (#7a); the requester
  -- is not the authority on what a loss cost, so a cost sent with a Remove is
  -- dropped here rather than stored where a later reader would trust it.
  v_unit_cost_kobo := CASE WHEN p_quantity_diff > 0 THEN p_unit_cost_kobo END;

  IF v_is_approver THEN
    -- Manager/CEO: apply immediately + record an approved request for the audit.
    -- #201 delta — the stated cost is passed straight to the movement; there is
    -- no pending row to read it back from on this branch.
    v_new_qty := public._apply_stock_adjustment(
      p_business_id, p_product_id, p_store_id, p_quantity_diff, p_reason,
      v_actor_id, v_unit_cost_kobo);

    INSERT INTO public.stock_adjustment_requests (
      id, business_id, product_id, store_id, quantity_diff, reason, summary,
      unit_cost_kobo,                                              -- #201 delta
      requested_by, status, approved_by, approved_at, created_at, last_updated_at
    )
    VALUES (
      p_request_id, p_business_id, p_product_id, p_store_id, p_quantity_diff,
      COALESCE(p_reason, 'Adjustment'), v_summary,
      v_unit_cost_kobo,                                            -- #201 delta
      v_actor_id, 'approved', v_actor_id, v_now, v_now, v_now
    );

    INSERT INTO public.activity_logs (
      id, business_id, user_id, action, description, product_id, store_id,
      entity_type, entity_id, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_approved',
      'Applied stock change: ' || v_summary, p_product_id, p_store_id,
      'stock_adjustment_request', p_request_id, v_now, v_now
    );

    RETURN jsonb_build_object('request_id', p_request_id, 'status', 'approved',
                              'applied', true, 'inventory_after', v_new_qty,
                              'replayed', false);
  END IF;

  -- Stock keeper: a pending request; NO inventory change. #201 delta — the cost
  -- rides on the row and is read back by `approve_stock_adjustment`, which is
  -- what makes it reach the FIFO layer the approval mints.
  INSERT INTO public.stock_adjustment_requests (
    id, business_id, product_id, store_id, quantity_diff, reason, summary,
    unit_cost_kobo,                                                -- #201 delta
    requested_by, status, created_at, last_updated_at
  )
  VALUES (
    p_request_id, p_business_id, p_product_id, p_store_id, p_quantity_diff,
    COALESCE(p_reason, 'Adjustment'), v_summary,
    v_unit_cost_kobo,                                              -- #201 delta
    v_actor_id, 'pending', v_now, v_now
  );

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_requested',
    'Requested approval: ' || v_summary, p_product_id, p_store_id,
    'stock_adjustment_request', p_request_id, v_now, v_now
  );

  RETURN jsonb_build_object('request_id', p_request_id, 'status', 'pending',
                            'applied', false, 'replayed', false);
END;
$$;

-- ---- approve_stock_adjustment ----
CREATE OR REPLACE FUNCTION public.approve_stock_adjustment(
  p_business_id uuid,
  p_request_id  uuid,
  p_approve     boolean,
  p_reason      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now      timestamptz := now();
  v_actor_id uuid;
  v_slug     text;
  v_req      public.stock_adjustment_requests%ROWTYPE;
  v_new_qty  double precision;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  v_slug := public.caller_role_slug(p_business_id);
  IF v_slug NOT IN ('ceo', 'manager') THEN
    RAISE EXCEPTION 'permission_denied: approve_stock_adjustment'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_req FROM public.stock_adjustment_requests
   WHERE id = p_request_id AND business_id = p_business_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_req.status <> 'pending' THEN
    RETURN jsonb_build_object('request_id', p_request_id, 'status', v_req.status,
                              'replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  IF p_approve THEN
    -- #201 delta — the increase is batched at the cost the REQUEST captured
    -- (#197 / US 22), the twin of `approveRequest`'s
    -- `inflowUnitCostKobo: req.unitCostKobo`. NULL — a request that stated no
    -- cost, and every row written before 0168 — falls the helper back to the
    -- product's recorded price (#189). The row is already locked FOR UPDATE
    -- above, so this costs no extra read and cannot race an edit.
    v_new_qty := public._apply_stock_adjustment(
      p_business_id, v_req.product_id, v_req.store_id, v_req.quantity_diff,
      v_req.reason, v_req.requested_by, v_req.unit_cost_kobo);

    UPDATE public.stock_adjustment_requests
       SET status = 'approved', approved_by = v_actor_id, approved_at = v_now,
           last_updated_at = v_now
     WHERE id = p_request_id AND business_id = p_business_id;

    INSERT INTO public.activity_logs (
      id, business_id, user_id, action, description, product_id, store_id,
      entity_type, entity_id, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_approved',
      'Approved stock change: ' || v_req.summary, v_req.product_id, v_req.store_id,
      'stock_adjustment_request', p_request_id, v_now, v_now
    );

    RETURN jsonb_build_object('request_id', p_request_id, 'status', 'approved',
                              'inventory_after', v_new_qty, 'replayed', false);
  END IF;

  -- Reject: no inventory change.
  UPDATE public.stock_adjustment_requests
     SET status = 'rejected', approved_by = v_actor_id, approved_at = v_now,
         last_updated_at = v_now
   WHERE id = p_request_id AND business_id = p_business_id;

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_rejected',
    'Rejected stock change: ' || v_req.summary
      || COALESCE(' — ' || NULLIF(btrim(p_reason), ''), ''),
    v_req.product_id, v_req.store_id, 'stock_adjustment_request', p_request_id,
    v_now, v_now
  );

  RETURN jsonb_build_object('request_id', p_request_id, 'status', 'rejected',
                            'replayed', false);
END;
$$;

-- ---- _checkout_draw_fifo ----
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
         SET qty_remaining = (v_rem->>(v_i - 1))::double precision
       WHERE id = v_batch_ids[v_i]
         AND qty_remaining IS DISTINCT FROM (v_rem->>(v_i - 1))::double precision;
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

-- ---- _checkout_insert_lines ----
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
  v_qty        double precision;
  v_unit_price bigint;
  v_line_total bigint;
  v_new_qty    double precision;
  v_stx_id     uuid;
  v_inv_after  jsonb := '[]'::jsonb;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty        := (v_item->>'quantity')::double precision;
    v_unit_price := (v_item->>'unit_price_kobo')::bigint;

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'product_id_required_per_line'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'item_quantity_must_be_positive'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_line_total := public.line_total_kobo(v_unit_price, v_qty);
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

-- ---- checkout_order ----
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
  SELECT COALESCE(SUM(public.line_total_kobo((it->>'unit_price_kobo')::bigint, (it->>'quantity')::double precision)), 0)
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
        -- 0237 (#621): a limit of 0 / none = NO limit (unlimited credit); only
        -- a positive limit caps the debt.
        SELECT wallet_limit_kobo INTO v_limit
          FROM public.customers
         WHERE id = p_customer_id AND business_id = p_business_id;
        IF COALESCE(v_limit, 0) > 0 AND v_projected < -v_limit THEN
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
        SELECT p.manufacturer_id AS mfr_id, SUM(oi.quantity) AS crates
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

-- ---- pos_record_sale_v2 ----
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
  v_existing_qty       double precision;
  v_new_qty            double precision;
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
  SELECT COALESCE(SUM(public.line_total_kobo((it->>'unit_price_kobo')::bigint, (it->>'quantity')::double precision)), 0)
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
      -- #219 delta — `total_amount_kobo` IS THE PAYABLE, not the gross. It used
      -- to be `v_total_amount`, which is the only place the two sync paths
      -- disagreed about what the column means. v1 (`OrderCommands.checkout`)
      -- writes the payable into BOTH money columns; `receiptTotalsFromOrder`
      -- reads this one as the payable and reconstructs the pre-discount goods
      -- from it. The gross stays available to any reader as
      -- `total_amount_kobo − crate_deposit_paid_kobo + discount_kobo`, exactly
      -- as the receipt derives it. `v_total_amount` is still computed above —
      -- it is the input to `v_net_amount` and to every per-line `total_kobo`.
      v_net_amount, p_discount_kobo, v_net_amount, p_amount_paid_kobo,
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
    IF (v_item->>'quantity')::double precision <= 0 THEN
      RAISE EXCEPTION 'item_quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_item_id    := gen_random_uuid();
    v_total_kobo := public.line_total_kobo((v_item->>'unit_price_kobo')::bigint, (v_item->>'quantity')::double precision);

    INSERT INTO public.order_items (
      id, business_id, order_id, product_id, store_id,
      quantity, unit_price_kobo, buying_price_kobo, total_kobo, price_snapshot,
      catalogue_price_kobo,                                        -- #183
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id,
      (v_item->>'product_id')::uuid, p_store_id,
      (v_item->>'quantity')::double precision,
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

    IF v_existing_qty < (v_item->>'quantity')::double precision THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id',    v_item->>'product_id',
                'store_id',      p_store_id,
                'requested_qty', (v_item->>'quantity')::double precision,
                'available_qty', v_existing_qty
              )::text;
    END IF;

    UPDATE public.inventory
       SET quantity = quantity - (v_item->>'quantity')::double precision
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
      -(v_item->>'quantity')::double precision, 'sale',
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

-- ---- pos_cancel_order ----
CREATE OR REPLACE FUNCTION public.pos_cancel_order(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_order_id             uuid,
  p_cancellation_reason  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now            timestamptz := now();
  v_existing       record;
  v_oi             record;
  v_pt             record;
  v_wt             record;
  v_stx_id         uuid;
  v_refund_id      uuid;
  v_compensate_id  uuid;
  v_new_qty        double precision;
  v_order_row      jsonb;
  v_stock_txns     jsonb := '[]'::jsonb;
  v_inv_after      jsonb := '[]'::jsonb;
  v_refund_payments jsonb := '[]'::jsonb;
  v_wallet_compens  jsonb := '[]'::jsonb;
  v_to_credit       bool;                        -- #201 delta
  v_correction_note text;                        -- #201 delta
  v_batch_id        uuid;                        -- #201 delta
  v_cost_batches    jsonb := '[]'::jsonb;        -- #201 delta
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- Lock and read existing.
  SELECT * INTO v_existing FROM public.orders
   WHERE id = p_order_id AND business_id = p_business_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Replay: already cancelled, return existing state.
  IF v_existing.status = 'cancelled' THEN
    SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;
    RETURN jsonb_build_object(
      'order',                v_order_row,
      'stock_transactions',   '[]'::jsonb,
      'inventory_after',      '[]'::jsonb,
      'voided_payments',      '[]'::jsonb,
      'refund_payments',      '[]'::jsonb,
      'wallet_compensations', '[]'::jsonb,
      'cost_batches',         '[]'::jsonb,                         -- #201 delta
      'replayed',             true
    );
  END IF;

  IF v_existing.status NOT IN ('pending','completed') THEN
    RAISE EXCEPTION 'cannot_cancel_status_%', v_existing.status USING ERRCODE = 'P0001';
  END IF;

  -- #201 delta — the CORRECTION note stamped on every compensating row,
  -- mirroring the client's `reason: 'order_cancelled: $reason'`. Named for what
  -- it is, not for the column it lands in: the destination is `void_reason`, but
  -- nothing here is voided any more — that column is the table's only free-text
  -- audit field and the seam reuses it (`postReversalPayment`'s `reason`). A NULL
  -- reason propagates through the concat and falls back to the bare marker.
  v_correction_note := COALESCE('order_cancelled: ' || p_cancellation_reason,
                                'order_cancelled');

  -- Update order header.
  UPDATE public.orders
     SET status              = 'cancelled',
         cancelled_at        = v_now,
         cancellation_reason = p_cancellation_reason
   WHERE id = p_order_id;

  -- Restore inventory + stock_transactions(return) per item, and — #201 delta —
  -- restore the cost LAYER each line drew (see the header: since 0167 nothing
  -- else restores it).
  FOR v_oi IN
    SELECT id, product_id, store_id, quantity,
           buying_price_kobo                                       -- #201 delta
      FROM public.order_items
     WHERE order_id    = p_order_id
       AND business_id = p_business_id                             -- #201 delta
  LOOP
    -- #201 delta — a Quick Sale line (§26.4, nullable product_id since 0091)
    -- bypassed inventory, the stock ledger and the cost queue on the way OUT, so
    -- it must bypass all three on the way back. Without this guard the inventory
    -- INSERT below raised 23502 on its NOT NULL product_id and failed the whole
    -- cancel — the v1 client path never hit it because its loop reads
    -- `stock_transactions`, which a quick-sale line never gets.
    CONTINUE WHEN v_oi.product_id IS NULL;

    INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
    VALUES (gen_random_uuid(), p_business_id, v_oi.product_id, v_oi.store_id, v_oi.quantity, v_now, v_now)
    ON CONFLICT (business_id, product_id, store_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_new_qty;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      v_oi.product_id,
      'store_id',        v_oi.store_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );

    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, v_oi.product_id, v_oi.store_id,
      v_oi.quantity, 'return', p_order_id, p_actor_id, v_now, v_now
    );
    v_stock_txns := v_stock_txns || to_jsonb(
      (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_stx_id));

    -- #201 delta — the cost layer comes back with the goods, at the per-unit COGS
    -- the SALE snapshotted, so the FIFO queue and the shelf stay in step (#170
    -- #7c, the twin of `CostBatchesDao.recordInflowBatch` in the client's cancel).
    -- One restore ⇒ one fresh layer, never merged (ADR 0005). A line the queue
    -- could not cover snapshotted 0 and comes back Uncosted — the same units,
    -- the same (absent) cost, no invention. `received_at = v_now` puts the
    -- returned units at the BACK of the queue, exactly where the client puts
    -- them: they are physically the newest arrivals on the shelf.
    IF v_oi.quantity > 0 THEN
      v_batch_id := gen_random_uuid();
      INSERT INTO public.cost_batches (
        id, business_id, product_id, store_id,
        qty_remaining, qty_original, cost_kobo, received_at,
        created_at, last_updated_at
      )
      VALUES (
        v_batch_id, p_business_id, v_oi.product_id, v_oi.store_id,
        v_oi.quantity, v_oi.quantity,
        GREATEST(COALESCE(v_oi.buying_price_kobo, 0), 0), v_now,
        v_now, v_now
      );
      v_cost_batches := v_cost_batches || to_jsonb(
        (SELECT cb FROM public.cost_batches cb WHERE cb.id = v_batch_id));
    END IF;
  END LOOP;

  -- #201 delta — PAYMENTS: post DATED COMPENSATING rows; every ORIGINAL row is
  -- LEFT UNTOUCHED (the pre-#155 body voided them in place AND posted a
  -- full-amount `refund` for each — a double reversal that also shrank the
  -- already-reviewed sale day). The SQL twin of `OrdersDao.markCancelled` /
  -- `PaymentTransactionsDao.postReversalPayment`:
  --   `sale`          → a POSITIVE `refund` cash-out, same amount;
  --   `crate_deposit` → a NEGATIVE `crate_deposit` (the held line nets to zero;
  --                     NOT a `refund` — that would move Cash refunds for money
  --                     that was never in Cash sales);
  --   `wallet_topup`  → a NEGATIVE `wallet_topup` ("Debts collected" nets to 0).
  -- The reversal copies the original's METHOD and STORE (a cash tender yields a
  -- cash reversal; #169 keeps the figure on the right store) and its `order_id`
  -- parent — the only parent these rows can have, since the filter is on
  -- `order_id`, so the exactly-one-parent CHECK holds. Rows of any other type (a
  -- prior cancel's `refund`, a `van_remittance`) and non-positive rows are never
  -- re-reversed. `created_at = v_now` lands the movement on the CANCEL day (#172).
  FOR v_pt IN
    SELECT * FROM public.payment_transactions
     WHERE order_id    = p_order_id
       AND business_id = p_business_id
       AND voided_at IS NULL
       AND type IN ('sale', 'crate_deposit', 'wallet_topup')
       AND amount_kobo > 0
     ORDER BY created_at, id
  LOOP
    v_refund_id := gen_random_uuid();
    INSERT INTO public.payment_transactions (
      id, business_id, store_id, amount_kobo, method, type,
      order_id, performed_by, void_reason, created_at, last_updated_at
    )
    VALUES (
      v_refund_id, p_business_id, v_pt.store_id,
      CASE WHEN v_pt.type = 'sale' THEN v_pt.amount_kobo
           ELSE -v_pt.amount_kobo END,
      v_pt.method,
      CASE WHEN v_pt.type = 'sale' THEN 'refund' ELSE v_pt.type END,
      p_order_id, p_actor_id, v_correction_note, v_now, v_now
    );
    v_refund_payments := v_refund_payments || to_jsonb(
      (SELECT pt FROM public.payment_transactions pt WHERE pt.id = v_refund_id));
  END LOOP;

  -- #201 delta — WALLET: reverse the sale's legs with APPENDED opposite legs
  -- (invariant #3 — a ledger is never mutated), closing the "R2" hold recorded at
  -- the client's flag check. The pre-#155 body compensated only the DEBIT legs
  -- and voided them in place, so the payment credit leg survived a cancel and the
  -- customer's balance never returned to its pre-sale position.
  -- The SQL twin of `markCancelled`'s wallet block:
  --   goods debit (`order_payment`)      → a `refund` CREDIT;
  --   payment credit (`topup_*`)         → a `void` DEBIT;
  --   held deposit (`crate_deposit`)     → a `crate_deposit_refunded` DEBIT — the
  --     DEPOSIT-FAMILY release, not the generic `void`, which lands in the
  --     SPENDABLE bucket and would both dock spendable and leave "deposits held"
  --     inflated (#162).
  -- Legs that are themselves a reversal or a settlement are skipped, so a cancel
  -- never reverses a compensation. `voided_at IS NULL` is retained from the
  -- pre-#155 body as a belt: under the append-only discipline no new row is ever
  -- voided, and a legacy voided row was already reversed once.
  FOR v_wt IN
    SELECT * FROM public.wallet_transactions
     WHERE order_id    = p_order_id
       AND business_id = p_business_id
       AND voided_at IS NULL
       AND reference_type NOT IN ('refund', 'void', 'crate_deposit_refunded',
                                  'crate_deposit_forfeited', 'crate_refund')
       -- #432 delta — a Mark as paid collection (a wallet credit with its own
       -- 'wallet_topup' payment row) stays as the customer's credit. A sale's
       -- own legs never have one (their payment row's parent is the order).
       AND NOT EXISTS (
         SELECT 1 FROM public.payment_transactions pt
          WHERE pt.wallet_txn_id = wallet_transactions.id
            AND pt.type = 'wallet_topup')
     ORDER BY created_at, id
  LOOP
    v_to_credit := (v_wt.type = 'debit');
    v_compensate_id := gen_random_uuid();
    INSERT INTO public.wallet_transactions (
      id, business_id, wallet_id, customer_id, type,
      amount_kobo, signed_amount_kobo, reference_type, order_id,
      performed_by, customer_verified, created_at, last_updated_at
    )
    VALUES (
      v_compensate_id, p_business_id, v_wt.wallet_id, v_wt.customer_id,
      CASE WHEN v_to_credit THEN 'credit' ELSE 'debit' END,
      v_wt.amount_kobo,
      CASE WHEN v_to_credit THEN v_wt.amount_kobo ELSE -v_wt.amount_kobo END,
      CASE WHEN v_wt.reference_type = 'crate_deposit'
             THEN 'crate_deposit_refunded'
           WHEN v_to_credit THEN 'refund'
           ELSE 'void' END,
      p_order_id, p_actor_id, false, v_now, v_now
    );
    v_wallet_compens := v_wallet_compens || to_jsonb(
      (SELECT wt FROM public.wallet_transactions wt WHERE wt.id = v_compensate_id));
  END LOOP;

  SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;

  RETURN jsonb_build_object(
    'order',                v_order_row,
    'stock_transactions',   v_stock_txns,
    'inventory_after',      v_inv_after,
    -- #201 delta — nothing is voided in place any more, so this is always empty.
    -- The key is RETAINED so the envelope stays wire-compatible with the shipped
    -- `_applyDomainResponse` (which restores whatever array it finds).
    'voided_payments',      '[]'::jsonb,
    'refund_payments',      v_refund_payments,
    'wallet_compensations', v_wallet_compens,
    'cost_batches',         v_cost_batches,                        -- #201 delta
    'replayed',             false
  );
END;
$$;

-- ---- pos_recost_product_store ----
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
  v_sales      jsonb;
  v_assigned   jsonb;
  v_line       jsonb;
  v_recount    int := 0;
  v_recosted   jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- #142 delta (0164) — a VAN is fenced out of the batch/recost machinery
  -- entirely (ADR 0019 decision 1, spec §5.6 fence 2). Returns the same
  -- response shape with a zero count, plus a `skipped` marker so a caller (or
  -- an operator reading `pos_recost_pairs`' per-pair breakdown) can tell
  -- "nothing changed" from "deliberately not attempted".
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
  -- (not qty_remaining) is the COSTING input — this pass re-derives which layer
  -- paid for each sale line from the top of history, which is what makes it
  -- idempotent and self-correcting for a late earlier-timestamped sale.
  --
  -- #187 delta — the batch ids are no longer collected: nothing downstream
  -- writes `qty_remaining` any more, so the queue is read for COSTING ONLY.
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object('cost_kobo', cb.cost_kobo, 'qty', cb.qty_original)
                       ORDER BY cb.received_at, cb.id), '[]'::jsonb)
  INTO v_batches
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
  -- #142 delta (0164) — trip-tagged (road) lines are excluded as well. For a
  -- normal store this changes nothing (every order there has van_trip_id NULL);
  -- it is the belt to the store-kind braces above, for a road line that somehow
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
    AND (o.status IN ('pending', 'completed')
         -- 0228: a cancelled line keeps consuming its layers ONLY when its
         -- Cancel restore layer exists (fixed id, CostBatchesDao.
         -- cancelRestoreLayerId on the phone). Without that layer the units
         -- went back with no layer, so dropping the line (0167) stays correct
         -- and the replay can never run short.
         OR (o.status = 'cancelled'
             AND EXISTS (
               SELECT 1 FROM public.cost_batches rb
                WHERE rb.id = extensions.uuid_generate_v5(
                        extensions.uuid_ns_url(), 'cancel_restore:' || oi.id::text)
                  AND rb.business_id = p_business_id)))
    AND o.van_trip_id IS NULL;                                     -- #142 delta

  -- Pure re-derivation. `batches_remaining` in the result is IGNORED from here
  -- on (#187 delta) — see the header: it is a sales-only view of consumption and
  -- writing it back resurrected every #170 non-sale draw.
  v_assigned := public.fifo_assign(v_batches, v_sales);

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
        'uncosted_units',     (v_line->>'uncosted_units')::double precision
      );
    END IF;
  END LOOP;

  -- #187 delta — the `cost_batches.qty_remaining` write-back loop that stood
  -- here is DELETED. `qty_remaining` belongs to the incremental drawers (the
  -- client's #170 draws and 0139's `_checkout_draw_fifo`), which see every
  -- outflow class; this replay sees sales only and must not overrule them.

  RETURN jsonb_build_object(
    'product_id',     p_product_id,
    'store_id',       p_store_id,
    'recosted_count', v_recount,
    'recosted_lines', v_recosted
  );
END;
$$;

-- ---- pos_inventory_delta_v2 ----
CREATE OR REPLACE FUNCTION public.pos_inventory_delta_v2(
  p_business_id uuid,
  p_actor_id    uuid,
  p_movements   jsonb   -- [{movement_id, product_id, store_id, quantity_delta, movement_type, ref_type?, ref_id?, reason?}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now           timestamptz := now();
  v_mv            jsonb;
  v_mv_id         uuid;
  v_movement_type text;
  v_ref_type      text;
  v_ref_id        uuid;
  v_adjustment_id uuid;
  v_new_qty       double precision;
  v_stx_id        uuid;
  v_inv_after     jsonb := '[]'::jsonb;
  v_stock_txns    jsonb := '[]'::jsonb;
  v_adjustments   jsonb := '[]'::jsonb;
  v_already_done  bool;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF jsonb_typeof(p_movements) <> 'array' THEN
    RAISE EXCEPTION 'movements_must_be_array' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_mv IN SELECT * FROM jsonb_array_elements(p_movements) LOOP
    v_mv_id         := (v_mv->>'movement_id')::uuid;
    v_movement_type := v_mv->>'movement_type';
    v_ref_type      := v_mv->>'ref_type';
    v_ref_id        := NULLIF(v_mv->>'ref_id', '')::uuid;

    IF v_mv_id IS NULL THEN
      RAISE EXCEPTION 'movement_id_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_movement_type = 'sale' THEN
      RAISE EXCEPTION 'sale_must_use_pos_record_sale_v2' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_movement_type NOT IN ('return','damage','transfer_out','transfer_in','purchase_received','adjustment') THEN
      RAISE EXCEPTION 'invalid_movement_type: %', v_movement_type USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Replay detection on the ledger row's idempotency id.
    SELECT EXISTS(SELECT 1 FROM public.stock_transactions WHERE id = v_mv_id) INTO v_already_done;
    IF v_already_done THEN
      v_stock_txns := v_stock_txns || to_jsonb(
        (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_mv_id));
      CONTINUE;
    END IF;

    -- Apply inventory delta.
    IF (v_mv->>'quantity_delta')::double precision < 0 THEN
      UPDATE public.inventory
         SET quantity = quantity + (v_mv->>'quantity_delta')::double precision
       WHERE business_id = p_business_id
         AND product_id  = (v_mv->>'product_id')::uuid
         AND store_id    = (v_mv->>'store_id')::uuid
         AND quantity + (v_mv->>'quantity_delta')::double precision >= 0
      RETURNING quantity INTO v_new_qty;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient_stock'
          USING ERRCODE = 'P0001',
                HINT = jsonb_build_object(
                  'product_id',      v_mv->>'product_id',
                  'store_id',        v_mv->>'store_id',
                  'requested_delta', (v_mv->>'quantity_delta')::double precision
                )::text;
      END IF;
    ELSE
      INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
      VALUES (
        gen_random_uuid(), p_business_id,
        (v_mv->>'product_id')::uuid, (v_mv->>'store_id')::uuid,
        (v_mv->>'quantity_delta')::double precision, v_now, v_now
      )
      ON CONFLICT (business_id, product_id, store_id)
        DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
      RETURNING quantity INTO v_new_qty;
    END IF;

    -- For movement_type='adjustment' with no ref, mint a stock_adjustments
    -- row to satisfy the ledger's exactly-one-FK CHECK.
    IF v_movement_type = 'adjustment' AND v_ref_type IS NULL THEN
      v_adjustment_id := gen_random_uuid();
      INSERT INTO public.stock_adjustments (
        id, business_id, product_id, store_id, quantity_diff, reason,
        performed_by, created_at, last_updated_at
      )
      VALUES (
        v_adjustment_id, p_business_id,
        (v_mv->>'product_id')::uuid, (v_mv->>'store_id')::uuid,
        (v_mv->>'quantity_delta')::double precision,
        COALESCE(v_mv->>'reason', 'manual_adjustment'),
        p_actor_id, v_now, v_now
      );
      v_ref_type := 'adjustment';
      v_ref_id   := v_adjustment_id;
      v_adjustments := v_adjustments || to_jsonb(
        (SELECT sa FROM public.stock_adjustments sa WHERE sa.id = v_adjustment_id));
    END IF;

    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, transfer_id, adjustment_id, shipment_id,
      performed_by, created_at, last_updated_at
    )
    VALUES (
      v_mv_id, p_business_id,
      (v_mv->>'product_id')::uuid, (v_mv->>'store_id')::uuid,
      (v_mv->>'quantity_delta')::double precision, v_movement_type,
      CASE WHEN v_ref_type = 'order'      THEN v_ref_id END,
      CASE WHEN v_ref_type = 'transfer'   THEN v_ref_id END,
      CASE WHEN v_ref_type = 'adjustment' THEN v_ref_id END,
      CASE WHEN v_ref_type = 'purchase'   THEN v_ref_id END,
      p_actor_id, v_now, v_now
    );

    v_stock_txns := v_stock_txns || to_jsonb(
      (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_mv_id));
    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      (v_mv->>'product_id')::uuid,
      'store_id',        (v_mv->>'store_id')::uuid,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );
  END LOOP;

  RETURN jsonb_build_object(
    'stock_transactions', v_stock_txns,
    'stock_adjustments',  v_adjustments,
    'inventory_after',    v_inv_after
  );
END;
$$;

-- ---- pos_create_product_v2 ----
CREATE OR REPLACE FUNCTION public.pos_create_product_v2(
  p_business_id              uuid,
  p_actor_id                 uuid,
  p_product_id               uuid,
  p_name                     text,
  p_unit                     text     DEFAULT 'Bottle',
  p_subtitle                 text     DEFAULT NULL,
  p_sku                      text     DEFAULT NULL,
  p_size                     text     DEFAULT NULL,
  p_retailer_price_kobo      int      DEFAULT 0,
  p_wholesaler_price_kobo    int      DEFAULT 0,
  p_buying_price_kobo        int      DEFAULT 0,
  p_category_id              uuid     DEFAULT NULL,
  p_crate_size_group_id      uuid     DEFAULT NULL,
  p_manufacturer_id          uuid     DEFAULT NULL,
  p_supplier_id              uuid     DEFAULT NULL,
  p_low_stock_threshold      int      DEFAULT 5,
  p_track_empties            bool     DEFAULT false,
  p_image_path               text     DEFAULT NULL,
  p_initial_stock            jsonb    DEFAULT NULL,  -- {store_id, quantity}
  p_allow_fractional_sales   bool     DEFAULT false,
  p_expiry_date              timestamptz DEFAULT NULL
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
  v_qty           double precision;
  v_adjustment_id uuid;
  v_stx_id        uuid;
  v_new_qty       double precision;
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
      retailer_price_kobo, wholesaler_price_kobo, buying_price_kobo,
      is_available, is_deleted, low_stock_threshold,
      track_empties, allow_fractional_sales, image_path, expiry_date,
      created_at, last_updated_at
    )
    VALUES (
      p_product_id, p_business_id, p_category_id, p_crate_size_group_id, p_manufacturer_id, p_supplier_id,
      p_name, p_subtitle, p_sku, p_size, p_unit,
      p_retailer_price_kobo, p_wholesaler_price_kobo, p_buying_price_kobo,
      true, false, p_low_stock_threshold,
      p_track_empties, p_allow_fractional_sales, p_image_path, p_expiry_date,
      v_now, v_now
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;

  SELECT to_jsonb(p.*) INTO v_product_row FROM public.products p WHERE p.id = p_product_id;

  IF v_inserted AND p_initial_stock IS NOT NULL THEN
    v_qty      := COALESCE((p_initial_stock->>'quantity')::double precision, 0);
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

-- ---- pos_record_crate_return ----
CREATE OR REPLACE FUNCTION public.pos_record_crate_return(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_ledger_id            uuid,
  p_owner_kind           text,        -- 'customer' | 'manufacturer'
  p_owner_id             uuid,
  p_manufacturer_id      uuid,        -- whose crates (customer path); == owner for manufacturer path
  p_quantity_delta       double precision,
  p_movement_type        text,
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
  v_mfr           uuid := COALESCE(p_manufacturer_id,
                          CASE WHEN p_owner_kind = 'manufacturer' THEN p_owner_id END);
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_owner_kind NOT IN ('customer','manufacturer') THEN
    RAISE EXCEPTION 'invalid_owner_kind: %', p_owner_kind USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_movement_type NOT IN ('issued','returned','damaged','adjusted','transferred_in','transferred_out') THEN
    RAISE EXCEPTION 'invalid_movement_type: %', p_movement_type USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_mfr IS NULL THEN
    RAISE EXCEPTION 'manufacturer_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Replay detection on ledger id.
  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_ledger_id) INTO v_already;
  IF v_already THEN
    SELECT to_jsonb(cl.*) INTO v_ledger_row FROM public.crate_ledger cl WHERE cl.id = p_ledger_id;
    IF p_owner_kind = 'customer' THEN
      SELECT to_jsonb(b.*) INTO v_balance_jsonb FROM public.customer_crate_balances b
       WHERE b.business_id = p_business_id AND b.customer_id = p_owner_id AND b.manufacturer_id = v_mfr;
    ELSE
      SELECT to_jsonb(b.*) INTO v_balance_jsonb FROM public.manufacturer_crate_balances b
       WHERE b.business_id = p_business_id AND b.manufacturer_id = v_mfr;
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
    CASE WHEN p_owner_kind = 'customer' THEN p_owner_id END,
    v_mfr, NULL, p_quantity_delta, p_movement_type,
    p_reference_order_id, p_reference_return_id,
    p_actor_id, v_now, v_now
  );

  IF p_owner_kind = 'customer' THEN
    INSERT INTO public.customer_crate_balances (
      id, business_id, customer_id, manufacturer_id, balance, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_owner_id, v_mfr,
      p_quantity_delta, v_now, v_now
    )
    ON CONFLICT (business_id, customer_id, manufacturer_id)
      DO UPDATE SET balance = public.customer_crate_balances.balance + EXCLUDED.balance,
                    last_updated_at = v_now
    RETURNING * INTO v_balance_row;
  ELSE
    INSERT INTO public.manufacturer_crate_balances (
      id, business_id, manufacturer_id, balance, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_mfr,
      p_quantity_delta, v_now, v_now
    )
    ON CONFLICT (business_id, manufacturer_id)
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

-- ---- pos_approve_crate_return ----
CREATE OR REPLACE FUNCTION public.pos_approve_crate_return(
  p_business_id        uuid,
  p_actor_id           uuid,
  p_pending_return_id  uuid,
  p_ledger_id          uuid
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
  v_delta         double precision;
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
        AND ccb.manufacturer_id = v_pending.manufacturer_id;
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
    p_ledger_id, p_business_id, v_pending.customer_id, v_pending.manufacturer_id, NULL,
    v_delta, 'returned', NULL, p_pending_return_id,
    p_actor_id, v_now, v_now
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.customer_crate_balances (
    id, business_id, customer_id, manufacturer_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_pending.customer_id, v_pending.manufacturer_id,
    v_delta, v_now, v_now
  )
  ON CONFLICT (business_id, customer_id, manufacturer_id)
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

-- ---- pos_transfer_crates ----
CREATE OR REPLACE FUNCTION public.pos_transfer_crates(
  p_business_id    uuid,
  p_actor_id       uuid,
  p_transfer_id    uuid,       -- parent stock_transfers row (for reference)
  p_from_store_id  uuid,
  p_to_store_id    uuid,
  p_manufacturer_id uuid,
  p_quantity       double precision,        -- positive; crates leaving source, arriving dest
  p_out_ledger_id  uuid,       -- idempotency key for the transferred_out row
  p_in_ledger_id   uuid        -- idempotency key for the transferred_in  row
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now          timestamptz := now();
  v_already      bool;
  v_src_balance  double precision;
  v_out_row      jsonb;
  v_in_row       jsonb;
  v_src_scb      jsonb;
  v_dst_scb      jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_from_store_id = p_to_store_id THEN
    RAISE EXCEPTION 'same_store_transfer' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotency: if the out-leg already landed, return the existing rows.
  SELECT EXISTS(SELECT 1 FROM public.crate_ledger WHERE id = p_out_ledger_id)
    INTO v_already;
  IF v_already THEN
    SELECT to_jsonb(cl.*) INTO v_out_row FROM public.crate_ledger cl WHERE id = p_out_ledger_id;
    SELECT to_jsonb(cl.*) INTO v_in_row  FROM public.crate_ledger cl WHERE id = p_in_ledger_id;
    SELECT to_jsonb(b.*)  INTO v_src_scb FROM public.store_crate_balances b
      WHERE b.business_id = p_business_id AND b.store_id = p_from_store_id AND b.manufacturer_id = p_manufacturer_id;
    SELECT to_jsonb(b.*)  INTO v_dst_scb FROM public.store_crate_balances b
      WHERE b.business_id = p_business_id AND b.store_id = p_to_store_id   AND b.manufacturer_id = p_manufacturer_id;
    RETURN jsonb_build_object(
      'out_ledger_row',      v_out_row,
      'in_ledger_row',       v_in_row,
      'src_store_balance',   v_src_scb,
      'dst_store_balance',   v_dst_scb,
      'replayed',            true
    );
  END IF;

  -- Guard: source must have enough crates.
  SELECT COALESCE(balance, 0)
    INTO v_src_balance
    FROM public.store_crate_balances
   WHERE business_id = p_business_id
     AND store_id    = p_from_store_id
     AND manufacturer_id = p_manufacturer_id;
  IF COALESCE(v_src_balance, 0) < p_quantity THEN
    RAISE EXCEPTION 'insufficient_crates: have %, need %',
      COALESCE(v_src_balance, 0), p_quantity
      USING ERRCODE = 'insufficient_privilege';  -- maps to the InsufficientStockException in client
  END IF;

  -- Source ledger row: transferred_out (negative delta = crates leaving).
  INSERT INTO public.crate_ledger (
    id, business_id, store_id, manufacturer_id,
    quantity_delta, movement_type,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_out_ledger_id, p_business_id, p_from_store_id, p_manufacturer_id,
    -p_quantity, 'transferred_out',
    p_actor_id, v_now, v_now
  );

  -- Destination ledger row: transferred_in (positive delta = crates arriving).
  INSERT INTO public.crate_ledger (
    id, business_id, store_id, manufacturer_id,
    quantity_delta, movement_type,
    performed_by, created_at, last_updated_at
  )
  VALUES (
    p_in_ledger_id, p_business_id, p_to_store_id, p_manufacturer_id,
    p_quantity, 'transferred_in',
    p_actor_id, v_now, v_now
  );

  -- Decrement source store_crate_balances.
  INSERT INTO public.store_crate_balances (
    id, business_id, store_id, manufacturer_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_from_store_id, p_manufacturer_id,
    -p_quantity, v_now, v_now
  )
  ON CONFLICT (business_id, store_id, manufacturer_id)
    DO UPDATE SET balance         = public.store_crate_balances.balance - p_quantity,
                  last_updated_at = v_now;

  -- Increment destination store_crate_balances.
  INSERT INTO public.store_crate_balances (
    id, business_id, store_id, manufacturer_id, balance, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_to_store_id, p_manufacturer_id,
    p_quantity, v_now, v_now
  )
  ON CONFLICT (business_id, store_id, manufacturer_id)
    DO UPDATE SET balance         = public.store_crate_balances.balance + p_quantity,
                  last_updated_at = v_now;

  SELECT to_jsonb(cl.*) INTO v_out_row FROM public.crate_ledger cl WHERE id = p_out_ledger_id;
  SELECT to_jsonb(cl.*) INTO v_in_row  FROM public.crate_ledger cl WHERE id = p_in_ledger_id;
  SELECT to_jsonb(b.*)  INTO v_src_scb FROM public.store_crate_balances b
    WHERE b.business_id = p_business_id AND b.store_id = p_from_store_id AND b.manufacturer_id = p_manufacturer_id;
  SELECT to_jsonb(b.*)  INTO v_dst_scb FROM public.store_crate_balances b
    WHERE b.business_id = p_business_id AND b.store_id = p_to_store_id   AND b.manufacturer_id = p_manufacturer_id;

  RETURN jsonb_build_object(
    'out_ledger_row',    v_out_row,
    'in_ledger_row',     v_in_row,
    'src_store_balance', v_src_scb,
    'dst_store_balance', v_dst_scb,
    'replayed',          false
  );
END;
$$;

-- ---- _storefront_cards ----
CREATE OR REPLACE FUNCTION public._storefront_cards(
  p_mode     text,
  p_country  text,
  p_state    text,
  p_lga      text,
  p_store_id uuid,
  p_category text,
  p_query    text,
  p_after    text,
  p_limit    integer
)
RETURNS TABLE (
  product_id         uuid,
  store_id           uuid,
  name               text,
  image_url          text,
  unit               text,
  units_per_pack     integer,
  category           text,
  price_kobo         bigint,
  currency           text,
  crate_deposit_kobo bigint,
  stock_label        text,
  only_left          integer,
  age_restricted     boolean,
  stock_may_be_stale boolean,
  business_name      text,
  store_lga          text,
  online_description text,
  brand              text,
  min_order_qty      integer,
  order_step         integer,
  max_order_qty      integer,
  sponsored          boolean,
  cursor             text
)
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_category text := lower(nullif(btrim(p_category), ''));
  v_query    text := nullif(btrim(p_query), '');
  v_pattern  text;
  v_limit    integer := least(greatest(coalesce(p_limit, 24), 1), 50);
  c_stale    integer;
  c_area     integer;
  c_stock    integer;
  c_nophoto  integer;
  c_recency  bigint;
  c_id       uuid;
BEGIN
  IF p_mode IS NULL OR p_mode NOT IN ('feed', 'search', 'store') THEN
    RAISE EXCEPTION 'unknown storefront mode' USING ERRCODE = '22023';
  END IF;
  IF p_mode = 'search' AND v_query IS NULL THEN
    RAISE EXCEPTION 'search needs a product name' USING ERRCODE = '22023';
  END IF;
  IF p_mode = 'store' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'store page needs a store' USING ERRCODE = '22023';
  END IF;
  IF char_length(coalesce(v_query, '')) > 100 THEN
    RAISE EXCEPTION 'search is too long' USING ERRCODE = '22023';
  END IF;

  IF v_query IS NOT NULL THEN
    v_pattern := '%' || replace(replace(replace(
      public.storefront_search_key(v_query),
      '\', '\\'), '%', '\%'), '_', '\_') || '%';
  END IF;

  IF p_after IS NOT NULL THEN
    IF p_after !~ ('^[01]:[0-9]{1,2}:[0-3]:[01]:-?[0-9]{1,20}:'
        || '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'invalid cursor' USING ERRCODE = '22023';
    END IF;
    c_stale   := split_part(p_after, ':', 1)::integer;
    c_area    := split_part(p_after, ':', 2)::integer;
    c_stock   := split_part(p_after, ':', 3)::integer;
    c_nophoto := split_part(p_after, ':', 4)::integer;
    c_recency := split_part(p_after, ':', 5)::bigint;
    c_id      := split_part(p_after, ':', 6)::uuid;
  END IF;

  RETURN QUERY
  WITH placed AS (
    SELECT s.*,
           CASE WHEN p_mode = 'store' THEN 0 ELSE r.area_rank END AS area_rank,
           public._shopper_price_tier(s.business_id) AS shopper_tier
    FROM public._storefront_stores(
           CASE WHEN p_mode = 'store' THEN p_store_id END) s
    LEFT JOIN public._storefront_reach(p_country, p_state, p_lga) r
      ON r.store_id = s.store_id
    WHERE p_mode = 'store' OR r.area_rank IS NOT NULL
  ),
  lines AS (
    SELECT
      p.id                                     AS product_id,
      pl.store_id                              AS store_id,
      p.name                                   AS name,
      nullif(btrim(p.image_url), '')           AS image_url,
      p.unit                                   AS unit,
      p.units_per_pack                         AS units_per_pack,
      coalesce(mc.slug, 'other')               AS category,
      -- Online, an unset (0) wholesale price falls back to Retail so a
      -- Wholesaler can never order at 0 (supervisor decision, #429).
      CASE WHEN pl.shopper_tier = 'wholesaler'
                AND coalesce(p.wholesaler_price_kobo, 0) > 0
           THEN p.wholesaler_price_kobo
           ELSE coalesce(p.retailer_price_kobo, 0)
      END::bigint                              AS price_kobo,
      pl.currency                              AS currency,
      CASE
        WHEN pl.tracks_empty_crates AND p.track_empties
             AND lower(coalesce(p.unit, '')) = 'bottle'
        THEN nullif(coalesce(nullif(m.deposit_amount_kobo, 0),
                             p.empty_crate_value_kobo, 0), 0)::bigint
      END                                      AS crate_deposit_kobo,
      CASE
        WHEN coalesce(i.quantity, 0) <= 0 THEN 3
        WHEN i.quantity <= 3 THEN 2
        WHEN i.quantity <= p.low_stock_threshold THEN 1
        ELSE 0
      END                                      AS stock_rank,
      CASE WHEN i.quantity BETWEEN 1 AND 3 THEN floor(i.quantity)::integer END AS only_left,
      coalesce(mc.restricted = 'age_18'
               OR parent.restricted = 'age_18', false) AS age_restricted,
      pl.stale_rank                            AS stale_rank,
      pl.business_name                         AS business_name,
      pl.store_lga                             AS store_lga,
      nullif(btrim(p.online_description), '')  AS online_description,
      nullif(btrim(p.brand), '')               AS brand,
      p.min_order_qty                          AS min_order_qty,
      p.order_step                             AS order_step,
      p.max_order_qty                          AS max_order_qty,
      pl.area_rank                             AS area_rank,
      CASE WHEN nullif(btrim(p.image_url), '') IS NULL THEN 1 ELSE 0 END
                                               AS nophoto,
      -floor(extract(epoch FROM p.last_updated_at) * 1000000)::bigint
                                               AS recency
    FROM placed pl
    JOIN public.products p ON p.business_id = pl.business_id
    LEFT JOIN public.inventory i
      ON i.product_id = p.id AND i.store_id = pl.store_id
    LEFT JOIN public.categories c
      ON c.id = p.category_id AND c.business_id = p.business_id
     AND NOT c.is_deleted
    LEFT JOIN public.marketplace_categories mc ON mc.slug = c.marketplace_category
    LEFT JOIN public.marketplace_categories parent ON parent.slug = mc.parent_slug
    LEFT JOIN public.manufacturers m
      ON m.id = p.manufacturer_id AND NOT m.is_deleted
    WHERE p.show_online AND p.is_available AND NOT p.is_deleted
      AND NOT EXISTS (
        SELECT 1 FROM public.storefront_blocks sb
         WHERE sb.target_type = 'product' AND sb.target_id = p.id
      )
      AND mc.restricted IS DISTINCT FROM 'prescription'
      AND parent.restricted IS DISTINCT FROM 'prescription'
      AND (v_pattern IS NULL
           OR public.storefront_search_key(p.name) LIKE v_pattern)
      AND (v_category IS NULL
           OR coalesce(mc.slug, 'other') = v_category
           OR mc.parent_slug = v_category)
  ),
  visible AS (
    SELECT * FROM lines l WHERE p_mode <> 'feed' OR l.stock_rank < 3
  ),
  one_per_product AS (
    SELECT DISTINCT ON (v.product_id) v.*
    FROM visible v
    ORDER BY v.product_id, v.stale_rank, v.area_rank, v.stock_rank, v.store_id
  )
  SELECT
    o.product_id, o.store_id, o.name, o.image_url, o.unit, o.units_per_pack,
    o.category, o.price_kobo, o.currency, o.crate_deposit_kobo,
    CASE o.stock_rank
      WHEN 0 THEN 'in_stock'
      WHEN 1 THEN 'low_stock'
      WHEN 2 THEN 'only_few_left'
      ELSE 'out_of_stock'
    END,
    o.only_left,
    o.age_restricted,
    o.stale_rank = 1,
    o.business_name,
    o.store_lga,
    o.online_description,
    o.brand,
    o.min_order_qty,
    o.order_step,
    o.max_order_qty,
    false,
    concat_ws(':', o.stale_rank, o.area_rank, o.stock_rank, o.nophoto,
              o.recency, o.product_id)
  FROM one_per_product o
  WHERE p_after IS NULL
     OR (o.stale_rank, o.area_rank, o.stock_rank, o.nophoto, o.recency,
         o.product_id)
        > (c_stale, c_area, c_stock, c_nophoto, c_recency, c_id)
  ORDER BY o.stale_rank, o.area_rank, o.stock_rank, o.nophoto, o.recency,
           o.product_id
  LIMIT v_limit;
END;
$$;

-- ---- shopper_place_orders ----
CREATE OR REPLACE FUNCTION public.shopper_place_orders(
  p_orders  jsonb,
  p_phone   text,
  p_address jsonb,
  p_note    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := public._shopper_uid();
  v_name     text;
  v_phone    text := btrim(coalesce(p_phone, ''));
  v_country  text := coalesce(nullif(btrim(p_address->>'country'), ''), 'Nigeria');
  v_state    text := btrim(coalesce(p_address->>'state', ''));
  v_lga      text := btrim(coalesce(p_address->>'lga', ''));
  v_street   text := btrim(coalesce(p_address->>'street', ''));
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_results  jsonb := '[]'::jsonb;
  v_order    jsonb;
  v_line     jsonb;
  v_order_id uuid;
  v_store_id uuid;
  v_store    record;
  v_product  record;
  v_existing record;
  v_qty      integer;
  v_stock    integer;
  v_total    bigint;
  v_ref      text;
  v_code     text;
  v_bad_product uuid;
  v_seen     uuid[];
  v_tier     text;
BEGIN
  SELECT p.name INTO v_name FROM public.shopper_profiles p
   WHERE p.auth_user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopper_profile_required' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_orders) = 0 OR jsonb_array_length(p_orders) > 20 THEN
    RAISE EXCEPTION 'invalid_orders' USING ERRCODE = '22023';
  END IF;
  IF v_phone = '' OR char_length(v_phone) > 30 THEN
    RAISE EXCEPTION 'invalid_phone' USING ERRCODE = '22023';
  END IF;
  IF v_state = '' OR v_lga = '' OR v_street = '' OR char_length(v_street) > 200
     OR char_length(v_state) > 100 OR char_length(v_lga) > 100
     OR char_length(v_country) > 100 THEN
    RAISE EXCEPTION 'invalid_address' USING ERRCODE = '22023';
  END IF;
  IF char_length(coalesce(v_note, '')) > 500 THEN
    RAISE EXCEPTION 'note_too_long' USING ERRCODE = '22023';
  END IF;

  FOR v_order IN SELECT value FROM jsonb_array_elements(p_orders) LOOP
    v_order_id := NULL;
    v_store_id := NULL;
    v_code := NULL;
    v_bad_product := NULL;
    BEGIN
      v_order_id := (v_order->>'id')::uuid;
      v_store_id := (v_order->>'store_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_code := 'invalid';
    END;
    IF v_order_id IS NULL OR v_store_id IS NULL
       OR jsonb_typeof(v_order->'lines') IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_order->'lines') = 0
       OR jsonb_array_length(v_order->'lines') > 100 THEN
      v_code := 'invalid';
    END IF;

    -- Idempotent retry: the order already exists.
    IF v_code IS NULL THEN
      SELECT o.shopper_account_id, o.reference, o.status,
             o.estimated_total_kobo, o.currency, o.store_id
        INTO v_existing
        FROM public.online_orders o WHERE o.id = v_order_id;
      IF FOUND THEN
        IF v_existing.shopper_account_id IS DISTINCT FROM v_uid
           OR v_existing.store_id <> v_store_id THEN
          v_code := 'invalid';
        ELSE
          v_results := v_results || jsonb_build_array(jsonb_build_object(
            'id', v_order_id, 'store_id', v_store_id, 'ok', true,
            'reference', v_existing.reference, 'status', v_existing.status,
            'total_kobo', v_existing.estimated_total_kobo,
            'currency', v_existing.currency));
          CONTINUE;
        END IF;
      END IF;
    END IF;

    IF v_code IS NULL AND (
      SELECT count(*) FROM public.online_orders o
       WHERE o.shopper_account_id = v_uid
         AND o.placed_at > now() - interval '1 hour') >= 20 THEN
      v_code := 'rate_limited';
    END IF;

    IF v_code IS NULL THEN
      SELECT s.store_id, s.business_id, s.currency INTO v_store
        FROM public._storefront_stores(v_store_id) s;
      IF NOT FOUND THEN
        v_code := 'store_unavailable';
      ELSIF EXISTS (SELECT 1 FROM public.businesses b
                     WHERE b.id = v_store.business_id AND b.owner_id = v_uid) THEN
        v_code := 'own_business';
      ELSIF NOT EXISTS (
        SELECT 1 FROM public._storefront_reach(v_country, v_state, v_lga) r
         WHERE r.store_id = v_store_id) THEN
        v_code := 'out_of_area';
      END IF;
    END IF;

    -- #429: the caller's tier at this shop (Wholesaler only when linked to a
    -- live Wholesaler customer there and the shop sells more than one price).
    IF v_code IS NULL THEN
      v_tier := public._shopper_price_tier(v_store.business_id);
    END IF;

    IF v_code IS NULL THEN
      BEGIN
        v_ref := 'ON-' || upper(substr(md5(v_order_id::text), 1, 8));
        INSERT INTO public.online_orders (
          id, business_id, store_id, shopper_account_id, status, reference,
          currency, estimated_total_kobo, shopper_name, delivery_phone,
          delivery_country, delivery_state, delivery_lga, delivery_street, note)
        VALUES (
          v_order_id, v_store.business_id, v_store_id, v_uid, 'new', v_ref,
          v_store.currency, 0, v_name, v_phone,
          v_country, v_state, v_lga, v_street, v_note);

        v_total := 0;
        v_seen := ARRAY[]::uuid[];
        FOR v_line IN SELECT value FROM jsonb_array_elements(v_order->'lines') LOOP
          v_bad_product := NULL;
          BEGIN
            v_bad_product := (v_line->>'product_id')::uuid;
            v_qty := (v_line->>'quantity')::integer;
          EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            v_code := 'invalid';
          END;
          IF v_code IS NULL AND (v_bad_product IS NULL OR v_qty IS NULL
             OR v_bad_product = ANY (v_seen)) THEN
            v_code := 'invalid';
          END IF;
          IF v_code IS NULL THEN
            v_seen := v_seen || v_bad_product;
            SELECT p.id, p.name, p.unit, p.min_order_qty, p.order_step,
                   p.max_order_qty,
                   CASE WHEN v_tier = 'wholesaler'
                             AND coalesce(p.wholesaler_price_kobo, 0) > 0
                        THEN p.wholesaler_price_kobo
                        ELSE coalesce(p.retailer_price_kobo, 0)
                   END::bigint AS price,
                   CASE WHEN v_tier = 'wholesaler'
                             AND coalesce(p.wholesaler_price_kobo, 0) > 0
                        THEN 'wholesaler' ELSE 'retailer'
                   END AS tier
              INTO v_product
              FROM public.products p
              LEFT JOIN public.categories c
                ON c.id = p.category_id AND c.business_id = p.business_id
               AND NOT c.is_deleted
              LEFT JOIN public.marketplace_categories mc
                ON mc.slug = c.marketplace_category
              LEFT JOIN public.marketplace_categories parent
                ON parent.slug = mc.parent_slug
             WHERE p.id = v_bad_product
               AND p.business_id = v_store.business_id
               AND p.show_online AND p.is_available AND NOT p.is_deleted
               AND mc.restricted IS DISTINCT FROM 'prescription'
               AND parent.restricted IS DISTINCT FROM 'prescription';
            IF NOT FOUND THEN
              v_code := 'product_unavailable';
            ELSIF NOT public.order_quantity_allowed(
                v_qty, v_product.min_order_qty, v_product.order_step,
                v_product.max_order_qty) THEN
              v_code := 'quantity_rule';
            ELSE
              SELECT floor(coalesce(i.quantity, 0)) INTO v_stock
                FROM public.inventory i
               WHERE i.product_id = v_bad_product AND i.store_id = v_store_id;
              IF coalesce(v_stock, 0) < v_qty THEN
                v_code := 'not_enough_stock';
              END IF;
            END IF;
            IF v_code IS NULL
               AND public.shopper_age_confirmation_missing(v_uid, ARRAY[v_product.id]) THEN
              v_code := 'age_confirmation_required';
            END IF;
          END IF;
          EXIT WHEN v_code IS NOT NULL;

          INSERT INTO public.online_order_lines (
            business_id, online_order_id, product_id, product_name, unit,
            unit_price_kobo, price_tier, requested_qty)
          VALUES (
            v_store.business_id, v_order_id, v_product.id, v_product.name,
            v_product.unit, v_product.price, v_product.tier, v_qty);
          v_total := v_total + v_product.price * v_qty;
        END LOOP;

        IF v_code IS NOT NULL THEN
          -- Undo this store's order only (the sub-transaction).
          RAISE EXCEPTION USING ERRCODE = 'OO426', MESSAGE = 'store_failed';
        END IF;

        UPDATE public.online_orders SET estimated_total_kobo = v_total
         WHERE id = v_order_id;
        -- Runs as the owner: the guard's client-only "total may only go
        -- down" rule does not apply to this first write.
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'id', v_order_id, 'store_id', v_store_id, 'ok', true,
          'reference', v_ref, 'status', 'new', 'total_kobo', v_total,
          'currency', v_store.currency));
        CONTINUE;
      EXCEPTION
        WHEN SQLSTATE 'OO426' THEN
          NULL; -- v_code / v_bad_product already say why
        WHEN unique_violation THEN
          v_code := 'invalid';
          v_bad_product := NULL;
      END;
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'id', v_order_id, 'store_id', v_store_id, 'ok', false, 'code', v_code,
      'product_id', CASE WHEN v_code IN ('product_unavailable', 'quantity_rule',
                                         'not_enough_stock')
                         THEN v_bad_product END)));
  END LOOP;

  RETURN v_results;
END;
$$;

-- ===========================================================================
-- C. Functions that originate in the reebaplus-web migrations (shared
--    database). Definitions below are the production bodies as of 2026-11-01,
--    changed ONLY in the quantity types (int -> double precision) and, for the
--    money line of receive_stock, rounded via line_total_kobo.
-- ===========================================================================

-- ---- console_adjust_inventory: p_quantity_delta int -> double precision ----
DROP FUNCTION IF EXISTS public.console_adjust_inventory(uuid, uuid, uuid, uuid, integer, text);
CREATE OR REPLACE FUNCTION public.console_adjust_inventory(
  p_business_id uuid,
  p_product_id uuid,
  p_store_id uuid,
  p_movement_id uuid,
  p_quantity_delta double precision,
  p_reason text DEFAULT NULL::text
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_product_name text;
  v_prod_biz     uuid;
  v_before_qty   double precision;
  v_after_qty    double precision;
  v_reason       text := coalesce(nullif(btrim(p_reason), ''), 'manual_adjustment');
  v_before       jsonb;
  v_after        jsonb;
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;
  if p_movement_id is null then
    raise exception 'movement id required';
  end if;
  if coalesce(p_quantity_delta, 0) = 0 then
    raise exception 'adjustment quantity must be non-zero';
  end if;
  if p_store_id is null then
    raise exception 'a store is required';
  end if;

  -- Resolve the product (guards a wrong id and confirms it belongs to this business).
  select p.name, p.business_id into v_product_name, v_prod_biz
    from public.products p
   where p.id = p_product_id;
  if v_prod_biz is null then
    raise exception 'product not found';
  end if;
  if v_prod_biz <> p_business_id then
    raise exception 'product does not belong to this business';
  end if;

  -- Snapshot the current per-store quantity for the audit before/after (0 if none).
  select coalesce(i.quantity, 0) into v_before_qty
    from public.inventory i
   where i.business_id = p_business_id and i.product_id = p_product_id and i.store_id = p_store_id;
  v_before_qty := coalesce(v_before_qty, 0);

  -- Reuse the POS delta RPC: one 'adjustment' movement, NULL actor, no ref (it mints
  -- the stock_adjustments row). A negative delta taking stock below zero raises
  -- 'insufficient_stock' inside pos_inventory_delta_v2, which aborts this transaction.
  perform public.pos_inventory_delta_v2(
    p_business_id,
    null,
    jsonb_build_array(jsonb_build_object(
      'movement_id',    p_movement_id,
      'movement_type',  'adjustment',
      'product_id',     p_product_id,
      'store_id',       p_store_id,
      'quantity_delta', p_quantity_delta,
      'reason',         v_reason
    ))
  );

  select coalesce(i.quantity, 0) into v_after_qty
    from public.inventory i
   where i.business_id = p_business_id and i.product_id = p_product_id and i.store_id = p_store_id;

  v_before := jsonb_build_object('product_id', p_product_id, 'store_id', p_store_id, 'quantity', v_before_qty);
  v_after  := jsonb_build_object(
    'product_id', p_product_id, 'store_id', p_store_id,
    'quantity', coalesce(v_after_qty, v_before_qty + p_quantity_delta),
    'quantity_delta', p_quantity_delta, 'reason', v_reason
  );

  perform public._console_log_activity(
    p_business_id,
    'inventory.adjust',
    'Adjusted stock of "' || v_product_name || '" by '
      || case when p_quantity_delta > 0 then '+' else '' end || p_quantity_delta
      || ' via Reebaplus Console',
    'product', p_product_id, v_before, v_after
  );

  insert into public.console_audit (admin_id, business_id, entity_type, entity_id, action, before, after)
  values (auth.uid(), p_business_id, 'product', p_product_id, 'inventory.adjust', v_before, v_after);
end;
$function$;

-- ---- console_create_product: p_opening_quantity int -> double precision ----
DROP FUNCTION IF EXISTS public.console_create_product(uuid, uuid, text, text, text, text, text, bigint, bigint, bigint, uuid, uuid, uuid, integer, timestamp with time zone, uuid, integer);
CREATE OR REPLACE FUNCTION public.console_create_product(
  p_business_id uuid,
  p_product_id uuid,
  p_name text,
  p_unit text DEFAULT 'Bottle'::text,
  p_subtitle text DEFAULT NULL::text,
  p_sku text DEFAULT NULL::text,
  p_size text DEFAULT NULL::text,
  p_retailer_price_kobo bigint DEFAULT 0,
  p_wholesaler_price_kobo bigint DEFAULT 0,
  p_buying_price_kobo bigint DEFAULT 0,
  p_category_id uuid DEFAULT NULL::uuid,
  p_manufacturer_id uuid DEFAULT NULL::uuid,
  p_supplier_id uuid DEFAULT NULL::uuid,
  p_low_stock_threshold integer DEFAULT 5,
  p_expiry_date timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_opening_store_id uuid DEFAULT NULL::uuid,
  p_opening_quantity double precision DEFAULT 0
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_opening_qty   double precision := greatest(coalesce(p_opening_quantity, 0), 0);
  v_initial_stock jsonb := null;
  v_after         jsonb;
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'product name must not be empty';
  end if;
  -- Opening stock is optional; a quantity needs a store to land in.
  if v_opening_qty > 0 and p_opening_store_id is null then
    raise exception 'opening stock needs a store';
  end if;
  if v_opening_qty > 0 then
    v_initial_stock := jsonb_build_object('store_id', p_opening_store_id, 'quantity', v_opening_qty);
  end if;

  -- Reuse the POS create RPC (widened gate accepts console admins). NULL actor +
  -- (optional) initial-stock jsonb → the RPC writes the products row and, when
  -- opening stock is present, the stock_adjustments / inventory / stock_transactions
  -- legs (reason 'initial_stock'). pos_create_product_v2's price params are integer,
  -- so a console price is int-bounded here.
  perform public.pos_create_product_v2(
    p_business_id           => p_business_id,
    p_actor_id              => null,
    p_product_id            => p_product_id,
    p_name                  => btrim(p_name),
    p_unit                  => coalesce(p_unit, 'Bottle'),
    p_subtitle              => p_subtitle,
    p_sku                   => p_sku,
    p_size                  => p_size,
    p_retailer_price_kobo   => p_retailer_price_kobo::int,
    p_wholesaler_price_kobo => p_wholesaler_price_kobo::int,
    p_buying_price_kobo     => p_buying_price_kobo::int,
    p_category_id           => p_category_id,
    p_manufacturer_id       => p_manufacturer_id,
    p_supplier_id           => p_supplier_id,
    p_low_stock_threshold   => coalesce(p_low_stock_threshold, 5),
    p_initial_stock         => v_initial_stock,
    p_expiry_date           => p_expiry_date
  );

  v_after := jsonb_build_object(
    'name', btrim(p_name), 'unit', coalesce(p_unit, 'Bottle'), 'subtitle', p_subtitle,
    'sku', p_sku, 'size', p_size,
    'retailer_price_kobo', p_retailer_price_kobo, 'wholesaler_price_kobo', p_wholesaler_price_kobo,
    'buying_price_kobo', p_buying_price_kobo,
    'category_id', p_category_id, 'manufacturer_id', p_manufacturer_id, 'supplier_id', p_supplier_id,
    'low_stock_threshold', coalesce(p_low_stock_threshold, 5), 'expiry_date', p_expiry_date,
    'opening_store_id', case when v_opening_qty > 0 then p_opening_store_id end,
    'opening_quantity', v_opening_qty
  );

  perform public._console_log_activity(
    p_business_id,
    'product.create',
    'Added product "' || btrim(p_name) || '"'
      || case when v_opening_qty > 0 then ' with ' || v_opening_qty || ' opening stock' else '' end
      || ' via Reebaplus Console',
    'product', p_product_id, null, v_after
  );

  insert into public.console_audit (admin_id, business_id, entity_type, entity_id, action, before, after)
  values (auth.uid(), p_business_id, 'product', p_product_id, 'product.create', null, v_after);

  return p_product_id;
end;
$function$;

-- ---- pos_stock_transfer: p_quantity int -> double precision ----
DROP FUNCTION IF EXISTS public.pos_stock_transfer(uuid, uuid, uuid, uuid, uuid, uuid, uuid, integer);
CREATE OR REPLACE FUNCTION public.pos_stock_transfer(
  p_business_id uuid,
  p_actor_id uuid,
  p_transfer_id uuid,
  p_movement_id uuid,
  p_from_store_id uuid,
  p_to_store_id uuid,
  p_product_id uuid,
  p_quantity double precision
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_now      timestamptz := now();
  v_new_qty  double precision;
  v_existing public.stock_transfers%ROWTYPE;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'invalid_quantity' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_from_store_id = p_to_store_id THEN
    RAISE EXCEPTION 'same_store_transfer' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Replay: the transfer id already exists → return canonical state, no-op.
  SELECT * INTO v_existing FROM public.stock_transfers WHERE id = p_transfer_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'stock_transfers',    jsonb_build_array(to_jsonb(v_existing)),
      'stock_transactions', '[]'::jsonb,
      'inventory_after',    '[]'::jsonb
    );
  END IF;

  -- Deduct from the source with a stock guard.
  UPDATE public.inventory
     SET quantity = quantity - p_quantity
   WHERE business_id = p_business_id
     AND product_id  = p_product_id
     AND store_id    = p_from_store_id
     AND quantity - p_quantity >= 0
  RETURNING quantity INTO v_new_qty;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'insufficient_stock'
      USING ERRCODE = 'P0001',
            HINT = jsonb_build_object(
              'product_id',      p_product_id,
              'store_id',        p_from_store_id,
              'requested_delta', -p_quantity
            )::text;
  END IF;

  INSERT INTO public.stock_transfers (
    id, business_id, from_location_id, to_location_id, product_id, quantity,
    status, initiated_by, initiated_at, created_at, last_updated_at
  ) VALUES (
    p_transfer_id, p_business_id, p_from_store_id, p_to_store_id, p_product_id,
    p_quantity, 'in_transit', p_actor_id, v_now, v_now, v_now
  );

  INSERT INTO public.stock_transactions (
    id, business_id, product_id, location_id, quantity_delta, movement_type,
    transfer_id, performed_by, created_at, last_updated_at
  ) VALUES (
    p_movement_id, p_business_id, p_product_id, p_from_store_id, -p_quantity,
    'transfer_out', p_transfer_id, p_actor_id, v_now, v_now
  );

  RETURN jsonb_build_object(
    'stock_transfers', jsonb_build_array(
      (SELECT to_jsonb(st) FROM public.stock_transfers st WHERE st.id = p_transfer_id)),
    'stock_transactions', jsonb_build_array(
      (SELECT to_jsonb(stx) FROM public.stock_transactions stx WHERE stx.id = p_movement_id)),
    'inventory_after', jsonb_build_array(jsonb_build_object(
      'product_id',      p_product_id,
      'store_id',        p_from_store_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now))
  );
END;
$function$;

-- ---- pos_cancel_transfer: v_new_qty int -> double precision ----
CREATE OR REPLACE FUNCTION public.pos_cancel_transfer(
  p_business_id uuid,
  p_actor_id uuid,
  p_transfer_id uuid,
  p_movement_id uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_now     timestamptz := now();
  v_t       public.stock_transfers%ROWTYPE;
  v_new_qty double precision;
  v_already bool;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  SELECT * INTO v_t FROM public.stock_transfers
   WHERE id = p_transfer_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.stock_transactions WHERE id = p_movement_id)
    INTO v_already;
  IF v_t.status = 'cancelled' OR v_already THEN
    RETURN jsonb_build_object(
      'stock_transfers',    jsonb_build_array(to_jsonb(v_t)),
      'stock_transactions', '[]'::jsonb,
      'inventory_after',    '[]'::jsonb);
  END IF;

  IF v_t.status <> 'in_transit' THEN
    RAISE EXCEPTION 'invalid_transfer_state'
      USING ERRCODE = 'P0001', HINT = v_t.status;
  END IF;

  INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
  VALUES (gen_random_uuid(), p_business_id, v_t.product_id, v_t.from_location_id, v_t.quantity, v_now, v_now)
  ON CONFLICT (business_id, product_id, store_id)
    DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
  RETURNING quantity INTO v_new_qty;

  UPDATE public.stock_transfers
     SET status = 'cancelled', last_updated_at = v_now
   WHERE id = p_transfer_id;

  INSERT INTO public.stock_transactions (
    id, business_id, product_id, location_id, quantity_delta, movement_type,
    transfer_id, performed_by, created_at, last_updated_at
  ) VALUES (
    p_movement_id, p_business_id, v_t.product_id, v_t.from_location_id, v_t.quantity,
    'transfer_in', p_transfer_id, p_actor_id, v_now, v_now
  );

  RETURN jsonb_build_object(
    'stock_transfers', jsonb_build_array(
      (SELECT to_jsonb(st) FROM public.stock_transfers st WHERE st.id = p_transfer_id)),
    'stock_transactions', jsonb_build_array(
      (SELECT to_jsonb(stx) FROM public.stock_transactions stx WHERE stx.id = p_movement_id)),
    'inventory_after', jsonb_build_array(jsonb_build_object(
      'product_id',      v_t.product_id,
      'store_id',        v_t.from_location_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now))
  );
END;
$function$;

-- ---- pos_receive_transfer: v_new_qty int -> double precision ----
CREATE OR REPLACE FUNCTION public.pos_receive_transfer(
  p_business_id uuid,
  p_actor_id uuid,
  p_transfer_id uuid,
  p_movement_id uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_now     timestamptz := now();
  v_t       public.stock_transfers%ROWTYPE;
  v_new_qty double precision;
  v_already bool;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  SELECT * INTO v_t FROM public.stock_transfers
   WHERE id = p_transfer_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.stock_transactions WHERE id = p_movement_id)
    INTO v_already;
  IF v_t.status = 'received' OR v_already THEN
    RETURN jsonb_build_object(
      'stock_transfers',    jsonb_build_array(to_jsonb(v_t)),
      'stock_transactions', '[]'::jsonb,
      'inventory_after',    '[]'::jsonb);
  END IF;

  IF v_t.status <> 'in_transit' THEN
    RAISE EXCEPTION 'invalid_transfer_state'
      USING ERRCODE = 'P0001', HINT = v_t.status;
  END IF;

  INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
  VALUES (gen_random_uuid(), p_business_id, v_t.product_id, v_t.to_location_id, v_t.quantity, v_now, v_now)
  ON CONFLICT (business_id, product_id, store_id)
    DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
  RETURNING quantity INTO v_new_qty;

  UPDATE public.stock_transfers
     SET status = 'received', received_by = p_actor_id,
         received_at = v_now, last_updated_at = v_now
   WHERE id = p_transfer_id;

  INSERT INTO public.stock_transactions (
    id, business_id, product_id, location_id, quantity_delta, movement_type,
    transfer_id, performed_by, created_at, last_updated_at
  ) VALUES (
    p_movement_id, p_business_id, v_t.product_id, v_t.to_location_id, v_t.quantity,
    'transfer_in', p_transfer_id, p_actor_id, v_now, v_now
  );

  RETURN jsonb_build_object(
    'stock_transfers', jsonb_build_array(
      (SELECT to_jsonb(st) FROM public.stock_transfers st WHERE st.id = p_transfer_id)),
    'stock_transactions', jsonb_build_array(
      (SELECT to_jsonb(stx) FROM public.stock_transactions stx WHERE stx.id = p_movement_id)),
    'inventory_after', jsonb_build_array(jsonb_build_object(
      'product_id',      v_t.product_id,
      'store_id',        v_t.to_location_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now))
  );
END;
$function$;

-- ---- add_product: p_opening_stock int -> double precision ----
DROP FUNCTION IF EXISTS public.add_product(uuid, uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, integer, boolean, uuid, integer);
CREATE OR REPLACE FUNCTION public.add_product(
  p_business_id uuid,
  p_product_id uuid,
  p_store_id uuid,
  p_name text,
  p_category_id uuid DEFAULT NULL::uuid,
  p_unit text DEFAULT 'Piece'::text,
  p_size text DEFAULT NULL::text,
  p_retailer_price_kobo bigint DEFAULT 0,
  p_wholesaler_price_kobo bigint DEFAULT 0,
  p_buying_price_kobo bigint DEFAULT 0,
  p_opening_stock double precision DEFAULT 0,
  p_track_empties boolean DEFAULT false,
  p_manufacturer_id uuid DEFAULT NULL::uuid,
  p_low_stock_threshold integer DEFAULT 5
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_now        timestamptz := now();
  v_actor_id   uuid;
  v_existing   boolean;
  v_product    jsonb;
  v_inv_id     uuid;
  v_batch_id   uuid;
  v_cost       bigint := GREATEST(COALESCE(p_buying_price_kobo, 0), 0);
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF NOT public.caller_has_permission(p_business_id, 'products.add') THEN
    RAISE EXCEPTION 'permission_denied: products.add'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'store_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF COALESCE(p_opening_stock, 0) < 0 THEN
    RAISE EXCEPTION 'opening_stock_must_be_non_negative'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT true INTO v_existing
    FROM public.products WHERE id = p_product_id AND business_id = p_business_id;
  IF v_existing THEN
    SELECT to_jsonb(p.*) INTO v_product
      FROM public.products p WHERE p.id = p_product_id AND p.business_id = p_business_id;
    RETURN jsonb_build_object('product', v_product, 'replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  INSERT INTO public.products (
    id, business_id, category_id, manufacturer_id, name, unit, size,
    retailer_price_kobo, wholesaler_price_kobo, buying_price_kobo,
    track_empties, low_stock_threshold, is_available, is_deleted,
    created_at, last_updated_at
  )
  VALUES (
    p_product_id, p_business_id, p_category_id, p_manufacturer_id, btrim(p_name),
    COALESCE(p_unit, 'Piece'), p_size,
    COALESCE(p_retailer_price_kobo, 0), COALESCE(p_wholesaler_price_kobo, 0), v_cost,
    COALESCE(p_track_empties, false), COALESCE(p_low_stock_threshold, 5), true, false,
    v_now, v_now
  );

  IF COALESCE(p_opening_stock, 0) > 0 THEN
    v_inv_id := gen_random_uuid();
    INSERT INTO public.inventory (
      id, business_id, product_id, store_id, quantity, created_at, last_updated_at
    )
    VALUES (
      v_inv_id, p_business_id, p_product_id, p_store_id, p_opening_stock, v_now, v_now
    );

    v_batch_id := gen_random_uuid();
    INSERT INTO public.cost_batches (
      id, business_id, product_id, store_id,
      qty_remaining, qty_original, cost_kobo, received_at, created_at, last_updated_at
    )
    VALUES (
      v_batch_id, p_business_id, p_product_id, p_store_id,
      p_opening_stock, p_opening_stock, v_cost, v_now, v_now, v_now
    );
  END IF;

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'product.created',
    'Added product ' || btrim(p_name)
      || CASE WHEN COALESCE(p_opening_stock, 0) > 0
              THEN ' with opening stock ' || p_opening_stock::text ELSE '' END,
    p_product_id, p_store_id, 'product', p_product_id, v_now, v_now
  );

  SELECT to_jsonb(p.*) INTO v_product FROM public.products p WHERE p.id = p_product_id;
  RETURN jsonb_build_object(
    'product',    v_product,
    'batch_id',   v_batch_id,
    'replayed',   false
  );
END;
$function$;

-- ---- receive_stock: v_qty / v_units / v_new_qty int -> double precision;
--      the invoice total uses line_total_kobo (round half up) ----
CREATE OR REPLACE FUNCTION public.receive_stock(
  p_business_id uuid,
  p_receipt_id uuid,
  p_supplier_id uuid,
  p_store_id uuid,
  p_lines jsonb,
  p_received_at timestamp with time zone DEFAULT now(),
  p_amount_paid_kobo bigint DEFAULT 0,
  p_payment_method text DEFAULT 'cash'::text,
  p_note text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_now         timestamptz := now();
  v_received_at timestamptz := COALESCE(p_received_at, v_now);
  v_actor_id    uuid;
  v_existing    boolean;
  v_invoice_tot bigint;
  v_units       double precision;
  v_line        jsonb;
  v_product_id  uuid;
  v_qty         double precision;
  v_buy         bigint;
  v_retail      bigint;
  v_wholesale   bigint;
  v_adj_id      uuid;
  v_inv_id      uuid;
  v_batch_id    uuid;
  v_new_qty     double precision;
  v_pay         bigint := GREATEST(COALESCE(p_amount_paid_kobo, 0), 0);
  v_method      text   := COALESCE(p_payment_method, 'cash');
  v_inv_after   jsonb  := '[]'::jsonb;
  v_batch_ids   jsonb  := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF NOT (public.caller_has_permission(p_business_id, 'stock.received')
       OR public.caller_has_permission(p_business_id, 'stock.add')
       OR public.caller_has_permission(p_business_id, 'products.add')) THEN
    RAISE EXCEPTION 'permission_denied: stock.received'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_receipt_id IS NULL THEN
    RAISE EXCEPTION 'receipt_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'supplier_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'store_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'lines_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_method NOT IN ('cash', 'transfer', 'pos', 'other') THEN
    RAISE EXCEPTION 'payment_method_invalid' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT true INTO v_existing FROM public.activity_logs WHERE id = p_receipt_id;
  IF v_existing THEN
    RETURN jsonb_build_object('replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  SELECT
    COALESCE(SUM(public.line_total_kobo(GREATEST((l->>'buying_price_kobo')::bigint, 0),
                                        (l->>'quantity')::double precision)), 0),
    COALESCE(SUM((l->>'quantity')::double precision), 0)
  INTO v_invoice_tot, v_units
  FROM jsonb_array_elements(p_lines) AS l;

  IF v_invoice_tot > 0 THEN
    INSERT INTO public.supplier_ledger_entries (
      id, business_id, supplier_id, store_id, type, amount_kobo, signed_amount_kobo,
      reference_type, activity_date, reference_note, performed_by, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_supplier_id, p_store_id, 'debit',
      v_invoice_tot, -v_invoice_tot, 'invoice', v_received_at, p_note, v_actor_id, v_now, v_now
    );
  END IF;

  IF v_pay > 0 THEN
    INSERT INTO public.supplier_ledger_entries (
      id, business_id, supplier_id, store_id, type, amount_kobo, signed_amount_kobo,
      reference_type, payment_method, activity_date, reference_note, performed_by,
      created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_supplier_id, p_store_id, 'credit',
      v_pay, v_pay, 'payment_' || v_method, v_method, v_received_at,
      COALESCE(p_note, 'Payment for received stock'), v_actor_id, v_now, v_now
    );
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_product_id := (v_line->>'product_id')::uuid;
    v_qty        := (v_line->>'quantity')::double precision;
    v_buy        := GREATEST(COALESCE((v_line->>'buying_price_kobo')::bigint, 0), 0);
    v_retail     := NULLIF(v_line->>'retailer_price_kobo', '')::bigint;
    v_wholesale  := NULLIF(v_line->>'wholesaler_price_kobo', '')::bigint;

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'product_id_required_per_line' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'line_quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO public.inventory (
      id, business_id, product_id, store_id, quantity, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_product_id, p_store_id, v_qty, v_now, v_now
    )
    ON CONFLICT (business_id, product_id, store_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity,
                    last_updated_at = v_now
    RETURNING quantity INTO v_new_qty;

    UPDATE public.products
       SET buying_price_kobo     = CASE WHEN v_buy > 0 THEN v_buy ELSE buying_price_kobo END,
           retailer_price_kobo   = COALESCE(v_retail, retailer_price_kobo),
           wholesaler_price_kobo = COALESCE(v_wholesale, wholesaler_price_kobo),
           last_updated_at       = v_now
     WHERE id = v_product_id AND business_id = p_business_id;

    v_adj_id := gen_random_uuid();
    INSERT INTO public.stock_adjustments (
      id, business_id, product_id, store_id, quantity_diff, reason, performed_by,
      created_at, last_updated_at
    )
    VALUES (
      v_adj_id, p_business_id, v_product_id, p_store_id, v_qty, 'Stock received',
      v_actor_id, v_now, v_now
    );
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      adjustment_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_product_id, p_store_id, v_qty, 'adjustment',
      v_adj_id, v_actor_id, v_now, v_now
    );

    v_batch_id := gen_random_uuid();
    INSERT INTO public.cost_batches (
      id, business_id, product_id, store_id,
      qty_remaining, qty_original, cost_kobo, received_at, created_at, last_updated_at
    )
    VALUES (
      v_batch_id, p_business_id, v_product_id, p_store_id,
      v_qty, v_qty, v_buy, v_received_at, v_now, v_now
    );

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id', v_product_id, 'store_id', p_store_id, 'quantity', v_new_qty);
    v_batch_ids := v_batch_ids || to_jsonb(v_batch_id);
  END LOOP;

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    p_receipt_id, p_business_id, v_actor_id, 'stock.received',
    'Received ' || jsonb_array_length(p_lines)::text || ' product(s), '
      || v_units::text || ' unit(s)',
    p_store_id, 'supplier', p_supplier_id, v_now, v_now
  );

  RETURN jsonb_build_object(
    'receipt_id',       p_receipt_id,
    'invoice_total_kobo', v_invoice_tot,
    'amount_paid_kobo', v_pay,
    'units',            v_units,
    'inventory_after',  v_inv_after,
    'batch_ids',        v_batch_ids,
    'replayed',         false
  );
END;
$function$;


-- ---- console revenue RPCs: line totals via line_total_kobo ----------------
-- `oi.quantity * oi.unit_price_kobo` is now double precision; summing raw
-- products and casting once would round differently from the app. Each line is
-- rounded to whole kobo (half up) exactly like Dart `lineTotalKobo`, then summed.

CREATE OR REPLACE FUNCTION public.console_revenue(p_business_id uuid, p_store_id uuid DEFAULT NULL::uuid, p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text;
  v_res jsonb;
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;

  select coalesce(
    (select value from public.settings where business_id = p_business_id and key = 'timezone' limit 1),
    'UTC'
  ) into v_tz;

  with order_aggregates as (
    select
      o.id as order_id,
      (o.created_at at time zone v_tz)::date as local_date,
      case
        when p_store_id is null or o.store_id = p_store_id then o.discount_kobo
        else 0
      end as discount_kobo,
      coalesce(sum(
        case
          when p_store_id is null or oi.store_id = p_store_id then public.line_total_kobo(oi.unit_price_kobo, oi.quantity)
          else 0
        end
      ), 0) as items_gross_kobo
    from public.orders o
    left join public.order_items oi on oi.order_id = o.id
    where o.business_id = p_business_id
      and o.status in ('pending', 'completed')
      and (p_store_id is null or o.store_id = p_store_id or oi.store_id = p_store_id)
      and (p_start_date is null or o.created_at >= p_start_date)
      and (p_end_date is null or o.created_at <= p_end_date)
    group by o.id, o.store_id, o.discount_kobo, o.created_at
  ),
  daily as (
    select
      local_date,
      count(*)::bigint as order_count,
      sum(items_gross_kobo)::bigint as items_gross_kobo,
      sum(discount_kobo)::bigint as discount_kobo,
      sum(items_gross_kobo - discount_kobo)::bigint as total_sales_kobo
    from order_aggregates
    group by local_date
    order by local_date
  )
  select jsonb_build_object(
    'total_sales_kobo', coalesce((select sum(total_sales_kobo) from daily), 0)::bigint,
    'order_count', coalesce((select sum(order_count) from daily), 0)::bigint,
    'items_gross_kobo', coalesce((select sum(items_gross_kobo) from daily), 0)::bigint,
    'discount_kobo', coalesce((select sum(discount_kobo) from daily), 0)::bigint,
    'timezone', v_tz,
    'by_day', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'date', local_date,
          'order_count', order_count,
          'items_gross_kobo', items_gross_kobo,
          'discount_kobo', discount_kobo,
          'total_sales_kobo', total_sales_kobo
        )
      ) from daily
    ), '[]'::jsonb)
  ) into v_res;

  return v_res;
end;
$function$;

CREATE OR REPLACE FUNCTION public.console_platform_revenue(p_include_test boolean DEFAULT false, p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_res jsonb;
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;

  with biz as (
    select
      b.id as business_id,
      upper(coalesce(nullif(btrim(
        (select s.value from public.settings s
          where s.business_id = b.id and s.key = 'default_currency' limit 1)
      ), ''), 'NGN')) as currency,
      coalesce(nullif(btrim(
        (select s.value from public.settings s
          where s.business_id = b.id and s.key = 'timezone' limit 1)
      ), ''), 'UTC') as tz
    from public.businesses b
    where p_include_test
       or not exists (
         select 1 from public.console_test_businesses t where t.business_id = b.id
       )
  ),
  order_totals as (
    select
      biz.business_id,
      biz.currency,
      (o.created_at at time zone biz.tz)::date as local_date,
      o.id as order_id,
      coalesce(sum(public.line_total_kobo(oi.unit_price_kobo, oi.quantity)), 0) - o.discount_kobo as sales_kobo
    from biz
    join public.orders o on o.business_id = biz.business_id
    left join public.order_items oi on oi.order_id = o.id
    where o.status in ('pending', 'completed')
      and (p_start_date is null or o.created_at >= p_start_date)
      and (p_end_date is null or o.created_at <= p_end_date)
    group by biz.business_id, biz.currency, biz.tz, o.id, o.created_at, o.discount_kobo
  ),
  by_day as (
    select currency, local_date,
           sum(sales_kobo)::bigint as total_sales_kobo,
           count(*)::bigint as order_count
    from order_totals
    group by currency, local_date
  ),
  by_currency as (
    select currency,
           sum(sales_kobo)::bigint as total_sales_kobo,
           count(*)::bigint as order_count,
           count(distinct business_id)::bigint as business_count
    from order_totals
    group by currency
  )
  select jsonb_build_object(
    'currencies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'currency', currency,
        'total_sales_kobo', total_sales_kobo,
        'order_count', order_count,
        'business_count', business_count
      ) order by currency) from by_currency
    ), '[]'::jsonb),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object(
        'currency', currency,
        'date', local_date,
        'total_sales_kobo', total_sales_kobo,
        'order_count', order_count
      ) order by currency, local_date) from by_day
    ), '[]'::jsonb)
  ) into v_res;

  return v_res;
end;
$function$;

CREATE OR REPLACE FUNCTION public.console_orders_summary(p_business_id uuid, p_store_id uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_channel text DEFAULT NULL::text, p_start_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text;
  v_res jsonb;
  v_status text;
  v_channel text;
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;

  select coalesce(
    (select value from public.settings where business_id = p_business_id and key = 'timezone' limit 1),
    'UTC'
  ) into v_tz;

  v_status := nullif(lower(btrim(p_status)), 'all');
  if v_status = '' then v_status := null; end if;

  v_channel := nullif(lower(btrim(p_channel)), 'all');
  if v_channel = '' then v_channel := null; end if;

  if p_business_id is null then
    return jsonb_build_object(
      'order_count', 0,
      'total_sales_kobo', 0,
      'items_gross_kobo', 0,
      'discount_kobo', 0,
      'avg_ticket_kobo', 0,
      'refunds_kobo', 0,
      'refund_count', 0,
      'crate_deposits_kobo', 0,
      'net_sales_kobo', 0,
      'payment_methods', '{}'::jsonb,
      'timezone', v_tz,
      'by_day', '[]'::jsonb
    );
  end if;

  with filtered_orders as (
    select
      o.id,
      o.store_id,
      lower(o.status) as status,
      lower(coalesce(o.payment_type, '')) as payment_type,
      coalesce(o.discount_kobo, 0) as discount_kobo,
      o.created_at,
      (o.created_at at time zone v_tz)::date as local_date
    from public.orders o
    where o.business_id = p_business_id
      and (p_store_id is null or o.store_id = p_store_id)
      and (v_status is null or lower(o.status) = v_status)
      and (v_channel is null or lower(coalesce(o.payment_type, '')) = v_channel)
      and (p_start_date is null or o.created_at >= p_start_date)
      and (p_end_date is null or o.created_at <= p_end_date)
  ),
  order_aggregates as (
    select
      fo.id as order_id,
      fo.local_date,
      fo.status,
      case
        when (v_status is not null and fo.status = v_status)
             or (v_status is null and fo.status in ('pending', 'completed'))
        then fo.discount_kobo
        else 0
      end as discount_kobo,
      coalesce(sum(
        case
          when (v_status is not null and fo.status = v_status)
               or (v_status is null and fo.status in ('pending', 'completed'))
          then
            case
              when p_store_id is null or oi.store_id = p_store_id or (oi.store_id is null and fo.store_id = p_store_id)
              then public.line_total_kobo(oi.unit_price_kobo, oi.quantity)
              else 0
            end
          else 0
        end
      ), 0) as items_gross_kobo
    from filtered_orders fo
    left join public.order_items oi on oi.order_id = fo.id
    group by fo.id, fo.local_date, fo.status, fo.discount_kobo
  ),
  order_totals as (
    select
      coalesce(count(*), 0)::bigint as total_order_count,
      coalesce(sum(items_gross_kobo), 0)::bigint as total_items_gross_kobo,
      coalesce(sum(discount_kobo), 0)::bigint as total_discount_kobo,
      coalesce(sum(items_gross_kobo - discount_kobo), 0)::bigint as total_sales_kobo
    from order_aggregates
  ),
  daily_orders as (
    select
      local_date,
      count(*)::bigint as order_count,
      coalesce(sum(items_gross_kobo), 0)::bigint as items_gross_kobo,
      coalesce(sum(discount_kobo), 0)::bigint as discount_kobo,
      coalesce(sum(items_gross_kobo - discount_kobo), 0)::bigint as total_sales_kobo
    from order_aggregates
    group by local_date
  ),
  filtered_payments as (
    select
      pt.id,
      pt.order_id,
      pt.store_id,
      lower(pt.method) as method,
      pt.type,
      pt.amount_kobo,
      pt.created_at,
      (pt.created_at at time zone v_tz)::date as local_date
    from public.payment_transactions pt
    where pt.business_id = p_business_id
      and pt.voided_at is null
      and (p_store_id is null or pt.store_id = p_store_id)
      and (v_channel is null or lower(pt.method) = v_channel)
      and (p_start_date is null or pt.created_at >= p_start_date)
      and (p_end_date is null or pt.created_at <= p_end_date)
  ),
  refund_totals as (
    select
      coalesce(count(*), 0)::bigint as refund_count,
      coalesce(sum(amount_kobo), 0)::bigint as refunds_kobo
    from filtered_payments pt
    where type = 'refund'
      and (
        v_status is null
        or pt.order_id is null
        or exists (select 1 from public.orders ro where ro.id = pt.order_id and lower(ro.status) = v_status)
      )
  ),
  daily_refunds as (
    select
      local_date,
      coalesce(sum(amount_kobo), 0)::bigint as refunds_kobo,
      count(*)::bigint as refund_count
    from filtered_payments pt
    where type = 'refund'
      and (
        v_status is null
        or pt.order_id is null
        or exists (select 1 from public.orders ro where ro.id = pt.order_id and lower(ro.status) = v_status)
      )
    group by local_date
  ),
  deposit_totals as (
    select
      coalesce(sum(amount_kobo), 0)::bigint as crate_deposits_kobo
    from filtered_payments pt
    where type = 'crate_deposit'
      and (
        v_status is null
        or pt.order_id is null
        or exists (select 1 from public.orders co where co.id = pt.order_id and lower(co.status) = v_status)
      )
  ),
  daily_deposits as (
    select
      local_date,
      coalesce(sum(amount_kobo), 0)::bigint as crate_deposits_kobo
    from filtered_payments pt
    where type = 'crate_deposit'
      and (
        v_status is null
        or pt.order_id is null
        or exists (select 1 from public.orders co where co.id = pt.order_id and lower(co.status) = v_status)
      )
    group by local_date
  ),
  payment_splits as (
    select
      method,
      coalesce(sum(amount_kobo), 0)::bigint as method_kobo
    from filtered_payments pt
    where type = 'sale'
      and (
        v_status is null
        or pt.order_id is null
        or exists (select 1 from public.orders so where so.id = pt.order_id and lower(so.status) = v_status)
      )
    group by method
  ),
  all_dates as (
    select local_date from daily_orders
    union
    select local_date from daily_refunds
    union
    select local_date from daily_deposits
  ),
  daily_combined as (
    select
      ad.local_date,
      coalesce(d_ord.order_count, 0)::bigint as order_count,
      coalesce(d_ord.items_gross_kobo, 0)::bigint as items_gross_kobo,
      coalesce(d_ord.discount_kobo, 0)::bigint as discount_kobo,
      coalesce(d_ord.total_sales_kobo, 0)::bigint as total_sales_kobo,
      coalesce(d_ref.refunds_kobo, 0)::bigint as refunds_kobo,
      coalesce(d_ref.refund_count, 0)::bigint as refund_count,
      coalesce(d_dep.crate_deposits_kobo, 0)::bigint as crate_deposits_kobo
    from all_dates ad
    left join daily_orders d_ord on d_ord.local_date = ad.local_date
    left join daily_refunds d_ref on d_ref.local_date = ad.local_date
    left join daily_deposits d_dep on d_dep.local_date = ad.local_date
    order by ad.local_date
  )
  select jsonb_build_object(
    'order_count', coalesce(ot.total_order_count, 0),
    'total_sales_kobo', coalesce(ot.total_sales_kobo, 0),
    'items_gross_kobo', coalesce(ot.total_items_gross_kobo, 0),
    'discount_kobo', coalesce(ot.total_discount_kobo, 0),
    'avg_ticket_kobo', case when coalesce(ot.total_order_count, 0) > 0 then (ot.total_sales_kobo / ot.total_order_count)::bigint else 0::bigint end,
    'refunds_kobo', coalesce(rt.refunds_kobo, 0),
    'refund_count', coalesce(rt.refund_count, 0),
    'crate_deposits_kobo', coalesce(dt.crate_deposits_kobo, 0),
    'net_sales_kobo', coalesce(ot.total_sales_kobo, 0) - coalesce(rt.refunds_kobo, 0),
    'payment_methods', coalesce((
      select jsonb_object_agg(method, method_kobo)
      from payment_splits
    ), '{}'::jsonb),
    'timezone', v_tz,
    'by_day', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'date', local_date,
          'order_count', order_count,
          'items_gross_kobo', items_gross_kobo,
          'discount_kobo', discount_kobo,
          'total_sales_kobo', total_sales_kobo,
          'refunds_kobo', refunds_kobo,
          'refund_count', refund_count,
          'crate_deposits_kobo', crate_deposits_kobo
        )
      ) from daily_combined
    ), '[]'::jsonb)
  )
  from order_totals ot
  cross join refund_totals rt
  cross join deposit_totals dt
  into v_res;

  return v_res;
end;
$function$;

-- ===========================================================================
-- D. Grants for the re-created (dropped + created) functions
-- ===========================================================================
REVOKE ALL ON FUNCTION public._apply_stock_adjustment(uuid, uuid, uuid, double precision, text, uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._apply_stock_adjustment(uuid, uuid, uuid, double precision, text, uuid, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.request_stock_adjustment(uuid, uuid, uuid, uuid, double precision, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_stock_adjustment(uuid, uuid, uuid, uuid, double precision, text, text, bigint) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, double precision, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_record_crate_return(uuid, uuid, uuid, text, uuid, uuid, double precision, text, uuid, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.pos_transfer_crates(uuid, uuid, uuid, uuid, uuid, uuid, double precision, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_transfer_crates(uuid, uuid, uuid, uuid, uuid, uuid, double precision, uuid, uuid) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.console_adjust_inventory(uuid, uuid, uuid, uuid, double precision, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.console_create_product(uuid, uuid, text, text, text, text, text, bigint, bigint, bigint, uuid, uuid, uuid, integer, timestamp with time zone, uuid, double precision) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.pos_stock_transfer(uuid, uuid, uuid, uuid, uuid, uuid, uuid, double precision) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.add_product(uuid, uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, double precision, boolean, uuid, integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.console_adjust_inventory(uuid, uuid, uuid, uuid, double precision, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.console_create_product(uuid, uuid, text, text, text, text, text, bigint, bigint, bigint, uuid, uuid, uuid, integer, timestamp with time zone, uuid, double precision) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pos_stock_transfer(uuid, uuid, uuid, uuid, uuid, uuid, uuid, double precision) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_product(uuid, uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, double precision, boolean, uuid, integer) FROM PUBLIC, anon;

-- PostgREST caches column types; ask it to reload after the DDL.
NOTIFY pgrst, 'reload schema';

COMMIT;
