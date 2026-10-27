-- Rollback for 0230_enforce_plan_staff_pause.
-- Drops the function only. Members it already suspended STAY suspended; to
-- restore them, re-activate (limit-checked by trg_user_businesses_plan_limit):
--   update public.user_businesses set status='active'
--    where business_id = '<biz>' and user_id = any('{<ids returned by the call>}');
BEGIN;
DROP FUNCTION IF EXISTS public.enforce_plan_staff_pause(uuid);
DELETE FROM supabase_migrations.schema_migrations WHERE version = '0230';
COMMIT;
