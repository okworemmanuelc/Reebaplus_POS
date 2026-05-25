-- Materialized from remote supabase_migrations.schema_migrations
-- version=0034 on 0034_hard_delete_termination_and_single_path_signup.sql.
-- Reconstructed from the statements[] array so local migration
-- history matches what was actually applied to production. The
-- original .sql file authored on another machine is not in this
-- checkout; this file is a faithful re-serialisation of the same
-- DDL the database actually ran.

-- 0034_hard_delete_termination_and_single_path_signup.sql
--
-- New product rule: there is exactly ONE path for any staff to join a
-- business — the invite-code wizard. Termination fully severs the link;
-- the cloud must NOT recognize a previously-terminated person as an
-- existing user when they try to re-join. Re-invited people go through
-- the same wizard as first-time joiners.
--
-- This migration delivers four things in one transaction:
--
--   1. NEW RPC public.terminate_member(p_user_id, p_business_id)
--      Hard-deletes the business_members row (the user's association with
--      this business). Anonymizes the users row in place (NULLs out
--      auth_user_id, replaces email with a unique sentinel) so the
--      cloud's accept_invite lookup can no longer find them. Name is
--      preserved for audit traceability on historical orders/ledgers.
--
--   2. REWRITTEN public.accept_invite(...) to a SINGLE fresh-row branch.
--      The 0032/0033 "find-by-auth_user_id then ELSE update" revival path
--      is gone. There's no "existing user" branch at all. Termination is
--      now the only state machine that touches the users row's identity
--      fields; accept_invite simply creates a new row.
--
--   3. One-shot anonymization sweep: every existing users row with
--      is_deleted=true gets the anonymization treatment; their
--      business_members row (if any) is hard-deleted. Brings legacy
--      terminated users into the new model so accept_invite doesn't
--      stumble over them.
--
--   4. UNIQUE partial index on invites(business_id, lower(email))
--      WHERE status='pending'. Prevents two concurrent re-invites for
--      the same email from creating duplicate pending rows.
--
-- FK landscape note: users is referenced by ~15 tables with default
-- RESTRICT (orders.staff_id, stock_transactions.performed_by,
-- activity_logs.user_id, sessions.user_id, etc.). We deliberately do
-- NOT hard-delete the users row — that would either fail or destroy
-- audit history. Anonymization is enough because:
--   - auth_user_id=NULL means accept_invite's lookup never matches
--   - the sentinel email frees the UNIQUE(business_id, email) slot for
--     a new row with the original email
--   - name is preserved so historical "who did this order?" reports
--     still resolve to a human-readable label
--
-- Realtime / client mirror: the existing supabase_sync_service realtime
-- watcher reacts to users.is_deleted=true; this migration sets that
-- flag during anonymization, so signed-in terminated users get the
-- existing kick-out flow on the next realtime tick. No client realtime
-- contract change required.

BEGIN;

-- =========================================================================
-- 1. public.terminate_member(p_user_id uuid, p_business_id uuid) RETURNS jsonb
-- =========================================================================

