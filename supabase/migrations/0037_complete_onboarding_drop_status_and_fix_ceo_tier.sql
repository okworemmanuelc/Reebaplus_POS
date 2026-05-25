-- 0037_complete_onboarding_drop_status_and_fix_ceo_tier.sql
--
-- Two related fixes to public.complete_onboarding(...) — the RPC that
-- materialises the businesses / warehouses / settings / users /
-- business_members rows for a brand-new CEO during onboarding.
--
-- 1. Drop the now-dropped `status` column from the business_members
--    INSERT. Migration 0035 dropped `business_members.{is_deleted,
--    status, removed_at, removed_by}`, but complete_onboarding was
--    missed by the pre-deploy audit (the line-by-line regex required
--    both the table name and the column name on the same source line;
--    here `business_members` and `status` are six lines apart inside
--    the same multi-line INSERT). The function has been raising
--    PostgrestException 42703 "column 'status' does not exist" on
--    every CEO onboarding attempt since 0035 landed — the user-visible
--    surface is "Failed to save PIN" because the create_pin_screen
--    handler that calls completeOnboarding wraps the failure in a
--    generic catch.
--
-- 2. Fix the CEO `role_tier`. The function still writes `role_tier = 5`
--    for the new CEO in three places (profiles, users, business_members).
--    Migration 0030's v9 role refactor moved CEO from tier 5 to tier 6
--    but never updated this function. Consequences if left as-is:
--      * CEO row would land at tier 5 (manager tier) on every fresh
--        onboarding, contradicting the v9 vocabulary used everywhere
--        else.
--      * Worse: 0036's CEO-cannot-be-fired guard checks
--        `IF v_target_tier = 6 THEN RAISE 'forbidden:cannot_terminate_ceo'`.
--        A tier-5 CEO would bypass the guard entirely — silently
--        firable by anyone outranking tier 5, i.e. nobody, but also
--        not protected by the explicit rule the spec demands.
--    Fix all three inserts to use `role_tier = 6`.
--
-- Same signature, same overall flow as the previous version — CREATE
-- OR REPLACE FUNCTION is sufficient. No data backfill needed because
-- complete_onboarding has been failing since 0035 deployed and the
-- cloud was wiped in the run-up to this fix, so there are no existing
-- CEO rows minted at tier 5 to repair.
--
-- Known follow-up (not addressed here, separate concern): the client-
-- side local mirror in lib/shared/services/auth_service.dart
-- completeOnboarding() inserts businesses, warehouses, users, settings
-- locally but NOT business_members. After this RPC succeeds the cloud
-- business_members row exists with NULL pin_hash, and setUserPin's
-- second write (the canonical-going-forward membership PIN) silently
-- skips because no local membership row exists yet. PIN unlock still
-- works off the legacy users.pin_hash device-local column, so the
-- immediate test scenario is unaffected; but the cloud's
-- business_members.pin_hash stays NULL for the CEO until a later
-- write. See PIN-on-membership follow-up entry to be added to
-- lib/features/staff/DEFERRED.md.

BEGIN;

CREATE OR REPLACE FUNCTION public.complete_onboarding(
  p_business_id   uuid,
  p_warehouse_id  uuid,
  p_owner_name    text,
  p_business_name text,
  p_business_type text,
  p_business_phone text,
  p_business_email text,
  p_location      jsonb,
  p_settings      jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_loc_name text;
  v_loc_combined text;
  v_currency text;
  v_timezone text;
  v_tax text;
  v_user_id uuid;
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

  -- 2. profiles. CEO is role_tier=6 in the v9 vocabulary (was 5 pre-0030).
  INSERT INTO public.profiles (id, business_id, name, role, role_tier)
    VALUES (v_uid, p_business_id, p_owner_name, 'ceo', 6)
  ON CONFLICT (id) DO UPDATE
    SET business_id = EXCLUDED.business_id,
        name        = EXCLUDED.name,
        role        = EXCLUDED.role,
        role_tier   = EXCLUDED.role_tier;

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

  -- 5. users — find-or-create. Idempotent on (auth_user_id). CEO at tier 6.
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = v_uid AND business_id = p_business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      auth_user_id, business_id, name, email,
      role, role_tier
    ) VALUES (
      v_uid, p_business_id, p_owner_name, p_business_email,
      'ceo', 6
    )
    ON CONFLICT (business_id, email) DO UPDATE
      SET auth_user_id    = EXCLUDED.auth_user_id,
          name            = EXCLUDED.name,
          role            = EXCLUDED.role,
          role_tier       = EXCLUDED.role_tier,
          last_updated_at = now()
    RETURNING id INTO v_user_id;
  END IF;

  -- 6. business_members — CEO membership at tier 6.
  --    `status` column was dropped by 0035; "active" is implicit (every
  --    row in the table is by definition an active membership). The CEO
  --    is auto-approved (no verification grace window — the business
  --    owner doesn't have an inviter to verify them).
  --    Idempotent on (business_id, user_id).
  INSERT INTO public.business_members (
    business_id, user_id, role, role_tier,
    verification_status, verification_due_at,
    joined_at
  ) VALUES (
    p_business_id, v_user_id, 'ceo', 6,
    'approved', NULL,
    now()
  )
  ON CONFLICT (business_id, user_id) DO UPDATE
    SET role                = EXCLUDED.role,
        role_tier           = EXCLUDED.role_tier,
        verification_status = EXCLUDED.verification_status,
        verification_due_at = EXCLUDED.verification_due_at,
        last_updated_at     = now();
END;
$function$;

COMMIT;

-- =============================================================================
-- Verification:
--
--   1. complete_onboarding body no longer references `status`:
--      SELECT position('status' IN pg_get_functiondef(oid))
--      FROM pg_proc
--      WHERE proname='complete_onboarding' AND pronamespace='public'::regnamespace;
--      -- expect 0 (or only positions inside comments / verification_status)
--
--   2. role_tier is 6 in all three CEO inserts:
--      SELECT (regexp_matches(pg_get_functiondef(oid),
--                             'role_tier(\s|[,)])+', 'g'))[1]
--      FROM pg_proc
--      WHERE proname='complete_onboarding' AND pronamespace='public'::regnamespace;
--
--   3. Run an actual onboarding from the app — the cloud RPC should no
--      longer 42703, the CEO row should land at role_tier=6, and the
--      "Failed to save PIN" surface in create_pin_screen should not fire.
-- =============================================================================
