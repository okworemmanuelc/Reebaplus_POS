-- 0075_expense_budgets_rls_via_profiles.sql
--
-- Fix 42501 "new row violates row-level security policy for table
-- expense_budgets" on Set monthly budget (§20.1/§20.3).
--
-- 0073 created expense_budgets_tenant_rw with the pre-0051 membership-subquery
-- pattern (auth.uid() -> users.auth_user_id -> user_businesses) — the same
-- already-broken shape that 0071 (fund_day_closings) and 0074 (stock_counts)
-- had to rewrite. As 0050/0051/0058/0071/0074 document, the inline subquery
-- runs as the *invoker* (subject to RLS on users/user_businesses) and returns
-- empty whenever users.auth_user_id has drifted from the caller's auth.uid(),
-- so every USING / WITH CHECK fails with 42501 even though the profiles path is
-- intact. The CEO "Set budget" upsert is rejected on push for exactly this
-- reason (reads still work — pos_pull_snapshot uses the profiles-based
-- public.business_id() — so the breakage is push-only and silent).
--
-- Fix: redefine the policy to resolve the caller's business via
-- public.current_user_business_ids() (profiles-based since 0051, SECURITY
-- DEFINER so the membership lookup can't be filtered out by RLS) — the
-- canonical path every other synced tenant table uses. Identical shape to
-- 0071/0074. No schema changes. The pending expense_budgets upsert still in the
-- sync queue flushes the moment this deploys (Retry now, or on the next
-- backoff tick).

BEGIN;

DROP POLICY IF EXISTS "expense_budgets_tenant_rw" ON public.expense_budgets;
CREATE POLICY "expense_budgets_tenant_rw" ON public.expense_budgets
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

COMMIT;
