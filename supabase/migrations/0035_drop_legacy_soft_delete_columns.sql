-- 0035_drop_legacy_soft_delete_columns.sql
--
-- Finalises the staff-lifecycle hard-delete model started in 0034:
--
--   1. Rewrites public.accept_invite as a TRUE fresh-row-only path.
--      0034 was registered as applied in schema_migrations but the live
--      function body on production was still 0032's revive version
--      (ON CONFLICT DO UPDATE branches with is_deleted=false, status='active'
--      etc.). This re-applies the fresh-row rewrite — verified post-deploy.
--
--   2. Rewrites public.terminate_member(p_user_id, p_business_id) to drop
--      every reference to the soft-delete columns. The anonymization of
--      the users row stays — it's what frees the UNIQUE(business_id, email)
--      and UNIQUE(auth_user_id) slots so a re-invited person can INSERT
--      a fresh users row. The `is_deleted=true` write goes because the
--      column is being dropped below.
--
--      Realtime kick: the previous "is_deleted=true trip-wire on users"
--      goes away. The new client (feat/staff-lifecycle-six-rules) listens
--      for the business_members DELETE realtime event from this RPC and
--      fires the kick from there. Existing in-the-wild clients will
--      discover their termination on their next cloud write being
--      rejected (RLS / membership check) or app restart, rather than
--      instantly via realtime — accepted gap per the rollout plan.
--
--   3. Drops the four dead columns on users / business_members and their
--      now-empty indexes:
--        users.is_deleted
--        business_members.{is_deleted, status, removed_at, removed_by}
--        idx_users_business_deleted
--        idx_business_members_business_deleted
--
-- FK landscape note (unchanged from 0034): users is referenced by ~15
-- tables with RESTRICT (orders.staff_id, stock_transactions.performed_by,
-- activity_logs.user_id, sessions.user_id, etc.). We continue NOT to
-- hard-delete the users row — only its identity fields get NULLed /
-- sentinel'd. Past orders keep their FK and the name keeps rendering.
--
-- Audit performed prior to drop (see PR description):
--   - pg_proc: only public.accept_invite, public.terminate_member
--     referenced these columns on users/business_members. Both rewritten
--     above to use them no longer.
--   - pg_policies: no RLS policies reference is_deleted / status /
--     removed_at / removed_by on these tables.
--   - pg_views: no views reference them.
--   - pg_indexes: only the two idx_*_business_deleted entries, dropped here.
--   - pg_trigger: only trg_users_bump_lua on users (column-agnostic).
--
-- Drift-side counterpart: schema v11 in lib/core/database/app_database.dart
-- drops the same columns and clears any pre-upgrade soft-deleted rows
-- plus stale sync_queue payloads. Both sides of the contract align.

BEGIN;

