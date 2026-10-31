-- Post-apply checks for 0231 (no more free trials, #587).
-- Runs inside BEGIN ... ROLLBACK: fixture businesses are never kept.
-- Passing = no error. A failed check raises 'verify_0231_failed: <names>'.
-- Run as postgres / via `supabase db query --linked -f`.
BEGIN;

CREATE TEMP TABLE _v0231 (n serial, chk text, ok boolean) ON COMMIT DROP;

-- Structure ------------------------------------------------------------------
INSERT INTO _v0231 (chk, ok)
SELECT 'status default inactive',
       (SELECT column_default FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'businesses'
           AND column_name = 'subscription_status') LIKE '''inactive''%'
UNION ALL
SELECT 'plan has no column default (trigger fills it)',
       (SELECT column_default FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'businesses'
           AND column_name = 'subscription_plan') IS NULL
UNION ALL
SELECT 'one set_business_trial_end (no overload)',
       (SELECT count(*) FROM pg_proc
         WHERE proname = 'set_business_trial_end'
           AND pronamespace = 'public'::regnamespace) = 1
UNION ALL
SELECT 'insert trigger present',
       EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgname = 'trg_businesses_set_trial_end'
                  AND tgrelid = 'public.businesses'::regclass)
UNION ALL
SELECT 'no ended trial left',
       NOT EXISTS (SELECT 1 FROM public.businesses
                    WHERE subscription_status = 'trial'
                      AND trial_ends_at <= now());

-- Behaviour --------------------------------------------------------------------
DO $$
DECLARE
  b_new   uuid := 'a0231000-0000-4000-8000-000000000001'; -- plain insert (like complete_onboarding)
  b_trial uuid := 'a0231000-0000-4000-8000-000000000002'; -- console explicit trial
  b_paid  uuid := 'a0231000-0000-4000-8000-000000000003'; -- console explicit active
  b_cust  uuid := 'a0231000-0000-4000-8000-000000000004'; -- customer role tries trial
  b_upd   uuid := 'a0231000-0000-4000-8000-000000000005'; -- console UPDATE to any status
  b       record;
BEGIN
  -- 1. A new business with no subscription columns starts on Free.
  INSERT INTO public.businesses (id, name) VALUES (b_new, 'v0231 new');
  SELECT * INTO b FROM public.businesses WHERE id = b_new;
  INSERT INTO _v0231 (chk, ok) VALUES ('new business = inactive/free/NULL trial',
    b.subscription_status = 'inactive' AND b.subscription_plan = 'free'
    AND b.trial_ends_at IS NULL);

  -- 2. Operator explicit trial still works (end date + premium stamped).
  INSERT INTO public.businesses (id, name, subscription_status) VALUES (b_trial, 'v0231 trial', 'trial');
  SELECT * INTO b FROM public.businesses WHERE id = b_trial;
  INSERT INTO _v0231 (chk, ok) VALUES ('operator trial insert honoured',
    b.subscription_status = 'trial' AND b.subscription_plan = 'premium'
    AND b.trial_ends_at > now());

  -- 3. Operator explicit active insert kept.
  INSERT INTO public.businesses (id, name, subscription_status, subscription_plan, current_period_end)
  VALUES (b_paid, 'v0231 paid', 'active', 'basic', now() + interval '30 days');
  SELECT * INTO b FROM public.businesses WHERE id = b_paid;
  INSERT INTO _v0231 (chk, ok) VALUES ('operator active insert kept',
    b.subscription_status = 'active' AND b.subscription_plan = 'basic');

  -- 4. Customer role cannot insert a trial / paid plan.
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.businesses (id, name, subscription_status, subscription_plan, trial_ends_at)
    VALUES (b_cust, 'v0231 cust', 'trial', 'premium', now() + interval '30 days');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    NULL; -- RLS may reject the insert outright; that also passes
  END;
  RESET ROLE;
  SELECT * INTO b FROM public.businesses WHERE id = b_cust;
  INSERT INTO _v0231 (chk, ok) VALUES ('customer insert forced to free',
    b.id IS NULL OR (b.subscription_status = 'inactive' AND b.subscription_plan = 'free'
                     AND b.trial_ends_at IS NULL));

  -- 5. Operator UPDATE can still set any status.
  INSERT INTO public.businesses (id, name) VALUES (b_upd, 'v0231 upd');
  UPDATE public.businesses SET subscription_status = 'trial', subscription_plan = 'premium',
         trial_ends_at = now() + interval '7 days' WHERE id = b_upd;
  SELECT * INTO b FROM public.businesses WHERE id = b_upd;
  INSERT INTO _v0231 (chk, ok) VALUES ('operator update to trial', b.subscription_status = 'trial');
  UPDATE public.businesses SET subscription_status = 'active', subscription_plan = 'premium',
         current_period_end = NULL WHERE id = b_upd;
  SELECT * INTO b FROM public.businesses WHERE id = b_upd;
  INSERT INTO _v0231 (chk, ok) VALUES ('operator update to active', b.subscription_status = 'active');
END $$;

SELECT n, chk, ok FROM _v0231 ORDER BY n;

DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(chk, ', ' ORDER BY n) INTO v_bad FROM _v0231 WHERE NOT ok;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'verify_0231_failed: %', v_bad;
  END IF;
END $$;

ROLLBACK;
