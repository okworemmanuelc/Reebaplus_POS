-- Development test backend only. Fixture business/category rows are rolled back.
BEGIN;
DO $test$
DECLARE
  caller_role text;
  statement text;
  denied integer := 0;
  fixture_business uuid := gen_random_uuid();
  fixture_category uuid := gen_random_uuid();
BEGIN
  FOREACH caller_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    FOREACH statement IN ARRAY ARRAY[
      'INSERT INTO public.marketplace_categories(slug,name,sort) VALUES (''test-private-write'', ''Test'',999)',
      'UPDATE public.marketplace_categories SET name = ''Changed'' WHERE slug = ''other''',
      'DELETE FROM public.marketplace_categories WHERE slug = ''other'''
    ] LOOP
      BEGIN
        EXECUTE format('SET LOCAL ROLE %I', caller_role);
        EXECUTE statement;
        RAISE EXCEPTION 'unexpected reference write by %', caller_role;
      EXCEPTION WHEN insufficient_privilege THEN
        denied := denied + 1;
      END;
      RESET ROLE;
    END LOOP;
  END LOOP;
  IF denied <> 6 THEN RAISE EXCEPTION 'expected six write denials'; END IF;

  INSERT INTO public.businesses(id,name)
    VALUES (fixture_business, 'Category mapping integration fixture');
  INSERT INTO public.categories(id,business_id,name,marketplace_category)
    VALUES (fixture_category,fixture_business,'Phones','phones');
  BEGIN
    UPDATE public.categories SET marketplace_category = 'unknown-invalid-slug'
      WHERE id = fixture_category;
    RAISE EXCEPTION 'unknown category mapping was accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  UPDATE public.categories SET marketplace_category = NULL WHERE id = fixture_category;
  IF NOT EXISTS (SELECT 1 FROM public.categories
    WHERE id = fixture_category AND marketplace_category IS NULL) THEN
    RAISE EXCEPTION 'clearing a mapping failed';
  END IF;
END
$test$;
ROLLBACK;

SELECT
  'six write denials; valid mapping; invalid FK; null clearing passed' AS checks,
  count(*) AS reference_rows,
  bool_and(has_table_privilege('anon', 'public.marketplace_categories', 'SELECT'))
    AS anon_read,
  bool_and(has_table_privilege('authenticated', 'public.marketplace_categories', 'SELECT'))
    AS authenticated_read,
  bool_and(has_table_privilege('service_role', 'public.marketplace_categories', 'INSERT,UPDATE,DELETE'))
    AS service_write
FROM public.marketplace_categories;
