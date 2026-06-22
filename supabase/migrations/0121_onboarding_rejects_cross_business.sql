-- 0121_onboarding_rejects_cross_business.sql
--
-- Companion to 0120. Enforces architecture invariant #9 (one email = one
-- identity = one business) at CEO create-business time.
--
-- complete_onboarding already guards against completing a business owned by a
-- DIFFERENT user, but it had no guard against the SAME identity creating a
-- SECOND business. Its `users` find-or-create (scoped to (auth_user_id,
-- business_id)) would then INSERT a new row with auth_user_id = v_uid, which —
-- when the identity already carries auth_user_id in another business — violates
-- the global users_auth_user_id_key (raw 23505). More fundamentally, the
-- architecture says "Create a new business with an already-registered email must
-- be rejected." Add that guard with a typed P0001.
--
-- Idempotent retry is preserved: completing the SAME p_business_id again is not
-- rejected (the guard only fires for a users row in a DIFFERENT business).
-- Re-registration after delete_business is unaffected (that cascade-deletes the
-- identity's users rows, so none match).
--
-- Body is otherwise identical to the deployed definition with the single guard
-- added after the existing ownership check.

BEGIN;

CREATE OR REPLACE FUNCTION public.complete_onboarding(
  p_business_id   uuid,
  p_store_id      uuid,
  p_owner_name    text,
  p_business_name text,
  p_business_type text,
  p_business_phone text,
  p_business_email text,
  p_location      jsonb,
  p_settings      jsonb,
  p_user_id       uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid          uuid := auth.uid();
  v_loc_name     text;
  v_loc_combined text;
  v_currency     text;
  v_timezone     text;
  v_tax          text;
  v_user_id      uuid;
  v_seed_row     RECORD;
  v_ceo_role_id  uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'complete_onboarding requires an authenticated session';
  END IF;

  IF p_business_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'complete_onboarding requires non-null p_business_id and p_store_id';
  END IF;

  IF p_owner_name IS NULL OR length(trim(p_owner_name)) = 0
     OR p_business_name IS NULL OR length(trim(p_business_name)) = 0 THEN
    RAISE EXCEPTION 'complete_onboarding requires non-empty p_owner_name and p_business_name';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.businesses
    WHERE id = p_business_id AND owner_id IS NOT NULL AND owner_id <> v_uid
  ) THEN
    RAISE EXCEPTION 'complete_onboarding: business % is owned by a different user', p_business_id;
  END IF;

  -- §9 one-email-one-business guard. If this identity already carries a `users`
  -- row (auth_user_id) in a DIFFERENT business, they already belong to a
  -- business and cannot create another. Reject cleanly (typed P0001) before the
  -- INSERTs — both to enforce the invariant and to avoid the raw 23505 the
  -- users find-or-create would otherwise raise on users_auth_user_id_key.
  -- Completing the SAME business again (idempotent retry) is unaffected.
  IF EXISTS (
    SELECT 1 FROM public.users u
     WHERE u.auth_user_id = v_uid
       AND u.business_id <> p_business_id
  ) THEN
    RAISE EXCEPTION 'complete_onboarding: this email is already linked to another business'
      USING ERRCODE = 'P0001';
  END IF;

  -- 1. businesses.
  INSERT INTO public.businesses (id, owner_id, onboarding_complete, name, type, phone, email)
    VALUES (p_business_id, v_uid, true, p_business_name, p_business_type, p_business_phone, p_business_email)
  ON CONFLICT (id) DO UPDATE
    SET name                = EXCLUDED.name,
        type                = EXCLUDED.type,
        phone               = EXCLUDED.phone,
        email               = EXCLUDED.email,
        onboarding_complete = true;

  -- 2. profiles — identity only.
  INSERT INTO public.profiles (id, business_id, name)
    VALUES (v_uid, p_business_id, p_owner_name)
  ON CONFLICT (id) DO UPDATE
    SET business_id = EXCLUDED.business_id,
        name        = EXCLUDED.name;

  -- 3. stores.
  v_loc_name := COALESCE(NULLIF(trim(p_location ->> 'name'), ''), 'Main Store');
  v_loc_combined := concat_ws(', ',
    NULLIF(trim(coalesce(p_location ->> 'street', '')), ''),
    NULLIF(trim(coalesce(p_location ->> 'city',   '')), ''),
    NULLIF(trim(coalesce(p_location ->> 'country',''))  , '')
  );

  INSERT INTO public.stores (id, business_id, name, location, is_deleted)
    VALUES (p_store_id, p_business_id, v_loc_name, NULLIF(v_loc_combined, ''), false)
  ON CONFLICT (id) DO UPDATE
    SET name     = EXCLUDED.name,
        location = EXCLUDED.location;

  -- 4. settings.
  v_currency := COALESCE(NULLIF(trim(p_settings ->> 'currency'), ''), 'NGN');
  v_timezone := COALESCE(NULLIF(trim(p_settings ->> 'timezone'), ''), 'Africa/Lagos');
  v_tax      := NULLIF(trim(coalesce(p_settings ->> 'tax_reg_number', '')), '');

  INSERT INTO public.settings (business_id, key, value)
    VALUES (p_business_id, 'default_currency', v_currency)
  ON CONFLICT (business_id, key) DO UPDATE SET value = EXCLUDED.value;

  INSERT INTO public.settings (business_id, key, value)
    VALUES (p_business_id, 'timezone', v_timezone)
  ON CONFLICT (business_id, key) DO UPDATE SET value = EXCLUDED.value;

  IF v_tax IS NOT NULL THEN
    INSERT INTO public.settings (business_id, key, value)
      VALUES (p_business_id, 'tax_registration_number', v_tax)
    ON CONFLICT (business_id, key) DO UPDATE SET value = EXCLUDED.value;
  END IF;

  -- 5. users — identity only. find-or-create by (auth_user_id, business_id).
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = v_uid AND business_id = p_business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      id, auth_user_id, business_id, name, email
    ) VALUES (
      COALESCE(p_user_id, gen_random_uuid()),
      v_uid, p_business_id, p_owner_name, p_business_email
    )
    ON CONFLICT (business_id, email) DO UPDATE
      SET auth_user_id    = EXCLUDED.auth_user_id,
          name            = EXCLUDED.name,
          last_updated_at = now()
    RETURNING id INTO v_user_id;
  END IF;

  -- 6. seed default roles + permissions + settings for the new business.
  SELECT * INTO v_seed_row
    FROM public.seed_default_roles_for_business(p_business_id);
  v_ceo_role_id := v_seed_row.ceo_role_id;

  -- 7. Bind the new CEO to their business with role=CEO.
  INSERT INTO public.user_businesses (
    business_id, user_id, role_id, status
  ) VALUES (
    p_business_id, v_user_id, v_ceo_role_id, 'active'
  )
  ON CONFLICT (user_id, business_id) DO UPDATE
    SET role_id = EXCLUDED.role_id,
        status  = 'active';

  -- 8. Bind the new CEO to their first store.
  INSERT INTO public.user_stores (
    business_id, user_id, store_id
  ) VALUES (
    p_business_id, v_user_id, p_store_id
  )
  ON CONFLICT (user_id, store_id) DO NOTHING;
END;
$function$;

COMMIT;
