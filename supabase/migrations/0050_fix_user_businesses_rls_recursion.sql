-- 0050_fix_user_businesses_rls_recursion.sql
--
-- Reebaplus — fix infinite-recursion RLS on the membership tables.
--
-- Bug: 0042 defined "user_businesses_self_or_member" ON public.user_businesses
-- with a USING / WITH CHECK branch that subqueries public.user_businesses
-- itself. Postgres re-applies the table's own policy while evaluating that
-- subquery → error 42P17 (infinite recursion in policy) on any authenticated
-- read or write of user_businesses. The five sibling "*_tenant_rw" policies
-- (roles, role_permissions, role_settings, invite_codes, user_stores) all
-- subquery user_businesses too, so reads of those tables re-trigger the same
-- recursion.
--
-- Fix: a SECURITY DEFINER helper, current_user_business_ids(), reads
-- user_businesses as the function owner — RLS is bypassed inside a definer
-- function — and returns the caller's active business ids. Every policy that
-- previously inlined `SELECT business_id FROM public.user_businesses WHERE …`
-- is dropped and recreated (same names, same intent) calling the helper
-- instead, so the membership lookup no longer re-enters the policy.
--
-- The "own membership" branch of user_businesses_self_or_member is kept as-is
-- (user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())):
-- it reads public.users, not user_businesses, so it never recursed. Only the
-- self-referencing business_id branch is swapped for the helper. Access rules
-- are unchanged — own membership row, plus any row in a business the caller is
-- an active member of.
--
-- No data is touched; this only redefines one function and six policies.

BEGIN;

-- -------------------------------------------------------------------------
-- 1. SECURITY DEFINER helper — the caller's active business ids, read with
--    RLS bypassed so the membership lookup can't recurse into any policy.
-- -------------------------------------------------------------------------
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

-- -------------------------------------------------------------------------
-- 2. Recreate the six recursive policies from 0042, same names + intent,
--    with the inline user_businesses subquery replaced by the helper.
-- -------------------------------------------------------------------------

-- 2a. user_businesses — bootstrap-safe self-or-member visibility. First
--     branch (own membership via public.users) is unchanged; only the
--     self-referencing business_id branch swaps to the helper.
DROP POLICY IF EXISTS "user_businesses_self_or_member" ON public.user_businesses;
CREATE POLICY "user_businesses_self_or_member" ON public.user_businesses
  FOR ALL TO authenticated
  USING (
    user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    OR business_id IN (SELECT public.current_user_business_ids())
  )
  WITH CHECK (
    user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    OR business_id IN (SELECT public.current_user_business_ids())
  );

-- 2b-2f. Standard "tenant member" policy for the remaining five tables.
DROP POLICY IF EXISTS "roles_tenant_rw" ON public.roles;
CREATE POLICY "roles_tenant_rw" ON public.roles
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "role_permissions_tenant_rw" ON public.role_permissions;
CREATE POLICY "role_permissions_tenant_rw" ON public.role_permissions
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "role_settings_tenant_rw" ON public.role_settings;
CREATE POLICY "role_settings_tenant_rw" ON public.role_settings
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "invite_codes_tenant_rw" ON public.invite_codes;
CREATE POLICY "invite_codes_tenant_rw" ON public.invite_codes
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "user_stores_tenant_rw" ON public.user_stores;
CREATE POLICY "user_stores_tenant_rw" ON public.user_stores
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

COMMIT;
