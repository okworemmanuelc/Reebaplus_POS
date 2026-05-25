-- 0039_unified_identity_alignment.sql
--
-- Unified fix for "Bug B" — the local↔cloud user.id divergence on fresh
-- CEO onboarding — plus two follow-up cleanups for cloud functions that
-- still reference the dropped `users.is_deleted` column.
--
-- The divergence ROOT CAUSE
-- -------------------------
-- The client mints `users.id` (and `business_members.id`) client-side as
-- UUIDv7 in OnboardingDraft and uses those ids in the local Drift mirror.
-- The cloud `complete_onboarding` RPC, however, doesn't accept either id
-- as a parameter — it lets the column DEFAULT fire and gets a totally
-- different `gen_random_uuid()` value server-side. Net effect: every
-- fresh CEO ends up with `cloud.users.id ≠ local.users.id`, and every
-- client code path that joins/filters by local user.id (staff list,
-- setUserPin's membership lookup, staff details, etc.) misfires.
--
-- The cloud is internally consistent — its FKs all resolve via
-- auth.uid() and its own ids — so this is purely a local/cloud
-- coordination bug, surfaced by any flow that asks the cloud "does this
-- *specific* local id exist over there?"
--
-- THE FIX
-- -------
-- Adopt the v2 POS RPC convention: client mints the id, RPC accepts it
-- as a parameter. Both `users.id` and `business_members.id` become
-- client-controlled values that flow through:
--   client OnboardingDraft.userId / .membershipId
--     → completeOnboarding(p_user_id, p_membership_id) RPC params
--     → INSERT INTO users (id, ...)        VALUES (p_user_id, ...)
--     → INSERT INTO business_members (id, ...) VALUES (p_membership_id, ...)
--
-- DEFAULT NULL on the new params keeps the signature backwards-compat —
-- any caller that doesn't pass them gets server-generated ids exactly
-- as today (so a stale client deploying against the new schema doesn't
-- break, it just keeps creating divergent ids). The Dart client update
-- in this branch always passes both.
--
-- ALSO IN THIS MIGRATION (orthogonal but same family)
-- ---------------------------------------------------
-- Migration 0035 dropped `users.is_deleted` and the soft-delete columns
-- on business_members. The pre-deploy audit's per-line regex missed two
-- cloud functions that still reference `users.is_deleted` in real code
-- (not comments). Both have been broken since 0035 landed:
--
--   * public.is_business_member_email(p_business_id, p_email)
--       called by the send-invite Edge Function as a pre-check.
--       Currently raises 42703 "column is_deleted does not exist", which
--       send-invite converts to error: internal, which the client surfaces
--       as "Something went wrong, please try again."
--
--   * public._redeem_invite_row(inv invites, p_user_name)
--       writes `is_deleted = false` in an ON CONFLICT UPDATE on users.
--       Same failure mode whenever a non-CEO redeems an invite.
--
-- Both rewritten here to drop the dropped-column predicates. No semantics
-- change — every users row in post-0035 is "active" by virtue of
-- existing.
--
-- NOT IN SCOPE
-- ------------
-- * accept_invite and terminate_member also got flagged by the audit,
--   but their hits are inline comments mentioning the dropped columns,
--   not real code references. They run fine.
-- * The `gen_random_uuid()` inside _redeem_invite_row is kept as-is —
--   moving invite-redemption to client-minted ids is a separate change
--   that needs the redeem-invite Edge Function to also pass the id
--   through. Out of scope.

BEGIN;

-- =========================================================================
-- 1. complete_onboarding — accept client-minted user_id + membership_id.
--
--    Same flow as 0037, plus:
--      * p_user_id uuid DEFAULT NULL parameter
--      * p_membership_id uuid DEFAULT NULL parameter
--      * users INSERT uses COALESCE(p_user_id, gen_random_uuid())
--      * business_members INSERT uses COALESCE(p_membership_id, gen_random_uuid())
--
--    The COALESCE keeps the function backwards-compat with callers that
--    haven't been updated yet — they get server-generated ids exactly
--    as before. The Dart client in this branch always passes both.
--
--    DROP+CREATE rather than CREATE OR REPLACE because we're appending
--    optional parameters; CREATE OR REPLACE can't change the signature.
-- =========================================================================

DROP FUNCTION IF EXISTS public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb
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
  p_user_id         uuid DEFAULT NULL,
  p_membership_id   uuid DEFAULT NULL
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

  -- 2. profiles. CEO at tier 6 (v9 vocabulary).
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

  -- 5. users — find-or-create. Uses p_user_id when provided so cloud and
  --    local Drift agree on the id from the start (resolves Bug B).
  --    Idempotent on (auth_user_id, business_id) which is already keyed
  --    via the UNIQUE(business_id, email) constraint.
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = v_uid AND business_id = p_business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      id, auth_user_id, business_id, name, email,
      role, role_tier
    ) VALUES (
      COALESCE(p_user_id, gen_random_uuid()),
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

  -- 6. business_members — CEO membership at tier 6. Uses p_membership_id
  --    when provided so cloud and local agree on the membership id too —
  --    the staff_screen filter, setUserPin lookup, etc. all key on this.
  INSERT INTO public.business_members (
    id, business_id, user_id, role, role_tier,
    verification_status, verification_due_at,
    joined_at
  ) VALUES (
    COALESCE(p_membership_id, gen_random_uuid()),
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

REVOKE ALL    ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid, uuid
) FROM public;
GRANT EXECUTE ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid, uuid
) TO authenticated, service_role;

