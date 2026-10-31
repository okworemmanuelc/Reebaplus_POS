-- Post-apply checks for 0235 (businesses.billing_issue, #591).
-- Runs inside BEGIN ... ROLLBACK: fixture businesses and purchase rows are
-- never kept (any pg_net push request queued by the trigger is rolled back
-- too, and the fixtures have no owner, so none is queued). Passing = no error.
-- Any failed check raises 'verify_0235_failed: <check names>'.
-- Run as postgres / via `supabase db query --linked -f`.
BEGIN;

CREATE TEMP TABLE _v0235 (n serial, chk text, ok boolean) ON COMMIT DROP;

-- Structure ------------------------------------------------------------------
INSERT INTO _v0235 (chk, ok)
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
SELECT 'apply fn keeps 0234 replaced-token rule',
       (SELECT prosrc FROM pg_proc WHERE proname = 'apply_play_purchase'
         AND pronamespace = 'public'::regnamespace) LIKE '%replaced_by_token IS NULL%'
UNION ALL
SELECT 'billing_issue column + check',
       EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'businesses'
                  AND column_name = 'billing_issue' AND is_nullable = 'YES')
       AND EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'businesses_billing_issue_check'
                      AND conrelid = 'public.businesses'::regclass)
UNION ALL
SELECT 'update guard resets billing_issue for customers',
       (SELECT prosrc FROM pg_proc WHERE proname = 'enforce_subscription_immutable'
         AND pronamespace = 'public'::regnamespace)
         LIKE '%NEW.billing_issue        := OLD.billing_issue%'
UNION ALL
SELECT 'grace push trigger present',
       EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgname = 'trg_send_push_billing_grace'
                  AND tgrelid = 'public.businesses'::regclass)
UNION ALL
SELECT 'helpers hidden from clients',
       NOT has_function_privilege('authenticated',
         'public._business_values_play_stamped(uuid,text,timestamptz)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated',
         'public.send_push_on_billing_grace()', 'EXECUTE');

-- Behaviour --------------------------------------------------------------------
DO $$
DECLARE
  b_grace  uuid := 'a0235000-0000-4000-8000-000000000001'; -- grace -> recover
  b_hold   uuid := 'a0235000-0000-4000-8000-000000000002'; -- grace -> hold -> expired
  b_admin  uuid := 'a0235000-0000-4000-8000-000000000003'; -- hold -> admin activates
  b_manual uuid := 'a0235000-0000-4000-8000-000000000004'; -- hold under a manual grant
  b_pend   uuid := 'a0235000-0000-4000-8000-000000000005'; -- PENDING leaves it alone
  r        jsonb;
  b        record;
  x        timestamptz := now() + interval '30 days';
