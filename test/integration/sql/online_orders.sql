-- #426 tier-2 SQL companion (reebaplus-dev, after applying 0205).
-- Everything runs inside one transaction that is rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/online_orders.sql
-- Covers: EXECUTE boundaries; one order per shop placed independently (a
-- failing shop reported, the other placed); stock refusal without a count;
-- min/step/max; out-of-area; a Shopper sees only their own orders (direct
-- table reads denied); cancel only while new; the status guard; the 20-per-
-- hour spam limit; live-signal triggers present.
BEGIN;

-- 0. EXECUTE boundaries + triggers.
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.shopper_get_profile()',
    'public.shopper_save_profile(text,text,text,text,text,text)',
    'public.shopper_save_phone(text,boolean)',
    'public.shopper_save_address(text,text,text,text,boolean)',
    'public.shopper_remove_phone(uuid)',
    'public.shopper_remove_address(uuid)',
    'public.shopper_place_orders(jsonb,text,jsonb,text)',
    'public.shopper_cancel_order(uuid)',
    'public.shopper_my_orders(integer,timestamptz)'
  ] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must not be callable signed out', fn;
    END IF;
    IF NOT has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be callable signed in', fn;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = fn::regprocedure) THEN
      RAISE EXCEPTION '% must be SECURITY DEFINER', fn;
    END IF;
  END LOOP;
  FOREACH fn IN ARRAY ARRAY[
    'public._shopper_uid()',
    'public._shopper_put_phone(uuid,text,boolean)',
    'public._shopper_put_address(uuid,text,text,text,text,boolean)',
    'public._online_orders_guard()'
  ] LOOP
    IF has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be server-only', fn;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_trigger
       WHERE tgname = 'zz_broadcast_sync_signal' AND NOT tgisinternal
         AND tgrelid IN ('public.online_orders'::regclass,
                         'public.online_order_lines'::regclass)) <> 2 THEN
    RAISE EXCEPTION 'live sync signal missing on the online order tables';
  END IF;
END $$;