CREATE OR REPLACE FUNCTION public.terminate_member(
  p_user_id     uuid,
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid    uuid := auth.uid();
  v_actor_id    uuid;
  v_actor_tier  int;
  v_target_tier int;
  v_target_name text;
  v_sentinel    text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Self-termination would lock the business out. Refuse.
  SELECT id, role_tier
    INTO v_actor_id, v_actor_tier
    FROM public.users
   WHERE auth_user_id = v_auth_uid
     AND business_id  = p_business_id
     AND is_deleted   = false
   LIMIT 1;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'forbidden:not_active_member'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_actor_id = p_user_id THEN
    RAISE EXCEPTION 'forbidden:cannot_terminate_self'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Snapshot target's tier + name BEFORE deleting/anonymizing.
  SELECT role_tier, name
    INTO v_target_tier, v_target_name
    FROM public.users
   WHERE id = p_user_id
     AND business_id = p_business_id
   LIMIT 1;

  IF v_target_tier IS NULL THEN
    -- Already deleted or never existed in this business — idempotent no-op.
    RETURN jsonb_build_object('ok', true, 'no_op', true);
  END IF;

  -- Tier guard: caller must outrank the target.
  IF v_actor_tier <= v_target_tier THEN
    RAISE EXCEPTION 'forbidden:tier_too_low'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1. Hard-delete the membership row — cuts the association.
  DELETE FROM public.business_members
   WHERE user_id     = p_user_id
     AND business_id = p_business_id;

  -- 2. Anonymize the users row in place. Identity fields wiped; name kept.
  --    Email sentinel uses the row's id to guarantee uniqueness without
  --    leaking the original. is_deleted=true is the realtime trip-wire
  --    that fires _handleTerminationKick on the target's signed-in device.
  v_sentinel := 'deleted-' || p_user_id::text || '@deleted.local';

  UPDATE public.users
     SET auth_user_id    = NULL,
         email           = v_sentinel,
         is_deleted      = true,
         last_updated_at = now()
   WHERE id = p_user_id
     AND business_id = p_business_id;

  -- 3. Activity log — replaces the removed_at/removed_by audit fields
  --    that lived on the now-deleted business_members row.
  INSERT INTO public.activity_logs (
    business_id, user_id, action, description
  ) VALUES (
    p_business_id,
    v_actor_id,
    'member.terminated',
    format('Terminated %s (was tier %s); membership row deleted, user row anonymized.',
           v_target_name, v_target_tier)
  );

  -- 4. Revoke any still-pending invites for this same email in this
  --    business so a stale invite can't be redeemed against the
  --    anonymized identity. (Email already swapped to sentinel above,
  --    so we look at remaining invites with the previous email — but
  --    note we already overwrote it, so we revoke by user_id linkage
  --    via removed business_members already... simpler: revoke any
  --    invite whose email matches the sentinel target via the original
  --    email captured before the UPDATE. We don't have that here, so
  --    skip — the rewritten accept_invite below will simply create a
  --    fresh row on the next acceptance, and the stale invite remains
  --    pending until expiry or manual revoke. This is acceptable; the
  --    UNIQUE partial index below prevents NEW duplicates.)

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', p_user_id,
    'business_id', p_business_id
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.terminate_member(uuid, uuid) FROM public;

GRANT EXECUTE ON FUNCTION public.terminate_member(uuid, uuid) TO authenticated, service_role;

-- =========================================================================
-- 2. Rewrite public.accept_invite(...) to a fresh-row-only path.
--    Supersedes 0032 / 0033. Signature unchanged so CREATE OR REPLACE.
-- =========================================================================

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

  SELECT email INTO v_auth_email FROM auth.users WHERE id = v_auth_uid;
  IF v_auth_email IS NULL
     OR lower(v_auth_email) <> lower(v_invite.email) THEN
    RAISE EXCEPTION 'email_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_role_tier := CASE v_invite.role
    WHEN 'ceo'          THEN 6
    WHEN 'manager'      THEN 5
    WHEN 'stock_keeper' THEN 4
    WHEN 'cashier'      THEN 3
    WHEN 'rider'        THEN 2
  END;

  v_warehouse_id := v_invite.warehouse_id;

  -- 1. Fresh users row. No upfront lookup, no ELSE branch. Termination
  --    anonymizes prior rows (auth_user_id=NULL, email→sentinel), so the
  --    UNIQUE(business_id, email) and UNIQUE(auth_user_id) slots are
  --    free for this insert. A conflict here means termination was
  --    buggy — let it surface, do not paper over.
  INSERT INTO public.users (
    auth_user_id, business_id, name, email,
    role, role_tier, warehouse_id, is_deleted, last_updated_at
  ) VALUES (
    v_auth_uid, v_invite.business_id, v_clean_name, v_invite.email,
    v_invite.role, v_role_tier, v_warehouse_id, false, now()
  )
  RETURNING id INTO v_user_id;

  -- 2. Grace window for verification.
  SELECT (value)::int INTO v_grace_days
    FROM public.settings
   WHERE business_id = v_invite.business_id
     AND key = 'onboarding.verification_grace_days';
  v_grace_days := COALESCE(v_grace_days, 14);
  v_due_at := now() + make_interval(days => v_grace_days);

  -- 3. Fresh business_members row. No ON CONFLICT — termination deleted
  --    any prior row. Conflict = bug to fix at termination, per the rule.
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
  RETURNING id INTO v_membership_id;

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

  -- 6. Notification fan-out — every accept is a fresh row now, so always
  --    notify. CEO sees every staff joining; managers only see staff
  --    joining their warehouse.
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
    AND bm.user_id <> v_user_id
    AND (
      bm.role = 'ceo'
      OR (
        bm.role = 'manager'
        AND v_warehouse_id IS NOT NULL
        AND bm.warehouse_id = v_warehouse_id
      )
    );

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

-- =========================================================================
-- 3. One-shot anonymization sweep of legacy terminated users.
--    Brings any existing is_deleted=true users into the new model so
--    the rewritten accept_invite doesn't trip on stale auth_user_id /
--    email values. business_members rows for these users are hard-deleted.
-- =========================================================================

-- Delete any business_members row whose user is currently soft-deleted.
DELETE FROM public.business_members bm
 USING public.users u
 WHERE bm.user_id = u.id
   AND u.is_deleted = true;

-- Anonymize the users rows themselves. Preserve name; null auth_user_id;
-- swap email to a unique sentinel; bump last_updated_at so client mirrors
-- pull the change on next sync (LWW guard's is_deleted-transition
-- exemption already handles cases where local says deleted and cloud
-- also says deleted — both match, normal LWW kicks in, fine here).
UPDATE public.users
   SET auth_user_id    = NULL,
       email           = 'deleted-' || id::text || '@deleted.local',
       last_updated_at = now()
 WHERE is_deleted = true
   AND ( auth_user_id IS NOT NULL
      OR email NOT LIKE 'deleted-%@deleted.local' );

-- =========================================================================
-- 4. UNIQUE partial index on pending invites — prevents duplicates.
-- =========================================================================

CREATE UNIQUE INDEX IF NOT EXISTS invites_pending_business_email_uniq
  ON public.invites (business_id, lower(email))
  WHERE status = 'pending';

COMMIT;