-- =========================================================================
-- 1. public.terminate_member(p_user_id uuid, p_business_id uuid)
--
--    Same signature, same overall flow as 0034. Differences:
--      * Caller-lookup drops `AND is_deleted = false` (column gone).
--      * Anonymization UPDATE no longer sets `is_deleted = true`.
--      * Header comment about the is_deleted realtime trip-wire is gone
--        — the kick now comes from the business_members DELETE event,
--        which the new client handles directly.
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

  -- Resolve caller. With users.is_deleted gone, "active member" is
  -- defined purely by presence — auth.uid mapped to a users row in this
  -- business, with a matching business_members row.
  SELECT u.id, bm.role_tier
    INTO v_actor_id, v_actor_tier
    FROM public.users u
    JOIN public.business_members bm
      ON bm.user_id = u.id
     AND bm.business_id = u.business_id
   WHERE u.auth_user_id = v_auth_uid
     AND u.business_id  = p_business_id
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
  SELECT bm.role_tier, u.name
    INTO v_target_tier, v_target_name
    FROM public.users u
    JOIN public.business_members bm
      ON bm.user_id = u.id
     AND bm.business_id = u.business_id
   WHERE u.id = p_user_id
     AND u.business_id = p_business_id
   LIMIT 1;

  IF v_target_tier IS NULL THEN
    -- No active membership for this user in this business — idempotent
    -- no-op. Could be a re-fire after the row already vanished.
    RETURN jsonb_build_object('ok', true, 'no_op', true);
  END IF;

  -- Tier guard: caller must outrank the target.
  IF v_actor_tier <= v_target_tier THEN
    RAISE EXCEPTION 'forbidden:tier_too_low'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1. Hard-delete the membership row — cuts the association. Realtime
  --    fires a DELETE event the new client listens to for the kick.
  DELETE FROM public.business_members
   WHERE user_id     = p_user_id
     AND business_id = p_business_id;

  -- 2. Anonymize the users row in place. Identity fields wiped; name kept.
  --    The sentinel uses the row's id to guarantee uniqueness on the
  --    UNIQUE(business_id, email) slot without leaking the original.
  --    auth_user_id=NULL frees the UNIQUE(auth_user_id) slot so a fresh
  --    accept_invite for the same Supabase user can INSERT cleanly.
  v_sentinel := 'deleted-' || p_user_id::text || '@deleted.local';

  UPDATE public.users
     SET auth_user_id    = NULL,
         email           = v_sentinel,
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
-- 2. public.accept_invite(...) — fresh-row-only.
--
--    Re-applies 0034's intended rewrite (production currently has 0032's
--    revive version despite 0034 being registered as applied — see header).
--    Same signature so CREATE OR REPLACE is sufficient. The only diff vs
--    0034's body is the notification fan-out: drops `bm.is_deleted = false
--    AND bm.status = 'active'` since those columns are dropped below.
--    Every row in business_members is now necessarily an active membership.
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
    role, role_tier, warehouse_id, last_updated_at
  ) VALUES (
    v_auth_uid, v_invite.business_id, v_clean_name, v_invite.email,
    v_invite.role, v_role_tier, v_warehouse_id, now()
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
  --    `status` column is gone (every row is active); `is_deleted` gone too.
  INSERT INTO public.business_members (
    business_id, user_id, role, role_tier, warehouse_id,
    verification_status, verification_due_at,
    joined_at, created_by,
    staff_phone, next_of_kin_name, next_of_kin_phone, next_of_kin_relation,
    guarantor_name, guarantor_phone, guarantor_relation
  ) VALUES (
    v_invite.business_id, v_user_id, v_invite.role, v_role_tier, v_warehouse_id,
    'not_started', v_due_at,
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
  --    joining their warehouse. The `bm.is_deleted = false AND bm.status =
  --    'active'` predicates are gone (columns dropped); every remaining
  --    business_members row is by definition an active membership.
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
-- 3. Drop now-unreachable indexes (column drop would cascade them anyway;
--    explicit DROP keeps the migration self-documenting).
-- =========================================================================

DROP INDEX IF EXISTS public.idx_users_business_deleted;
DROP INDEX IF EXISTS public.idx_business_members_business_deleted;

-- =========================================================================
-- 4. Drop the columns. The functions above no longer reference them, and
--    the audit above confirmed nothing else does either.
-- =========================================================================

ALTER TABLE public.users
  DROP COLUMN IF EXISTS is_deleted;

ALTER TABLE public.business_members
  DROP COLUMN IF EXISTS is_deleted,
  DROP COLUMN IF EXISTS status,
  DROP COLUMN IF EXISTS removed_at,
  DROP COLUMN IF EXISTS removed_by;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor signed in as the CEO):
--
--   1. Columns are gone:
--      SELECT column_name FROM information_schema.columns
--       WHERE table_schema='public' AND table_name='users'
--         AND column_name='is_deleted';
--      -- expect 0 rows
--
--      SELECT column_name FROM information_schema.columns
--       WHERE table_schema='public' AND table_name='business_members'
--         AND column_name IN ('is_deleted','status','removed_at','removed_by');
--      -- expect 0 rows
--
--   2. Indexes are gone:
--      SELECT indexname FROM pg_indexes
--       WHERE schemaname='public'
--         AND indexname IN ('idx_users_business_deleted',
--                           'idx_business_members_business_deleted');
--      -- expect 0 rows
--
--   3. accept_invite body is fresh-row (no revive markers):
--      SELECT position('-- revive' IN pg_get_functiondef(oid))
--      FROM pg_proc
--      WHERE proname='accept_invite' AND pronamespace='public'::regnamespace;
--      -- expect 0
--
--   4. terminate_member has no is_deleted writes:
--      SELECT position('is_deleted' IN pg_get_functiondef(oid))
--      FROM pg_proc
--      WHERE proname='terminate_member' AND pronamespace='public'::regnamespace;
--      -- expect 0
--
--   5. Re-invite a previously-terminated user works end-to-end (manual):
--      a. CEO terminates staff member X.
--      b. CEO sends fresh invite to X's email.
--      c. X completes the OTP + wizard.
--      d. SELECT count(*) FROM public.users WHERE email = '<X email>';
--         -- expect 2 (the anonymized historical row + the fresh one)
--      e. SELECT count(*) FROM public.business_members
--          WHERE user_id = '<X new users.id>'::uuid;
--         -- expect 1
-- =============================================================================
