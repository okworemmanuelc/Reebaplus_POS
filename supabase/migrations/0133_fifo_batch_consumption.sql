-- 0133_fifo_batch_consumption.sql
--
-- Reebaplus — Epic 2 / FIFO batch costing (master plan ADR 0005, issue #39, F3).
--
-- SERVER-AUTHORITATIVE batch consumption + replay. The server owns the per-
-- (product, store) FIFO cost queue (`cost_batches`, from 0132/#37) and decides
-- "which batch paid for each sale," ordering consumption by the sale's OWN
-- recorded timestamp (`orders.created_at`), not server-arrival order. From that
-- it re-derives the authoritative per-line COGS onto `order_items.buying_price_kobo`.
--
-- WHY A SEPARATE DERIVATION PASS (not more logic inside the quantity RPCs):
-- quantities are ALREADY ordered and resolved by the server-minted movement
-- seam (pos_record_sale_v2 for sale deltas, pos_inventory_delta_v2 for the rest).
-- This epic must only add "which batch paid" to movements that are already
-- quantified, and must NOT reopen stock-quantity conflict resolution (ADR 0005).
-- So we DO NOT touch pos_inventory_delta_v2 / pos_record_sale_v2 at all. Instead
-- we add a pure, replayable re-derivation over the already-quantified ledger.
-- Batch consumption is derived, recomputable state — assignments are stable only
-- until an earlier-timestamped sale arrives, at which point a full replay from
-- the timestamp-ordered ledger deterministically re-assigns already-corrected
-- lines.
--
-- Two layers:
--   1. public.fifo_assign(batches, sales)  — PURE (IMMUTABLE), no table access.
--      The whole FIFO draw-down algorithm: a queue + a timestamp-ordered sale
--      sequence in, per-line COGS (incl. partial-batch splits across boundaries
--      and cost-0 "uncosted" units) + resulting batch remainders out. This is
--      the seam the tests exercise directly — deterministic and idempotent by
--      construction, no fixtures required.
--   2. public.pos_recost_product_store(business, product, store) — the thin
--      orchestrator: loads the queue + sale ledger, calls fifo_assign, writes
--      back the derived COGS + batch qty_remaining. Full replay from scratch
--      every call → idempotent; a late earlier-timestamped sale re-orders the
--      ledger → re-assigns already-corrected lines on the next call.
--   3. public.pos_recost_pairs(business, pairs) — batch wrapper that recosts a
--      set of (product, store) pairs (the ones a sync touched) and returns one
--      rolled-up count, for the client correction flow (#40) to audit with a
--      single "N sales re-costed on sync" Activity Log row. This RPC does not
--      write the Activity Log itself (client owns that copy + localization).
--
-- DEPLOY ORDER: after 0132 (cost_batches). No app-schema dependency — this is
-- pure server logic the client correction flow (#40) will call; it is inert
-- until called, so it is safe to land ahead of the client work.

BEGIN;

-- ─── 1. fifo_assign — the pure FIFO draw-down (the seam) ────────────────────
--
-- Inputs (caller supplies the ordering — this function never sorts):
--   p_batches : oldest-first FIFO queue,   [{ "cost_kobo": <bigint>, "qty": <int> }, ...]
--   p_sales   : sale-timestamp-ordered,    [{ "line_id": <text>, "quantity": <int> }, ...]
--
-- cost_kobo = 0 marks an UNCOSTED batch: units drawn from it contribute 0 to
-- COGS and are counted in `uncosted_units` (surfaced for the "uncosted items"
-- reporting / prompted backfill — a later issue). Units the queue can't cover
-- at all (exhausted) are likewise uncosted.
--
-- Rounding: `cogs_per_unit_kobo` = round(line_total / quantity) (round-half-away-
-- from-zero, Postgres `round(numeric)`). buying_price_kobo is a per-unit int, so
-- a boundary-spanning line carries the exact line total as an averaged per-unit
-- cost — the same per-unit shape the scalar model always used. The exact total
-- is also returned as `cogs_total_kobo`. The client provisional draw-down (#38)
-- MUST use this same rounding so a provisional line and its server correction
-- agree when no re-ordering happened.
--
-- Output:
--   {
--     "lines": [{ "line_id", "quantity", "cogs_total_kobo", "cogs_per_unit_kobo",
--                 "uncosted_units" }, ...],   -- one per input sale, input order
--     "batches_remaining": [<int>, ...]        -- qty left per input batch, input order
--   }
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
  v_qty         int[]    := ARRAY[]::int[];     -- remaining qty per batch (1-indexed)
  v_cost        bigint[] := ARRAY[]::bigint[];  -- cost_kobo per batch
  v_b           jsonb;
  v_s           jsonb;
  v_i           int;
  v_ptr         int := 1;        -- oldest batch with qty > 0 (persists across sales)
  v_need        int;
  v_qty_line    int;
  v_take        int;
  v_line_cost   bigint;
  v_uncosted    int;
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
    v_qty  := array_append(v_qty,  COALESCE((v_b->>'qty')::int, 0));
    v_cost := array_append(v_cost, COALESCE((v_b->>'cost_kobo')::bigint, 0));
  END LOOP;
  v_n_batches := COALESCE(array_length(v_qty, 1), 0);

  -- Draw each sale down oldest-first. v_ptr is the global consumption cursor:
  -- it never rewinds, so a partially consumed batch continues serving the next
  -- line until it empties.
  FOR v_s IN SELECT * FROM jsonb_array_elements(p_sales) LOOP
    v_qty_line  := COALESCE((v_s->>'quantity')::int, 0);
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
        v_line_cost := v_line_cost + v_take::bigint * v_cost[v_ptr];
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
      'cogs_total_kobo',    v_line_cost,
      'cogs_per_unit_kobo',
        COALESCE(round(v_line_cost::numeric / NULLIF(v_qty_line, 0))::bigint, 0),
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

-- Pure + tenant-agnostic (no data access), so safe for any authenticated caller.
REVOKE ALL ON FUNCTION public.fifo_assign(jsonb, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.fifo_assign(jsonb, jsonb)
  TO authenticated, service_role;


-- ─── 2. pos_recost_product_store — orchestrator (loads ledger, replays) ─────
--
-- Full replay from scratch for ONE (product, store): reads the FIFO queue and
-- the recognized-sale ledger, re-derives via fifo_assign, and writes back the
-- authoritative per-line COGS + derived batch remainders. Because it always
-- replays the entire timestamp-ordered ledger from qty_original, it is
-- idempotent (same ledger → same result) and self-correcting (a late
-- earlier-timestamped sale re-orders the ledger → its cheaper-batch claim wins
-- and already-corrected lines are re-assigned on the next call).
--
-- Only lines whose COGS actually changes get last_updated_at bumped, so the
-- correction flows to peer devices as an ordinary LWW row update and
-- `recosted_count` reflects genuinely re-costed sales (drives the rolled-up
-- Activity Log row in #40). Only cost_batches whose qty_remaining changes are
-- written.
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
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object('line_id', oi.id, 'quantity', oi.quantity)
                       ORDER BY o.created_at, o.id, oi.id), '[]'::jsonb)
  INTO v_sales
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.business_id = p_business_id
    AND oi.product_id  = p_product_id
    AND oi.store_id    = p_store_id
    AND o.status IN ('pending', 'completed');

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


-- ─── 3. pos_recost_pairs — recost the (product, store) pairs a sync touched ──
--
-- p_pairs : [{ "product_id": <uuid>, "store_id": <uuid> }, ...]  (deduped here)
-- Returns one rolled-up count across the batch + a per-pair breakdown, so the
-- client correction flow (#40) can write a single "N sales re-costed on sync"
-- Activity Log row instead of nagging per sale.
CREATE OR REPLACE FUNCTION public.pos_recost_pairs(
  p_business_id uuid,
  p_pairs       jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_pair    record;
  v_one     jsonb;
  v_total   int := 0;
  v_results jsonb := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_pairs IS NULL OR jsonb_typeof(p_pairs) <> 'array' THEN
    RAISE EXCEPTION 'pos_recost_pairs: p_pairs must be a json array'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  FOR v_pair IN
    SELECT DISTINCT
           (p->>'product_id')::uuid AS product_id,
           (p->>'store_id')::uuid   AS store_id
      FROM jsonb_array_elements(p_pairs) AS p
     WHERE (p->>'product_id') IS NOT NULL
       AND (p->>'store_id')   IS NOT NULL
  LOOP
    v_one := public.pos_recost_product_store(
      p_business_id, v_pair.product_id, v_pair.store_id);
    v_total   := v_total + (v_one->>'recosted_count')::int;
    v_results := v_results || v_one;
  END LOOP;

  RETURN jsonb_build_object(
    'recosted_count', v_total,
    'pairs',          v_results
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_recost_pairs(uuid, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_recost_pairs(uuid, jsonb)
  TO authenticated, service_role;

COMMIT;
