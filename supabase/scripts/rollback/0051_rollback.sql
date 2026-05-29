-- =============================================================================
-- 0051_rollback.sql — reverse of 0051_business_ids_via_profiles.sql.
--
-- Restores current_user_business_ids() to its 0050 body (resolve via
-- users.auth_user_id -> user_businesses). WARNING: this reinstates the
-- profiles/users divergence sensitivity that causes 42501 on the membership
-- tables when users.auth_user_id is not aligned with the caller's auth.uid().
-- Only run it to get back to the pre-0051 state. No data is touched.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.current_user_business_ids()
RETURNS SETOF uuid
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public
AS $$
  SELECT ub.business_id FROM public.user_businesses ub
  JOIN public.users u ON u.id = ub.user_id
  WHERE u.auth_user_id = auth.uid() AND ub.status = 'active';
$$;

REVOKE ALL ON FUNCTION public.current_user_business_ids() FROM public;
GRANT EXECUTE ON FUNCTION public.current_user_business_ids() TO authenticated;

COMMIT;
