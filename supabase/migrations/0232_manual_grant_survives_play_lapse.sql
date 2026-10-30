-- 0232_manual_grant_survives_play_lapse.sql
--
-- #592 (PRD #584 slice 8). A Play subscription ending must never pull a shop
-- below a plan an admin gave it by hand that has not run out yet.
-- DEPENDS ON 0224 + 0225. Re-issues apply_play_purchase() with the SAME
-- signature (a new signature would create an overload, causing PGRST203).
-- Idempotent: safe to run twice.
--
-- THE RULE
-- --------
-- "Play-written" = the business's current plan + end date are what Play last
-- put there. It is Play-written when EITHER:
--   (a) the stamp in play_applied_entitlements (written by every entitled
--       apply below) has the same plan and the same end date (both NULL, or
--       within 1 second); OR
--   (b) a play_subscription_purchases row of the business has the same plan
--       (from product_id) and an expiry_time within 1 second of the end date.
--       (b) covers businesses that Play set before this migration (no stamp).
-- "Manual grant still running" = subscription_status = 'active'
--   AND subscription_plan IN ('basic','premium')
--   AND (current_period_end IS NULL OR current_period_end > now())
--   AND NOT Play-written.
--
-- Effect:
--   * Not entitled (EXPIRED / ON_HOLD / PAUSED / revoked / CANCELED past
--     expiry): if there is no other entitled purchase AND no manual grant is
--     running, downgrade to free/inactive (as 0225). A running manual grant
--     is left untouched ('kept_manual_grant': true).
--   * Entitled (ACTIVE / IN_GRACE_PERIOD / CANCELED before expiry): overwrites
--     a manual grant (they paid) and stamps play_applied_entitlements. One
--     exception: a CANCELED (not renewing) purchase does NOT overwrite a
--     running manual grant that is at least as good on BOTH plan and end date
--     (forever, or ending on/after the Play expiry). This stops a late RTDN for
--     a cancelled token from replacing a forever partner grant, and the shop
--     never loses anything it paid for.
--
-- Why the stamp (and not only rule b): a refund/revoke rewrites the purchase
-- row's expiry_time to the revoke time, so the old end date on the business no
-- longer matches any row and would look like a manual grant. The stamp keeps
-- the last end date Play wrote. Why 1 second: Play sends milliseconds; a
-- console round trip through a JS Date can drop sub-millisecond digits.
--
-- Edge cases:
--   * Admin extends a business that has an old cancelled Play row: the new end
--     date matches neither the stamp nor the row, so the lapse keeps it.
--   * Late RTDN for a stale token: lapse never beats a running manual grant;
--     a stale CANCELED entitlement never beats a better manual grant.
--   * Admin re-saves exactly the values Play wrote: indistinguishable, treated
--     as Play (to protect, give a different end date or plan).
--
-- play_applied_entitlements is cloud-only (not synced to the app), one row per
-- business, written only by this function (service_role).

BEGIN;

