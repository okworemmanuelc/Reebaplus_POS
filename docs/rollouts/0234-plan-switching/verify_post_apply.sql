-- Post-apply checks for 0234 (plan switching without double billing, #589).
-- Runs inside BEGIN ... ROLLBACK: fixture businesses and purchase rows are never
-- kept. Passing = no error; a failed check raises 'verify_0234_failed: <names>'.
-- Run as postgres / via `supabase db query --linked -f`.
--
-- The Edge Function skips apply_play_purchase() for a replaced token and holds
-- an early non-revoke EXPIRED (deno tests cover that). These checks cover the
-- SQL half: the new columns, and replaced rows no longer counting as "another
-- entitled purchase" on a lapse, while 0232's behaviour is unchanged.
BEGIN;

CREATE TEMP TABLE _v0234 (n serial, chk text, ok boolean) ON COMMIT DROP;

-- Structure ------------------------------------------------------------------
INSERT INTO _v0234 (chk, ok)
SELECT 'one apply_play_purchase signature (no overload)',
       (SELECT count(*) FROM pg_proc
         WHERE proname = 'apply_play_purchase'
           AND pronamespace = 'public'::regnamespace) = 1
UNION ALL
SELECT 'apply fn is service_role only',
       has_function_privilege('service_role',
         'public.apply_play_purchase(uuid,text,text,text,timestamptz)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated',
         'public.apply_play_purchase(uuid,text,text,text,timestamptz)', 'EXECUTE')
UNION ALL
SELECT 'replacement columns exist',
       (SELECT count(*) FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'play_subscription_purchases'
           AND column_name IN ('linked_purchase_token', 'replaced_by_token', 'replaced_at')) = 3
UNION ALL
SELECT '0232 stamp table still there',
       to_regclass('public.play_applied_entitlements') IS NOT NULL;

-- Behaviour --------------------------------------------------------------------
DO $$
DECLARE
  b_up   uuid := 'a0234000-0000-4000-8000-000000000001'; -- upgrade, then revoke new
  b_lap  uuid := 'a0234000-0000-4000-8000-000000000002'; -- old lapses after new
  b_def  uuid := 'a0234000-0000-4000-8000-000000000003'; -- deferred downgrade
  b_man  uuid := 'a0234000-0000-4000-8000-000000000004'; -- 0232 manual grant intact
  r      jsonb;
  b      record;
  x      timestamptz := now() + interval '20 days';
  y      timestamptz := now() + interval '40 days';
BEGIN
  INSERT INTO public.businesses (id, name, subscription_status, subscription_plan, current_period_end, trial_ends_at)
  VALUES (b_up,  'v0234 up',  'inactive', 'free', NULL, now()),
         (b_lap, 'v0234 lap', 'inactive', 'free', NULL, now()),
         (b_def, 'v0234 def', 'inactive', 'free', NULL, now()),
         (b_man, 'v0234 man', 'active', 'premium', now() + interval '30 days', now());

  -- 1. Basic -> Premium upgrade. Old basic row stays CANCELED-in-period (stale)
  --    and is marked replaced; then the NEW token is revoked: the stale old row
  --    must not keep the business paid.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_up, 'v0234-up-old', 'reebaplus_basic', 'monthly', 'ACTIVE', x);
  r := public.apply_play_purchase(b_up, 'reebaplus_basic', 'monthly', 'ACTIVE', x);
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time, linked_purchase_token)
  VALUES (b_up, 'v0234-up-new', 'reebaplus_premium', 'monthly', 'ACTIVE', x, 'v0234-up-old');
  UPDATE public.play_subscription_purchases
     SET state = 'CANCELED', replaced_by_token = 'v0234-up-new', replaced_at = now()
   WHERE purchase_token = 'v0234-up-old';
  r := public.apply_play_purchase(b_up, 'reebaplus_premium', 'monthly', 'ACTIVE', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_up;
  INSERT INTO _v0234 (chk, ok) VALUES ('upgrade applies premium',
    b.subscription_status = 'active' AND b.subscription_plan = 'premium' AND b.current_period_end = x);
  UPDATE public.play_subscription_purchases
     SET state = 'EXPIRED', expiry_time = now() - interval '1 minute'
   WHERE purchase_token = 'v0234-up-new';
  r := public.apply_play_purchase(b_up, 'reebaplus_premium', 'monthly', 'EXPIRED', now() - interval '1 minute');
  SELECT * INTO b FROM public.businesses WHERE id = b_up;
  INSERT INTO _v0234 (chk, ok) VALUES ('replaced stale row does not keep a revoked switch paid',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free'
    AND (r->>'downgraded')::boolean);

  -- 2. Old token's lapse reaching SQL after the new one is entitled (e.g. an
  --    old function version): the new token keeps the business paid.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_lap, 'v0234-lap-new', 'reebaplus_basic', 'yearly', 'ACTIVE', y);
  r := public.apply_play_purchase(b_lap, 'reebaplus_basic', 'yearly', 'ACTIVE', y);
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time, replaced_by_token)
  VALUES (b_lap, 'v0234-lap-old', 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 minute', 'v0234-lap-new');
  r := public.apply_play_purchase(b_lap, 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 minute');
  SELECT * INTO b FROM public.businesses WHERE id = b_lap;
  INSERT INTO _v0234 (chk, ok) VALUES ('old-token lapse never downgrades while new is entitled',
    b.subscription_status = 'active' AND b.subscription_plan = 'basic'
    AND b.billing_cycle = 'yearly' AND (r->>'downgraded')::boolean IS FALSE);

  -- 3. Deferred Premium -> Basic: the function verifies the NEW token whose
  --    owned item is still premium until renewal (x), then basic after (y).
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time, linked_purchase_token)
  VALUES (b_def, 'v0234-def-new', 'reebaplus_premium', 'monthly', 'ACTIVE', x, 'v0234-def-old');
  r := public.apply_play_purchase(b_def, 'reebaplus_premium', 'monthly', 'ACTIVE', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_def;
  INSERT INTO _v0234 (chk, ok) VALUES ('deferred downgrade keeps premium until renewal',
    b.subscription_plan = 'premium' AND b.current_period_end = x);
  UPDATE public.play_subscription_purchases
     SET product_id = 'reebaplus_basic', expiry_time = y
   WHERE purchase_token = 'v0234-def-new';
  r := public.apply_play_purchase(b_def, 'reebaplus_basic', 'monthly', 'ACTIVE', y);
  SELECT * INTO b FROM public.businesses WHERE id = b_def;
  INSERT INTO _v0234 (chk, ok) VALUES ('renewal applies the lower plan',
    b.subscription_plan = 'basic' AND b.current_period_end = y);

  -- 4. 0232 intact: a lapse still keeps a running manual grant.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_man, 'v0234-man', 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 day');
  r := public.apply_play_purchase(b_man, 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 day');
  SELECT * INTO b FROM public.businesses WHERE id = b_man;
  INSERT INTO _v0234 (chk, ok) VALUES ('0232 manual grant still survives a lapse',
    b.subscription_status = 'active' AND b.subscription_plan = 'premium'
    AND (r->>'kept_manual_grant')::boolean);
END $$;

SELECT n, chk, ok FROM _v0234 ORDER BY n;

DO $$
DECLARE v_failed text;
BEGIN
  SELECT string_agg(chk, '; ' ORDER BY n) INTO v_failed
    FROM _v0234 WHERE ok IS DISTINCT FROM true;
  IF v_failed IS NOT NULL THEN
    RAISE EXCEPTION 'verify_0234_failed: %', v_failed;
  END IF;
  RAISE NOTICE 'verify_0234 ok: % checks', (SELECT count(*) FROM _v0234);
END $$;

ROLLBACK;
