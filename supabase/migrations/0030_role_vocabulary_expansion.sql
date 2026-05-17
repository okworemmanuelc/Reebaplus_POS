-- =============================================================================
-- 0030_role_vocabulary_expansion.sql — granular role refactor.
--
-- Replaces the legacy 4-role vocabulary (admin / staff / ceo / manager) with
-- the canonical 5-role granular vocabulary (ceo / manager / stock_keeper /
-- cashier / rider) across profiles, users, business_members, invites; bumps
-- every role's tier by one (ceo: 5→6, manager: 4→5, new stock_keeper: 4,
-- cashier: 3, rider: 2); rewrites accept_invite's role→tier CASE and
-- notification routing; bumps the < 4 caller-tier gates in regenerate_invite_code
-- and extend_verification to < 5 so only manager + CEO can call them
-- (stock keepers manage stock, not people).
--
-- Changes captured:
--
--   admin → ceo / tier 6      (admin removed; existing rows backfill up to ceo)
--   staff → cashier / tier 3  (staff was a misnomer; everyone is staff)
--   ceo:     tier 5 → 6
--   manager: tier 4 → 5
--   stock_keeper: new first-class DB role at tier 4
--   rider: now an app-user role at tier 2
--   cleaner: dropped from the granular set (never landed in DB)
--
-- Pre-flight audit (queried 2026-05-14, the day this migration was written):
--   • profiles:        1× ceo/5
--   • users:           1× ceo/5,    1× manager/4
--   • business_members:1× ceo/5,    1× manager/4
--   • invites:         1× cashier (granular leakage from staff_constants UI),
--                      5× manager  (legitimate pending invites)
--   • No admin or staff rows anywhere; no NULLs; no cleaner orphans.
--
--   The admin/staff/cleaner backfill clauses below are therefore no-ops on
--   this live DB but are kept for defense-in-depth against test/dev DBs and
--   any future row that might exist before the migration runs.
--
-- Apply after 0029_repair_invites_regeneration_columns.sql.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Drop existing CHECK constraints on role / role_tier across the four
--    tables. Cloud-side audit confirmed Postgres named them with the
--    default `<table>_<column>_check` pattern. Drop by exact name —
--    explicit, idempotent via IF EXISTS, and immune to the pg_get_constraintdef
--    representation (Postgres stores `IN (...)` as `= ANY (ARRAY[...])`, so a
--    naive ILIKE on `%role IN%` would miss them).
--
--    Cloud-state finding (also captured in the briefing doc): users_role_check
--    and invites_role_check were already partially permissive — their existing
--    definitions allowed the granular set including 'cleaner'. The other
--    four constraints still enforced the old 4-role set. That asymmetry is
--    how the cashier invite ever landed on cloud. After this migration all
--    seven constraints are consistent.
-- -----------------------------------------------------------------------------

ALTER TABLE public.profiles         DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles         DROP CONSTRAINT IF EXISTS profiles_role_tier_check;
ALTER TABLE public.users            DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users            DROP CONSTRAINT IF EXISTS users_role_tier_check;
ALTER TABLE public.business_members DROP CONSTRAINT IF EXISTS business_members_role_check;
ALTER TABLE public.business_members DROP CONSTRAINT IF EXISTS business_members_role_tier_check;
ALTER TABLE public.invites          DROP CONSTRAINT IF EXISTS invites_role_check;

-- -----------------------------------------------------------------------------
-- 2. Data backfill. Order matters: admin→ceo and staff→cashier first
--    (they rewrite both role and tier in one shot), then bump existing
--    ceo/5 → ceo/6 and manager/4 → manager/5 for rows that didn't go
--    through the first pass.
-- -----------------------------------------------------------------------------

-- profiles
UPDATE public.profiles SET role = 'ceo',     role_tier = 6 WHERE role = 'admin';
UPDATE public.profiles SET role = 'cashier', role_tier = 3 WHERE role = 'staff';
UPDATE public.profiles SET role_tier = 6 WHERE role = 'ceo'     AND role_tier <> 6;
UPDATE public.profiles SET role_tier = 5 WHERE role = 'manager' AND role_tier <> 5;

-- users
UPDATE public.users SET role = 'ceo',     role_tier = 6 WHERE role = 'admin';
UPDATE public.users SET role = 'cashier', role_tier = 3 WHERE role = 'staff';
UPDATE public.users SET role_tier = 6 WHERE role = 'ceo'     AND role_tier <> 6;
UPDATE public.users SET role_tier = 5 WHERE role = 'manager' AND role_tier <> 5;

