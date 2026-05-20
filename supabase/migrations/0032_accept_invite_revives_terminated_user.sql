-- 0032_accept_invite_revives_terminated_user.sql
--
-- Make accept_invite revive a previously-terminated staff member when their
-- invite is re-accepted, instead of leaving stale soft-delete state on the
-- two ON CONFLICT branches.
--
-- Why this matters
-- ----------------
-- The Topic 3 termination flow (fix/staff-list-own-view-and-terminate)
-- soft-deletes a staff member by flipping users.is_deleted=true and
-- business_members.status='removed' / is_deleted=true. When that staff
-- member is later re-invited (same email + same auth_user_id), accept_invite
-- finds the existing rows and falls into its ON CONFLICT DO UPDATE branches.
--
-- In 0030 those branches only touched role/role_tier/warehouse_id/
-- last_updated_at — they did NOT reset is_deleted=false on users, and did
-- NOT reset status='active' / is_deleted=false / removed_at=NULL /
-- removed_by=NULL on business_members. Net effect: the invite would
-- "succeed" server-side, but the re-invited staff member would still be
-- soft-deleted on their next sign-in, locking them out silently.
--
-- This migration replaces accept_invite with the same body as 0030, plus:
--
--   * users ON CONFLICT branch: adds `is_deleted = false`.
--   * business_members ON CONFLICT branch: adds `status = 'active'`,
--     `is_deleted = false`, `removed_at = NULL`, `removed_by = NULL`, plus
--     `verification_status = 'not_started'` and
--     `verification_due_at = EXCLUDED.verification_due_at`. The verification
--     reset reflects the "re-invited person re-onboards from scratch"
--     semantic (decision: 2026-05-20). If a future use case argues for
--     preserving prior verification state, drop those two lines.
--
-- Everything else is verbatim from 0030 — function signature, RETURNS,
-- SECURITY DEFINER, search_path, the email-match guard, the grace-window
-- resolution, the activity log, the notification fan-out, and the JSONB
-- return shape. CREATE OR REPLACE FUNCTION is sufficient since the
-- signature is unchanged.
--
-- The notification fan-out at step 6 is correctly suppressed on revival
-- because v_just_inserted = (xmax = 0) is false when ON CONFLICT runs the
-- UPDATE branch. Re-invited staff don't re-broadcast as new joiners.
--
-- Re-acceptance reset behaviour is symmetric with the local
-- BusinessMembersDao.terminateMember client fix landing in the same
-- commit (lib/core/database/daos.dart).

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
      SET auth_user_id    = EXCLUDED.auth_user_id,
          name            = EXCLUDED.name,
          role            = EXCLUDED.role,
          role_tier       = EXCLUDED.role_tier,
          warehouse_id    = EXCLUDED.warehouse_id,
          is_deleted      = false,                 -- revive terminated user
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
  --    fan-out: true on first insert, false on idempotent replay
  --    (including the re-acceptance-after-termination path).
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
    SET role                = EXCLUDED.role,
        role_tier           = EXCLUDED.role_tier,
        status              = 'active',                      -- revive
        is_deleted          = false,                         -- revive
        removed_at          = NULL,                          -- clear termination
        removed_by          = NULL,                          -- clear termination
        verification_status = 'not_started',                 -- re-onboard
        verification_due_at = EXCLUDED.verification_due_at,  -- refresh grace clock
        last_updated_at     = now()
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
  --    not notified.
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
