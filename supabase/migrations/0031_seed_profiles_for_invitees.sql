-- =============================================================================
-- 0031_seed_profiles_for_invitees.sql — make public.profiles authoritative
-- for every business member, not just the CEO owner.
--
-- Context. Pre-0031, only the CEO owner-creation path
-- ([0023_complete_onboarding_seeds_membership.sql:75-81]) inserted into
-- public.profiles. accept_invite (last touched in 0030) created the
-- users + business_members rows for invitee-accepted staff but never a
-- paired profiles row. Consequence: every non-CEO invitee's auth.uid()
-- resolved to NULL through public.business_id(), which made the tenant
-- RLS deny every SELECT, which stranded the fresh-device acceptance
-- flow on the Welcome-back recovery screen ("Could not load your
-- account").
--
-- The audit captured in lib/features/staff/DEFERRED.md §"Non-CEO
-- invitee acceptance blocked by missing profiles row" identified three
-- distinct profiles-authoritative consumers:
--   1. public.business_id() — the RLS principal helper.
--   2. regenerate_invite_code / extend_verification — both read
--      role_tier from profiles directly for their manager-tier gate.
--   3. AuthService.upsertLocalUserFromProfile — the client-side seeder
--      for the local Drift users row.
-- Path C (COALESCE into business_members from business_id()) would
-- only have addressed (1); (2) and (3) still pointed at profiles.
-- Path B (this migration) closes all three at once by restoring the
-- original "profile row exists for every authenticated tenant member"
-- invariant. Audit details + flip rationale in DEFERRED.md (rev 2).
--
-- Idempotent: accept_invite's profiles INSERT uses ON CONFLICT (id) DO
-- UPDATE; the backfill uses ON CONFLICT (id) DO NOTHING.
--
-- Apply after 0030_role_vocabulary_expansion.sql.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. accept_invite — extend the RPC to seed public.profiles alongside the
--    existing users + business_members inserts.
--
--    Body is copied verbatim from 0030 (same 9-arg signature, same
--    SECURITY DEFINER, same search_path) with a single new INSERT block
--    between the users find-or-create (Step 1) and the grace-window
--    resolution (Step 2). The new block is marked `-- 0031:` for
--    diff-ability against 0030's body.
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

  -- role → role_tier (v9 granular vocabulary).
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

  -- 0031: seed public.profiles. Mirrors the CEO-only pattern at
  -- 0023:75-81 — extends it to every accept_invite call so the
  -- principal-lookup helper (public.business_id) and other
  -- profiles-authoritative consumers (regenerate_invite_code,
  -- extend_verification, AuthService.upsertLocalUserFromProfile)
  -- resolve for invitee-accepted staff. ON CONFLICT (id) DO UPDATE
  -- keeps the row in sync if the user re-redeems and their name or
  -- role has changed via the RPC.
  INSERT INTO public.profiles (id, business_id, name, role, role_tier)
    VALUES (v_auth_uid, v_invite.business_id, v_clean_name, v_invite.role, v_role_tier)
  ON CONFLICT (id) DO UPDATE
    SET business_id = EXCLUDED.business_id,
        name        = EXCLUDED.name,
        role        = EXCLUDED.role,
        role_tier   = EXCLUDED.role_tier;

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

-- -----------------------------------------------------------------------------
-- 2. Backfill. Every existing public.users row with auth_user_id NOT
--    NULL (set by 0028's owner-backfill and by accept_invite at INSERT
--    time for invitee-accepted staff) gets a paired profiles row if
--    one doesn't already exist. Role and tier come from
--    business_members (the canonical per-business state post-0020),
--    not from the legacy users.role / users.role_tier columns that
--    0020's header flags for removal in a future phase.
--
--    DISTINCT ON (auth_user_id) + ORDER BY ... joined_at DESC is a
--    defensive tiebreaker: the current single-tenant data model gives
--    each user one membership, but a future cross-business user
--    would be ambiguous; pick the most-recent membership.
--
--    Idempotent: ON CONFLICT (id) DO NOTHING so re-running does not
--    clobber rows that may have been edited between runs.
-- -----------------------------------------------------------------------------

INSERT INTO public.profiles (id, business_id, name, role, role_tier)
SELECT DISTINCT ON (u.auth_user_id)
  u.auth_user_id,
  u.business_id,
  u.name,
  bm.role,
  bm.role_tier
FROM public.users u
JOIN public.business_members bm
  ON bm.user_id = u.id
 AND bm.is_deleted = false
 AND bm.status = 'active'
WHERE u.auth_user_id IS NOT NULL
  AND u.is_deleted = false
ORDER BY u.auth_user_id, bm.joined_at DESC
ON CONFLICT (id) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while signed in as a non-CEO
-- invitee post-deploy):
--
--   1. Profile exists for the caller:
--      SELECT id, business_id, role, role_tier FROM public.profiles
--      WHERE id = auth.uid();
--      -- expect exactly 1 row
--
--   2. business_id() resolves to the caller's business (matches the
--      profile row from step 1):
--      SELECT public.business_id();
--      -- expect non-NULL
--
--   3. Tenant SELECTs return data (RLS no longer denies):
--      SELECT count(*) FROM public.businesses;     -- expect 1
--      SELECT count(*) FROM public.warehouses;     -- expect >= 1
--      SELECT count(*) FROM public.business_members;  -- expect >= 1
--
--   4. Every active member has a profile (post-backfill invariant):
--      SELECT COUNT(*) FROM public.users u
--      LEFT JOIN public.profiles p ON p.id = u.auth_user_id
--      WHERE u.auth_user_id IS NOT NULL
--        AND u.is_deleted = false
--        AND p.id IS NULL;
--      -- expect 0
--
--   5. Idempotency — re-running this migration is a no-op:
--      -- (a) Re-execute the function body via psql or the dashboard
--      --     SQL editor; CREATE OR REPLACE replaces, no error.
--      -- (b) Re-execute the backfill INSERT; ON CONFLICT (id) DO
--      --     NOTHING swallows the duplicates; no row count changes.
-- =============================================================================