-- 1. Fixtures (as the migration owner): two shops in one state; shop A
--    delivers to Near, shop B only to Far. Stock 5 at shop A.
SELECT set_config('t.biz_a', gen_random_uuid()::text, true),
       set_config('t.biz_b', gen_random_uuid()::text, true),
       set_config('t.store_a', gen_random_uuid()::text, true),
       set_config('t.store_b', gen_random_uuid()::text, true),
       set_config('t.prod_a', gen_random_uuid()::text, true),
       set_config('t.prod_crate', gen_random_uuid()::text, true),
       set_config('t.prod_b', gen_random_uuid()::text, true),
       set_config('t.shopper', gen_random_uuid()::text, true),
       set_config('t.other', gen_random_uuid()::text, true),
       set_config('t.state', 'Teststate ' || substr(md5(random()::text), 1, 8), true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid'),
  (current_setting('t.other')::uuid, current_setting('t.other') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status) VALUES
  (current_setting('t.biz_a')::uuid, 'Fixture A', 'active'),
  (current_setting('t.biz_b')::uuid, 'Fixture B', 'active');
INSERT INTO public.stores (id, business_id, name, kind, country, state, lga,
                           online_ordering_enabled) VALUES
  (current_setting('t.store_a')::uuid, current_setting('t.biz_a')::uuid, 'A',
   'store', 'Nigeria', current_setting('t.state'), 'Near', true),
  (current_setting('t.store_b')::uuid, current_setting('t.biz_b')::uuid, 'B',
   'store', 'Nigeria', current_setting('t.state'), 'Far', true);
INSERT INTO public.store_delivery_areas (business_id, store_id, country, state, lga) VALUES
  (current_setting('t.biz_a')::uuid, current_setting('t.store_a')::uuid,
   'Nigeria', current_setting('t.state'), 'Near'),
  (current_setting('t.biz_b')::uuid, current_setting('t.store_b')::uuid,
   'Nigeria', current_setting('t.state'), 'Far');
INSERT INTO public.products (id, business_id, name, retailer_price_kobo,
                             buying_price_kobo, show_online, is_available,
                             min_order_qty, order_step, max_order_qty) VALUES
  (current_setting('t.prod_a')::uuid, current_setting('t.biz_a')::uuid,
   'Lager', 450000, 300000, true, true, 1, 1, NULL),
  (current_setting('t.prod_crate')::uuid, current_setting('t.biz_a')::uuid,
   'Whole crates', 100000, 1, true, true, 12, 12, 24),
  (current_setting('t.prod_b')::uuid, current_setting('t.biz_b')::uuid,
   'Water', 120000, 1, true, true, 1, 1, NULL);
INSERT INTO public.inventory (business_id, product_id, store_id, quantity) VALUES
  (current_setting('t.biz_a')::uuid, current_setting('t.prod_a')::uuid,
   current_setting('t.store_a')::uuid, 5),
  (current_setting('t.biz_a')::uuid, current_setting('t.prod_crate')::uuid,
   current_setting('t.store_a')::uuid, 100),
  (current_setting('t.biz_b')::uuid, current_setting('t.prod_b')::uuid,
   current_setting('t.store_b')::uuid, 50);

-- 2. Act as the Shopper (a login with no business membership).
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  r jsonb;
  addr jsonb := jsonb_build_object('state', current_setting('t.state'),
                                   'lga', 'Near', 'street', '1 Road');
  o1 uuid := gen_random_uuid();
  o2 uuid := gen_random_uuid();
BEGIN
  -- Place needs the first-time details.
  BEGIN
    PERFORM public.shopper_place_orders(
      jsonb_build_array(jsonb_build_object('id', o1, 'store_id',
        current_setting('t.store_a'), 'lines', jsonb_build_array(
          jsonb_build_object('product_id', current_setting('t.prod_a'), 'quantity', 1)))),
      '0803', addr, NULL);
    RAISE EXCEPTION 'placed without details';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'shopper_profile_required' THEN RAISE; END IF;
  END;
  PERFORM public.shopper_save_profile('Ada', '0803', 'Nigeria',
    current_setting('t.state'), 'Near', '1 Road');

  -- Stock: 6 > 5 is refused with a code only (no count anywhere).
  r := public.shopper_place_orders(
    jsonb_build_array(jsonb_build_object('id', o1, 'store_id',
      current_setting('t.store_a'), 'lines', jsonb_build_array(
        jsonb_build_object('product_id', current_setting('t.prod_a'), 'quantity', 6)))),
    '0803', addr, NULL);
  IF r->0->>'code' <> 'not_enough_stock' OR r::text ~ '"5"|: 5[,}]' THEN
    RAISE EXCEPTION 'stock refusal wrong or leaks the count: %', r;
  END IF;

  -- min/step/max (#473): 13 of a "whole crates (12), up to 24" product.
  r := public.shopper_place_orders(
    jsonb_build_array(jsonb_build_object('id', o1, 'store_id',
      current_setting('t.store_a'), 'lines', jsonb_build_array(
        jsonb_build_object('product_id', current_setting('t.prod_crate'), 'quantity', 13)))),
    '0803', addr, NULL);
  IF r->0->>'code' <> 'quantity_rule' THEN
    RAISE EXCEPTION 'quantity rule not enforced: %', r;
  END IF;

  -- Two shops: A places, B (does not deliver to Near) is reported.
  r := public.shopper_place_orders(
    jsonb_build_array(
      jsonb_build_object('id', o1, 'store_id', current_setting('t.store_a'),
        'lines', jsonb_build_array(
          jsonb_build_object('product_id', current_setting('t.prod_a'), 'quantity', 2),
          jsonb_build_object('product_id', current_setting('t.prod_crate'), 'quantity', 24))),
      jsonb_build_object('id', o2, 'store_id', current_setting('t.store_b'),
        'lines', jsonb_build_array(
          jsonb_build_object('product_id', current_setting('t.prod_b'), 'quantity', 1)))),
    '0803', addr, 'Blue gate');
  IF (r->0->>'ok')::boolean IS NOT TRUE
     OR (r->0->>'total_kobo')::bigint <> 2 * 450000 + 24 * 100000
     OR r->1->>'code' <> 'out_of_area' THEN
    RAISE EXCEPTION 'independent placement wrong: %', r;
  END IF;

  -- Idempotent retry returns the same order, not a second one.
  r := public.shopper_place_orders(
    jsonb_build_array(jsonb_build_object('id', o1, 'store_id',
      current_setting('t.store_a'), 'lines', jsonb_build_array(
        jsonb_build_object('product_id', current_setting('t.prod_a'), 'quantity', 2)))),
    '0803', addr, NULL);
  IF (SELECT jsonb_array_length(public.shopper_my_orders(50, NULL))) <> 1 THEN
    RAISE EXCEPTION 'retry duplicated the order';
  END IF;

  -- No stock moved (an Online Order is a request, not a Sale).
  -- (checked below as the owner)

  -- Direct tenant/shopper table reads give a Shopper nothing.
  IF EXISTS (SELECT 1 FROM public.online_orders)
     OR EXISTS (SELECT 1 FROM public.online_order_lines) THEN
    RAISE EXCEPTION 'Shopper can read online_orders directly';
  END IF;
  BEGIN
    PERFORM 1 FROM public.shopper_profiles;
    RAISE EXCEPTION 'Shopper can read shopper_profiles directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Direct creation is refused.
  BEGIN
    INSERT INTO public.online_orders (id, business_id, store_id, reference,
      shopper_name, delivery_phone, delivery_state, delivery_lga, delivery_street)
    VALUES (gen_random_uuid(), current_setting('t.biz_a')::uuid,
      current_setting('t.store_a')::uuid, 'X', 'x', 'x', 'x', 'x', 'x');
    RAISE EXCEPTION 'Shopper inserted an online order directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Cancel while new.
  IF public.shopper_cancel_order(o1) <> 'cancelled_by_customer' THEN
    RAISE EXCEPTION 'cancel failed';
  END IF;
END $$;

-- 3. Another Shopper sees none of it.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.other'), 'role', 'authenticated')::text, true);
DO $$
BEGIN
  IF jsonb_array_length(public.shopper_my_orders(50, NULL)) <> 0 THEN
    RAISE EXCEPTION 'another Shopper sees foreign orders';
  END IF;
  IF public.shopper_get_profile() IS NOT NULL THEN
    RAISE EXCEPTION 'another Shopper sees a foreign profile';
  END IF;
END $$;

-- 4. Owner checks: no stock moved; the status guard; cancel after accept.
RESET ROLE;
DO $$
DECLARE
  o uuid := gen_random_uuid();
BEGIN
  IF (SELECT quantity FROM public.inventory
       WHERE product_id = current_setting('t.prod_a')::uuid) <> 5 THEN
    RAISE EXCEPTION 'placing an order moved stock';
  END IF;
  -- cancelled_by_customer is terminal.
  BEGIN
    UPDATE public.online_orders SET status = 'accepted'
     WHERE shopper_account_id = current_setting('t.shopper')::uuid;
    RAISE EXCEPTION 'guard let a cancelled order be accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'online_order_transition_rejected' THEN RAISE; END IF;
  END;
  -- An accepted order cannot be cancelled by the Shopper.
  INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id,
    reference, shopper_name, delivery_phone, delivery_state, delivery_lga,
    delivery_street)
  VALUES (o, current_setting('t.biz_a')::uuid, current_setting('t.store_a')::uuid,
    current_setting('t.shopper')::uuid, 'ON-FIXTURE', 'Ada', '0803',
    current_setting('t.state'), 'Near', '1 Road');
  UPDATE public.online_orders SET status = 'accepted' WHERE id = o;
  -- Decline needs a reason.
  BEGIN
    UPDATE public.online_orders SET status = 'cancelled_by_shop' WHERE id = o;
    RAISE EXCEPTION 'cancel by shop without a reason was allowed';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'online_order_transition_rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('t.accepted', o::text, true);
END $$;

SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.shopper_cancel_order(current_setting('t.accepted')::uuid);
    RAISE EXCEPTION 'Shopper cancelled an accepted order';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'order_not_cancellable' THEN RAISE; END IF;
  END;
END $$;

-- 5. Spam limit: the 21st order inside an hour is refused.
RESET ROLE;
INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id,
  reference, shopper_name, delivery_phone, delivery_state, delivery_lga,
  delivery_street)
SELECT gen_random_uuid(), current_setting('t.biz_a')::uuid,
       current_setting('t.store_a')::uuid, current_setting('t.shopper')::uuid,
       'ON-SPAM-' || g, 'Ada', '0803', current_setting('t.state'), 'Near', '1 Road'
  FROM generate_series(1, 18) g;  -- + the 2 above = 20 this hour
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.shopper_place_orders(
    jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'store_id',
      current_setting('t.store_a'), 'lines', jsonb_build_array(
        jsonb_build_object('product_id', current_setting('t.prod_a'), 'quantity', 1)))),
    '0803', jsonb_build_object('state', current_setting('t.state'),
      'lga', 'Near', 'street', '1 Road'), NULL);
  IF r->0->>'code' <> 'rate_limited' THEN
    RAISE EXCEPTION '21st order in an hour was not refused: %', r;
  END IF;
END $$;

ROLLBACK;
