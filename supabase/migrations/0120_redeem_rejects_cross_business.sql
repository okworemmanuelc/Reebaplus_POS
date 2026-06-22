-- 0120_redeem_rejects_cross_business.sql
--
-- Bug: redeeming a staff invite with an email/identity that already carries a
-- `users` row (auth_user_id) in a DIFFERENT business crashed the client.
--
-- Why it happened: `users` has a GLOBAL unique constraint
-- `users_auth_user_id_key UNIQUE (auth_user_id)`, but redeem_invite_code's
-- existence check and INSERT ... ON CONFLICT are both scoped to
-- (auth_user_id, business_id) / (business_id, email). When the identity's
-- auth_user_id is already bound to another business, the lookup at
-- `WHERE auth_user_id = v_uid AND business_id = v_invite.business_id` finds
-- nothing, so the INSERT runs and sets auth_user_id = v_uid again — colliding
-- with the existing row's auth_user_id and raising a raw 23505
-- ("users_auth_user_id_key") that surfaced to the user as
-- "Something went wrong" (followed by an FK-787 in the client's cloud-hydrate
-- fallback, which tried to mirror the *other* business locally).
--
-- This is the deferred §6.2 "email already linked to another business" case
-- (staff_sign_up_screen.dart) leaking through as a crash. Per architecture
-- invariant #9 (one email = one identity = one business; multi-business is out
-- of scope), the correct behaviour is a CLEAN rejection, not a crash. Add an
-- explicit guard that rejects with a typed P0001 before the conflicting INSERT,
-- so the client can show a clear message. Affects ALL staff roles (they share
-- this one RPC).
--
-- Re-redeeming an invite for the SAME business (new-device recovery) is
-- unaffected: that hits the existence check (auth_user_id + business_id match)
-- and takes the UPDATE branch, never the conflicting INSERT.
--
-- Body is otherwise byte-for-byte identical to 0116 with the single guard added
-- after the invite-email match check.

BEGIN;

CREATE OR REPLACE FUNCTION public.redeem_invite_code(
  p_code     text,
  p_user_id  uuid DEFAULT NULL,
  p_name     text DEFAULT NULL,
  p_phone    text DEFAULT NULL,
  p_address  text DEFAULT NULL
)
RETURNS TABLE (
  id            uuid,
  business_id   uuid,
  auth_user_id  uuid,
  name          text,
  email         text,
  phone         text,
  address       text,
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
#variable_conflict use_column
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

  SELECT email INTO v_authmail FROM auth.users WHERE id = v_uid;
  IF v_authmail IS NULL THEN
    RAISE EXCEPTION 'redeem_invite_code: no email on the authenticated user';
  END IF;

  SELECT * INTO v_invite
    FROM public.invite_codes ic
   WHERE ic.code = p_code
     AND ic.is_deleted = false
     AND (
           (ic.used_at IS NULL AND ic.revoked_at IS NULL AND ic.expires_at > now())
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

  -- §9 one-email-one-business guard. If this identity already carries a `users`
  -- row (auth_user_id) in a DIFFERENT business, redeeming here would violate the
  -- global users_auth_user_id_key and surface as a raw 23505. Reject cleanly so
  -- the client shows a clear message instead of crashing. Multi-business is out
  -- of scope (architecture invariant #9).
  IF EXISTS (
    SELECT 1 FROM public.users u
     WHERE u.auth_user_id = v_uid
       AND u.business_id <> v_invite.business_id
  ) THEN
    RAISE EXCEPTION 'redeem_invite_code: this email is already linked to another business'
      USING ERRCODE = 'P0001';
  END IF;

  v_name := COALESCE(NULLIF(trim(p_name), ''), v_authmail);

  SELECT u.id INTO v_user_id
    FROM public.users u
   WHERE u.auth_user_id = v_uid AND u.business_id = v_invite.business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      id, auth_user_id, business_id, name, email, phone, address, store_id
    ) VALUES (
      COALESCE(p_user_id, gen_random_uuid()),
      v_uid, v_invite.business_id, v_name, v_authmail,
      NULLIF(trim(p_phone), ''), NULLIF(trim(p_address), ''),
      v_invite.store_id
    )
    ON CONFLICT (business_id, email) DO UPDATE
      SET auth_user_id    = EXCLUDED.auth_user_id,
          name            = EXCLUDED.name,
          phone           = COALESCE(EXCLUDED.phone, public.users.phone),
          address         = COALESCE(EXCLUDED.address, public.users.address),
          store_id        = EXCLUDED.store_id,
          last_updated_at = now()
    RETURNING id INTO v_user_id;
  ELSE
    UPDATE public.users
       SET name            = v_name,
           phone           = COALESCE(NULLIF(trim(p_phone), ''), phone),
           address         = COALESCE(NULLIF(trim(p_address), ''), address),
           store_id        = v_invite.store_id,
           last_updated_at = now()
     WHERE id = v_user_id;
  END IF;

  INSERT INTO public.profiles (id, business_id, name)
    VALUES (v_uid, v_invite.business_id, v_name)
  ON CONFLICT (id) DO UPDATE
    SET business_id = EXCLUDED.business_id,
        name        = EXCLUDED.name;

  INSERT INTO public.user_businesses (
    business_id, user_id, role_id, status
  ) VALUES (
    v_invite.business_id, v_user_id, v_invite.role_id, 'active'
  )
  ON CONFLICT (user_id, business_id) DO UPDATE
    SET role_id         = EXCLUDED.role_id,
        status          = 'active',
        last_updated_at = now();

  INSERT INTO public.user_stores (
    business_id, user_id, store_id
  ) VALUES (
    v_invite.business_id, v_user_id, v_invite.store_id
  )
  ON CONFLICT (user_id, store_id) DO NOTHING;

  UPDATE public.invite_codes
     SET used_by_user_id = v_user_id,
         used_at         = COALESCE(used_at, now()),
         last_updated_at = now()
   WHERE id = v_invite.id;

  RETURN QUERY
    SELECT u.id,
           u.business_id,
           u.auth_user_id,
           u.name,
           u.email,
           u.phone,
           u.address,
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

REVOKE ALL    ON FUNCTION public.redeem_invite_code(text, uuid, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.redeem_invite_code(text, uuid, text, text, text) TO authenticated, service_role;

COMMIT;
