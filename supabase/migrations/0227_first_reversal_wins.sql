-- 0227_first_reversal_wins.sql
--
-- #550 (PRD #337 slice d, stories 52a-52c): the cloud accepts exactly ONE
-- reversal (Cancel / Pending-tab Refund / the future Return) per Order. ADR 0032.
--
-- WHY. A reversal is many rows (compensating stock, payment, wallet, crate and
-- cost-layer rows plus the header). The phone used to upload them one table at a
-- time, so two phones that both reversed the same sale offline would BOTH land
-- their rows: money handed back twice in the books. The "already cancelled"
-- check only ever saw one phone's data.
--
-- HOW (claim-then-release, reusing the #121 hold machinery).
--   The phone writes its reversal locally exactly as before, but HOLDS every
--   outbox row it enqueued (held_by_order_id = the reversal id) behind ONE
--   envelope, `domain:pos_claim_order_reversal`. The drain calls this RPC:
--     • no claim yet  → insert the per-order marker, flip the header to
--                        `cancelled` (same transaction), return; the phone then
--                        RELEASES its held rows, which upload as ordinary rows.
--     • same reversal id already claimed → replay, `{replayed: true}` (the
--                        winner's retry is idempotent; nothing is written).
--     • a DIFFERENT reversal already claimed (or the order was reversed by a
--                        path that never claims: an older build's header push or
--                        the flag-held v2 pos_cancel_order, detected by its
--                        compensating rows) → P0001 `reversal_already_applied`,
--                        DETAIL = the cloud header. The losing phone discards its
--                        held rows (none of them ever reached the cloud — the
--                        rejection is whole), undoes its local reversal and
--                        alerts the CEO / Managers (`sale_refund_rejected`).
--
-- WHAT THIS ADDS
--   1. public.order_reversals — cloud-only (NOT a synced table, no Drift twin):
--      one row per reversed order, UNIQUE(order_id). RLS read-only to members;
--      written only by the definer RPC below.
--   2. public.pos_claim_order_reversal(...) — new RPC, new name (no overload).
--   3. Trigger trg_orders_reversal_sticky on public.orders: once an order is
--      claimed, a later header upsert cannot change its status / cancelled_at /
--      cancellation_reason (they are forced to the claim's); and a cancelled
--      order can never be flipped back to pending/completed by a late header
--      (e.g. phone B's Confirm landing after phone A's refund).
--
-- UNCHANGED: pos_cancel_order (v2, flag-held). Its own "already cancelled →
-- replay" check already makes it a no-op on a claimed order, and its rows are
-- detected as evidence by the claim. Enabling the v2 cancel flag is still gated
-- as before.
--
-- DEPLOY: on production BEFORE any phone build that offers the Return (#551)
-- and before the build carrying this client change (that build enqueues the
-- envelope; against a cloud without the RPC it would fail PGRST202, a
-- transient error, and the held reversal rows would wait — no data loss, but
-- the refund would not upload until this is deployed). Never together with 0193.

-- =========================================================================
-- 1. The per-order reversal marker
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.order_reversals (
  id                  uuid PRIMARY KEY,
  business_id         uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  order_id            uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  performed_by        uuid,
  cancellation_reason text,
  cancelled_at        timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  last_updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_reversals_one_per_order UNIQUE (order_id)
);

CREATE INDEX IF NOT EXISTS idx_order_reversals_business
  ON public.order_reversals (business_id);

ALTER TABLE public.order_reversals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "order_reversals_tenant_read" ON public.order_reversals;
CREATE POLICY "order_reversals_tenant_read" ON public.order_reversals
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()));

REVOKE INSERT, UPDATE, DELETE ON public.order_reversals FROM anon, authenticated;
GRANT SELECT ON public.order_reversals TO authenticated;

-- Every public table with business_id carries the live-sync signal (0147/0198
-- rule, enforced by broadcast_trigger_coverage_test).
DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.order_reversals;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.order_reversals
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- =========================================================================
-- 2. pos_claim_order_reversal — the first reversal wins
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

REVOKE ALL ON FUNCTION public.pos_claim_order_reversal(uuid, uuid, uuid, uuid, text, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_claim_order_reversal(uuid, uuid, uuid, uuid, text, timestamptz)
  TO authenticated;

-- =========================================================================
-- 3. A reversed order's cancellation is sticky
-- =========================================================================
CREATE OR REPLACE FUNCTION public._orders_reversal_sticky()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_claim record;
BEGIN
  SELECT cancellation_reason, cancelled_at INTO v_claim
    FROM public.order_reversals WHERE order_id = NEW.id;
  IF FOUND THEN
    NEW.status              := 'cancelled';
    NEW.cancelled_at        := v_claim.cancelled_at;
    NEW.cancellation_reason := v_claim.cancellation_reason;
  ELSIF OLD.status = 'cancelled' AND NEW.status IS DISTINCT FROM 'cancelled' THEN
    NEW.status              := OLD.status;
    NEW.cancelled_at        := OLD.cancelled_at;
    NEW.cancellation_reason := OLD.cancellation_reason;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._orders_reversal_sticky() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_orders_reversal_sticky ON public.orders;
CREATE TRIGGER trg_orders_reversal_sticky
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public._orders_reversal_sticky();
