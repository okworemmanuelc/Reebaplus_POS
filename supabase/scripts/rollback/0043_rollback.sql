-- 0043_rollback.sql — rollback for migration 0043_seed_permissions_and_backfill_businesses.sql
--
-- WHEN TO USE
--   * 0043 deployed but the seed produced wrong data (e.g. permission
--     keys misspelled, wrong default values), and you want to clear
--     the slate and re-seed.
--   * You want to roll back 0042 next, so the tables can drop cleanly.
--   * 0044 has NOT yet altered `complete_onboarding` to depend on
--     `seed_default_roles_for_business`. If 0044 has run, roll IT
--     back first (0044_rollback.sql), otherwise dropping the helper
--     here will break `complete_onboarding`.
--
-- WHAT THIS DOES
--   1. Drops the `seed_default_roles_for_business` helper function.
--   2. Deletes every backfilled row from the seven new tables, in
--      reverse FK order. This is wholesale — if a real user signed
--      up via the app AFTER 0044 ran, their CEO row gets wiped too.
--      Acceptable for dev / staging rollback; in production, scope
--      the DELETEs by `created_at` instead (see commented variant).
--
-- WHAT THIS DOES NOT DO
--   * Does not drop the seven tables. Use 0042_rollback.sql for that.
--   * Does not alter `complete_onboarding`. Use 0044_rollback.sql.
--
-- VERIFY BEFORE RUNNING
--   psql -c "SELECT COUNT(*) FROM public.user_businesses"
--   psql -c "SELECT COUNT(*) FROM public.user_stores"
--   psql -c "SELECT COUNT(*) FROM public.permissions"
--   -- These are the row counts you're about to clear.

BEGIN;

-- 1. Drop the helper. If 0044 still references it, this DROP will
--    fail (good — forces you to run 0044_rollback.sql first).
DROP FUNCTION IF EXISTS public.seed_default_roles_for_business(uuid);

-- 2. Wholesale delete of all backfilled data. Reverse FK order so the
--    child tables go first. ON CONFLICT in 0043 means re-running it
--    is idempotent — these deletes set things back to the post-0042
--    empty-tables state.
DELETE FROM public.user_stores;
DELETE FROM public.user_businesses;
DELETE FROM public.invite_codes;
DELETE FROM public.role_settings;
DELETE FROM public.role_permissions;
DELETE FROM public.roles;
DELETE FROM public.permissions;

-- 2b. ALTERNATIVE for production: scope by created_at instead so you
--      preserve any rows written after the migration (e.g. by a real
--      sign-up). Comment out the wholesale DELETEs above and use:
--
--      DELETE FROM public.user_stores      WHERE created_at < '2026-05-27';
--      DELETE FROM public.user_businesses  WHERE created_at < '2026-05-27';
--      DELETE FROM public.invite_codes     WHERE created_at < '2026-05-27';
--      DELETE FROM public.role_settings    WHERE created_at < '2026-05-27';
--      DELETE FROM public.role_permissions WHERE created_at < '2026-05-27';
--      DELETE FROM public.roles            WHERE created_at < '2026-05-27';
--      DELETE FROM public.permissions      WHERE created_at < '2026-05-27';
--      -- Replace the timestamp with one just before 0043's deploy time.

COMMIT;

-- =============================================================================
-- Verify rollback:
--   SELECT COUNT(*) FROM public.permissions;        -- expect 0
--   SELECT COUNT(*) FROM public.roles;              -- expect 0
--   SELECT COUNT(*) FROM public.role_permissions;   -- expect 0
--   SELECT COUNT(*) FROM public.role_settings;      -- expect 0
--   SELECT COUNT(*) FROM public.user_businesses;    -- expect 0
--   SELECT COUNT(*) FROM public.user_stores;        -- expect 0
--   SELECT proname FROM pg_proc
--    WHERE pronamespace='public'::regnamespace
--      AND proname='seed_default_roles_for_business';
--   -- expect zero rows
-- =============================================================================
