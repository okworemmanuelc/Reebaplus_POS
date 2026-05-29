-- =============================================================================
-- 0050_rollback.sql — reverse of 0050_fix_user_businesses_rls_recursion.sql.
--
-- Restores the original (recursive) policies exactly as 0042 defined them and
-- drops the current_user_business_ids() helper. WARNING: this reintroduces the
-- 42P17 infinite-recursion bug on user_businesses and the five *_tenant_rw
-- tables — only run it to get back to the pre-0050 state. No data is touched.
-- =============================================================================

BEGIN;

-- 1. Restore the six policies to their 0042 definitions.
DROP POLICY IF EXISTS "user_businesses_self_or_member" ON public.user_businesses;
CREATE POLICY "user_businesses_self_or_member" ON public.user_businesses
  FOR ALL TO authenticated
  USING (
    user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    OR business_id IN (
      SELECT ub.business_id FROM public.user_businesses ub
       WHERE ub.user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
         AND ub.status = 'active'
    )
  )
  WITH CHECK (
    user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    OR business_id IN (
      SELECT ub.business_id FROM public.user_businesses ub
       WHERE ub.user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
         AND ub.status = 'active'
    )
  );

DROP POLICY IF EXISTS "roles_tenant_rw" ON public.roles;
CREATE POLICY "roles_tenant_rw" ON public.roles
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

DROP POLICY IF EXISTS "role_permissions_tenant_rw" ON public.role_permissions;
CREATE POLICY "role_permissions_tenant_rw" ON public.role_permissions
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

DROP POLICY IF EXISTS "role_settings_tenant_rw" ON public.role_settings;
CREATE POLICY "role_settings_tenant_rw" ON public.role_settings
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

DROP POLICY IF EXISTS "invite_codes_tenant_rw" ON public.invite_codes;
CREATE POLICY "invite_codes_tenant_rw" ON public.invite_codes
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

DROP POLICY IF EXISTS "user_stores_tenant_rw" ON public.user_stores;
CREATE POLICY "user_stores_tenant_rw" ON public.user_stores
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

-- 2. Drop the helper added in 0050.
DROP FUNCTION IF EXISTS public.current_user_business_ids();

COMMIT;
