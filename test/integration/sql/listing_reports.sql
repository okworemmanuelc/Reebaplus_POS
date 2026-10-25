-- #478 tier-2 SQL companion (reebaplus-dev ONLY, after applying 0214). NOT run
-- against production. Everything runs in one transaction that is rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/listing_reports.sql
-- Covers: report stored; validation; one open report per target; 10/hour rate
-- limit; no client read/write of the cloud-only tables; a blocked product and
-- a blocked store vanish from feed, search, store page and photos for anon and
-- authenticated; unblocking restores them; the till tables are untouched.
BEGIN;

-- 0. Grants / shape.
DO $$
BEGIN
  IF has_function_privilege('anon', 'public.shopper_report_listing(text,uuid,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.shopper_report_listing(text,uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'shopper_report_listing must be authenticated-only';
  END IF;
  IF has_table_privilege('anon', 'public.listing_reports', 'SELECT')
     OR has_table_privilege('authenticated', 'public.listing_reports', 'SELECT')
     OR has_table_privilege('authenticated', 'public.listing_reports', 'INSERT')
     OR has_table_privilege('anon', 'public.storefront_blocks', 'SELECT')
     OR has_table_privilege('authenticated', 'public.storefront_blocks', 'SELECT')
     OR has_table_privilege('authenticated', 'public.storefront_blocks', 'INSERT') THEN
    RAISE EXCEPTION 'report/block tables must have no client grants';
  END IF;
  IF has_function_privilege('authenticated',
       'public._storefront_cards(text,text,text,text,uuid,text,text,text,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._storefront_stores(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'storefront helpers must stay server-only';
  END IF;
  IF NOT has_function_privilege('anon', 'public.storefront_product_photos(uuid,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.storefront_feed(text,text,text,text,text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon storefront access changed';
  END IF;
  IF (SELECT count(*) FROM pg_proc
       WHERE proname IN ('_storefront_cards', '_storefront_stores', 'storefront_product_photos')
         AND pronamespace = 'public'::regnamespace) <> 3 THEN
    RAISE EXCEPTION 'an overload was created';
  END IF;
END $$;

-- 1. Fixtures: store A (products A1 + A2) and store B (product B1).
SELECT set_config('t.biz_a', gen_random_uuid()::text, true),
       set_config('t.biz_b', gen_random_uuid()::text, true),
       set_config('t.store_a', gen_random_uuid()::text, true),
       set_config('t.store_b', gen_random_uuid()::text, true),
       set_config('t.prod_a1', gen_random_uuid()::text, true),
       set_config('t.prod_a2', gen_random_uuid()::text, true),
       set_config('t.prod_b1', gen_random_uuid()::text, true),
       set_config('t.shopper', gen_random_uuid()::text, true),
       set_config('t.other', gen_random_uuid()::text, true),
       set_config('t.state', 'Teststate ' || substr(md5(random()::text), 1, 8), true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid'),
  (current_setting('t.other')::uuid, current_setting('t.other') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status) VALUES
  (current_setting('t.biz_a')::uuid, 'Block Fixture A', 'active'),
  (current_setting('t.biz_b')::uuid, 'Block Fixture B', 'active');
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
                             buying_price_kobo, show_online, is_available,
                             image_url, min_order_qty, order_step) VALUES
  (current_setting('t.prod_a1')::uuid, current_setting('t.biz_a')::uuid,
   'Blockbeer', 1000, 1, true, true, 'https://example.invalid/a1.png', 1, 1),
  (current_setting('t.prod_a2')::uuid, current_setting('t.biz_a')::uuid,
   'Blockkeep', 1000, 1, true, true, 'https://example.invalid/a2.png', 1, 1),
  (current_setting('t.prod_b1')::uuid, current_setting('t.biz_b')::uuid,
   'Blockwater', 500, 1, true, true, 'https://example.invalid/b1.png', 1, 1);
INSERT INTO public.inventory (business_id, product_id, store_id, quantity) VALUES
  (current_setting('t.biz_a')::uuid, current_setting('t.prod_a1')::uuid, current_setting('t.store_a')::uuid, 50),
  (current_setting('t.biz_a')::uuid, current_setting('t.prod_a2')::uuid, current_setting('t.store_a')::uuid, 50),
  (current_setting('t.biz_b')::uuid, current_setting('t.prod_b1')::uuid, current_setting('t.store_b')::uuid, 50);

-- Till snapshot BEFORE any block (the till must not change).
CREATE TEMP TABLE till_before ON COMMIT DROP AS
  SELECT 'products' AS t, md5(string_agg(p::text, '|' ORDER BY p.id)) AS h
    FROM public.products p WHERE p.business_id IN
      (current_setting('t.biz_a')::uuid, current_setting('t.biz_b')::uuid)
  UNION ALL
  SELECT 'stores', md5(string_agg(s::text, '|' ORDER BY s.id))
    FROM public.stores s WHERE s.business_id IN
      (current_setting('t.biz_a')::uuid, current_setting('t.biz_b')::uuid)
  UNION ALL
  SELECT 'inventory', md5(string_agg(i::text, '|' ORDER BY i.id))
    FROM public.inventory i WHERE i.business_id IN
      (current_setting('t.biz_a')::uuid, current_setting('t.biz_b')::uuid);

-- Visible-id helper: what the storefront shows right now, as the given role.
CREATE TEMP TABLE seen (phase text, who text, surface text, id uuid)
  ON COMMIT DROP;
GRANT ALL ON seen TO anon, authenticated;

-- 2. Reports as the Shopper.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.shopper_report_listing('product', current_setting('t.prod_a1')::uuid, 'scam', ' fake ');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'report not ok: %', r; END IF;
  -- Same target again: still ok, no second row.
  r := public.shopper_report_listing('product', current_setting('t.prod_a1')::uuid, 'other', NULL);
  IF (r->>'duplicate')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'duplicate expected: %', r; END IF;
  r := public.shopper_report_listing('store', current_setting('t.store_b')::uuid, 'offensive', NULL);
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'store report not ok: %', r; END IF;
  -- Validation.
  BEGIN
    PERFORM public.shopper_report_listing('order', gen_random_uuid(), 'scam', NULL);
    RAISE EXCEPTION 'bad target accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL; END;
  BEGIN
    PERFORM public.shopper_report_listing('product', gen_random_uuid(), 'spam', NULL);
    RAISE EXCEPTION 'bad reason accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL; END;
  BEGIN
    PERFORM public.shopper_report_listing('product', gen_random_uuid(), 'scam', repeat('x', 501));
    RAISE EXCEPTION 'long details accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL; END;
  -- The tables are not readable or writable by the client.
  BEGIN
    PERFORM 1 FROM public.listing_reports LIMIT 1;
    RAISE EXCEPTION 'client could read listing_reports';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    INSERT INTO public.storefront_blocks (target_type, target_id) VALUES ('product', gen_random_uuid());
    RAISE EXCEPTION 'client could write storefront_blocks';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.listing_reports
       WHERE reporter_auth_id = current_setting('t.shopper')::uuid) <> 2 THEN
    RAISE EXCEPTION 'expected exactly 2 stored reports (dedupe)';
  END IF;
  IF (SELECT details FROM public.listing_reports
       WHERE target_id = current_setting('t.prod_a1')::uuid) <> 'fake' THEN
    RAISE EXCEPTION 'details not trimmed';
  END IF;
END $$;

-- 3. Rate limit: 10 reports an hour per shopper (2 already used).
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb; i int;
BEGIN
  FOR i IN 1..8 LOOP
    r := public.shopper_report_listing('product', gen_random_uuid(), 'other', NULL);
    IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'report % should pass: %', i, r; END IF;
  END LOOP;
  r := public.shopper_report_listing('product', gen_random_uuid(), 'other', NULL);
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'rate_limited' THEN
    RAISE EXCEPTION 'the 11th report must be rate_limited: %', r;
  END IF;
END $$;
RESET ROLE;
-- A different shopper is not limited; a signed-out caller is refused.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.other'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF (public.shopper_report_listing('store', current_setting('t.store_b')::uuid, 'scam', NULL)->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'other shopper should not be limited';
  END IF;
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM public.shopper_report_listing('store', gen_random_uuid(), 'scam', NULL);
  RAISE EXCEPTION 'anon must not be able to report';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

-- 4. Before any block: A1, A2, B1 all visible.
CREATE OR REPLACE FUNCTION pg_temp.snap(p_phase text, p_who text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO seen SELECT p_phase, p_who, 'feed', f.product_id
    FROM public.storefront_feed('Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) f;
  INSERT INTO seen SELECT p_phase, p_who, 'search', s.product_id
    FROM public.storefront_search('Block', 'Nigeria', current_setting('t.state'), 'Near', NULL, NULL, 50) s;
  INSERT INTO seen SELECT p_phase, p_who, 'store_a', s.product_id
    FROM public.storefront_store_products(current_setting('t.store_a')::uuid, NULL, NULL, NULL, 50) s;
  INSERT INTO seen SELECT p_phase, p_who, 'store_b', s.product_id
    FROM public.storefront_store_products(current_setting('t.store_b')::uuid, NULL, NULL, NULL, 50) s;
  INSERT INTO seen SELECT p_phase, p_who, 'store_page_a', s.store_id
    FROM public.storefront_store(current_setting('t.store_a')::uuid, NULL, NULL, NULL) s;
  INSERT INTO seen SELECT p_phase, p_who, 'store_page_b', s.store_id
    FROM public.storefront_store(current_setting('t.store_b')::uuid, NULL, NULL, NULL) s;
  INSERT INTO seen SELECT p_phase, p_who, 'photos_a1', current_setting('t.prod_a1')::uuid
    FROM public.storefront_product_photos(current_setting('t.store_a')::uuid, current_setting('t.prod_a1')::uuid) ph
   LIMIT 1;
  INSERT INTO seen SELECT p_phase, p_who, 'photos_b1', current_setting('t.prod_b1')::uuid
    FROM public.storefront_product_photos(current_setting('t.store_b')::uuid, current_setting('t.prod_b1')::uuid) ph
   LIMIT 1;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.snap(text, text) TO anon, authenticated;

SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
SELECT pg_temp.snap('before', 'anon');
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(DISTINCT surface) FROM seen WHERE phase = 'before' AND who = 'anon'
        AND id IN (current_setting('t.prod_a1')::uuid, current_setting('t.store_a')::uuid)) < 4 THEN
    RAISE EXCEPTION 'fixture A1 should be visible on feed/search/store/photos before a block';
  END IF;
END $$;

-- 5. Admin blocks product A1 and store B (service_role / owner).
INSERT INTO public.storefront_blocks (target_type, target_id, reason, blocked_by) VALUES
  ('product', current_setting('t.prod_a1')::uuid, 'scam reports', 'test-admin'),
  ('store', current_setting('t.store_b')::uuid, 'illegal goods', 'test-admin');

SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
SELECT pg_temp.snap('blocked', 'anon');
RESET ROLE;
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.snap('blocked', 'authed');
RESET ROLE;

DO $$
DECLARE who text;
BEGIN
  FOREACH who IN ARRAY ARRAY['anon', 'authed'] LOOP
    -- Blocked product A1: gone from feed, search, its store page, photos.
    IF EXISTS (SELECT 1 FROM seen WHERE phase = 'blocked' AND seen.who = who
                 AND id = current_setting('t.prod_a1')::uuid) THEN
      RAISE EXCEPTION '% still sees blocked product A1: %', who,
        (SELECT array_agg(surface) FROM seen WHERE phase = 'blocked' AND seen.who = who
           AND id = current_setting('t.prod_a1')::uuid);
    END IF;
    -- Its sibling A2 and its store page are unaffected.
    IF NOT EXISTS (SELECT 1 FROM seen WHERE phase = 'blocked' AND seen.who = who
                     AND surface = 'store_a' AND id = current_setting('t.prod_a2')::uuid)
       OR NOT EXISTS (SELECT 1 FROM seen WHERE phase = 'blocked' AND seen.who = who
                        AND surface = 'store_page_a') THEN
      RAISE EXCEPTION '% lost unblocked A2 / store A', who;
    END IF;
    -- Blocked store B: its product, store page and photos are gone everywhere.
    IF EXISTS (SELECT 1 FROM seen WHERE phase = 'blocked' AND seen.who = who
                 AND (id = current_setting('t.prod_b1')::uuid
                      OR id = current_setting('t.store_b')::uuid)) THEN
      RAISE EXCEPTION '% still sees blocked store B', who;
    END IF;
  END LOOP;
END $$;

-- Placing an order at a blocked store is refused too (store not listed).
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM public.shopper_save_profile('Ada', '0803', 'Nigeria',
    current_setting('t.state'), 'Near', '1 Road');
  r := public.shopper_place_orders(
    jsonb_build_array(jsonb_build_object('id', gen_random_uuid(),
      'store_id', current_setting('t.store_b'),
      'lines', jsonb_build_array(jsonb_build_object(
        'product_id', current_setting('t.prod_b1'), 'quantity', 1)))),
    '0803', jsonb_build_object('state', current_setting('t.state'), 'lga', 'Near', 'street', '1 Road'), NULL);
  IF (r->0->>'ok')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'order at a blocked store must fail: %', r;
  END IF;
END $$;
RESET ROLE;

-- 6. The till is untouched: tenant rows are byte-identical.
DO $$
DECLARE cur record;
BEGIN
  FOR cur IN
    SELECT 'products' AS t, md5(string_agg(p::text, '|' ORDER BY p.id)) AS h
      FROM public.products p WHERE p.business_id IN
        (current_setting('t.biz_a')::uuid, current_setting('t.biz_b')::uuid)
    UNION ALL
    SELECT 'stores', md5(string_agg(s::text, '|' ORDER BY s.id))
      FROM public.stores s WHERE s.business_id IN
        (current_setting('t.biz_a')::uuid, current_setting('t.biz_b')::uuid)
    UNION ALL
    SELECT 'inventory', md5(string_agg(i::text, '|' ORDER BY i.id))
      FROM public.inventory i WHERE i.business_id IN
        (current_setting('t.biz_a')::uuid, current_setting('t.biz_b')::uuid)
  LOOP
    IF cur.h IS DISTINCT FROM (SELECT b.h FROM till_before b WHERE b.t = cur.t) THEN
      RAISE EXCEPTION 'blocking changed the till table %', cur.t;
    END IF;
  END LOOP;
END $$;

-- 7. Unblock restores everything.
DELETE FROM public.storefront_blocks
 WHERE target_id IN (current_setting('t.prod_a1')::uuid, current_setting('t.store_b')::uuid);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
SELECT pg_temp.snap('unblocked', 'anon');
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM seen WHERE phase = 'unblocked' AND surface = 'store_a'
                   AND id = current_setting('t.prod_a1')::uuid)
     OR NOT EXISTS (SELECT 1 FROM seen WHERE phase = 'unblocked' AND surface = 'store_page_b') THEN
    RAISE EXCEPTION 'unblock did not restore the listing';
  END IF;
END $$;

ROLLBACK;
