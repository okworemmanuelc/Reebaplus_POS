-- 0255: Free plan allows 2 staff accounts (owner + 1), up from owner-only.
--
-- Owner decision 2026-11-08: every new shop starts on Free and should be able
-- to add one helper without upgrading. business_plan_limits() is the single
-- source both staff guards read (the user_businesses insert/activate guard from
-- 0238 and the plan-pause sweep from 0230), so only this function changes.
-- Existing Free shops get the same allowance. Mirrors: the app's
-- limitsForPlan() (subscription_plan.dart) and the console's LIMITS
-- (reebaplus-web src/lib/subscription.js).

CREATE OR REPLACE FUNCTION public.business_plan_limits(p_plan text)
 RETURNS TABLE(max_stores integer, max_staff integer, warehouse_allowed boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT t.max_stores, t.max_staff, t.warehouse_allowed
    FROM (VALUES
      ('free'::text,    1,          2,          false),
      ('basic'::text,   1,          5,          false),
      ('premium'::text, NULL::int,  NULL::int,  true)
    ) AS t(plan, max_stores, max_staff, warehouse_allowed)
   WHERE t.plan = CASE WHEN p_plan IN ('free','basic','premium') THEN p_plan ELSE 'free' END
$function$;
