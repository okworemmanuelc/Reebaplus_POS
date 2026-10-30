-- Post-apply checks for 0232 (manual admin grants survive a Play lapse, #592).
-- Runs inside BEGIN ... ROLLBACK: the fixture businesses and purchase rows are
-- never kept. Passing = no error. Any failed check raises
-- 'verify_0232_failed: <check names>'. (psql also prints the results table.)
-- Run as postgres / via `supabase db query --linked -f`.
BEGIN;

CREATE TEMP TABLE _v0232 (n serial, chk text, ok boolean) ON COMMIT DROP;

-- Structure ------------------------------------------------------------------
INSERT INTO _v0232 (chk, ok)
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
       AND NOT has_function_privilege('anon',
         'public.apply_play_purchase(uuid,text,text,text,timestamptz)', 'EXECUTE')
UNION ALL
SELECT 'stamp table rls forced',
       (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
         WHERE oid = 'public.play_applied_entitlements'::regclass)
UNION ALL
SELECT 'stamp table hidden from authenticated',
       NOT has_table_privilege('authenticated', 'public.play_applied_entitlements', 'SELECT');

-- Behaviour --------------------------------------------------------------------
DO $$
DECLARE
  b_run    uuid := 'a0232000-0000-4000-8000-000000000001'; -- manual, running
  b_ever   uuid := 'a0232000-0000-4000-8000-000000000002'; -- manual, forever
  b_old    uuid := 'a0232000-0000-4000-8000-000000000003'; -- manual, expired
  b_play   uuid := 'a0232000-0000-4000-8000-000000000004'; -- Play only (revoke)
  b_legacy uuid := 'a0232000-0000-4000-8000-000000000005'; -- Play pre-0232, no stamp
  b_paid   uuid := 'a0232000-0000-4000-8000-000000000006'; -- entitled beats manual
  b_cxl    uuid := 'a0232000-0000-4000-8000-000000000007'; -- stale CANCELED vs forever
  b_prec   uuid := 'a0232000-0000-4000-8000-000000000008'; -- precision drift
  r        jsonb;
  b        record;
  x        timestamptz;
BEGIN
  INSERT INTO public.businesses (id, name, subscription_status, subscription_plan, current_period_end, trial_ends_at)
  VALUES (b_run,    'v0232 run',    'active', 'premium', now() + interval '30 days', now()),
         (b_ever,   'v0232 ever',   'active', 'premium', NULL,                       now()),
         (b_old,    'v0232 old',    'active', 'basic',   now() - interval '1 day',   now()),
         (b_play,   'v0232 play',   'inactive', 'free',  NULL,                       now()),
         (b_legacy, 'v0232 legacy', 'active', 'basic',   now() + interval '5 days',  now()),
         (b_paid,   'v0232 paid',   'active', 'basic',   now() + interval '10 days', now()),
         (b_cxl,    'v0232 cxl',    'active', 'premium', NULL,                       now()),
         (b_prec,   'v0232 prec',   'inactive', 'free',  NULL,                       now());

  -- 1. Lapse while a manual grant is running (old cancelled Play row exists).
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_run, 'v0232-run', 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 day');
  r := public.apply_play_purchase(b_run, 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 day');
  SELECT * INTO b FROM public.businesses WHERE id = b_run;
  INSERT INTO _v0232 (chk, ok) VALUES ('lapse keeps running manual grant',
    b.subscription_status = 'active' AND b.subscription_plan = 'premium'
    AND b.current_period_end > now() AND (r->>'kept_manual_grant')::boolean);

  -- 2. Lapse with a manual forever grant.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_ever, 'v0232-ever', 'reebaplus_premium', 'yearly', 'EXPIRED', now() - interval '2 hours');
  r := public.apply_play_purchase(b_ever, 'reebaplus_premium', 'yearly', 'EXPIRED', now() - interval '2 hours');
  SELECT * INTO b FROM public.businesses WHERE id = b_ever;
  INSERT INTO _v0232 (chk, ok) VALUES ('lapse keeps manual forever grant',
    b.subscription_status = 'active' AND b.subscription_plan = 'premium'
    AND b.current_period_end IS NULL AND (r->>'kept_manual_grant')::boolean);

  -- 3. Lapse after the manual grant has run out.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_old, 'v0232-old', 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '3 days');
  r := public.apply_play_purchase(b_old, 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '3 days');
  SELECT * INTO b FROM public.businesses WHERE id = b_old;
  INSERT INTO _v0232 (chk, ok) VALUES ('lapse downgrades expired manual grant',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free'
    AND (r->>'downgraded')::boolean);

  -- 4. Play only: buy, then refund/revoke (Play rewrites expiry to revoke time).
  x := now() + interval '30 days';
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_play, 'v0232-play', 'reebaplus_premium', 'monthly', 'ACTIVE', x);
  r := public.apply_play_purchase(b_play, 'reebaplus_premium', 'monthly', 'ACTIVE', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_play;
  INSERT INTO _v0232 (chk, ok) VALUES ('play purchase activates + stamps',
    b.subscription_status = 'active' AND b.subscription_plan = 'premium'
    AND b.current_period_end = x
    AND EXISTS (SELECT 1 FROM public.play_applied_entitlements e
                 WHERE e.business_id = b_play AND e.period_end = x AND e.plan = 'premium'));
  UPDATE public.play_subscription_purchases
     SET state = 'EXPIRED', expiry_time = now() - interval '1 minute'
   WHERE purchase_token = 'v0232-play';
  r := public.apply_play_purchase(b_play, 'reebaplus_premium', 'monthly', 'EXPIRED', now() - interval '1 minute');
  SELECT * INTO b FROM public.businesses WHERE id = b_play;
  INSERT INTO _v0232 (chk, ok) VALUES ('play-only lapse (revoke) downgrades',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free'
    AND (r->>'downgraded')::boolean);

  -- 5. Play-written before 0232 (no stamp): matched by the purchase row.
  SELECT current_period_end INTO x FROM public.businesses WHERE id = b_legacy;
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_legacy, 'v0232-legacy', 'reebaplus_basic', 'monthly', 'ON_HOLD', x);
  r := public.apply_play_purchase(b_legacy, 'reebaplus_basic', 'monthly', 'ON_HOLD', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_legacy;
  INSERT INTO _v0232 (chk, ok) VALUES ('pre-0232 play plan (no stamp) downgrades',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free');

  -- 6. An entitled purchase overwrites a running manual grant.
  x := now() + interval '31 days';
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_paid, 'v0232-paid', 'reebaplus_premium', 'monthly', 'ACTIVE', x);
  r := public.apply_play_purchase(b_paid, 'reebaplus_premium', 'monthly', 'ACTIVE', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_paid;
  INSERT INTO _v0232 (chk, ok) VALUES ('entitled purchase overwrites manual grant',
    b.subscription_plan = 'premium' AND b.billing_cycle = 'monthly'
    AND b.current_period_end = x);

  -- 7. Stale CANCELED (still in period) never replaces a better forever grant.
  x := now() + interval '10 days';
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_cxl, 'v0232-cxl', 'reebaplus_basic', 'monthly', 'CANCELED', x);
  r := public.apply_play_purchase(b_cxl, 'reebaplus_basic', 'monthly', 'CANCELED', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_cxl;
  INSERT INTO _v0232 (chk, ok) VALUES ('stale CANCELED keeps better forever grant',
    b.subscription_plan = 'premium' AND b.current_period_end IS NULL
    AND (r->>'kept_manual_grant')::boolean);

  -- 8. Play-written end date drifted by < 1 s (console round trip): still Play.
  x := now() + interval '20 days';
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_prec, 'v0232-prec', 'reebaplus_basic', 'yearly', 'ACTIVE', x);
  r := public.apply_play_purchase(b_prec, 'reebaplus_basic', 'yearly', 'ACTIVE', x);
  UPDATE public.businesses SET current_period_end = date_trunc('milliseconds', x) - interval '400 microseconds'
   WHERE id = b_prec;
  UPDATE public.play_subscription_purchases SET state = 'ON_HOLD' WHERE purchase_token = 'v0232-prec';
  r := public.apply_play_purchase(b_prec, 'reebaplus_basic', 'yearly', 'ON_HOLD', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_prec;
  INSERT INTO _v0232 (chk, ok) VALUES ('sub-second drift still counts as Play',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free');
END $$;

SELECT n, chk, ok FROM _v0232 ORDER BY n;

DO $$
DECLARE v_failed text;
BEGIN
  SELECT string_agg(chk, '; ' ORDER BY n) INTO v_failed
    FROM _v0232 WHERE ok IS DISTINCT FROM true;
  IF v_failed IS NOT NULL THEN
    RAISE EXCEPTION 'verify_0232_failed: %', v_failed;
  END IF;
  RAISE NOTICE 'verify_0232 ok: % checks', (SELECT count(*) FROM _v0232);
END $$;

ROLLBACK;