-- =========================================================================
-- 2. is_business_member_email — drop the dropped-column predicate.
--
--    Pre-0035 this filtered out soft-deleted user rows; post-0035 every
--    users row is "active" by virtue of existing (the column is gone).
--    Without this fix every call to send-invite errors at the pre-check.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.is_business_member_email(
  p_business_id uuid,
  p_email       text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE business_id = p_business_id
      AND lower(email) = lower(p_email)
  );
$function$;

REVOKE ALL    ON FUNCTION public.is_business_member_email(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION public.is_business_member_email(uuid, text)
  TO authenticated, service_role;

-- =========================================================================
-- 3. _redeem_invite_row — drop the `is_deleted = false` from the ON
--    CONFLICT UPDATE on users. Same reason as above.
--
--    Body is otherwise identical to the deployed version (function still
--    server-mints users.id via gen_random_uuid — out of scope to change
--    the invite-redemption id flow in this migration).
-- =========================================================================

CREATE OR REPLACE FUNCTION public._redeem_invite_row(
  inv          invites,
  p_user_name  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_email   text;
  v_collapsed_role text;
  v_collapsed_tier int;
  v_user_id        uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  v_caller_email := (auth.jwt() ->> 'email');
  IF v_caller_email IS NULL OR length(v_caller_email) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthenticated');
  END IF;

  IF inv.status = 'revoked'  THEN RETURN jsonb_build_object('ok', false, 'error', 'revoked');     END IF;
  IF inv.status = 'accepted' THEN RETURN jsonb_build_object('ok', false, 'error', 'already_used'); END IF;
  IF inv.expires_at < now()  THEN RETURN jsonb_build_object('ok', false, 'error', 'expired');     END IF;

  IF lower(inv.email) <> lower(v_caller_email) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email_mismatch');
  END IF;

  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_member');
  END IF;

  v_collapsed_role := CASE
    WHEN inv.role = 'ceo'     THEN 'ceo'
    WHEN inv.role = 'manager' THEN 'manager'
    ELSE 'staff'
  END;
  v_collapsed_tier := CASE v_collapsed_role
    WHEN 'ceo'     THEN 5
    WHEN 'manager' THEN 4
    ELSE 1
  END;

  INSERT INTO public.profiles (id, business_id, name, role, role_tier)
  VALUES (auth.uid(), inv.business_id, p_user_name, v_collapsed_role, v_collapsed_tier);

  INSERT INTO public.users (
    id, business_id, auth_user_id, name, email,
    role, role_tier, warehouse_id
  ) VALUES (
    gen_random_uuid(), inv.business_id, auth.uid(), p_user_name, lower(inv.email),
    inv.role, v_collapsed_tier, inv.warehouse_id
  )
  ON CONFLICT (business_id, email) DO UPDATE
    SET auth_user_id    = EXCLUDED.auth_user_id,
        name            = EXCLUDED.name,
        role            = EXCLUDED.role,
        role_tier       = EXCLUDED.role_tier,
        warehouse_id    = EXCLUDED.warehouse_id,
        last_updated_at = now()
  RETURNING id INTO v_user_id;

  UPDATE public.invites
  SET status  = 'accepted',
      used_at = now(),
      last_updated_at = now()
  WHERE id = inv.id;

  RETURN jsonb_build_object(
    'ok',           true,
    'business_id',  inv.business_id,
    'user_id',      v_user_id,
    'role',         inv.role,
    'role_tier',    v_collapsed_tier,
    'warehouse_id', inv.warehouse_id
  );
END;
$function$;

COMMIT;

-- =============================================================================
-- Verification:
--
--   1. complete_onboarding new signature with 11 args (9 + p_user_id + p_membership_id):
--      SELECT pg_get_function_arguments(oid)
--      FROM pg_proc
--      WHERE proname='complete_onboarding' AND pronamespace='public'::regnamespace;
--      -- expect args ending in: ..., p_user_id uuid DEFAULT NULL::uuid,
--      --                            p_membership_id uuid DEFAULT NULL::uuid
--
--   2. is_business_member_email no longer references is_deleted:
--      SELECT position('is_deleted' IN pg_get_functiondef(oid))
--      FROM pg_proc
--      WHERE proname='is_business_member_email' AND pronamespace='public'::regnamespace;
--      -- expect 0
--
--      Call it: SELECT public.is_business_member_email(
--                 '00000000-0000-0000-0000-000000000000'::uuid, 'x@y.z');
--      -- expect false (no error, just false because no row matches)
--
--   3. _redeem_invite_row's ON CONFLICT UPDATE no longer writes is_deleted:
--      SELECT position('is_deleted' IN pg_get_functiondef(oid))
--      FROM pg_proc
--      WHERE proname='_redeem_invite_row' AND pronamespace='public'::regnamespace;
--      -- expect 0
--
--   4. End-to-end: run a fresh CEO onboarding from the emulator. After
--      complete_onboarding, the cloud's public.users.id MUST equal the
--      local Drift users.id MUST equal OnboardingDraft.userId. Same for
--      business_members.id == draft.membershipId.
-- =============================================================================
