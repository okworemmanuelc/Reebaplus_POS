-- 0036_terminate_member_explicit_ceo_guard.sql
--
-- Adds an explicit "CEO cannot be fired" guard to public.terminate_member.
--
-- Today the function only protects the CEO transitively, via the strict
-- tier check (`v_actor_tier <= v_target_tier` rejects). Because the CEO
-- is tier 6 and no other role is tier 6, no current staff role can fire
-- a CEO — but the protection relies on the one-CEO-per-business
-- invariant, which is not enforced anywhere in the schema. A second
-- tier-6 membership (created by future code, manual SQL, or a bug) would
-- be able to fire the first CEO, since `6 <= 6` fails the strict-greater
-- check.
--
-- The spec for the staff-lifecycle work says "A business has one CEO
-- (the owner). The CEO cannot be fired." Make that rule unconditional in
-- the function itself, independent of any uniqueness invariant elsewhere
-- in the schema. The new guard sits between the existence check (target
-- has a membership in this business) and the tier check (caller outranks
-- target), so a no-op self-terminate or no-op against a missing member
-- still short-circuits at the right place.
--
-- Same signature, same body as 0035 except for the four new lines. CREATE
-- OR REPLACE FUNCTION is sufficient.

BEGIN;

CREATE OR REPLACE FUNCTION public.terminate_member(
  p_user_id     uuid,
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid    uuid := auth.uid();
  v_actor_id    uuid;
  v_actor_tier  int;
  v_target_tier int;
  v_target_name text;
  v_sentinel    text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolve caller. "Active member" = auth.uid mapped to a users row in
  -- this business with a matching business_members row.
  SELECT u.id, bm.role_tier
    INTO v_actor_id, v_actor_tier
    FROM public.users u
    JOIN public.business_members bm
      ON bm.user_id = u.id
     AND bm.business_id = u.business_id
   WHERE u.auth_user_id = v_auth_uid
     AND u.business_id  = p_business_id
   LIMIT 1;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'forbidden:not_active_member'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_actor_id = p_user_id THEN
    RAISE EXCEPTION 'forbidden:cannot_terminate_self'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Snapshot target's tier + name BEFORE deleting/anonymizing.
  SELECT bm.role_tier, u.name
    INTO v_target_tier, v_target_name
    FROM public.users u
    JOIN public.business_members bm
      ON bm.user_id = u.id
     AND bm.business_id = u.business_id
   WHERE u.id = p_user_id
     AND u.business_id = p_business_id
   LIMIT 1;

  IF v_target_tier IS NULL THEN
    -- No active membership for this user in this business — idempotent
    -- no-op. Could be a re-fire after the row already vanished.
    RETURN jsonb_build_object('ok', true, 'no_op', true);
  END IF;

  -- CEO is never a fireable target. Unconditional — independent of the
  -- tier-guard below, which only protects CEO transitively (and would
  -- fail if a second tier-6 membership ever existed in this business).
  IF v_target_tier = 6 THEN
    RAISE EXCEPTION 'forbidden:cannot_terminate_ceo'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Tier guard: caller must outrank the target.
  IF v_actor_tier <= v_target_tier THEN
    RAISE EXCEPTION 'forbidden:tier_too_low'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1. Hard-delete the membership row — cuts the association. Realtime
  --    fires a DELETE event the new client listens to for the kick.
  DELETE FROM public.business_members
   WHERE user_id     = p_user_id
     AND business_id = p_business_id;

  -- 2. Anonymize the users row in place. Identity fields wiped; name kept.
  --    The sentinel uses the row's id to guarantee uniqueness on the
  --    UNIQUE(business_id, email) slot without leaking the original.
  --    auth_user_id=NULL frees the UNIQUE(auth_user_id) slot so a fresh
  --    accept_invite for the same Supabase user can INSERT cleanly.
  v_sentinel := 'deleted-' || p_user_id::text || '@deleted.local';

  UPDATE public.users
     SET auth_user_id    = NULL,
         email           = v_sentinel,
         last_updated_at = now()
   WHERE id = p_user_id
     AND business_id = p_business_id;

  -- 3. Activity log — replaces the removed_at/removed_by audit fields
  --    that lived on the now-deleted business_members row.
  INSERT INTO public.activity_logs (
    business_id, user_id, action, description
  ) VALUES (
    p_business_id,
    v_actor_id,
    'member.terminated',
    format('Terminated %s (was tier %s); membership row deleted, user row anonymized.',
           v_target_name, v_target_tier)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', p_user_id,
    'business_id', p_business_id
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.terminate_member(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.terminate_member(uuid, uuid) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification:
--
--   1. Function body has the new guard at the right place:
--      SELECT position('forbidden:cannot_terminate_ceo' IN pg_get_functiondef(oid)) > 0
--      FROM pg_proc
--      WHERE proname='terminate_member' AND pronamespace='public'::regnamespace;
--      -- expect t
--
--   2. Live behaviour (as a manager calling against a CEO target):
--      SELECT public.terminate_member(
--        '<ceo_user_id>'::uuid,
--        '<biz_id>'::uuid
--      );
--      -- expect ERROR: forbidden:cannot_terminate_ceo  (SQLSTATE 42501)
--
--   3. Non-CEO targets still terminate normally (no regression):
--      -- exercise via the staff screen Terminate action against a cashier.
-- =============================================================================
