-- #425 tier-2 SQL companion (reebaplus-dev, after applying 0202).
-- Read-only; everything runs inside a transaction that is rolled back.
--   psql "$DEV_DB_URL" -f test/integration/sql/storefront_browse.sql
BEGIN;

-- 1. EXECUTE boundaries: public RPCs for anon + authenticated, helpers server-only.
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.storefront_feed(text,text,text,text,text,integer)',
    'public.storefront_search(text,text,text,text,text,text,integer)',
    'public.storefront_store(uuid,text,text,text)',
    'public.storefront_store_products(uuid,text,text,text,integer)'
  ] LOOP
    IF NOT has_function_privilege('anon', fn, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be callable signed out', fn;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = fn::regprocedure) THEN
      RAISE EXCEPTION '% must be SECURITY DEFINER', fn;
    END IF;
  END LOOP;
  FOREACH fn IN ARRAY ARRAY[
    'public._storefront_stores(uuid)',
    'public._storefront_reach(text,text,text)',
    'public._storefront_cards(text,text,text,text,uuid,text,text,text,integer)'
  ] LOOP
    IF has_function_privilege('anon', fn, 'EXECUTE')
       OR has_function_privilege('authenticated', fn, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be server-only', fn;
    END IF;
  END LOOP;
END;
$$;

-- 2. Speed (record the timings in the PR / progress tracker).
EXPLAIN (ANALYZE, BUFFERS)
  SELECT * FROM public.storefront_feed('Nigeria', 'Nasarawa', 'Keffi', NULL, NULL, 24);
EXPLAIN (ANALYZE, BUFFERS)
  SELECT * FROM public.storefront_feed('Nigeria', NULL, NULL, NULL, NULL, 24);
EXPLAIN (ANALYZE, BUFFERS)
  SELECT * FROM public.storefront_search('star', 'Nigeria', NULL, NULL, NULL, NULL, 24);
-- The trigram index must serve a name filter on listable products.
SET LOCAL enable_seqscan = off;
EXPLAIN
  SELECT id FROM public.products
   WHERE show_online AND is_available AND NOT is_deleted
     AND public.storefront_search_key(name) LIKE '%star%';

ROLLBACK;
