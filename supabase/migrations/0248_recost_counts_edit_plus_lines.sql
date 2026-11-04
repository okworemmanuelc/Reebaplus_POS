-- 0248_recost_counts_edit_plus_lines.sql
--
-- #713 (PRD #707 slice 6, ADR 0035 addendum): an edited sale's adjustment can
-- carry PLUS lines (added goods, positive quantity) that draw FIFO layers like a
-- sale. 0247's recost replay skipped every kind = 'adjustment' order, so those
-- draws were invisible to it. Only the sale-ledger filter changes; minus lines
-- (negative quantity) stay excluded. NOT DEPLOYED by the agent.

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
    AND o.van_trip_id IS NULL                                      -- #142 delta
    -- 0247 (#712): a sale ADJUSTMENT's minus lines are not sales. 0248 (#713):
    -- but an edit's PLUS lines (quantity > 0) ARE sales: they drew FIFO layers
    -- at the time, so the replay must consume them too.
    AND (o.kind = 'sale' OR oi.quantity > 0);

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

COMMIT;
