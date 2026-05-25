-- Materialized from remote supabase_migrations.schema_migrations
-- version=0033 on 0033_accept_invite_revive_users_on_existing_row.sql.
-- Reconstructed from the statements[] array so local migration
-- history matches what was actually applied to production. The
-- original .sql file authored on another machine is not in this
-- checkout; this file is a faithful re-serialisation of the same
-- DDL the database actually ran.

-- 0033_accept_invite_revive_users_on_existing_row.sql
--
-- Fix accept_invite so a re-invited previously-terminated user actually has
-- users.is_deleted flipped back to false.
--
-- The 0032 revision wraps the users INSERT/ON CONFLICT inside
--   IF v_user_id IS NULL THEN ... END IF;
-- For any previously-signed-in user, termination preserves auth_user_id,
-- so the SELECT INTO at lines 125-129 finds the existing row, v_user_id is
-- non-NULL, the IF is false, and the ON CONFLICT … is_deleted = false UPDATE
-- never runs. Net effect: business_members revives correctly (its INSERT/
-- ON CONFLICT runs unconditionally), but users.is_deleted stays true — so
-- the re-invited user keeps showing in the TERMINATED section everywhere.
--
-- This migration adds an ELSE branch that runs an idempotent UPDATE for the
-- existing-row case, applying the same field refresh + revive flip we'd
-- otherwise apply in the ON CONFLICT branch. The UPDATE WHERE-guard makes it
-- a no-op for already-active users whose role/warehouse/name haven't changed,
-- so steady-state replay does nothing.
--
-- Everything else in the function (membership revival, invite mark-accepted,
-- activity log, notification fan-out, response builder) is verbatim from 0032.
-- CREATE OR REPLACE is sufficient since the signature is unchanged.

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
  ELSE
    -- 0033 fix: user already existed (found by auth_user_id), so the
    -- INSERT/ON CONFLICT path above didn't run and the revive flip
    -- (is_deleted = false) was skipped. Apply the same field refresh +
    -- revival here. The WHERE guard keeps this idempotent: re-running
    -- accept_invite on an already-active user whose invite attributes
    -- haven't changed touches nothing.
    UPDATE public.users
       SET name            = v_clean_name,
           role            = v_invite.role,
           role_tier       = v_role_tier,
           warehouse_id    = v_warehouse_id,
           is_deleted      = false,
           last_updated_at = now()
     WHERE id = v_user_id
       AND ( is_deleted    = true
          OR name          <> v_clean_name
          OR role          <> v_invite.role
          OR role_tier     <> v_role_tier
          OR warehouse_id IS DISTINCT FROM v_warehouse_id );
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
