-- #422: release gate: updated business clients must use the 0192 RPC first.
-- Do not deploy this with 0192 until that client rollout is complete.
BEGIN;
REVOKE SELECT ON public.deleted_businesses FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS deleted_businesses_select ON public.deleted_businesses;
COMMIT;
