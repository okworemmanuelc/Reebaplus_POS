-- 0260_rls_initplan_helpers.sql
--
-- #839 (2026-11-22): sync slows down as a shop's history grows.
--
-- Every public RLS policy calls helper functions like
--   business_id = business_id()        (169 uses)
--   is_console_admin()                 (40 uses)
--   owner_id = auth.uid()              (15 uses)
-- Written bare, Postgres re-runs the helper for EVERY row it reads. Measured
-- on prod for the largest shop (11k order_items): a late pull page took 602 ms
-- as the phone's user, 92 ms with the lookup run once. Full-pull pages
-- averaged 2.5 s and peaked at 7.8 s against the 8 s statement_timeout.
--
-- Change: wrap each call as a scalar sub-select, e.g.
--   business_id = (SELECT public.business_id())
-- so the planner runs it ONCE per statement (an InitPlan). Same value, same
-- rows allowed; only the number of calls changes. This is the Supabase
-- "auth_rls_initplan" advice applied to our own helpers too.
--
-- Done in place with ALTER POLICY over the live definitions (pg_policies), so
-- it is identical on dev and prod and needs no hand-copied policy text. Only
-- the expressions change; policy names, commands, roles and permissive/
-- restrictive settings are untouched. Idempotent: an already-wrapped call
-- (deparsed as "SELECT business_id() AS ...") is skipped by the look-behind.
-- `IN (SELECT current_user_business_ids())` is already a sub-select and is
-- left alone. public schema only (storage.objects belongs to Supabase).
--
-- No table, column, status or money rule changes -> no pos-parity issue.

DO $mig$
DECLARE
  r       record;
  v_qual  text;
  v_check text;
  v_sql   text;
  n       int := 0;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname, qual, with_check
      FROM pg_policies
     WHERE schemaname = 'public'
  LOOP
    v_qual := r.qual;
    v_check := r.with_check;

    IF v_qual IS NOT NULL THEN
      v_qual := regexp_replace(v_qual,
        '(?<![.\w])(?<!SELECT )business_id\(\)',
        '(SELECT public.business_id())', 'g');
      v_qual := regexp_replace(v_qual,
        '(?<![.\w])(?<!SELECT )is_console_admin\(\)',
        '(SELECT public.is_console_admin())', 'g');
      v_qual := regexp_replace(v_qual,
        '(?<!SELECT )auth\.uid\(\)',
        '(SELECT auth.uid())', 'g');
    END IF;

    IF v_check IS NOT NULL THEN
      v_check := regexp_replace(v_check,
        '(?<![.\w])(?<!SELECT )business_id\(\)',
        '(SELECT public.business_id())', 'g');
      v_check := regexp_replace(v_check,
        '(?<![.\w])(?<!SELECT )is_console_admin\(\)',
        '(SELECT public.is_console_admin())', 'g');
      v_check := regexp_replace(v_check,
        '(?<!SELECT )auth\.uid\(\)',
        '(SELECT auth.uid())', 'g');
    END IF;

    IF v_qual IS NOT DISTINCT FROM r.qual
       AND v_check IS NOT DISTINCT FROM r.with_check THEN
      CONTINUE;
    END IF;

    v_sql := format('ALTER POLICY %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
    IF v_qual IS DISTINCT FROM r.qual THEN
      v_sql := v_sql || format(' USING (%s)', v_qual);
    END IF;
    IF v_check IS DISTINCT FROM r.with_check THEN
      v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE v_sql;
    n := n + 1;
  END LOOP;

  RAISE NOTICE '0260: rewrote % policies', n;
END
$mig$;
