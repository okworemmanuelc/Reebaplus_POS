-- 0230_enforce_plan_staff_pause.sql
--
-- Reebaplus - server-side pausing of over-limit staff (reebaplus-web#90 gap).
--
-- 0224 limits ADDING staff but, by design, never touches existing rows, so after
-- a downgrade the client only hides/pauses extras (pausedStaffIdsProvider).
-- This adds the server half as a callable function. It is NOT scheduled and NOT
-- called by anything yet: a later job (or the billing webhook) invokes it.
--
--   public.enforce_plan_staff_pause(p_business_id uuid) RETURNS uuid[]
--
-- When the business has more ACTIVE members than the effective plan's max_staff,
-- the extras get status 'suspended'. Kept first: the owner (role slug 'ceo'),
-- then the longest-serving (created_at ASC, id ASC) - the same ordering as the
-- app's pausedStaffIds(). Owners are never suspended, even if that leaves the
-- business over the cap. Returns the user_id of every member it suspended
-- (empty array when nothing to do), so a caller can re-activate them later.
--
-- Interaction with trg_user_businesses_plan_limit (0224): suspending is an
-- UPDATE to 'suspended', which that trigger ignores (it only checks rows going
-- to 'active'). RE-ACTIVATION is limit-checked: setting a row back to 'active'
-- raises plan_limit_staff while active >= max_staff, so re-activate only after
-- the plan was raised (or in cap order). 'removed' members are never touched.
--
-- SECURITY DEFINER, execute revoked from everyone but service_role.

BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_plan_staff_pause(p_business_id uuid)
RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_max int;
  v_ids uuid[];
BEGIN
  SELECT l.max_staff INTO v_max
    FROM public.business_plan_limits(public.business_effective_plan(p_business_id)) l;

  IF v_max IS NULL THEN
    RETURN ARRAY[]::uuid[];   -- unlimited plan
  END IF;

  WITH ranked AS (
    SELECT ub.id, ub.user_id,
           row_number() OVER (
             ORDER BY (r.slug = 'ceo') DESC NULLS LAST, ub.created_at ASC, ub.id ASC
           ) AS rn,
           COALESCE(r.slug = 'ceo', false) AS is_owner
      FROM public.user_businesses ub
      LEFT JOIN public.roles r ON r.id = ub.role_id
     WHERE ub.business_id = p_business_id
       AND ub.status = 'active'
  ), paused AS (
    UPDATE public.user_businesses ub
       SET status = 'suspended',
           last_updated_at = now()
      FROM ranked
     WHERE ub.id = ranked.id
       AND ranked.rn > v_max
       AND NOT ranked.is_owner
    RETURNING ub.user_id, ranked.rn
  )
  SELECT COALESCE(array_agg(user_id ORDER BY rn), ARRAY[]::uuid[])
    INTO v_ids FROM paused;

  RETURN v_ids;
END $$;

REVOKE ALL ON FUNCTION public.enforce_plan_staff_pause(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_plan_staff_pause(uuid) TO service_role;

COMMIT;
