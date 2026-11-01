-- 0238_user_businesses_is_hidden.sql
--
-- #622 (part of #619). A Reebaplus support login sits in a shop as a full-rights
-- CEO but is hidden from that shop's staff list, pickers, staff filters and
-- staff counts. History rows still resolve its name (the users row is synced as
-- before; only the MEMBERSHIP is flagged).
--
--   1. user_businesses.is_hidden boolean NOT NULL DEFAULT false.
--   2. Server-only flag. BEFORE INSERT OR UPDATE guard (same pattern as
--      enforce_subscription_immutable, 0224/0235): for authenticated / anon the
--      flag is forced to false on INSERT and kept at OLD on UPDATE, so a client
--      upsert can neither set nor clear it. Only service_role / the console /
--      SECURITY DEFINER RPCs (current_user not authenticated/anon) can flip it.
--      On a HIDDEN row the same guard also freezes user_id / business_id /
--      role_id / status for app users, so the shop cannot demote or suspend it
--      (last_login_at etc. still update, the support user logs in normally).
--   3. enforce_plan_limit_staff(): hidden rows are not counted against
--      max_staff, and a hidden row being inserted / activated is never blocked.
--   4. enforce_plan_staff_pause(): hidden rows do not take a rank slot, so a
--      hidden CEO never causes a real staff member to be paused.
--   5. remove_staff_member(): refuses a hidden target (the shop cannot remove
--      it from the app; the console can, directly).
--
-- Server functions that LIST members for the console are untouched and keep
-- returning hidden rows (the console shows the member as "Support").
-- Idempotent. No deploy gate: old clients ignore the new column.

BEGIN;

-- 1. Column ---------------------------------------------------------------------
ALTER TABLE public.user_businesses
  ADD COLUMN IF NOT EXISTS is_hidden boolean NOT NULL DEFAULT false;

-- 2. Guard ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_user_businesses_hidden_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF TG_OP = 'INSERT' THEN
      NEW.is_hidden := false;
    ELSE
      NEW.is_hidden := OLD.is_hidden;
      IF OLD.is_hidden THEN
        NEW.user_id     := OLD.user_id;
        NEW.business_id := OLD.business_id;
        NEW.role_id     := OLD.role_id;
        NEW.status      := OLD.status;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- Named so it sorts BEFORE trg_user_businesses_plan_limit (BEFORE triggers fire
-- alphabetically): the plan trigger must see the already-forced flag.
DROP TRIGGER IF EXISTS trg_user_businesses_a_hidden_guard ON public.user_businesses;
CREATE TRIGGER trg_user_businesses_a_hidden_guard
  BEFORE INSERT OR UPDATE ON public.user_businesses
  FOR EACH ROW EXECUTE FUNCTION public.enforce_user_businesses_hidden_immutable();

-- 3. Plan staff limit (0224 body; only the is_hidden lines are new) --------------
CREATE OR REPLACE FUNCTION public.enforce_plan_limit_staff()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim record;
  v_count int;
BEGIN
  IF NEW.status <> 'active' THEN RETURN NEW; END IF;
  IF NEW.is_hidden THEN RETURN NEW; END IF;   -- #622: support login is never limited
  IF TG_OP = 'INSERT' THEN
    IF EXISTS (SELECT 1 FROM public.user_businesses ub
                WHERE ub.id = NEW.id
                   OR (ub.user_id = NEW.user_id AND ub.business_id = NEW.business_id)) THEN
      RETURN NEW;
    END IF;
  ELSIF OLD.status = 'active' THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_lim
    FROM public.business_plan_limits(public.business_effective_plan(NEW.business_id));
  IF v_lim.max_staff IS NOT NULL THEN
    SELECT count(*) INTO v_count FROM public.user_businesses ub
     WHERE ub.business_id = NEW.business_id AND ub.status = 'active'
       AND NOT ub.is_hidden;                  -- #622
    IF v_count >= v_lim.max_staff THEN
      RAISE EXCEPTION 'plan_limit_staff' USING ERRCODE = 'P0001',
        HINT = 'Your plan allows ' || v_lim.max_staff || ' staff account(s). Upgrade for more.';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- 4. Plan pause (0230 body; only the is_hidden filter is new) ---------------------
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
       AND NOT ub.is_hidden                    -- #622
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

-- 5. remove_staff_member (0149 body; only the hidden refusal is new) --------------
CREATE OR REPLACE FUNCTION public.remove_staff_member(
  p_business_id uuid,
  p_user_id     uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid    uuid := auth.uid();
  v_owner_id    uuid;
  v_target_auth uuid;
  v_membership  uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT public.caller_has_permission(p_business_id, 'staff.remove') THEN
    RAISE EXCEPTION 'forbidden:not_permitted_to_remove_staff'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT owner_id INTO v_owner_id
    FROM public.businesses WHERE id = p_business_id;

  SELECT auth_user_id INTO v_target_auth
    FROM public.users
   WHERE id = p_user_id AND business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member_not_found'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- #622: the hidden support login can only be removed from the console.
  IF EXISTS (SELECT 1 FROM public.user_businesses
              WHERE business_id = p_business_id
                AND user_id = p_user_id
                AND is_hidden) THEN
    RAISE EXCEPTION 'cannot_remove_hidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_owner_id IS NOT NULL AND v_target_auth IS NOT NULL
     AND v_target_auth = v_owner_id THEN
    RAISE EXCEPTION 'cannot_remove_owner'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_target_auth IS NOT NULL AND v_target_auth = v_auth_uid THEN
    RAISE EXCEPTION 'cannot_remove_self'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE public.user_businesses
     SET status = 'removed', last_updated_at = now()
   WHERE business_id = p_business_id AND user_id = p_user_id
  RETURNING id INTO v_membership;

  IF v_membership IS NULL THEN
    RAISE EXCEPTION 'member_not_found'
      USING ERRCODE = 'no_data_found';
  END IF;

  UPDATE public.users
     SET auth_user_id = NULL, last_updated_at = now()
   WHERE id = p_user_id AND business_id = p_business_id;

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'user_id', p_user_id,
    'membership_id', v_membership
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.remove_staff_member(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.remove_staff_member(uuid, uuid) TO authenticated, service_role;

COMMIT;
