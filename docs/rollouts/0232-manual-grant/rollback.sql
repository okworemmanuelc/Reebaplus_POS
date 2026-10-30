-- Rollback for 0232_manual_grant_survives_play_lapse.sql.
-- Restores the 0225 body of apply_play_purchase (same signature) and drops the
-- cloud-only stamp table. Does not touch businesses values.
BEGIN;

-- Applies a verified purchase to the business.
--   p_state: Play SubscriptionPurchaseV2 state without the prefix, e.g.
--   ACTIVE, IN_GRACE_PERIOD, CANCELED, ON_HOLD, PAUSED, EXPIRED, PENDING.
-- Entitled = ACTIVE | IN_GRACE_PERIOD | (CANCELED with expiry in the future).
-- A lapse only downgrades when the business has no OTHER entitled purchase.
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
  v_plan     text;
  v_cycle    text;
  v_entitled boolean;
  v_other    boolean;
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

  IF v_entitled THEN
    UPDATE public.businesses
       SET subscription_plan   = v_plan,
           billing_cycle       = v_cycle,
           subscription_status = 'active',
           current_period_end  = p_expiry_time
     WHERE id = p_business_id;
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

  IF NOT v_other THEN
    UPDATE public.businesses
       SET subscription_plan   = 'free',
           billing_cycle       = NULL,
           subscription_status = 'inactive',
           current_period_end  = p_expiry_time
     WHERE id = p_business_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', NOT v_other);
END $$;

REVOKE ALL ON FUNCTION public.apply_play_purchase(uuid, text, text, text, timestamptz)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_play_purchase(uuid, text, text, text, timestamptz)
  TO service_role;

DROP TABLE IF EXISTS public.play_applied_entitlements;

DELETE FROM supabase_migrations.schema_migrations WHERE version = '0232';
COMMIT;
