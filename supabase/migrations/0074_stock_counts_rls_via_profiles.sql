-- 0074_stock_counts_rls_via_profiles.sql
--
-- Fix 42501 "new row violates row-level security policy for table stock_counts"
-- on Save Count (§17).
--
-- 0072 created stock_counts_tenant_rw with the pre-0051 membership-subquery
-- pattern (auth.uid() -> users.auth_user_id -> user_businesses), copied from
-- 0068's fund_day_closings policy — which was ITSELF already broken and had to
-- be rewritten by 0071. As 0050/0051/0058/0071 document, the inline subquery
-- runs as the *invoker* (subject to RLS on users/user_businesses) and returns
-- empty whenever users.auth_user_id has drifted from the caller's auth.uid(),
-- so every USING / WITH CHECK fails with 42501 even though the profiles path is
-- intact. The Daily Stock Count session upserts would be rejected on push for
-- exactly this reason (reads still work — pos_pull_snapshot uses the
-- profiles-based public.business_id() — so the breakage is push-only and silent).
--
-- Fix: redefine the policy to resolve the caller's business via
-- public.current_user_business_ids() (profiles-based since 0051, SECURITY
-- DEFINER so the membership lookup can't be filtered out by RLS) — the
-- canonical path every other synced tenant table uses. Identical shape to
-- 0071/0058. No schema changes. Pending stock_counts upserts still in the sync
-- queue flush the moment this deploys (Retry now, or on the next backoff tick).

BEGIN;

DROP POLICY IF EXISTS "stock_counts_tenant_rw" ON public.stock_counts;
CREATE POLICY "stock_counts_tenant_rw" ON public.stock_counts
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

COMMIT;
