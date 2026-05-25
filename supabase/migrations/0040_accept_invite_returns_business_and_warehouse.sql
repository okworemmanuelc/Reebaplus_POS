-- 0040_accept_invite_returns_business_and_warehouse.sql
--
-- Closes a FK-ordering gap in the invite-redemption flow.
--
-- The problem
-- -----------
-- accept_invite (last rewritten in 0034) returns a jsonb response
-- shaped as { user, membership, invite }. The client's
-- _applyDomainResponse walks each key and calls _restoreTableData to
-- mirror them into local Drift. For a freshly-installed device joining
-- via invite — i.e. a manager or staff member redeeming an invite on
-- their phone for the first time — local Drift is empty: no
-- businesses, no warehouses, no anything.
--
-- The users row carried in the response has FK columns:
--   users.business_id  → public.businesses(id)
--   users.warehouse_id → public.warehouses(id)
--
-- On a fresh-device redemption neither parent exists locally yet (the
-- sync pull that would populate them fires later, AFTER
-- applyServerResponse). SQLite raises 787 FOREIGN KEY CONSTRAINT FAILED
-- and the SignupOrchestrator pivots the user to the
-- "existing account" recovery screen, which itself can't recover
-- because the same FK chain blocks upsertLocalUserFromProfile.
--
-- The fix
-- -------
-- Extend the response with the immediate FK parents so the client can
-- restore them in dependency order (businesses → warehouses → users →
-- business_members → invites). Same signature, body changes only the
-- RETURN clause: add 'business' and 'warehouse' subqueries.
--
-- The COMPANION client edit updates supabase_sync_service.dart's
-- _applyDomainResponse to process the new keys BEFORE 'user' / 'membership'
-- so the FK chain resolves at restore time.
--
-- Out of scope: profiles. The client's local Drift schema doesn't have
-- a profiles table (profiles lives only in the cloud as the RLS
-- pivot for business_id()); _restoreTableData has no handler for it
-- and adding one would be a separate, larger change. Profiles aren't
-- FK targets for users / business_members locally anyway, so they
-- don't block this restore.

BEGIN;

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

  -- 3. Fresh business_members row. `status` column was dropped by 0035;
  --    every row in the table is by definition an active membership.
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
    AND bm.user_id <> v_user_id
    AND (
      bm.role = 'ceo'
      OR (
        bm.role = 'manager'
        AND v_warehouse_id IS NOT NULL
        AND bm.warehouse_id = v_warehouse_id
      )
    );

  -- 7. Return canonical rows for _applyDomainResponse. Adds `business`
  --    and `warehouse` to the previous {user, membership, invite}
  --    shape — fresh-device redemption clients have empty local Drift,
  --    and the users / business_members rows have FK columns
  --    (users.business_id, users.warehouse_id, business_members.business_id,
  --    business_members.user_id, business_members.warehouse_id) that
  --    would otherwise fail with 787 FOREIGN KEY CONSTRAINT FAILED on
  --    the local INSERT. The client restores in dependency order:
  --    businesses → warehouses → users → business_members → invites.
  --
  --    `warehouse` may be NULL when v_warehouse_id is NULL (some staff
  --    roles like CEO-invitee have no warehouse assignment); the
  --    subquery just returns NULL JSON and the client skips the restore.
  RETURN jsonb_build_object(
    'business',   (SELECT to_jsonb(b) FROM public.businesses        b WHERE b.id = v_invite.business_id),
    'warehouse',  (SELECT to_jsonb(w) FROM public.warehouses        w WHERE w.id = v_warehouse_id),
    'user',       (SELECT to_jsonb(u) FROM public.users             u WHERE u.id = v_user_id),
    'membership', (SELECT to_jsonb(m) FROM public.business_members  m WHERE m.id = v_membership_id),
    'invite',     (SELECT to_jsonb(i) FROM public.invites           i WHERE i.id = p_invite_id)
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.accept_invite(uuid, text, text, text, text, text, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.accept_invite(uuid, text, text, text, text, text, text, text, text) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification:
--
--   1. Return shape:
--      SELECT jsonb_object_keys(public.accept_invite(...))
--      -- (can't easily run from psql without a real auth context;
--      --  see client-side e2e test instead).
--
--   2. Function body has the new keys:
--      SELECT position('''business''' IN pg_get_functiondef(oid)) > 0,
--             position('''warehouse''' IN pg_get_functiondef(oid)) > 0
--      FROM pg_proc
--      WHERE proname='accept_invite' AND pronamespace='public'::regnamespace;
--      -- expect t, t
--
--   3. End-to-end: from a freshly-installed second emulator, sign in
--      with the manager's invite email, complete the wizard. The
--      [SignupOrchestrator] applyServerResponse step should NOT fail
--      with SqliteException(787). Manager lands on dashboard.
-- =============================================================================
