-- 0167_recost_stops_rewriting_qty_remaining.sql
--
-- #187 (P0, found by the #155 close-out audit; parent #155, slice #170) —
-- `pos_recost_product_store` must STOP writing `cost_batches.qty_remaining`.
--
-- ── The defect ──────────────────────────────────────────────────────────────
--
-- The replay (0133, fenced for vans in 0164) rebuilds a (product, store) FIFO
-- queue from `cost_batches.qty_original` against the SALE ledger only
-- (`orders.status IN ('pending','completed')`), then wrote the derived
-- remainders back over `qty_remaining`. That was true when a sale was the only
-- thing that could consume a batch.
--
-- Slice #170 (7a/7b/7c) added CLIENT-side batch draws for outflows the replay
-- knows nothing about: damages, count shortages, product-delete write-offs
-- (`stock_adjustments.value_kobo`, 0155), transfer dispatches
-- (`stock_transfers.cost_kobo`, 0156) and the van dispatch draw on the source
-- warehouse. The replay fires on every sale push and every cancel push
-- (`reconcilePushedSaleCosts` → `pos_recost_pairs`), and `cost_batches` is a
-- pass-through synced table, so the server's value landed back on every device.
-- Every non-sale draw was RESURRECTED on the next sale push of the same pair:
--
--   • a damage / shortage was counted twice — once as the snapshotted valued
--     loss, then again as real COGS when the resurrected units were sold;
--   • a transfer source store regained the phantom cost coverage 7b removed —
--     the exact defect that slice set out to fix;
--   • a cancel restored units twice: B1 `qty_original` 10, sell 4 →
--     `qty_remaining` 6; the cancel appends a restore layer B2(4); the next
--     recost re-derived B1 = 10 (the cancelled order drops out of the sale
--     ledger) while B2(4) survived ⇒ 14 units covered against 10 on hand.
--
-- ── The fix (#187 option 2) ─────────────────────────────────────────────────
--
-- Drop the `qty_remaining` write-back. The replay keeps doing the one thing it
-- is uniquely able to do — re-derive the authoritative per-line COGS ordered by
-- each sale's own recorded timestamp across all tills (ADR 0005
-- "Batch-Boundary Reconciliation", #40) — and stops overwriting a number only
-- the client can compute correctly.
--
-- WHY NOT option 1 (subtract the non-sale draws from the replay input): the
-- server would have to learn EVERY present and future outflow class, and — to
-- rebuild the queue faithfully — also which LAYER each of those draws hit,
-- which is not recorded anywhere (`stock_adjustments` / `stock_transfers` carry
-- a value snapshot, not a per-batch attribution). Option 2 is the smaller
-- change and keeps the #170 draws authoritative. A durable option 1 needs a
-- per-batch draw ledger (`cost_batch_draws`), which is a design, not a patch.
--
-- ── What this means for `qty_remaining` ownership ────────────────────────────
--
-- `cost_batches.qty_remaining` is now written by exactly two authorities, both
-- of which draw INCREMENTALLY (never by replay), so both see every outflow:
--   1. the client (`CostBatchesDao.drawDownSale` / `drawDownOutflow` /
--      `recordInflowBatch`), pushed as an ordinary LWW row update; and
--   2. `_checkout_draw_fifo` (0139) on the v2 checkout path, which reads
--      `qty_remaining` (not `qty_original`) and decrements what the sale drew.
-- Neither resurrects anything. `qty_original` stays what it always was: the
-- immutable size of the layer.
--
-- COST OF THIS TRADE-OFF, stated plainly: when a late earlier-timestamped sale
-- re-orders the ledger, the per-line COGS is still re-assigned (that correction
-- is the whole point of the pass), but the per-layer remainder SPLIT is no
-- longer re-attributed to match. The TOTAL is unaffected — every device draws
-- the same number of units for the same movements, so Σ`qty_remaining` per
-- (product, store) still tracks on-hand — only which layer holds the leftover
-- can differ from a strict from-scratch replay. That is a strictly smaller
-- error than resurrecting units that were physically destroyed, transferred or
-- restored, and it does not move money: the per-line COGS snapshot is the cost
-- of goods truth, and Business worth sums the whole queue.
--
-- SCOPE NOTE — what #187 option 2 does NOT fix: the replay still builds its
-- COSTING input from `qty_original`, so it can still assign a later sale line
-- to a layer a damage / dispatch already consumed (queue B1 10 @₦500 destroyed
-- by a damage, B2 5 @₦900 received, then a sale of 3 → the client snapshots
-- ₦900/unit and this pass restates it to ₦500). That is a per-line COGS
-- mis-assignment with the same root cause (a sales-only view of consumption)
-- and needs the per-batch draw ledger above. Filed as a follow-up; deliberately
-- untouched here. Removing the write-back can only reduce what this function
-- writes, so it cannot make that residual worse.
--
-- ── Shape ───────────────────────────────────────────────────────────────────
--
-- Body copied from 0164 (the CURRENT definition — 0164 fenced van stores out).
-- Deltas are marked `-- #187 delta`: the `qty_remaining` write-back loop is
-- gone, and with it the now-dead `v_batch_ids` / `v_rem` / `v_i` locals. The van
-- fence (0164, ADR 0019 decision 1, spec §5.6 fence 2) and the trip-tagged-line
-- exclusion are PRESERVED verbatim — "anyone extending the backfill or the
-- recost RPC must preserve the van fence".
--
-- SIGNATURE UNCHANGED (uuid, uuid, uuid) → plain `CREATE OR REPLACE`, no new
-- parameter, no DROP: adding a parameter here would leave two candidates and
-- PostgREST would refuse to choose (PGRST203) on every recost call. Response
-- shape unchanged too (`product_id`, `store_id`, `recosted_count`,
-- `recosted_lines`, plus `skipped` for a van) — `pos_recost_pairs` calls this by
-- name and is untouched, as is the client's `reconcilePushedSaleCosts`.
--
-- NO DATA REPAIR IN THIS MIGRATION. Historical inflation is already in the
-- cloud and on every device that pulled it; the read-only quantification query
-- at the bottom of this file is the first step and needs sign-off before any
-- repair pass. This migration only stops the bleeding.

BEGIN;

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
    AND o.status IN ('pending', 'completed')
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
        'uncosted_units',     (v_line->>'uncosted_units')::int
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

REVOKE ALL ON FUNCTION public.pos_recost_product_store(uuid, uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_recost_product_store(uuid, uuid, uuid)
  TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business
-- user; every statement here is READ-ONLY):
--
--   1. Exactly ONE candidate function survives (no PGRST203 overload):
--
--      SELECT p.oid::regprocedure AS signature
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public' AND p.proname = 'pos_recost_product_store';
--      -- expect exactly 1 row: pos_recost_product_store(uuid,uuid,uuid)
--
--   2. The body no longer writes cost_batches:
--
--      SELECT position('UPDATE public.cost_batches' IN prosrc) = 0 AS write_back_gone
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public' AND p.proname = 'pos_recost_product_store';
--      -- expect: t
--
--   3. Behaviour, on a scratch (product, store): note a batch's qty_remaining,
--      call `pos_recost_product_store` twice, re-read it. The per-line
--      `order_items.buying_price_kobo` may change on the first call; the batch's
--      `qty_remaining` must be byte-identical before and after both calls.
--
-- =============================================================================
-- BLAST RADIUS — read-only quantification. DO NOT REPAIR WITHOUT SIGN-OFF.
-- =============================================================================
--
-- #187 says the blast radius is NOT yet quantified and prod data must not be
-- touched without sign-off, so NOTHING below runs as part of this migration —
-- it is commented out on purpose. Both queries are pure SELECTs. Run them with
-- the service role (they are cross-tenant by design) and hand the output to the
-- owner before anyone proposes a repair.
--
-- Q1 — WHO IS EXPOSED. The issue's own criterion: a business that recorded a
-- valued loss (damage / shortage / delete write-off, 0155) or a dispatched
-- transfer (0156) and then sold the same product on the same store. These pairs
-- are the ones whose `qty_remaining` the old write-back could have inflated.
--
--   WITH non_sale_draws AS (
--     SELECT sa.business_id, sa.product_id, sa.store_id, MIN(sa.created_at) AS first_draw_at
--       FROM public.stock_adjustments sa
--      WHERE sa.value_kobo IS NOT NULL
--      GROUP BY 1, 2, 3
--     UNION ALL
--     SELECT st.business_id, st.product_id, st.from_location_id AS store_id,
--            MIN(st.initiated_at) AS first_draw_at
--       FROM public.stock_transfers st
--      WHERE st.cost_kobo IS NOT NULL
--      GROUP BY 1, 2, 3
--   ), exposed AS (
--     SELECT d.business_id, d.product_id, d.store_id, MIN(d.first_draw_at) AS first_draw_at
--       FROM non_sale_draws d
--      GROUP BY 1, 2, 3
--   )
--   SELECT b.id AS business_id, b.name AS business_name,
--          COUNT(*)                              AS exposed_pairs,
--          COUNT(*) FILTER (WHERE s.sold_after)   AS pairs_with_a_later_sale
--     FROM exposed e
--     JOIN public.businesses b ON b.id = e.business_id
--     CROSS JOIN LATERAL (
--       SELECT EXISTS (
--         SELECT 1
--           FROM public.order_items oi
--           JOIN public.orders o ON o.id = oi.order_id
--          WHERE oi.business_id = e.business_id
--            AND oi.product_id  = e.product_id
--            AND oi.store_id    = e.store_id
--            AND o.status IN ('pending', 'completed')
--            AND o.van_trip_id IS NULL
--            AND o.created_at >= e.first_draw_at
--       ) AS sold_after
--     ) s
--    GROUP BY 1, 2
--    ORDER BY pairs_with_a_later_sale DESC, exposed_pairs DESC;
--
-- Q2 — HOW BAD, measured against physical stock. The queue invariant the client
-- maintains is Σ`qty_remaining` = on-hand for a (product, store) (every inflow
-- appends a layer, every outflow draws one down inside the same transaction).
-- Rows where the queue claims MORE units than the shelf holds are the concrete
-- inflation candidates. Van stores are excluded (ADR 0019 keeps no batches
-- there); a surplus can also come from other causes, so this is a CANDIDATE
-- list for human review, not a repair list — and it under-counts, since an
-- inflated layer is invisible here once a later real outflow has absorbed it.
--
--   SELECT b.id AS business_id, b.name AS business_name,
--          COUNT(*)                        AS pairs_over_covered,
--          SUM(q.batch_total - q.on_hand)  AS surplus_units,
--          MAX(q.batch_total - q.on_hand)  AS worst_pair_surplus
--     FROM (
--       SELECT cb.business_id, cb.product_id, cb.store_id,
--              SUM(cb.qty_remaining)           AS batch_total,
--              COALESCE(MAX(inv.quantity), 0)  AS on_hand
--         FROM public.cost_batches cb
--         JOIN public.stores st ON st.id = cb.store_id AND st.kind IS DISTINCT FROM 'van'
--         LEFT JOIN public.inventory inv
--                ON inv.business_id = cb.business_id
--               AND inv.product_id  = cb.product_id
--               AND inv.store_id    = cb.store_id
--        GROUP BY 1, 2, 3
--     ) q
--     JOIN public.businesses b ON b.id = q.business_id
--    WHERE q.batch_total > q.on_hand
--    GROUP BY 1, 2
--    ORDER BY surplus_units DESC;
--
-- If a repair is signed off, note that the fix is NOT "recompute from the sale
-- ledger" (that is the very bug): it is to re-derive each layer's remainder from
-- the full movement history — every inflow layer minus every draw against it,
-- sales AND #170 non-sale outflows — or, where that history is not attributable,
-- to true the queue up to on-hand oldest-first and audit the correction. Both
-- devices and cloud hold the inflated value, so a repair has to land on both.
