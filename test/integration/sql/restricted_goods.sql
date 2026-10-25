-- #479 tier-2 SQL companion (reebaplus-dev only, after 0202 + 0204 + 0206).
-- Every fixture (auth users, business, store, products) is rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/restricted_goods.sql
BEGIN;

-- 1. EXECUTE boundaries: rules server-only; age RPCs signed-in only.
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.product_online_restriction(uuid)',
    'public.shopper_age_confirmation_missing(uuid,uuid[])'
  ] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE')
       OR has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be server-only', fn;
    END IF;
  END LOOP;
  FOREACH fn IN ARRAY ARRAY[
    'public.shopper_confirm_age()',
    'public.shopper_age_confirmed_at()'
  ] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must not be callable signed out', fn;
    END IF;
    IF NOT has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be callable signed in', fn;
    END IF;
  END LOOP;
  IF has_table_privilege('authenticated', 'public.shopper_age_confirmations', 'SELECT')
     OR has_table_privilege('anon', 'public.shopper_age_confirmations', 'SELECT') THEN
    RAISE EXCEPTION 'shopper_age_confirmations must be RPC-only';
  END IF;
  IF (SELECT restricted FROM public.marketplace_categories
       WHERE slug = 'prescription-medicines') IS DISTINCT FROM 'prescription' THEN
    RAISE EXCEPTION 'prescription-medicines category missing';
  END IF;
END;
$$;

