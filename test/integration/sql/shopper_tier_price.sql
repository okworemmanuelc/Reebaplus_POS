-- #429 tier-2 SQL companion (reebaplus-dev ONLY, after applying 0211).
-- Everything runs inside one transaction that is rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/shopper_tier_price.sql
-- Covers: _shopper_price_tier is server-only and anon storefront grants are
-- unchanged; a Shopper linked to a Wholesaler customer at shop A sees A's
-- Wholesaler price and only there (shop B, where the same login is a linked
-- Retailer, stays Retailer); an unlinked login sees Retailer; anon sees
-- Retailer; a deleted customer or a one-price shop falls back to Retailer;
-- placed order lines snapshot the price and price_tier used.
BEGIN;

-- 0. EXECUTE boundaries.
DO $$
DECLARE fn text;
BEGIN
  IF has_function_privilege('anon', 'public._shopper_price_tier(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._shopper_price_tier(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION '_shopper_price_tier must be server-only';
  END IF;
  IF has_function_privilege('authenticated',
       'public._storefront_cards(text,text,text,text,uuid,text,text,text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION '_storefront_cards must stay server-only';
  END IF;
  FOREACH fn IN ARRAY ARRAY[
    'public.storefront_feed(text,text,text,text,text,integer)',
    'public.storefront_search(text,text,text,text,text,text,integer)',
    'public.storefront_store(uuid,text,text,text)',
    'public.storefront_store_products(uuid,text,text,text,integer)'
  ] LOOP
    IF NOT has_function_privilege('anon', fn, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must stay callable signed out and signed in', fn;
    END IF;
  END LOOP;
  IF has_function_privilege('anon', 'public.shopper_place_orders(jsonb,text,jsonb,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.shopper_place_orders(jsonb,text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'shopper_place_orders grants changed';
  END IF;
  IF (SELECT count(*) FROM pg_proc
       WHERE proname IN ('_storefront_cards', 'shopper_place_orders')
         AND pronamespace = 'public'::regnamespace) <> 2 THEN
    RAISE EXCEPTION 'an overload was created';
  END IF;
END $$;

-- 1. Fixtures (as the migration owner): shops A and B both deliver to Near.
--    A: retail 1000, wholesale 800. B: retail 500, wholesale 400.
--    The Shopper is a linked Wholesaler at A and a linked Retailer at B.
SELECT set_config('t.biz_a', gen_random_uuid()::text, true),
       set_config('t.biz_b', gen_random_uuid()::text, true),
       set_config('t.store_a', gen_random_uuid()::text, true),
       set_config('t.store_b', gen_random_uuid()::text, true),
       set_config('t.prod_a', gen_random_uuid()::text, true),
       set_config('t.prod_b', gen_random_uuid()::text, true),
       set_config('t.cust_a', gen_random_uuid()::text, true),
       set_config('t.shopper', gen_random_uuid()::text, true),
       set_config('t.other', gen_random_uuid()::text, true),
       set_config('t.state', 'Teststate ' || substr(md5(random()::text), 1, 8), true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid'),
  (current_setting('t.other')::uuid, current_setting('t.other') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status) VALUES
  (current_setting('t.biz_a')::uuid, 'Tier Fixture A', 'active'),
  (current_setting('t.biz_b')::uuid, 'Tier Fixture B', 'active');
INSERT INTO public.stores (id, business_id, name, kind, country, state, lga,
                           online_ordering_enabled) VALUES
  (current_setting('t.store_a')::uuid, current_setting('t.biz_a')::uuid, 'A',
   'store', 'Nigeria', current_setting('t.state'), 'Near', true),
  (current_setting('t.store_b')::uuid, current_setting('t.biz_b')::uuid, 'B',
   'store', 'Nigeria', current_setting('t.state'), 'Near', true);
INSERT INTO public.store_delivery_areas (business_id, store_id, country, state, lga) VALUES
  (current_setting('t.biz_a')::uuid, current_setting('t.store_a')::uuid,
   'Nigeria', current_setting('t.state'), 'Near'),
  (current_setting('t.biz_b')::uuid, current_setting('t.store_b')::uuid,
   'Nigeria', current_setting('t.state'), 'Near');
INSERT INTO public.products (id, business_id, name, retailer_price_kobo,
                             wholesaler_price_kobo, buying_price_kobo,
                             show_online, is_available,
                             min_order_qty, order_step, max_order_qty) VALUES
  (current_setting('t.prod_a')::uuid, current_setting('t.biz_a')::uuid,
   'Tierlager', 1000, 800, 1, true, true, 1, 1, NULL),
  (current_setting('t.prod_b')::uuid, current_setting('t.biz_b')::uuid,
   'Tierwater', 500, 400, 1, true, true, 1, 1, NULL);
INSERT INTO public.inventory (business_id, product_id, store_id, quantity) VALUES
  (current_setting('t.biz_a')::uuid, current_setting('t.prod_a')::uuid,
   current_setting('t.store_a')::uuid, 50),
  (current_setting('t.biz_b')::uuid, current_setting('t.prod_b')::uuid,
   current_setting('t.store_b')::uuid, 50);
INSERT INTO public.customers (id, business_id, name, price_tier, shopper_account_id) VALUES
  (current_setting('t.cust_a')::uuid, current_setting('t.biz_a')::uuid,
   'Ada (wholesale)', 'wholesaler', current_setting('t.shopper')::uuid),
  (gen_random_uuid(), current_setting('t.biz_b')::uuid,
   'Ada (retail)', 'retailer', current_setting('t.shopper')::uuid);

-- Prices seen by the current caller, one row per fixture product.
CREATE TEMP TABLE tier_seen (who text, product_id uuid, price_kobo bigint)
  ON COMMIT DROP;
GRANT ALL ON tier_seen TO anon, authenticated;

-- 2. Anon: Retailer everywhere (feed, search, store page).
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
INSERT INTO tier_seen
  SELECT 'anon_feed', f.product_id, f.price_kobo
    FROM public.storefront_feed('Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) f
   WHERE f.product_id IN (current_setting('t.prod_a')::uuid, current_setting('t.prod_b')::uuid);
INSERT INTO tier_seen
  SELECT 'anon_search', s.product_id, s.price_kobo
    FROM public.storefront_search('Tierlager', 'Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) s;
INSERT INTO tier_seen
  SELECT 'anon_store', s.product_id, s.price_kobo
    FROM public.storefront_store_products(current_setting('t.store_a')::uuid, NULL, NULL, NULL, 50) s;
RESET ROLE;

-- 3. The linked Shopper.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO tier_seen
  SELECT 'linked_feed', f.product_id, f.price_kobo
    FROM public.storefront_feed('Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) f
   WHERE f.product_id IN (current_setting('t.prod_a')::uuid, current_setting('t.prod_b')::uuid);
INSERT INTO tier_seen
  SELECT 'linked_search', s.product_id, s.price_kobo
    FROM public.storefront_search('Tierlager', 'Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) s;
INSERT INTO tier_seen
  SELECT 'linked_store', s.product_id, s.price_kobo
    FROM public.storefront_store_products(current_setting('t.store_a')::uuid, NULL, NULL, NULL, 50) s;
RESET ROLE;

-- 4. An unlinked login.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.other'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO tier_seen
  SELECT 'unlinked_feed', f.product_id, f.price_kobo
    FROM public.storefront_feed('Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) f
   WHERE f.product_id IN (current_setting('t.prod_a')::uuid, current_setting('t.prod_b')::uuid);
RESET ROLE;

DO $$
DECLARE
  a uuid := current_setting('t.prod_a')::uuid;
  b uuid := current_setting('t.prod_b')::uuid;
  exp record;
BEGIN
  FOR exp IN SELECT * FROM (VALUES
    ('anon_feed', a, 1000::bigint), ('anon_feed', b, 500::bigint),
    ('anon_search', a, 1000::bigint), ('anon_store', a, 1000::bigint),
    ('linked_feed', a, 800::bigint), ('linked_feed', b, 500::bigint),
    ('linked_search', a, 800::bigint), ('linked_store', a, 800::bigint),
    ('unlinked_feed', a, 1000::bigint), ('unlinked_feed', b, 500::bigint)
  ) v(who, product_id, price_kobo) LOOP
    IF NOT EXISTS (SELECT 1 FROM tier_seen t
                    WHERE t.who = exp.who AND t.product_id = exp.product_id
                      AND t.price_kobo = exp.price_kobo) THEN
      RAISE EXCEPTION '% expected % for %, saw %', exp.who, exp.price_kobo,
        exp.product_id, (SELECT array_agg(t.price_kobo) FROM tier_seen t
                          WHERE t.who = exp.who AND t.product_id = exp.product_id);
    END IF;
  END LOOP;
END $$;

-- 5. Placement as the linked Shopper: A's line at 800 'wholesaler',
--    B's line at 500 'retailer'.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  r jsonb;
  addr jsonb := jsonb_build_object('state', current_setting('t.state'),
                                   'lga', 'Near', 'street', '1 Road');
  oa uuid := gen_random_uuid();
  ob uuid := gen_random_uuid();
BEGIN
  PERFORM public.shopper_save_profile('Ada', '0803', 'Nigeria',
    current_setting('t.state'), 'Near', '1 Road');
  r := public.shopper_place_orders(
    jsonb_build_array(
      jsonb_build_object('id', oa, 'store_id', current_setting('t.store_a'),
        'lines', jsonb_build_array(jsonb_build_object(
          'product_id', current_setting('t.prod_a'), 'quantity', 3))),
      jsonb_build_object('id', ob, 'store_id', current_setting('t.store_b'),
        'lines', jsonb_build_array(jsonb_build_object(
          'product_id', current_setting('t.prod_b'), 'quantity', 2)))),
    '0803', addr, NULL);
  IF (r->0->>'ok')::boolean IS NOT TRUE OR (r->0->>'total_kobo')::bigint <> 3 * 800
     OR (r->1->>'ok')::boolean IS NOT TRUE OR (r->1->>'total_kobo')::bigint <> 2 * 500 THEN
    RAISE EXCEPTION 'tier totals wrong: %', r;
  END IF;
  PERFORM set_config('t.order_a', oa::text, true);
  PERFORM set_config('t.order_b', ob::text, true);
END $$;
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.online_order_lines l
                  WHERE l.online_order_id = current_setting('t.order_a')::uuid
                    AND l.unit_price_kobo = 800 AND l.price_tier = 'wholesaler') THEN
    RAISE EXCEPTION 'shop A line did not snapshot the Wholesaler tier';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.online_order_lines l
                  WHERE l.online_order_id = current_setting('t.order_b')::uuid
                    AND l.unit_price_kobo = 500 AND l.price_tier = 'retailer') THEN
    RAISE EXCEPTION 'shop B line did not snapshot the Retailer tier';
  END IF;
END $$;

-- 6. Fall-backs (owner edits, then re-read as the Shopper): a one-price shop
--    and a deleted customer both give Retailer.
UPDATE public.businesses SET sells_one_price = true
 WHERE id = current_setting('t.biz_a')::uuid;
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO tier_seen
  SELECT 'one_price', s.product_id, s.price_kobo
    FROM public.storefront_store_products(current_setting('t.store_a')::uuid, NULL, NULL, NULL, 50) s;
RESET ROLE;

UPDATE public.businesses SET sells_one_price = false
 WHERE id = current_setting('t.biz_a')::uuid;
UPDATE public.customers SET is_deleted = true
 WHERE id = current_setting('t.cust_a')::uuid;
SET LOCAL ROLE authenticated;
INSERT INTO tier_seen
  SELECT 'deleted_customer', s.product_id, s.price_kobo
    FROM public.storefront_store_products(current_setting('t.store_a')::uuid, NULL, NULL, NULL, 50) s;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT t.price_kobo FROM tier_seen t WHERE t.who = 'one_price') IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'a one-price shop must show Retailer';
  END IF;
  IF (SELECT t.price_kobo FROM tier_seen t WHERE t.who = 'deleted_customer') IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'a deleted customer link must show Retailer';
  END IF;
END $$;

SELECT 'tier price: anon/unlinked Retailer, linked Wholesaler at its shop only, '
       'line snapshots, one-price + deleted fall-backs passed' AS checks;

ROLLBACK;
