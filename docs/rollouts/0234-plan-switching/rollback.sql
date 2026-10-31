-- Rollback for 0234_play_plan_switching.sql.
-- Restores the 0232 body of apply_play_purchase (same signature; 0232's
-- manual-grant rule and stamp stay). Keeps the three new columns: the #589
-- play-billing-verify writes them, so drop them only AFTER redeploying the
-- pre-#589 function (statements below, commented out). No businesses values
-- are touched.
BEGIN;

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

-- After redeploying the pre-#589 play-billing-verify:
-- DROP INDEX IF EXISTS public.idx_play_purchases_linked;
-- ALTER TABLE public.play_subscription_purchases
--   DROP COLUMN IF EXISTS linked_purchase_token,
--   DROP COLUMN IF EXISTS replaced_by_token,
--   DROP COLUMN IF EXISTS replaced_at;

DELETE FROM supabase_migrations.schema_migrations WHERE version = '0234';
COMMIT;