-- 2. Fixtures: one online store with a beer, a prescription medicine, a
--    product under a prescription PARENT category, and a plain product.
SELECT set_config('t.biz', gen_random_uuid()::text, true);
SELECT set_config('t.store', gen_random_uuid()::text, true);
SELECT set_config('t.shopper', gen_random_uuid()::text, true);
SELECT set_config('t.tok', 'rg' || substr(md5(random()::text), 1, 8), true);
INSERT INTO auth.users(id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid');
INSERT INTO public.marketplace_categories (slug, name, parent_slug, sort, restricted)
VALUES ('rx-parent-' || current_setting('t.tok'), 'Rx parent', NULL, 9998, 'prescription'),
       ('rx-child-' || current_setting('t.tok'), 'Rx child',
        'rx-parent-' || current_setting('t.tok'), 9999, NULL);
INSERT INTO public.businesses(id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Restricted ' || current_setting('t.tok'), 'active');
INSERT INTO public.stores(id, business_id, name, kind, country, state, lga,
                          online_ordering_enabled)
VALUES (current_setting('t.store')::uuid, current_setting('t.biz')::uuid, 'RG store',
        'store', 'Nigeria', 'State ' || current_setting('t.tok'), 'Lga',
        true);
INSERT INTO public.store_delivery_areas(id, business_id, store_id, country, state, lga)
VALUES (gen_random_uuid(), current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
        'Nigeria', 'State ' || current_setting('t.tok'), NULL);
INSERT INTO public.categories(id, business_id, name, marketplace_category)
SELECT gen_random_uuid(), current_setting('t.biz')::uuid, 'Cat ' || s, s
  FROM unnest(ARRAY['beer', 'prescription-medicines', 'painkillers',
                    'rx-child-' || current_setting('t.tok')]) AS s;
INSERT INTO public.products(id, business_id, name, retailer_price_kobo, show_online,
                            is_available, image_url, category_id)
SELECT gen_random_uuid(), current_setting('t.biz')::uuid,
       x.name || ' ' || current_setting('t.tok'), 1000, true, true,
       'https://example.invalid/p.jpg', c.id
  FROM (VALUES ('Beer', 'beer'), ('Rx', 'prescription-medicines'),
               ('Paracetamol', 'painkillers'),
               ('Rx by parent', 'rx-child-' || current_setting('t.tok'))) AS x(name, slug)
  JOIN public.categories c
    ON c.business_id = current_setting('t.biz')::uuid AND c.marketplace_category = x.slug;
INSERT INTO public.inventory(id, business_id, product_id, store_id, quantity)
SELECT gen_random_uuid(), p.business_id, p.id, current_setting('t.store')::uuid, 50
  FROM public.products p WHERE p.business_id = current_setting('t.biz')::uuid;

-- 3. Classification + the placement rule.
DO $$
DECLARE
  v_beer uuid; v_rx uuid; v_rx_parent uuid; v_plain uuid;
  v_uid uuid := current_setting('t.shopper')::uuid;
BEGIN
  SELECT id INTO v_beer FROM public.products WHERE name = 'Beer ' || current_setting('t.tok');
  SELECT id INTO v_rx FROM public.products WHERE name = 'Rx ' || current_setting('t.tok');
  SELECT id INTO v_rx_parent FROM public.products
   WHERE name = 'Rx by parent ' || current_setting('t.tok');
  SELECT id INTO v_plain FROM public.products
   WHERE name = 'Paracetamol ' || current_setting('t.tok');
  IF public.product_online_restriction(v_beer) IS DISTINCT FROM 'age_18'
     OR public.product_online_restriction(v_rx) IS DISTINCT FROM 'prescription'
     OR public.product_online_restriction(v_rx_parent) IS DISTINCT FROM 'prescription'
     OR public.product_online_restriction(v_plain) IS NOT NULL THEN
    RAISE EXCEPTION 'product_online_restriction misclassified';
  END IF;
  IF NOT public.shopper_age_confirmation_missing(v_uid, ARRAY[v_plain, v_beer]) THEN
    RAISE EXCEPTION 'unconfirmed shopper must be refused an 18+ item';
  END IF;
  IF public.shopper_age_confirmation_missing(v_uid, ARRAY[v_plain]) THEN
    RAISE EXCEPTION 'no confirmation needed without an 18+ item';
  END IF;
END;
$$;

-- 4. Prescription items are never returned by any storefront RPC (signed out).
SET LOCAL ROLE anon;
DO $$
DECLARE
  v_names text[];
  v_tok text := current_setting('t.tok');
  v_state text := 'State ' || current_setting('t.tok');
  v_store uuid := current_setting('t.store')::uuid;
  v_id uuid;
BEGIN
  SELECT array_agg(name) INTO v_names FROM (
    SELECT name FROM public.storefront_feed('Nigeria', v_state, 'Lga', NULL, NULL, 100)
    UNION ALL
    SELECT name FROM public.storefront_search(v_tok, 'Nigeria', v_state, 'Lga', NULL, NULL, 100)
    UNION ALL
    SELECT name FROM public.storefront_store_products(v_store, NULL, NULL, NULL, 100)
  ) s;
  IF NOT ('Beer ' || v_tok = ANY (v_names)) OR NOT ('Paracetamol ' || v_tok = ANY (v_names)) THEN
    RAISE EXCEPTION 'fixture not listed: %', v_names;
  END IF;
  IF 'Rx ' || v_tok = ANY (v_names) OR 'Rx by parent ' || v_tok = ANY (v_names) THEN
    RAISE EXCEPTION 'prescription item listed: %', v_names;
  END IF;
  FOR v_id IN SELECT id FROM public.products WHERE name IN
      ('Rx ' || v_tok, 'Rx by parent ' || v_tok) LOOP
    IF EXISTS (SELECT 1 FROM public.storefront_product_photos(v_store, v_id)) THEN
      RAISE EXCEPTION 'prescription photo returned';
    END IF;
  END LOOP;
  BEGIN
    PERFORM public.shopper_confirm_age();
    RAISE EXCEPTION 'anon confirmed an age';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- 5. A signed-in Shopper confirms once (idempotent); the rule then passes.
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('t.shopper'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_first timestamptz;
BEGIN
  IF public.shopper_age_confirmed_at() IS NOT NULL THEN
    RAISE EXCEPTION 'fresh login must be unconfirmed';
  END IF;
  v_first := public.shopper_confirm_age();
  IF v_first IS NULL OR public.shopper_confirm_age() <> v_first
     OR public.shopper_age_confirmed_at() <> v_first THEN
    RAISE EXCEPTION 'confirmation must be recorded once and kept';
  END IF;
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF public.shopper_age_confirmation_missing(current_setting('t.shopper')::uuid,
       ARRAY(SELECT id FROM public.products
              WHERE name = 'Beer ' || current_setting('t.tok'))) THEN
    RAISE EXCEPTION 'confirmed shopper must pass the 18+ rule';
  END IF;
END;
$$;

ROLLBACK;
