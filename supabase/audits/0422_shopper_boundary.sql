-- #422: read-only catalogue audit. Run as an operator, not as an app RPC.
-- Contains no tenant row data and performs no writes or schema changes.

SELECT c.relname AS tenant_table, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  AND (c.relname = 'businesses' OR EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = c.oid AND a.attname = 'business_id' AND NOT a.attisdropped
  ))
ORDER BY c.relname;

SELECT tablename, policyname, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname IN ('public', 'storage')
ORDER BY schemaname, tablename, policyname;

-- Inventory ALL definer functions, not just the mobile repo's pos_* RPCs.
-- Table/entity IDs in an argument are sufficient to require a tenant guard;
-- SECURITY DEFINER bypasses RLS even when every table above has it enabled.
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS shopper_execute,
  p.proconfig AS settings, p.prosrc AS body
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef
ORDER BY p.proname, arguments;

-- The pointer authority and the profile-write policies must be reviewed together.
SELECT pg_get_functiondef('public.current_user_business_ids()'::regprocedure),
  pg_get_functiondef('public.business_id()'::regprocedure);

SELECT version, name FROM supabase_migrations.schema_migrations
ORDER BY version DESC LIMIT 5;
