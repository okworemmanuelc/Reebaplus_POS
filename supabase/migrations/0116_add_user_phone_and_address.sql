-- 0116_add_user_phone_and_address.sql
--
-- Adds phone and address columns to public.users (collected during staff
-- sign-up §6) and recreates redeem_invite_code to accept and persist them.

BEGIN;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS phone   text,
  ADD COLUMN IF NOT EXISTS address text;

-- Recreate redeem_invite_code with p_phone / p_address params.
-- Body is otherwise byte-for-byte identical to 0052 with the addition of
-- phone/address on the INSERT and UPDATE paths and in the RETURN QUERY.
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