-- business_members
UPDATE public.business_members SET role = 'ceo',     role_tier = 6 WHERE role = 'admin';
UPDATE public.business_members SET role = 'cashier', role_tier = 3 WHERE role = 'staff';
UPDATE public.business_members SET role_tier = 6 WHERE role = 'ceo'     AND role_tier <> 6;
UPDATE public.business_members SET role_tier = 5 WHERE role = 'manager' AND role_tier <> 5;

-- invites (no role_tier column)
UPDATE public.invites SET role = 'ceo'     WHERE role = 'admin';
UPDATE public.invites SET role = 'cashier' WHERE role = 'staff';

-- -----------------------------------------------------------------------------
-- 3. Add new CHECK constraints. Named explicitly so future migrations can
--    target them by name. Tier set is (2,3,4,5,6) — rider is the new floor;
--    tier 1 is no longer valid.
-- -----------------------------------------------------------------------------

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
    CHECK (role IN ('ceo','manager','stock_keeper','cashier','rider')),
  ADD CONSTRAINT profiles_role_tier_check
    CHECK (role_tier IN (2,3,4,5,6));

ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
    CHECK (role IN ('ceo','manager','stock_keeper','cashier','rider')),
  ADD CONSTRAINT users_role_tier_check
    CHECK (role_tier IN (2,3,4,5,6));

ALTER TABLE public.business_members
  ADD CONSTRAINT business_members_role_check
    CHECK (role IN ('ceo','manager','stock_keeper','cashier','rider')),
  ADD CONSTRAINT business_members_role_tier_check
    CHECK (role_tier IN (2,3,4,5,6));

ALTER TABLE public.invites
  ADD CONSTRAINT invites_role_check
    CHECK (role IN ('ceo','manager','stock_keeper','cashier','rider'));

