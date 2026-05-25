-- 0041_remove_staff_management.sql
--
-- Forward-only removal of the entire staff/membership/invite/role-tier
-- system. After this migration, the cloud schema has:
--   * No business_members table.
--   * No invites table.
--   * No role / role_tier columns on users or profiles.
--   * No staff-related RPCs (accept_invite, terminate_member,
--     am_i_a_member, is_business_member_email, _redeem_invite_row,
--     regenerate_invite_code, extend_verification,
--     seed_profiles_for_invitees).
--   * complete_onboarding still exists but only seeds business identity
--     (businesses, profiles, warehouses, settings, users). No CEO
--     membership row, no role/tier writes.
--   * activity_logs truncated. The only surviving caller is
--     pos_approve_crate_return (migration 0011); future POS activity
--     will repopulate.
--   * onboarding.verification_grace_days and onboarding.invite_ttl_days
--     settings rows removed.
--
-- Migrations 0020-0040 are NOT rolled back — they remain in version
-- control as the historical record of what existed. This migration is
-- the forward path to a clean slate so staff management can be
-- redesigned and rebuilt from scratch.
--
-- A separate manual data wipe (see tool/wipe_cloud.sql) will run after
-- this migration is approved and deployed.

BEGIN;

-- =========================================================================
-- 1. Drop staff RPCs first, before the tables they depend on.
--    DROP FUNCTION with explicit signatures because several were
--    overloaded across the 0020-0040 series.
-- =========================================================================

-- accept_invite: signature evolved across 0022, 0026, 0032, 0033, 0034,
-- 0035, 0040. Drop all known variants. Use IF EXISTS so missing
-- variants don't fail.
DROP FUNCTION IF EXISTS public.accept_invite(uuid, text);
DROP FUNCTION IF EXISTS public.accept_invite(uuid, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.accept_invite(uuid, text, text, text, text, text, text, text, text);

-- terminate_member: 0034, 0035, 0036
DROP FUNCTION IF EXISTS public.terminate_member(uuid, uuid);

-- Membership / invite query helpers
DROP FUNCTION IF EXISTS public.am_i_a_member(uuid);
DROP FUNCTION IF EXISTS public.is_business_member_email(uuid, text);
DROP FUNCTION IF EXISTS public._redeem_invite_row(invites, text);
DROP FUNCTION IF EXISTS public.regenerate_invite_code(uuid);
DROP FUNCTION IF EXISTS public.extend_verification(uuid);
DROP FUNCTION IF EXISTS public.extend_verification(uuid, integer, text);
DROP FUNCTION IF EXISTS public.seed_profiles_for_invitees();

-- =========================================================================
-- 2. Drop staff tables. CASCADE removes the RLS policies, triggers, and
--    indexes attached to each table. Realtime publication membership is
--    cleaned up automatically by the table drop.
-- =========================================================================

DROP TABLE IF EXISTS public.business_members CASCADE;
DROP TABLE IF EXISTS public.invites CASCADE;

-- =========================================================================
-- 3. Strip role/role_tier columns from surviving tables. PIN columns on
--    users are retained — the lone owner still needs PIN unlock.
-- =========================================================================

-- users: drop role + role_tier + their CHECK constraints. The CHECKs
-- were defined inline on the column in 0001 / 0030, so dropping the
-- column drops the constraint with it.
ALTER TABLE public.users
  DROP COLUMN IF EXISTS role,
  DROP COLUMN IF EXISTS role_tier;

-- profiles: same.
ALTER TABLE public.profiles
  DROP COLUMN IF EXISTS role,
  DROP COLUMN IF EXISTS role_tier;

-- Drop the now-orphaned (business_id, is_deleted) index on users.
-- is_deleted was dropped in 0035 but the index name may linger.
DROP INDEX IF EXISTS public.idx_users_business_deleted;

-- =========================================================================
-- 4. Replace complete_onboarding with a slimmer version that only seeds
--    business identity. No business_members insert, no role writes.
--
--    Signature change: drop p_membership_id (no membership table to
--    target). Keep p_user_id for client/cloud user.id alignment.
--
--    DROP+CREATE because we're changing the signature.
-- =========================================================================

DROP FUNCTION IF EXISTS public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb
);
DROP FUNCTION IF EXISTS public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid, uuid
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

  -- 2. profiles — identity only. No role/role_tier.
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
  --    Uses p_user_id when provided so cloud and local Drift agree on the
  --    id from the start. No role/role_tier writes.
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
END;
$function$;

REVOKE ALL    ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
) FROM public;
GRANT EXECUTE ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid
) TO authenticated, service_role;

-- =========================================================================
-- 6. Remove staff-only settings rows. The keys are unused now that the
--    RPCs that read them are gone.
-- =========================================================================

DELETE FROM public.settings
 WHERE key IN ('onboarding.verification_grace_days',
               'onboarding.invite_ttl_days');

-- =========================================================================
-- 7. Truncate activity_logs. The only surviving caller is
--    pos_approve_crate_return (migration 0011); everything else that
--    wrote to this table belonged to the deleted staff/invite flows.
--    Future POS activity will repopulate.
-- =========================================================================

TRUNCATE TABLE public.activity_logs;

COMMIT;

-- =============================================================================
-- Verification queries (run by hand after deploy):
--
--   1. Staff tables gone:
--      SELECT to_regclass('public.business_members'); -- expect NULL
--      SELECT to_regclass('public.invites');          -- expect NULL
--
--   2. Role/tier columns gone:
--      SELECT column_name FROM information_schema.columns
--        WHERE table_schema='public' AND table_name='users'
--          AND column_name IN ('role','role_tier');     -- expect 0 rows
--      SELECT column_name FROM information_schema.columns
--        WHERE table_schema='public' AND table_name='profiles'
--          AND column_name IN ('role','role_tier');     -- expect 0 rows
--
--   3. Staff RPCs gone:
--      SELECT proname FROM pg_proc
--       WHERE pronamespace='public'::regnamespace
--         AND proname IN ('accept_invite','terminate_member','am_i_a_member',
--                         'is_business_member_email','_redeem_invite_row',
--                         'regenerate_invite_code','extend_verification',
--                         'seed_profiles_for_invitees');
--      -- expect 0 rows
--
--   4. complete_onboarding signature has 10 args (no p_membership_id):
--      SELECT pg_get_function_arguments(oid)
--      FROM pg_proc
--      WHERE proname='complete_onboarding' AND pronamespace='public'::regnamespace;
--      -- expect args ending in ..., p_user_id uuid DEFAULT NULL::uuid
--      --                       (NOT p_membership_id)
--
--   5. End-to-end: a fresh CEO onboarding from the emulator must succeed
--      and produce exactly one users row + one profiles row + one
--      businesses row + one warehouses row + N settings rows. NO row in
--      business_members or invites (tables don't exist).
-- =============================================================================
