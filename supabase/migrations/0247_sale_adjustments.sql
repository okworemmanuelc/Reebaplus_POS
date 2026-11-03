-- 0247_sale_adjustments.sql
--
-- #712 (PRD #707 slice 5, ADR 0035): the SALE ADJUSTMENT record and part return.
--
-- A part return is saved as a NEW `orders` row (kind = 'adjustment',
-- adjusts_order_id = the sale) with MINUS order_items lines; its stock, payment,
-- wallet and crate rows reference that row. The original sale is never changed.
--
--   1. orders.kind (CHECK sale|adjustment, default 'sale') and
--      orders.adjusts_order_id (FK orders). Existing rows and every existing
--      insert path (pos_record_sale_v2 etc.) take the 'sale' default.
--   2. order_items.quantity CHECK (quantity > 0) -> (quantity <> 0): a returned
--      line is minus. The 0239 quarter-step CHECK already accepts negatives.
--   3. public.sale_adjustment_claims (cloud-only, no Drift twin) +
--      public.pos_claim_sale_adjustment(...): the over-return guard, the part
--      return's twin of #550's first-reversal-wins claim. The phone HOLDS the
--      adjustment's rows behind the claim; the cloud locks the parent, sums
--      every accepted claim per parent line and refuses a return that exceeds
--      what was sold (P0001 adjustment_exceeds_returnable) or a parent that is
--      not `completed` (P0001 order_not_returnable).
--   4. pos_claim_order_reversal (full cancel) now also refuses a sale that has
--      an accepted adjustment claim (reversal_already_applied).
--   5. pos_recost_product_store ignores adjustment orders in the sale ledger.
--
-- DEPLOY: before any phone build that carries v105 (it pushes `kind` /
-- `adjusts_order_id` on every orders upsert). Never together with 0193.

BEGIN;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'sale',
  ADD COLUMN IF NOT EXISTS adjusts_order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.orders'::regclass AND conname = 'orders_kind_check'
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_kind_check CHECK (kind IN ('sale', 'adjustment'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_orders_adjusts_order
  ON public.orders (adjusts_order_id) WHERE adjusts_order_id IS NOT NULL;

-- order_items.quantity: drop the "> 0" CHECK by definition lookup (name-agnostic,
-- the 0239 quarter-step CHECK is a different definition and stays), add "<> 0".
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.order_items'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%quantity%> 0%'
       AND pg_get_constraintdef(oid) NOT ILIKE '%qty_is_quarter%'
  LOOP
    EXECUTE format('ALTER TABLE public.order_items DROP CONSTRAINT %I', c.conname);
  END LOOP;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.order_items'::regclass
       AND conname = 'order_items_quantity_nonzero'
  ) THEN
    ALTER TABLE public.order_items
      ADD CONSTRAINT order_items_quantity_nonzero CHECK (quantity <> 0);
  END IF;
END $$;

-- =========================================================================
-- 3. The over-return guard
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.sale_adjustment_claims (
  id                  uuid PRIMARY KEY,
  business_id         uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  parent_order_id     uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  adjustment_order_id uuid NOT NULL,
  lines               jsonb NOT NULL,
  performed_by        uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  last_updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sale_adjustment_claims_one_per_adjustment UNIQUE (adjustment_order_id)
);

CREATE INDEX IF NOT EXISTS idx_sale_adjustment_claims_parent
  ON public.sale_adjustment_claims (parent_order_id);

ALTER TABLE public.sale_adjustment_claims ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sale_adjustment_claims_tenant_read" ON public.sale_adjustment_claims;
CREATE POLICY "sale_adjustment_claims_tenant_read" ON public.sale_adjustment_claims
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()));

REVOKE INSERT, UPDATE, DELETE ON public.sale_adjustment_claims FROM anon, authenticated;
GRANT SELECT ON public.sale_adjustment_claims TO authenticated;

DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.sale_adjustment_claims;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.sale_adjustment_claims
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- p_lines: [{"order_item_id": <parent line id>, "quantity": <units returned>}]
CREATE OR REPLACE FUNCTION public.pos_claim_sale_adjustment(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_parent_order_id      uuid,
  p_adjustment_order_id  uuid,
  p_reversal_id          uuid,
  p_lines                jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order    record;
  v_line     record;
  v_sold     double precision;
  v_claimed  double precision;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_reversal_id IS NULL OR p_adjustment_order_id IS NULL THEN
    RAISE EXCEPTION 'reversal_id_required' USING ERRCODE = 'P0001';
  END IF;

  -- Lock the parent: concurrent adjustments of one sale serialize here.
  SELECT * INTO v_order FROM public.orders
   WHERE id = p_parent_order_id AND business_id = p_business_id
   FOR UPDATE;
  IF NOT FOUND THEN
    -- The sale's own header has not landed yet: FK-deferred, retried.
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '23503';
  END IF;

  -- The winner retrying (lost response, crash before markDone): idempotent.
  IF EXISTS (SELECT 1 FROM public.sale_adjustment_claims
              WHERE adjustment_order_id = p_adjustment_order_id) THEN
    RETURN jsonb_build_object('replayed', true, 'reversal_id', p_reversal_id);
  END IF;

  IF v_order.status <> 'completed'
     OR EXISTS (SELECT 1 FROM public.order_reversals WHERE order_id = p_parent_order_id)
  THEN
    RAISE EXCEPTION 'order_not_returnable' USING ERRCODE = 'P0001';
  END IF;

  FOR v_line IN
    SELECT (l->>'order_item_id')::uuid AS order_item_id,
           sum((l->>'quantity')::double precision) AS quantity
      FROM jsonb_array_elements(p_lines) l
     GROUP BY 1
  LOOP
    IF v_line.quantity <= 0 THEN
      RAISE EXCEPTION 'bad_adjustment_quantity' USING ERRCODE = 'P0001';
    END IF;
    SELECT quantity INTO v_sold FROM public.order_items
     WHERE id = v_line.order_item_id AND order_id = p_parent_order_id
       AND business_id = p_business_id;
    IF NOT FOUND THEN
      -- The parent's line has not landed yet: FK-deferred, retried.
      RAISE EXCEPTION 'order_item_not_found' USING ERRCODE = '23503';
    END IF;
    SELECT COALESCE(sum((cl->>'quantity')::double precision), 0) INTO v_claimed
      FROM public.sale_adjustment_claims c,
           jsonb_array_elements(c.lines) cl
     WHERE c.parent_order_id = p_parent_order_id
       AND (cl->>'order_item_id')::uuid = v_line.order_item_id;
    IF v_claimed + v_line.quantity > v_sold + 0.0001 THEN
      RAISE EXCEPTION 'adjustment_exceeds_returnable' USING
        ERRCODE = 'P0001',
        DETAIL  = jsonb_build_object('order_item_id', v_line.order_item_id,
                                     'sold', v_sold, 'already_returned', v_claimed)::text;
    END IF;
  END LOOP;

  INSERT INTO public.sale_adjustment_claims (
    id, business_id, parent_order_id, adjustment_order_id, lines, performed_by
  ) VALUES (
    p_reversal_id, p_business_id, p_parent_order_id, p_adjustment_order_id,
    p_lines, p_actor_id
  );

  RETURN jsonb_build_object('replayed', false, 'reversal_id', p_reversal_id);
END;
$$;

REVOKE ALL ON FUNCTION public.pos_claim_sale_adjustment(uuid, uuid, uuid, uuid, uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_claim_sale_adjustment(uuid, uuid, uuid, uuid, uuid, jsonb)
  TO authenticated;

-- =========================================================================
-- 4. Full cancel refuses a sale with a part return (replaces 0227's body)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pos_claim_order_reversal(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_order_id             uuid,
  p_reversal_id          uuid,
  p_cancellation_reason  text DEFAULT NULL,
  p_cancelled_at         timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order     record;
  v_claim     record;
  v_detail    text;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_reversal_id IS NULL THEN
    RAISE EXCEPTION 'reversal_id_required' USING ERRCODE = 'P0001';
  END IF;

  -- Lock the order: concurrent claims of the same order serialize here.
  SELECT * INTO v_order FROM public.orders
   WHERE id = p_order_id AND business_id = p_business_id
   FOR UPDATE;

  IF NOT FOUND THEN
    -- The sale's own header has not landed yet (sold and reversed offline):
    -- FK-deferred on the phone, retried after the next drain pushes it.
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = '23503';
  END IF;

  SELECT * INTO v_claim FROM public.order_reversals WHERE order_id = p_order_id;

  IF FOUND AND v_claim.id = p_reversal_id THEN
    -- The winner retrying (lost response, crash before markDone): idempotent.
    RETURN jsonb_build_object('replayed', true, 'reversal_id', p_reversal_id);
  END IF;

  IF FOUND
     -- 0247 (#712): a sale that already has a part return cannot be fully
     -- cancelled from a phone that did not see it (the cancel would refund the
     -- returned goods twice). The loser re-reads the header and undoes.
     OR EXISTS (SELECT 1 FROM public.sale_adjustment_claims sac
                 WHERE sac.parent_order_id = p_order_id)
     OR v_order.status = 'refunded'
     OR (v_order.status = 'cancelled' AND (
           EXISTS (SELECT 1 FROM public.stock_transactions s
                    WHERE s.business_id = p_business_id
                      AND s.order_id = p_order_id
                      AND s.movement_type = 'return')
        OR EXISTS (SELECT 1 FROM public.payment_transactions pt
                    WHERE pt.business_id = p_business_id
                      AND pt.order_id = p_order_id
                      AND pt.type = 'refund')
        -- A credit sale with no stocked lines and nothing paid (e.g. Quick
        -- Sale lines on account) reverses ONLY its credit-balance legs:
        -- markCancelled's 'refund' credit / 'void' debit carry the order id.
        OR EXISTS (SELECT 1 FROM public.wallet_transactions wt
                    WHERE wt.business_id = p_business_id
                      AND wt.order_id = p_order_id
                      AND wt.reference_type IN ('refund', 'void'))))
  THEN
    -- Someone else reversed this order first. Rejected WHOLE: this phone's
    -- reversal rows are still held on the phone and never reach the cloud.
    -- DETAIL carries the cloud header so the loser can restore it exactly.
    v_detail := jsonb_build_object(
      'status',              v_order.status,
      'cancelled_at',        v_order.cancelled_at,
      'cancellation_reason', v_order.cancellation_reason,
      'last_updated_at',     v_order.last_updated_at
    )::text;
    RAISE EXCEPTION 'reversal_already_applied' USING
      ERRCODE = 'P0001',
      DETAIL  = v_detail;
  END IF;

  IF v_order.status NOT IN ('pending', 'completed', 'cancelled') THEN
    RAISE EXCEPTION 'cannot_reverse_status_%', v_order.status USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.order_reversals (
    id, business_id, order_id, performed_by, cancellation_reason, cancelled_at
  ) VALUES (
    p_reversal_id, p_business_id, p_order_id, p_actor_id, p_cancellation_reason,
    COALESCE(p_cancelled_at, now())
  );

  -- The header flips in the same transaction as the claim (the sticky trigger
  -- below forces the claim's values on this and every later header update).
  UPDATE public.orders
     SET status              = 'cancelled',
         cancelled_at        = COALESCE(p_cancelled_at, now()),
         cancellation_reason = p_cancellation_reason
   WHERE id = p_order_id;

  RETURN jsonb_build_object('replayed', false, 'reversal_id', p_reversal_id);
END;
$$;

-- =========================================================================
-- 5. The recost replay ignores adjustment orders (replaces 0239's body)
-- =========================================================================
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
    -- 0247 (#712): a sale ADJUSTMENT's minus lines are not sales. The part
    -- return's restored units come back as their own cancel_restore layer
    -- (fixed id from the adjustment line), while the parent's lines keep
    -- consuming their layers, so the replay never runs short.
    AND o.kind = 'sale';

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
