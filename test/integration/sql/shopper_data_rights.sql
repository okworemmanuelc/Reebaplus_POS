-- #477 tier-2 SQL companion (reebaplus-dev only, after 0205 + 0209).
-- Every fixture is rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/shopper_data_rights.sql
BEGIN;

SELECT set_config('t.biz', gen_random_uuid()::text, true);
SELECT set_config('t.store', gen_random_uuid()::text, true);
SELECT set_config('t.a', gen_random_uuid()::text, true);
SELECT set_config('t.b', gen_random_uuid()::text, true);
SELECT set_config('t.tok', 'dr' || substr(md5(random()::text), 1, 8), true);

INSERT INTO auth.users(id, email) VALUES
  (current_setting('t.a')::uuid, current_setting('t.a') || '@example.invalid'),
  (current_setting('t.b')::uuid, current_setting('t.b') || '@example.invalid');
INSERT INTO public.businesses(id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Rights ' || current_setting('t.tok'), 'active');
INSERT INTO public.stores(id, business_id, name, kind, country, state, lga)
VALUES (current_setting('t.store')::uuid, current_setting('t.biz')::uuid, 'DR store',
        'store', 'Nigeria', 'State', 'Lga');

INSERT INTO public.shopper_profiles(auth_user_id, name) VALUES
  (current_setting('t.a')::uuid, 'Alice ' || current_setting('t.tok')),
  (current_setting('t.b')::uuid, 'Bob ' || current_setting('t.tok'));
INSERT INTO public.shopper_phones(auth_user_id, phone, is_default) VALUES
  (current_setting('t.a')::uuid, '0801' || current_setting('t.tok'), true),
  (current_setting('t.b')::uuid, '0802' || current_setting('t.tok'), true);
INSERT INTO public.shopper_addresses(auth_user_id, state, lga, street, is_default) VALUES
  (current_setting('t.a')::uuid, 'S', 'L', 'A street ' || current_setting('t.tok'), true),
  (current_setting('t.b')::uuid, 'S', 'L', 'B street ' || current_setting('t.tok'), true);
INSERT INTO public.online_orders(id, business_id, store_id, shopper_account_id, reference,
  shopper_name, delivery_phone, delivery_state, delivery_lga, delivery_street) VALUES
  (gen_random_uuid(), current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.a')::uuid, 'DR-A-' || current_setting('t.tok'), 'Alice', '0801', 'S', 'L', 'A'),
  (gen_random_uuid(), current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.b')::uuid, 'DR-B-' || current_setting('t.tok'), 'Bob', '0802', 'S', 'L', 'B');

-- 1. EXECUTE boundaries: signed in only.
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY['public.shopper_export()',
                            'public.shopper_set_marketing_opt_in(boolean)'] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must not be callable signed out', fn;
    END IF;
    IF NOT has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be callable signed in', fn;
    END IF;
  END LOOP;
END;
$$;

-- 2. Alice's export holds only Alice's data.
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('t.a'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  j jsonb := public.shopper_export();
  txt text := j::text;
BEGIN
  IF j->'profile'->>'name' IS DISTINCT FROM 'Alice ' || current_setting('t.tok') THEN
    RAISE EXCEPTION 'export profile is not the caller''s';
  END IF;
  IF jsonb_array_length(j->'orders') <> 1
     OR j->'orders'->0->>'reference' <> 'DR-A-' || current_setting('t.tok') THEN
    RAISE EXCEPTION 'export must hold exactly the caller''s own order';
  END IF;
  IF jsonb_array_length(j->'phones') <> 1 OR jsonb_array_length(j->'addresses') <> 1 THEN
    RAISE EXCEPTION 'export must hold exactly the caller''s phone and address';
  END IF;
  IF txt LIKE '%Bob%' OR txt LIKE '%0802%' OR txt LIKE '%B street%' OR txt LIKE '%DR-B-%' THEN
    RAISE EXCEPTION 'export leaked another shopper''s data';
  END IF;
  IF (j->'profile'->>'marketing_opt_in')::boolean THEN
    RAISE EXCEPTION 'marketing opt-in must default to off';
  END IF;
END;
$$;

-- 3. Opt-in sets consent_at; opt-out clears it; Bob is untouched.
DO $$
BEGIN
  PERFORM public.shopper_set_marketing_opt_in(true);
  IF NOT (public.shopper_get_profile()->>'marketing_opt_in')::boolean THEN
    RAISE EXCEPTION 'opt-in not stored';
  END IF;
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT marketing_consent_at FROM public.shopper_profiles
       WHERE auth_user_id = current_setting('t.a')::uuid) IS NULL THEN
    RAISE EXCEPTION 'consent_at must be set on opt-in';
  END IF;
  IF (SELECT marketing_opt_in FROM public.shopper_profiles
       WHERE auth_user_id = current_setting('t.b')::uuid) THEN
    RAISE EXCEPTION 'opt-in leaked to another shopper';
  END IF;
END;
$$;
SET LOCAL ROLE authenticated;
SELECT public.shopper_set_marketing_opt_in(false);
RESET ROLE;
DO $$
BEGIN
  IF (SELECT marketing_consent_at FROM public.shopper_profiles
       WHERE auth_user_id = current_setting('t.a')::uuid) IS NOT NULL THEN
    RAISE EXCEPTION 'consent_at must be NULL after opt-out';
  END IF;
END;
$$;

ROLLBACK;
