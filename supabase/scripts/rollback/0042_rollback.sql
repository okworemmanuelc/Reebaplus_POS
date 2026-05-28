-- 0042_rollback.sql — rollback for migration 0042_create_roles_permissions_tables.sql
--
-- WHEN TO USE
--   * 0042 itself failed mid-way (rare — the whole migration is one
--     transaction, so a failure auto-rolls back. This file only
--     matters if you committed 0042 and then need to back out.)
--   * 0042 deployed cleanly but you want to undo it before 0043
--     runs (e.g. design change before the seed).
--
-- WHAT THIS DOES
--   Drops the seven tables, their RLS policies, indexes, triggers,
--   and removes them from the realtime publication. Does NOT drop
--   `_bump_last_updated_at()` — that function is reusable and other
--   future migrations may rely on it.
--
-- WHAT THIS DOES NOT DO
--   * Does not roll back 0043 or 0044. If those have already run,
--     run their rollback scripts FIRST (0044_rollback.sql first, then
--     0043_rollback.sql, then this file). 0043 left rows in the
--     tables; this file drops the tables anyway and CASCADE handles
--     the rows, but you lose the deletion audit trail.
--   * Does not touch the Drift client. Local devices on schema v13
--     will see empty cloud tables on next pull and behave as if the
--     business has no roles. Roll the client back to v12 separately
--     if needed (Drift doesn't natively support downgrades — easiest
--     path is `clearAllData()` and re-onboard).
--
-- VERIFY BEFORE RUNNING
--   psql -c "SELECT COUNT(*) FROM public.user_businesses"
--   psql -c "SELECT COUNT(*) FROM public.role_permissions"
--   -- Confirm these are what you expect to lose.

BEGIN;

-- 1. Drop triggers (table drops would clean these up, but explicit is
--    safer and faster).
DROP TRIGGER IF EXISTS bump_user_stores_last_updated_at      ON public.user_stores;
DROP TRIGGER IF EXISTS bump_invite_codes_last_updated_at     ON public.invite_codes;
DROP TRIGGER IF EXISTS bump_user_businesses_last_updated_at  ON public.user_businesses;
DROP TRIGGER IF EXISTS bump_role_settings_last_updated_at    ON public.role_settings;
DROP TRIGGER IF EXISTS bump_role_permissions_last_updated_at ON public.role_permissions;
DROP TRIGGER IF EXISTS bump_roles_last_updated_at            ON public.roles;

-- 2. Remove from realtime publication. Doing this BEFORE the drop
--    avoids "publication membership orphan" warnings.
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.user_stores;
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.invite_codes;
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.user_businesses;
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.role_settings;
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.role_permissions;
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.roles;

-- 3. Drop tables. CASCADE cleans up policies, indexes, and any
--    dangling FKs. Reverse FK-dependency order (children first).
DROP TABLE IF EXISTS public.user_stores      CASCADE;
DROP TABLE IF EXISTS public.invite_codes     CASCADE;
DROP TABLE IF EXISTS public.user_businesses  CASCADE;
DROP TABLE IF EXISTS public.role_settings    CASCADE;
DROP TABLE IF EXISTS public.role_permissions CASCADE;
DROP TABLE IF EXISTS public.roles            CASCADE;
DROP TABLE IF EXISTS public.permissions      CASCADE;

-- 4. _bump_last_updated_at() left in place intentionally. Future
--    migrations may use it. If you're absolutely sure no other table
--    uses it, drop manually:
--      DROP FUNCTION IF EXISTS public._bump_last_updated_at() CASCADE;

COMMIT;

-- =============================================================================
-- Verify rollback:
--   SELECT to_regclass('public.permissions');       -- expect NULL
--   SELECT to_regclass('public.roles');             -- expect NULL
--   SELECT to_regclass('public.role_permissions');  -- expect NULL
--   SELECT to_regclass('public.role_settings');     -- expect NULL
--   SELECT to_regclass('public.user_businesses');   -- expect NULL
--   SELECT to_regclass('public.invite_codes');      -- expect NULL
--   SELECT to_regclass('public.user_stores');       -- expect NULL
-- =============================================================================
