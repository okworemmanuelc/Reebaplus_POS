-- 0058_funds_rls_via_profiles.sql
--
-- Fix 42501 "new row violates row-level security policy" on funds_accounts /
-- fund_days / fund_transactions.
--
-- 0057 created these policies with the pre-0051 membership-subquery pattern
-- (auth.uid() -> users.auth_user_id -> user_businesses). As 0050/0051 document,
-- that path returns empty whenever users.auth_user_id has drifted from the
-- caller's auth.uid(), so every USING / WITH CHECK fails with 42501 even though
-- the profiles path is intact. The CEO's funds writes were rejected on push for
-- exactly this reason.
--
-- Fix: redefine the three policies to resolve the caller's business via
-- public.current_user_business_ids() (profiles-based, the canonical path every
-- other synced table uses). No schema changes.

BEGIN;

DROP POLICY IF EXISTS "funds_accounts_tenant_rw" ON public.funds_accounts;
CREATE POLICY "funds_accounts_tenant_rw" ON public.funds_accounts
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "fund_days_tenant_rw" ON public.fund_days;
CREATE POLICY "fund_days_tenant_rw" ON public.fund_days
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "fund_transactions_tenant_rw" ON public.fund_transactions;
CREATE POLICY "fund_transactions_tenant_rw" ON public.fund_transactions
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

COMMIT;
