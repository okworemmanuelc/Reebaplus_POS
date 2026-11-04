-- 0251_claim_returns_added_goods.sql
--
-- #732 (PR B, ADR 0035 addendum): goods added to a completed sale by an edit can
-- be returned. The phone now names, in p_lines, the line it consumed: a sale line
-- (original lines first) or an edit's PLUS line (oldest edit first).
--
-- Only the lookup of what was sold changes: a claim line may also be a plus line
-- of an adjustment of this sale. Everything else is 0247's body, unchanged:
--   * same signature (CREATE OR REPLACE, no new parameter, no overload);
--   * same p_lines format, {"order_item_id", "quantity"}, so claims already
--     accepted from older builds (sale-line ids) keep counting;
--   * the parent row lock still serializes concurrent claims, and the per-line
--     sum still stops two phones returning more than the line holds;
--   * the winner's retry stays idempotent and a non-completed or reversed sale
--     stays refused.
--
-- A plus line that has not landed yet stays FK-deferred (23503), the same as a
-- parent line, so a return made right after the edit waits for the edit's rows.
--
-- DEPLOY: before any phone build carrying #732, or a return of added goods is
-- FK-deferred on the old body until its retries run out. Requires 0247 and 0249.
-- NOT DEPLOYED by the agent.

BEGIN;

-- p_lines: [{"order_item_id": <sale line or plus line id>, "quantity": <units>}]
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
    -- 0251 (#732): a sale line, or a plus line of an adjustment of this sale.
    -- A minus line is never a target.
    SELECT oi.quantity INTO v_sold
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
     WHERE oi.id = v_line.order_item_id
       AND oi.business_id = p_business_id
       AND oi.quantity > 0
       AND (oi.order_id = p_parent_order_id
            OR (o.kind = 'adjustment' AND o.adjusts_order_id = p_parent_order_id));
    IF NOT FOUND THEN
      -- The line has not landed yet: FK-deferred, retried.
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

COMMIT;
