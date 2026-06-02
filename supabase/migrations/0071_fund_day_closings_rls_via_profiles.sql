-- 0071_fund_day_closings_rls_via_profiles.sql
--
-- Fix 42501 "new row violates row-level security policy for table
-- fund_day_closings" on Close Day (§23.6).
--
-- 0068 created fund_day_closings_tenant_rw with the pre-0051 membership-subquery
-- pattern (auth.uid() -> users.auth_user_id -> user_businesses), copied verbatim
-- from 0057's ORIGINAL fund_days policy. But 0057's policy was already superseded
-- by 0058: as 0050/0051 document, the inline subquery runs as the *invoker*
-- (subject to RLS on users/user_businesses) and returns empty whenever
-- users.auth_user_id has drifted from the caller's auth.uid(), so every USING /
-- WITH CHECK fails with 42501 even though the profiles path is intact. The CEO's
-- Close Day per-account upserts were rejected on push for exactly this reason,
-- while funds_accounts / fund_days / fund_transactions (already on the 0058 path)
-- synced fine.
--
-- Fix: redefine the policy to resolve the caller's business via
-- public.current_user_business_ids() (profiles-based since 0051, SECURITY DEFINER
-- so the membership lookup can't be filtered out by RLS) — the canonical path
-- every other synced tenant table uses. Identical shape to 0058. No schema
-- changes. Pending fund_day_closings upserts still in the sync queue flush the
-- moment this deploys (Retry now, or on the next backoff tick).

BEGIN;

DROP POLICY IF EXISTS "fund_day_closings_tenant_rw" ON public.fund_day_closings;
CREATE POLICY "fund_day_closings_tenant_rw" ON public.fund_day_closings
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

COMMIT;