CREATE TABLE IF NOT EXISTS public.play_applied_entitlements (
  business_id    uuid PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  plan           text NOT NULL,
  billing_cycle  text,
  period_end     timestamptz,
  applied_at     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.play_applied_entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.play_applied_entitlements FORCE ROW LEVEL SECURITY;

REVOKE ALL ON public.play_applied_entitlements FROM public, anon, authenticated;
GRANT ALL ON public.play_applied_entitlements TO service_role;

DROP POLICY IF EXISTS play_applied_service_all ON public.play_applied_entitlements;
CREATE POLICY play_applied_service_all ON public.play_applied_entitlements
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.apply_play_purchase(
  p_business_id  uuid,
  p_product_id   text,
  p_base_plan_id text,
  p_state        text,
  p_expiry_time  timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_plan         text;
  v_cycle        text;
  v_entitled     boolean;
  v_other        boolean;
  v_status       text;
  v_cur_plan     text;
  v_cur_end      timestamptz;
  v_play_written boolean;
  v_manual       boolean;
BEGIN
  v_plan := CASE p_product_id
    WHEN 'reebaplus_basic'   THEN 'basic'
    WHEN 'reebaplus_premium' THEN 'premium'
    ELSE NULL END;
  IF v_plan IS NULL THEN
    RAISE EXCEPTION 'unknown_product %', p_product_id;
  END IF;
  IF p_base_plan_id NOT IN ('monthly', 'yearly') THEN
    RAISE EXCEPTION 'unknown_base_plan %', p_base_plan_id;
  END IF;
  v_cycle := p_base_plan_id;

  v_entitled := p_state IN ('ACTIVE', 'IN_GRACE_PERIOD')
    OR (p_state = 'CANCELED' AND p_expiry_time IS NOT NULL AND p_expiry_time > now());

  -- Lock the business so an app verify and an RTDN cannot interleave.
  SELECT b.subscription_status, b.subscription_plan, b.current_period_end
    INTO v_status, v_cur_plan, v_cur_end
    FROM public.businesses b
   WHERE b.id = p_business_id
   FOR UPDATE;

  v_play_written :=
    EXISTS (
      SELECT 1 FROM public.play_applied_entitlements e
       WHERE e.business_id = p_business_id
         AND e.plan IS NOT DISTINCT FROM v_cur_plan
         AND ((e.period_end IS NULL AND v_cur_end IS NULL)
              OR abs(extract(epoch FROM (e.period_end - v_cur_end))) < 1)
    )
    OR EXISTS (
      SELECT 1 FROM public.play_subscription_purchases p
       WHERE p.business_id = p_business_id
         AND p.expiry_time IS NOT NULL
         AND v_cur_end IS NOT NULL
         AND abs(extract(epoch FROM (p.expiry_time - v_cur_end))) < 1
         AND (CASE p.product_id
                WHEN 'reebaplus_basic'   THEN 'basic'
                WHEN 'reebaplus_premium' THEN 'premium'
              END) IS NOT DISTINCT FROM v_cur_plan
    );

  v_manual := COALESCE(
    v_status = 'active'
    AND v_cur_plan IN ('basic', 'premium')
    AND (v_cur_end IS NULL OR v_cur_end > now())
    AND NOT v_play_written,
    false);

  IF v_entitled THEN
    -- A cancelled (winding-down) purchase never replaces a manual grant that
    -- is at least as good on plan AND end date.
    IF v_manual AND p_state = 'CANCELED'
       AND (v_cur_end IS NULL OR v_cur_end >= p_expiry_time)
       AND (v_cur_plan = 'premium' OR v_plan = 'basic') THEN
      RETURN jsonb_build_object('ok', true, 'entitled', true, 'unchanged', true,
                                'kept_manual_grant', true);
    END IF;

    UPDATE public.businesses
       SET subscription_plan   = v_plan,
           billing_cycle       = v_cycle,
           subscription_status = 'active',
           current_period_end  = p_expiry_time
     WHERE id = p_business_id;

    IF FOUND THEN
      INSERT INTO public.play_applied_entitlements AS e
             (business_id, plan, billing_cycle, period_end, applied_at)
      VALUES (p_business_id, v_plan, v_cycle, p_expiry_time, now())
      ON CONFLICT (business_id) DO UPDATE
         SET plan          = EXCLUDED.plan,
             billing_cycle = EXCLUDED.billing_cycle,
             period_end    = EXCLUDED.period_end,
             applied_at    = EXCLUDED.applied_at;
    END IF;
    RETURN jsonb_build_object('ok', true, 'entitled', true, 'plan', v_plan, 'billing_cycle', v_cycle);
  END IF;

  -- PENDING never changes entitlement.
  IF p_state = 'PENDING' THEN
    RETURN jsonb_build_object('ok', true, 'entitled', false, 'unchanged', true);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.play_subscription_purchases p
     WHERE p.business_id = p_business_id
       AND p.expiry_time > now()
       AND p.state IN ('ACTIVE', 'IN_GRACE_PERIOD', 'CANCELED')
       AND NOT (p.product_id = p_product_id AND p.base_plan_id = p_base_plan_id
                AND p.state = p_state AND p.expiry_time IS NOT DISTINCT FROM p_expiry_time)
  ) INTO v_other;

  IF v_other THEN
    RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', false);
  END IF;

  IF v_manual THEN
    RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', false,
                              'kept_manual_grant', true);
  END IF;

  UPDATE public.businesses
     SET subscription_plan   = 'free',
         billing_cycle       = NULL,
         subscription_status = 'inactive',
         current_period_end  = p_expiry_time
   WHERE id = p_business_id;
  RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', true);
END $$;

REVOKE ALL ON FUNCTION public.apply_play_purchase(uuid, text, text, text, timestamptz)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_play_purchase(uuid, text, text, text, timestamptz)
  TO service_role;

COMMIT;
