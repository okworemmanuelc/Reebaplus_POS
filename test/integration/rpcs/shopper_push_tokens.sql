-- #476 Tier2 companion (migration 0200): Shopper push tokens. Run on the
-- dedicated reebaplus-dev project only, after 0200 is applied. Every fixture
-- (auth users, business, profile, devices rows) rolls back.
BEGIN;
SELECT set_config('test.shopper', gen_random_uuid()::text, true);
SELECT set_config('test.staff', gen_random_uuid()::text, true);
SELECT set_config('test.biz', gen_random_uuid()::text, true);
INSERT INTO auth.users(id, email) VALUES
  (current_setting('test.shopper')::uuid, current_setting('test.shopper') || '@example.invalid'),
  (current_setting('test.staff')::uuid, current_setting('test.staff') || '@example.invalid');
INSERT INTO public.businesses(id, name)
VALUES (current_setting('test.biz')::uuid, 'Push token fixture');
INSERT INTO public.profiles(id, business_id, name)
VALUES (current_setting('test.staff')::uuid, current_setting('test.biz')::uuid, 'Staff fixture');

-- Grants: no anonymous path; trigger function is not client-callable.
DO $$
BEGIN
  IF has_function_privilege('anon',
      'public.register_shopper_push_token(text,text,boolean,text,text,text,text,text,text,boolean)',
      'EXECUTE')
     OR has_function_privilege('anon', 'public.clear_shopper_push_token(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Shopper push RPC executable by anon';
  END IF;
  IF has_function_privilege('authenticated',
      'public._devices_stamp_auth_user_id()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Stamp trigger function executable by authenticated';
  END IF;
END;
$$;

-- 1. A Shopper-only phone registers a token with no business.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('test.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
SELECT public.register_shopper_push_token('push-fixture-shopper-phone', 'tok-shopper', true,
  p_platform => 'android', p_app_version => '9.9.9+1');
SELECT public.register_shopper_push_token('push-fixture-shopper-phone', 'tok-shopper-2', true);
DO $$
BEGIN
  -- The Shopper has no direct table access, not even to its own row.
  IF (SELECT count(*) FROM public.devices) <> 0 THEN
    RAISE EXCEPTION 'Shopper can read devices rows directly';
  END IF;
  BEGIN
    INSERT INTO public.devices(business_id, device_id) VALUES (NULL, 'push-fixture-forged');
    RAISE EXCEPTION 'Shopper inserted a devices row directly';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN NULL;
  END;
END;
$$;
RESET ROLE;
DO $$
DECLARE r record;
BEGIN
  SELECT count(*) AS n, max(fcm_token) AS tok, max(platform) AS platform,
         bool_and(business_id IS NULL) AS no_biz
    INTO r FROM public.devices
   WHERE auth_user_id = current_setting('test.shopper')::uuid;
  IF r.n <> 1 OR r.tok <> 'tok-shopper-2' OR r.platform <> 'android' OR NOT r.no_biz THEN
    RAISE EXCEPTION 'Shopper row wrong: %', row_to_json(r);
  END IF;
END;
$$;

-- 2. Staff write: auth_user_id is server-stamped, a forged value is ignored.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('test.staff'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO public.devices(business_id, device_id, fcm_token, auth_user_id)
VALUES (current_setting('test.biz')::uuid, 'push-fixture-till', 'tok-till',
        current_setting('test.shopper')::uuid);
-- The same login shopping on its business phone: no second row, token stays.
SELECT public.register_shopper_push_token('push-fixture-till', 'tok-till', true);
RESET ROLE;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.devices WHERE fcm_token = 'tok-till') <> 1
     OR (SELECT auth_user_id FROM public.devices WHERE fcm_token = 'tok-till')
        <> current_setting('test.staff')::uuid THEN
    RAISE EXCEPTION 'Staff row not stamped with the caller, or duplicated';
  END IF;
  -- Both routes reach the one token: staff by business, Shopper by auth user.
  IF NOT EXISTS (SELECT 1 FROM public.devices WHERE fcm_token = 'tok-till'
                 AND business_id = current_setting('test.biz')::uuid)
     OR NOT EXISTS (SELECT 1 FROM public.devices WHERE fcm_token = 'tok-till'
                 AND auth_user_id = current_setting('test.staff')::uuid) THEN
    RAISE EXCEPTION 'Shared phone token not routable both ways';
  END IF;
END;
$$;

-- 3. Phone changes hands: the Shopper registers the till's token. One row per
--    token still holds, and the staff row keeps its own auth_user_id.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('test.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
SELECT public.register_shopper_push_token('push-fixture-shopper-phone', 'tok-till', true);
RESET ROLE;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.devices WHERE fcm_token = 'tok-till') <> 1
     OR (SELECT auth_user_id FROM public.devices WHERE fcm_token = 'tok-till')
        <> current_setting('test.shopper')::uuid
     OR (SELECT auth_user_id FROM public.devices WHERE device_id = 'push-fixture-till')
        <> current_setting('test.staff')::uuid THEN
    RAISE EXCEPTION 'Token uniqueness or staff ownership broken';
  END IF;
END;
$$;

-- 4. Shopper sign-out clears only the caller's business-less token.
SET LOCAL ROLE authenticated;
SELECT public.clear_shopper_push_token('push-fixture-shopper-phone');
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.devices
             WHERE auth_user_id = current_setting('test.shopper')::uuid
               AND fcm_token IS NOT NULL) THEN
    RAISE EXCEPTION 'Shopper token not cleared';
  END IF;
  BEGIN
    INSERT INTO public.devices(business_id, auth_user_id, device_id)
    VALUES (NULL, NULL, 'push-fixture-unaddressed');
    RAISE EXCEPTION 'Unaddressed devices row accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END;
$$;

-- 5. Signed out: the RPC refuses.
SELECT set_config('request.jwt.claims', '{"role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.register_shopper_push_token('push-fixture-x', 'tok-x', true);
    RAISE EXCEPTION 'Token registered without a login';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;
ROLLBACK;
