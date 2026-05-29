-- =============================================================================
-- 0052_rollback.sql — reverse of 0052_fix_redeem_ambiguous_columns.sql.
--
-- Re-creates redeem_invite_code with its original 0049 body (no
-- `#variable_conflict use_column` directive). WARNING: this reinstates the
-- 42702 'column reference "email" is ambiguous' runtime failure. Only run it
-- to get back to the pre-0052 state. No data is touched; the signature and
-- grants are unchanged.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.redeem_invite_code(
  p_code     text,
  p_user_id  uuid DEFAULT NULL,
  p_name     text DEFAULT NULL
)
RETURNS TABLE (
  id            uuid,
  business_id   uuid,
  auth_user_id  uuid,
  name          text,
  email         text,
  store_id      uuid,
  role_id       uuid,
  business_name text,
  role_name     text,
  role_slug     text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_authmail  text;
  v_invite    invite_codes%ROWTYPE;
  v_user_id   uuid;
  v_name      text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'redeem_invite_code requires an authenticated session';
  END IF;

  -- The authenticated user's email is the source of truth for the
  -- "must match" check (master plan §6.1). auth.users is readable from a
  -- SECURITY DEFINER function owned by postgres.
  SELECT email INTO v_authmail FROM auth.users WHERE id = v_uid;
  IF v_authmail IS NULL THEN
    RAISE EXCEPTION 'redeem_invite_code: no email on the authenticated user';
  END IF;

  -- Look up the invite. Accept it if it is currently active, OR if it was
  -- already used BY THIS auth user (idempotent re-redeem). Any other
  -- used/revoked/expired/deleted state is a hard rejection.
  SELECT * INTO v_invite
    FROM public.invite_codes ic
   WHERE ic.code = p_code
     AND ic.is_deleted = false
     AND (
           -- active
           (ic.used_at IS NULL AND ic.revoked_at IS NULL AND ic.expires_at > now())
           -- or already redeemed by this same auth user (idempotency)
           OR ic.used_by_user_id IN (
                SELECT u.id FROM public.users u
                 WHERE u.auth_user_id = v_uid AND u.business_id = ic.business_id
              )
         )
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'redeem_invite_code: invite code is not valid'
      USING ERRCODE = 'P0001';
  END IF;

  IF lower(trim(v_invite.email)) <> lower(trim(v_authmail)) THEN
    RAISE EXCEPTION 'redeem_invite_code: invite email does not match the signed-in account'
      USING ERRCODE = 'P0001';
  END IF;

  v_name := COALESCE(NULLIF(trim(p_name), ''), v_authmail);

  -- 2a. users — find-or-create by (auth_user_id, business_id). Reuse
  --     p_user_id when provided so cloud and local Drift agree on the id
  --     from the start (mirrors complete_onboarding). Never mint a second
  --     id for an auth user that already has a row in this business.
  SELECT u.id INTO v_user_id
    FROM public.users u
   WHERE u.auth_user_id = v_uid AND u.business_id = v_invite.business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      id, auth_user_id, business_id, name, email, store_id
    ) VALUES (
      COALESCE(p_user_id, gen_random_uuid()),
      v_uid, v_invite.business_id, v_name, v_authmail, v_invite.store_id
    )
    ON CONFLICT (business_id, email) DO UPDATE
      SET auth_user_id    = EXCLUDED.auth_user_id,
          name            = EXCLUDED.name,
          store_id        = EXCLUDED.store_id,
          last_updated_at = now()
    RETURNING id INTO v_user_id;
  ELSE
    -- Existing row: keep it canonical but make sure the store assignment
    -- on the user record reflects the invite (re-redeem / repair).
    UPDATE public.users
       SET name            = v_name,
           store_id        = v_invite.store_id,
           last_updated_at = now()
     WHERE id = v_user_id;
  END IF;

  -- 2b. profiles — identity only (no role/role_tier; dropped in 0041).
  INSERT INTO public.profiles (id, business_id, name)
    VALUES (v_uid, v_invite.business_id, v_name)
  ON CONFLICT (id) DO UPDATE
    SET business_id = EXCLUDED.business_id,
        name        = EXCLUDED.name;

  -- 2c. user_businesses — role from invite, active. Idempotent on
  --     (user_id, business_id).
  INSERT INTO public.user_businesses (
    business_id, user_id, role_id, status
  ) VALUES (
    v_invite.business_id, v_user_id, v_invite.role_id, 'active'
  )
  ON CONFLICT (user_id, business_id) DO UPDATE
    SET role_id         = EXCLUDED.role_id,
        status          = 'active',
        last_updated_at = now();

  -- 2d. user_stores — store from invite. Idempotent on (user_id, store_id).
  INSERT INTO public.user_stores (
    business_id, user_id, store_id
  ) VALUES (
    v_invite.business_id, v_user_id, v_invite.store_id
  )
  ON CONFLICT (user_id, store_id) DO NOTHING;

  -- 2e. Mark the invite used. Only stamp it the first time so a repeat
  --     redeem by the same user keeps the original used_at.
  UPDATE public.invite_codes
     SET used_by_user_id = v_user_id,
         used_at         = COALESCE(used_at, now()),
         last_updated_at = now()
   WHERE id = v_invite.id;

  -- 2f. Return the canonical users row + business/role display fields.
  RETURN QUERY
    SELECT u.id,
           u.business_id,
           u.auth_user_id,
           u.name,
           u.email,
           u.store_id,
           v_invite.role_id,
           b.name,
           r.name,
           r.slug
      FROM public.users u
      JOIN public.businesses b ON b.id = u.business_id
      JOIN public.roles r      ON r.id = v_invite.role_id
     WHERE u.id = v_user_id;
END;
$function$;

REVOKE ALL    ON FUNCTION public.redeem_invite_code(text, uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.redeem_invite_code(text, uuid, text) TO authenticated, service_role;

COMMIT;