BEGIN
  INSERT INTO public.businesses (id, name, subscription_status, subscription_plan, current_period_end)
  VALUES (b_grace,  'v0235 grace',  'inactive', 'free',    NULL),
         (b_hold,   'v0235 hold',   'inactive', 'free',    NULL),
         (b_admin,  'v0235 admin',  'inactive', 'free',    NULL),
         (b_manual, 'v0235 manual', 'active',   'premium', now() + interval '60 days'),
         (b_pend,   'v0235 pend',   'inactive', 'free',    NULL);

  -- 1. Payment fails: grace keeps the plan and flags 'grace'.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_grace, 'v0235-grace', 'reebaplus_premium', 'monthly', 'IN_GRACE_PERIOD', x);
  r := public.apply_play_purchase(b_grace, 'reebaplus_premium', 'monthly', 'IN_GRACE_PERIOD', x);
  SELECT * INTO b FROM public.businesses WHERE id = b_grace;
  INSERT INTO _v0235 (chk, ok) VALUES ('grace keeps plan + flags grace',
    b.subscription_status = 'active' AND b.subscription_plan = 'premium'
    AND b.billing_issue = 'grace' AND r->>'billing_issue' = 'grace');

  -- 2. Repeat grace RTDN with a later end date: still grace (guard sees Play).
  r := public.apply_play_purchase(b_grace, 'reebaplus_premium', 'monthly', 'IN_GRACE_PERIOD', x + interval '1 day');
  SELECT * INTO b FROM public.businesses WHERE id = b_grace;
  INSERT INTO _v0235 (chk, ok) VALUES ('repeat grace stays grace',
    b.billing_issue = 'grace' AND b.current_period_end = x + interval '1 day');

  -- 3. Payment recovered: ACTIVE clears it.
  r := public.apply_play_purchase(b_grace, 'reebaplus_premium', 'monthly', 'ACTIVE', x + interval '31 days');
  SELECT * INTO b FROM public.businesses WHERE id = b_grace;
  INSERT INTO _v0235 (chk, ok) VALUES ('recovery clears billing_issue',
    b.billing_issue IS NULL AND b.subscription_plan = 'premium');

  -- 4. Grace runs out: ON_HOLD downgrades to Free and flags 'hold'.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_hold, 'v0235-hold', 'reebaplus_basic', 'monthly', 'IN_GRACE_PERIOD', x);
  r := public.apply_play_purchase(b_hold, 'reebaplus_basic', 'monthly', 'IN_GRACE_PERIOD', x);
  UPDATE public.play_subscription_purchases SET state = 'ON_HOLD', expiry_time = now() - interval '1 minute'
   WHERE purchase_token = 'v0235-hold';
  r := public.apply_play_purchase(b_hold, 'reebaplus_basic', 'monthly', 'ON_HOLD', now() - interval '1 minute');
  SELECT * INTO b FROM public.businesses WHERE id = b_hold;
  INSERT INTO _v0235 (chk, ok) VALUES ('hold downgrades + flags hold',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free'
    AND b.billing_issue = 'hold' AND (r->>'downgraded')::boolean);

  -- 5. Hold ends without payment: EXPIRED clears the flag, stays Free.
  UPDATE public.play_subscription_purchases SET state = 'EXPIRED' WHERE purchase_token = 'v0235-hold';
  r := public.apply_play_purchase(b_hold, 'reebaplus_basic', 'monthly', 'EXPIRED', now() - interval '1 minute');
  SELECT * INTO b FROM public.businesses WHERE id = b_hold;
  INSERT INTO _v0235 (chk, ok) VALUES ('expired after hold clears flag',
    b.billing_issue IS NULL AND b.subscription_plan = 'free');

  -- 6. On hold, then an admin activates the shop by hand: flag cleared.
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_admin, 'v0235-admin', 'reebaplus_basic', 'yearly', 'ON_HOLD', now() - interval '1 hour');
  r := public.apply_play_purchase(b_admin, 'reebaplus_basic', 'yearly', 'ON_HOLD', now() - interval '1 hour');
  SELECT * INTO b FROM public.businesses WHERE id = b_admin;
  INSERT INTO _v0235 (chk, ok) VALUES ('admin fixture on hold', b.billing_issue = 'hold');
  UPDATE public.businesses
     SET subscription_status = 'active', subscription_plan = 'basic',
         current_period_end = now() + interval '90 days'
   WHERE id = b_admin;
  SELECT * INTO b FROM public.businesses WHERE id = b_admin;
  INSERT INTO _v0235 (chk, ok) VALUES ('manual admin activation clears flag',
    b.billing_issue IS NULL AND b.subscription_status = 'active');

  -- 7. ON_HOLD while a manual grant runs: shop keeps its grant, no flag.
  UPDATE public.businesses SET billing_issue = 'grace' WHERE id = b_manual; -- as operator
  INSERT INTO public.play_subscription_purchases (business_id, purchase_token, product_id, base_plan_id, state, expiry_time)
  VALUES (b_manual, 'v0235-manual', 'reebaplus_basic', 'monthly', 'ON_HOLD', now() - interval '1 hour');
  r := public.apply_play_purchase(b_manual, 'reebaplus_basic', 'monthly', 'ON_HOLD', now() - interval '1 hour');
  SELECT * INTO b FROM public.businesses WHERE id = b_manual;
  INSERT INTO _v0235 (chk, ok) VALUES ('hold under manual grant: kept, no flag',
    b.subscription_plan = 'premium' AND b.billing_issue IS NULL
    AND (r->>'kept_manual_grant')::boolean);

  -- 8. PENDING leaves an existing flag alone.
  UPDATE public.businesses SET billing_issue = 'hold' WHERE id = b_pend; -- as operator
  r := public.apply_play_purchase(b_pend, 'reebaplus_basic', 'monthly', 'PENDING', NULL);
  SELECT * INTO b FROM public.businesses WHERE id = b_pend;
  INSERT INTO _v0235 (chk, ok) VALUES ('pending leaves flag unchanged',
    b.billing_issue = 'hold' AND (r->>'unchanged')::boolean);
END $$;

SELECT n, chk, ok FROM _v0235 ORDER BY n;

DO $$
DECLARE v_failed text;
BEGIN
  SELECT string_agg(chk, '; ' ORDER BY n) INTO v_failed
    FROM _v0235 WHERE ok IS DISTINCT FROM true;
  IF v_failed IS NOT NULL THEN
    RAISE EXCEPTION 'verify_0235_failed: %', v_failed;
  END IF;
  RAISE NOTICE 'verify_0235 ok: % checks', (SELECT count(*) FROM _v0235);
END $$;

ROLLBACK;