-- -----------------------------------------------------------------------------
-- 4. accept_invite — replace the role→tier CASE block and the notification
--    fan-out predicate.
--
-- Notification routing rewrite — read of original (0026 lines 203-233):
--
--   The original fan-out has two recipient tiers:
--     (a) ceo  → notified about every new staff joining the business, any
--                warehouse.
--     (b) admin OR manager → notified only when assigned to the SAME
--                warehouse as the new staff (warehouse-targeted).
--
--   Original predicate (0026:222-233):
--     bm.role = 'ceo'
--     OR (
--       bm.role IN ('admin', 'manager')
--       AND v_warehouse_id IS NOT NULL
--       AND bm.warehouse_id = v_warehouse_id
--     )
--
--   Rewrite reasoning under the new vocabulary:
--     • admin is gone (rows backfilled to ceo above); they're now covered by
--       branch (a). The second branch collapses to manager-only.
--     • stock_keeper is NOT a people-manager (Decision #2 of the refactor
--       plan — "stock keepers manage stock, not people"). They do NOT
--       receive notifications about new staff joining. No new branch.
--     • cashier / rider were never notification recipients; unchanged.
--
--   New predicate:
--     bm.role = 'ceo'
--     OR (
--       bm.role = 'manager'
--       AND v_warehouse_id IS NOT NULL
--       AND bm.warehouse_id = v_warehouse_id
--     )
--
--   This preserves the original intent (CEO broadcast + manager
--   warehouse-targeted); it does NOT widen or narrow the recipient set
--   beyond the admin→ceo vocabulary substitution.
--
-- The signature is unchanged (9-arg v3 from 0026); CREATE OR REPLACE is
-- sufficient. The body is copied verbatim from 0026 with two changes:
-- the role→tier CASE (line 115-120 of 0026) and the predicate above.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.accept_invite(
  p_invite_id            uuid,
  p_user_name            text,
  p_staff_phone          text,
  p_next_of_kin_name     text,
  p_next_of_kin_phone    text,
  p_next_of_kin_relation text,
  p_guarantor_name       text DEFAULT NULL,
  p_guarantor_phone      text DEFAULT NULL,
  p_guarantor_relation   text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid       uuid := auth.uid();
  v_auth_email     text;
  v_invite         public.invites%ROWTYPE;
  v_user_id        uuid;
  v_membership_id  uuid;
  v_just_inserted  boolean;
  v_grace_days     int;
  v_due_at         timestamptz;
  v_role_tier      int;
  v_clean_name     text;
  v_warehouse_id   uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_clean_name := COALESCE(NULLIF(trim(p_user_name), ''), 'Unknown');

  -- Lock the invite row to keep concurrent claims from racing.
  SELECT * INTO v_invite
    FROM public.invites
   WHERE id = p_invite_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invite_not_found'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_invite.status NOT IN ('pending', 'accepted') THEN
    RAISE EXCEPTION 'invite_status_invalid:%', v_invite.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_invite.status = 'pending' AND v_invite.expires_at < now() THEN
    RAISE EXCEPTION 'invite_expired'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Email-match guard.
  SELECT email INTO v_auth_email FROM auth.users WHERE id = v_auth_uid;
  IF v_auth_email IS NULL
     OR lower(v_auth_email) <> lower(v_invite.email) THEN
    RAISE EXCEPTION 'email_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- role → role_tier (new granular vocabulary).
  v_role_tier := CASE v_invite.role
    WHEN 'ceo'          THEN 6
    WHEN 'manager'      THEN 5
    WHEN 'stock_keeper' THEN 4
    WHEN 'cashier'      THEN 3
    WHEN 'rider'        THEN 2
  END;

  v_warehouse_id := v_invite.warehouse_id;

  -- 1. Find-or-create users row (Phase 1 model: one users row per
  --    (business, email); auth_user_id UNIQUE).
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = v_auth_uid
     AND business_id  = v_invite.business_id
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.users (
      auth_user_id, business_id, name, email,
      role, role_tier, warehouse_id
    ) VALUES (
      v_auth_uid, v_invite.business_id, v_clean_name, v_invite.email,
      v_invite.role, v_role_tier, v_warehouse_id
    )
    ON CONFLICT (business_id, email) DO UPDATE
      SET auth_user_id = EXCLUDED.auth_user_id,
          name         = EXCLUDED.name,
          role         = EXCLUDED.role,
          role_tier    = EXCLUDED.role_tier,
          warehouse_id = EXCLUDED.warehouse_id,
          last_updated_at = now()
    RETURNING id INTO v_user_id;
  END IF;

  -- 2. Resolve grace window. Default 14 (was 7 in rev 2).
  SELECT (value)::int INTO v_grace_days
    FROM public.settings
   WHERE business_id = v_invite.business_id
     AND key = 'onboarding.verification_grace_days';
  v_grace_days := COALESCE(v_grace_days, 14);
  v_due_at := now() + make_interval(days => v_grace_days);

  -- 3. Find-or-create membership. Capture xmax = 0 to gate notification
  --    fan-out: true on first insert, false on idempotent replay.
  INSERT INTO public.business_members (
    business_id, user_id, role, role_tier, warehouse_id,
    status, verification_status, verification_due_at,
    joined_at, created_by,
    staff_phone, next_of_kin_name, next_of_kin_phone, next_of_kin_relation,
    guarantor_name, guarantor_phone, guarantor_relation
  ) VALUES (
    v_invite.business_id, v_user_id, v_invite.role, v_role_tier, v_warehouse_id,
    'active', 'not_started', v_due_at,
    now(), v_invite.created_by,
    NULLIF(trim(p_staff_phone), ''),
    NULLIF(trim(p_next_of_kin_name), ''),
    NULLIF(trim(p_next_of_kin_phone), ''),
    NULLIF(trim(p_next_of_kin_relation), ''),
    NULLIF(trim(coalesce(p_guarantor_name, '')), ''),
    NULLIF(trim(coalesce(p_guarantor_phone, '')), ''),
    NULLIF(trim(coalesce(p_guarantor_relation, '')), '')
  )
  ON CONFLICT (business_id, user_id) DO UPDATE
    SET role            = EXCLUDED.role,
        role_tier       = EXCLUDED.role_tier,
        last_updated_at = now()
  RETURNING id, (xmax = 0) INTO v_membership_id, v_just_inserted;

  -- 4. Mark invite accepted (idempotent).
  UPDATE public.invites
     SET status  = 'accepted',
         used_at = COALESCE(used_at, now()),
         last_updated_at = now()
   WHERE id = p_invite_id
     AND status = 'pending';

  -- 5. Activity log.
  INSERT INTO public.activity_logs (
    business_id, user_id, action, description
  ) VALUES (
    v_invite.business_id,
    v_user_id,
    'invite.accepted',
    format('%s joined as %s via invite %s',
           v_clean_name, v_invite.role, p_invite_id)
  );

  -- 6. Notification fan-out — only on first acceptance (replay skipped).
  --    CEO sees every staff joining; managers only see staff joining
  --    THEIR warehouse. Stock keepers are not people-managers and are
  --    not notified. See header comment block for the rewrite reasoning.
  IF v_just_inserted THEN
    INSERT INTO public.notifications (
      business_id, type, message, linked_record_id, recipient_user_id
    )
    SELECT
      v_invite.business_id,
      'member.created',
      format('%s joined as %s', v_clean_name, v_invite.role),
      v_membership_id,
      bm.user_id
    FROM public.business_members bm
    WHERE bm.business_id = v_invite.business_id
      AND bm.is_deleted = false
      AND bm.status = 'active'
      AND bm.user_id <> v_user_id  -- don't notify the joiner
      AND (
        bm.role = 'ceo'
        OR (
          bm.role = 'manager'
          AND v_warehouse_id IS NOT NULL
          AND bm.warehouse_id = v_warehouse_id
        )
      );
  END IF;

  -- 7. Return canonical rows for _applyDomainResponse.
  RETURN jsonb_build_object(
    'user',       (SELECT to_jsonb(u) FROM public.users           u WHERE u.id = v_user_id),
    'membership', (SELECT to_jsonb(m) FROM public.business_members m WHERE m.id = v_membership_id),
    'invite',     (SELECT to_jsonb(i) FROM public.invites          i WHERE i.id = p_invite_id)
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.accept_invite(uuid, text, text, text, text, text, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.accept_invite(uuid, text, text, text, text, text, text, text, text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. regenerate_invite_code — bump caller-tier gate from < 4 to < 5.
--    Old: rejected staff (tier 1); allowed admin/manager/ceo (tiers 4, 5).
--    New: rejects rider/cashier/stock_keeper (tiers 2, 3, 4); allows
--    manager/ceo (tiers 5, 6). Stock keepers don't regenerate invites —
--    that's people-management territory (Decision #2).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.regenerate_invite_code(p_invite_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid := public.business_id();
  v_caller_tier     int;
  v_invite          public.invites%ROWTYPE;
  v_new_id          uuid;
  v_new_code        text;
  v_new_human_code  text;
  v_now             timestamptz := now();
  v_expires_at      timestamptz;
  v_alphabet        text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_attempt         int;
  v_ttl_days        int;
BEGIN
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Caller must be manager (tier 5) or ceo (tier 6).
  SELECT role_tier INTO v_caller_tier
    FROM public.profiles
   WHERE id = auth.uid();
  IF v_caller_tier IS NULL OR v_caller_tier < 5 THEN
    RAISE EXCEPTION 'forbidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock the invite, validate it belongs to the caller's business and is
  -- still pending (regen only works on unredeemed).
  SELECT * INTO v_invite
    FROM public.invites
   WHERE id = p_invite_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invite_not_found'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_invite.business_id <> v_caller_business THEN
    RAISE EXCEPTION 'forbidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_invite.status <> 'pending' THEN
    RAISE EXCEPTION 'invite_not_pending:%', v_invite.status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- TTL — read setting, fallback 7 days.
  SELECT (value)::int INTO v_ttl_days
    FROM public.settings
   WHERE business_id = v_caller_business
     AND key = 'onboarding.invite_ttl_days';
  v_ttl_days := COALESCE(v_ttl_days, 7);
  v_expires_at := v_now + make_interval(days => v_ttl_days);

  -- 1. Revoke the old row.
  UPDATE public.invites
     SET status = 'revoked',
         last_updated_at = v_now
   WHERE id = v_invite.id;

  -- 2. Mint a fresh 8-char code, retrying on collision (partial unique
  --    index uq_invites_pending_human_code can fire). 32^8 ≈ 1.1T values
  --    so collisions are vanishingly rare; 5 attempts is generous.
  FOR v_attempt IN 1..5 LOOP
    SELECT string_agg(
      substr(v_alphabet, 1 + (floor(random() * 32))::int, 1), ''
    ) INTO v_new_human_code
    FROM generate_series(1, 8);

    -- Legacy 8-char `code` column — keep populated for any consumer still
    -- reading it; same alphabet, same length, separate value.
    SELECT string_agg(
      substr(v_alphabet, 1 + (floor(random() * 32))::int, 1), ''
    ) INTO v_new_code
    FROM generate_series(1, 8);

    BEGIN
      INSERT INTO public.invites (
        business_id, email, code, human_code, phone,
        role, warehouse_id, created_by, invitee_name,
        status, expires_at,
        regenerated_from, regenerated_at
      ) VALUES (
        v_invite.business_id, v_invite.email, v_new_code, v_new_human_code,
        v_invite.phone, v_invite.role, v_invite.warehouse_id, v_invite.created_by,
        v_invite.invitee_name, 'pending', v_expires_at,
        v_invite.id, v_now
      )
      RETURNING id INTO v_new_id;
      EXIT;  -- success
    EXCEPTION WHEN unique_violation THEN
      IF v_attempt = 5 THEN
        RAISE EXCEPTION 'code_generation_failed_collisions'
          USING ERRCODE = 'unique_violation';
      END IF;
    END;
  END LOOP;

  -- 3. Activity log.
  INSERT INTO public.activity_logs (business_id, user_id, action, description)
  VALUES (
    v_caller_business,
    (SELECT id FROM public.users WHERE auth_user_id = auth.uid() AND business_id = v_caller_business LIMIT 1),
    'invite.regenerated',
    format('regenerated invite %s → %s', v_invite.id, v_new_id)
  );

  -- 4. Return the new row. RETURN ... FROM is not valid PL/pgSQL; wrap as
  --    a scalar subquery (same fix as 0029).
  RETURN (SELECT to_jsonb(i.*) FROM public.invites i WHERE i.id = v_new_id);
END;
$$;

REVOKE ALL    ON FUNCTION public.regenerate_invite_code(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.regenerate_invite_code(uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. extend_verification — same caller-tier bump as regenerate_invite_code.
--    Only manager + ceo can extend verification deadlines.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.extend_verification(
  p_membership_id uuid,
  p_extra_days    int,
  p_reason        text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid := public.business_id();
  v_caller_tier     int;
  v_member          public.business_members%ROWTYPE;
  v_clean_reason    text;
  v_new_due_at      timestamptz;
BEGIN
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Caller must be manager (tier 5) or ceo (tier 6).
  SELECT role_tier INTO v_caller_tier
    FROM public.profiles
   WHERE id = auth.uid();
  IF v_caller_tier IS NULL OR v_caller_tier < 5 THEN
    RAISE EXCEPTION 'forbidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_extra_days IS NULL OR p_extra_days <= 0 OR p_extra_days > 60 THEN
    RAISE EXCEPTION 'invalid_extra_days:%', p_extra_days
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_clean_reason := NULLIF(trim(coalesce(p_reason, '')), '');
  IF v_clean_reason IS NULL THEN
    RAISE EXCEPTION 'reason_required'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Lock the membership row, validate it's the caller's business.
  SELECT * INTO v_member
    FROM public.business_members
   WHERE id = p_membership_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'member_not_found'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_member.business_id <> v_caller_business THEN
    RAISE EXCEPTION 'forbidden'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cap-check in the RPC body (not via column CHECK — see plan §C / pickup).
  IF v_member.verification_extensions_used >= 2 THEN
    RAISE EXCEPTION 'extension_cap_reached'
      USING ERRCODE = 'check_violation';
  END IF;

  v_new_due_at := COALESCE(v_member.verification_due_at, now())
                  + make_interval(days => p_extra_days);

  UPDATE public.business_members
     SET verification_due_at          = v_new_due_at,
         verification_extensions_used = verification_extensions_used + 1,
         last_updated_at              = now()
   WHERE id = p_membership_id;

  -- Activity log captures who, when, why.
  INSERT INTO public.activity_logs (business_id, user_id, action, description)
  VALUES (
    v_caller_business,
    (SELECT id FROM public.users WHERE auth_user_id = auth.uid() AND business_id = v_caller_business LIMIT 1),
    'verification.extended',
    format('extended membership %s by %s days; reason: %s',
           p_membership_id, p_extra_days, v_clean_reason)
  );

  RETURN jsonb_build_object(
    'membership_id',                p_membership_id,
    'verification_due_at',          v_new_due_at,
    'verification_extensions_used', v_member.verification_extensions_used + 1
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.extend_verification(uuid, int, text) FROM public;
GRANT EXECUTE ON FUNCTION public.extend_verification(uuid, int, text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. In-transaction verification. Any failure here raises and rolls the
--    whole migration back — we never want a partial state where some rows
--    are migrated and others aren't.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  n int;
BEGIN
  SELECT count(*) INTO n FROM public.profiles
   WHERE role NOT IN ('ceo','manager','stock_keeper','cashier','rider');
  IF n > 0 THEN RAISE EXCEPTION 'profiles.role backfill incomplete: % offending row(s)', n; END IF;

  SELECT count(*) INTO n FROM public.profiles
   WHERE role_tier NOT IN (2,3,4,5,6);
  IF n > 0 THEN RAISE EXCEPTION 'profiles.role_tier backfill incomplete: % offending row(s)', n; END IF;

  SELECT count(*) INTO n FROM public.users
   WHERE role NOT IN ('ceo','manager','stock_keeper','cashier','rider');
  IF n > 0 THEN RAISE EXCEPTION 'users.role backfill incomplete: % offending row(s)', n; END IF;

  SELECT count(*) INTO n FROM public.users
   WHERE role_tier NOT IN (2,3,4,5,6);
  IF n > 0 THEN RAISE EXCEPTION 'users.role_tier backfill incomplete: % offending row(s)', n; END IF;

  SELECT count(*) INTO n FROM public.business_members
   WHERE role NOT IN ('ceo','manager','stock_keeper','cashier','rider');
  IF n > 0 THEN RAISE EXCEPTION 'business_members.role backfill incomplete: % offending row(s)', n; END IF;

  SELECT count(*) INTO n FROM public.business_members
   WHERE role_tier NOT IN (2,3,4,5,6);
  IF n > 0 THEN RAISE EXCEPTION 'business_members.role_tier backfill incomplete: % offending row(s)', n; END IF;

  SELECT count(*) INTO n FROM public.invites
   WHERE role NOT IN ('ceo','manager','stock_keeper','cashier','rider');
  IF n > 0 THEN RAISE EXCEPTION 'invites.role backfill incomplete: % offending row(s)', n; END IF;

  RAISE NOTICE 'migration 0030 verification: all role/role_tier values valid.';
END $$;

COMMIT;

-- =============================================================================
-- Verification (manual, after deploy):
--
--   1. CHECK constraints in force:
--      SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--      WHERE conrelid IN (
--        'public.profiles'::regclass,
--        'public.users'::regclass,
--        'public.business_members'::regclass,
--        'public.invites'::regclass
--      ) AND contype = 'c' AND pg_get_constraintdef(oid) ILIKE '%role%';
--      -- expect: 7 rows (4 role checks + 3 role_tier checks).
--
--   2. CEO row at tier 6:
--      SELECT role, role_tier FROM public.business_members WHERE role = 'ceo';
--      -- expect role_tier = 6.
--
--   3. Manager rows at tier 5:
--      SELECT role, role_tier FROM public.business_members WHERE role = 'manager';
--      -- expect role_tier = 5 for every row.
--
--   4. Cashier invite passes (the one row that started this whole refactor):
--      SELECT role FROM public.invites WHERE role = 'cashier';
--      -- expect 1 row, no constraint violation on read.
--
--   5. Reject invalid roles (sanity):
--      INSERT INTO public.invites (
--        business_id, email, code, role, created_by, invitee_name,
--        status, expires_at
--      ) VALUES (
--        gen_random_uuid(), 'x@y.z', 'TESTCODE', 'admin',
--        (SELECT id FROM public.users LIMIT 1), 'Test', 'pending',
--        now() + interval '1 day'
--      );
--      -- expect: ERROR: new row for relation "invites" violates check
--      -- constraint "invites_role_check"
--      -- (don't actually run this in prod; it's documentation of expected
--      -- behavior.)
--
--   6. accept_invite role→tier (run via a real invite flow):
--      -- accept an invite with role='cashier' → membership.role_tier = 3.
--      -- accept an invite with role='rider'   → membership.role_tier = 2.
--      -- accept an invite with role='manager' → membership.role_tier = 5.
--
--   7. regenerate_invite_code / extend_verification tier gate:
--      -- as a cashier (tier 3) call regenerate_invite_code → ERROR forbidden.
--      -- as a stock_keeper (tier 4) call regenerate_invite_code → ERROR forbidden.
--      -- as a manager (tier 5) call regenerate_invite_code → success.
-- =============================================================================
