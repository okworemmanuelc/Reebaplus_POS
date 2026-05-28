-- 0044_complete_onboarding_seeds_roles.sql
--
-- Extends `complete_onboarding` (last touched in
-- 0041_remove_staff_management.sql) so that every new business gets
-- the four default roles + permissions + settings seeded server-side,
-- and the new CEO gets bound to their business + their first store
-- via user_businesses and user_stores.
--
-- Signature unchanged from 0041 — only the body grows. Idempotency
-- keys unchanged so a retried RPC after a transient network failure
-- still converges.

BEGIN;

DROP FUNCTION IF EXISTS public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
);

CREATE OR REPLACE FUNCTION public.complete_onboarding(
  p_business_id     uuid,
  p_warehouse_id    uuid,
  p_owner_name      text,
  p_business_name   text,
  p_business_type   text,
  p_business_phone  text,
  p_business_email  text,
  p_location        jsonb,
  p_settings        jsonb,
  p_user_id         uuid DEFAULT NULL
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

  IF p_business_id IS NULL OR p_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'complete_onboarding requires non-null p_business_id and p_warehouse_id';
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

  -- 3. warehouses.
  v_loc_name := COALESCE(NULLIF(trim(p_location ->> 'name'), ''), 'Main Warehouse');
  v_loc_combined := concat_ws(', ',
    NULLIF(trim(coalesce(p_location ->> 'street', '')), ''),
    NULLIF(trim(coalesce(p_location ->> 'city',   '')), ''),
    NULLIF(trim(coalesce(p_location ->> 'country',''))  , '')
  );

  INSERT INTO public.warehouses (id, business_id, name, location, is_deleted)
    VALUES (p_warehouse_id, p_business_id, v_loc_name, NULLIF(v_loc_combined, ''), false)
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

  -- 6. (v13 / master plan §2.4): seed default roles + permissions +
  --    settings for the new business. Idempotent helper from
  --    migration 0043 — re-running on retry is a no-op.
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
    business_id, user_id, warehouse_id
  ) VALUES (
    p_business_id, v_user_id, p_warehouse_id
  )
  ON CONFLICT (user_id, warehouse_id) DO NOTHING;
END;
$function$;

REVOKE ALL    ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
) FROM public;
GRANT EXECUTE ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (after a real CEO signs up via the app):
--
--   -- Get the new business id from the app, then:
--   SELECT COUNT(*) FROM public.roles            WHERE business_id = '<NEW>';  -- 4
--   SELECT COUNT(*) FROM public.role_permissions WHERE business_id = '<NEW>';  -- 63
--   SELECT COUNT(*) FROM public.role_settings    WHERE business_id = '<NEW>';  -- 8
--   SELECT COUNT(*) FROM public.user_businesses  WHERE business_id = '<NEW>';  -- 1
--   SELECT COUNT(*) FROM public.user_stores      WHERE business_id = '<NEW>';  -- 1
-- =============================================================================
