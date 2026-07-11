-- 0149_remove_staff_member.sql
--
-- Staff offboarding — core (issue #107). Three idempotent parts:
--
--   1a. Widen the public.user_businesses.status CHECK to admit the terminal
--       `removed` state (was active/suspended only). Mirrors the client-side
--       widening (schemaVersion 61 in lib/core/database/app_database.dart).
--
--   1b. Add the `staff.remove` permission to the global catalog and backfill the
--       CEO grant for every existing business. The key MUST exist before any
--       grant can sync (role_permissions.permission_key FK). CEO-only by default;
--       it is a grantable Staff permission (the CEO can grant it to a Manager via
--       the role page). New businesses get the CEO grant automatically through
--       seed_default_roles_for_business's dynamic `SELECT key FROM permissions`,
--       so that function needs no change (same as 0096 staff.assign_stores).
--
--   2.  Create public.remove_staff_member(p_business_id, p_user_id) — the
--       server-authoritative removal. The app calls it DIRECTLY (supabase.rpc),
--       NOT through the §6 sync outbox, exactly like delete_business, because it
--       must be server-confirmed and the queue would retry it blindly. In one
--       transaction it: (1) sets the membership status to `removed`, and (2) nulls
--       the target identity's users.auth_user_id so the email frees up — the
--       one-email-one-business guard in complete_onboarding (0121) and the
--       existing-account router current_user_linked_business (0128) both key off
--       users.auth_user_id, so nulling it lets the freed email create a brand-new
--       business. The users row is KEPT intact as an Attribution Stub (name /
--       email / phone retained, NEVER hard-deleted) so every historical sale still
--       renders the person's name. The business owner can never be removed, and a
--       caller cannot remove themselves (self-resign is #117, out of scope here).
--
-- NOTE: the issue references "ADR 0016", but that ADR file does not exist yet;
-- this migration implements the acceptance criteria directly (no ADR is written
-- here, to avoid colliding with open docs PRs).

BEGIN;

-- =========================================================================
-- 1a. Widen the membership status CHECK: active | suspended | removed.
--     The constraint is unnamed (inline in 0042), so drop it by its
--     system-generated name via a catalog lookup, then re-add the widened
--     form under a stable name. Idempotent: if a CHECK already admits
--     `removed`, do nothing. Postgres alters a CHECK in place (no table
--     rebuild, unlike SQLite), so there are no index/trigger concerns.
-- =========================================================================
DO $$
DECLARE
  v_conname text;
  v_def     text;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.user_businesses'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%status%'
   LIMIT 1;

  -- Already widened (idempotent re-run) — nothing to do.
  IF v_def IS NOT NULL AND v_def ILIKE '%removed%' THEN
    RETURN;
  END IF;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.user_businesses DROP CONSTRAINT %I', v_conname
    );
  END IF;

  ALTER TABLE public.user_businesses
    ADD CONSTRAINT user_businesses_status_check
    CHECK (status IN ('active','suspended','removed'));
END $$;

-- =========================================================================
-- 1b. staff.remove permission — catalog + CEO backfill. last_updated_at =
--     now() on the grant so the incremental pull (0048) ships it to devices.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('staff.remove', 'Permanently remove staff (frees their email)', 'Staff')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'staff.remove', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- =========================================================================
-- 2. remove_staff_member(p_business_id, p_user_id) — server-authoritative.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.remove_staff_member(
  p_business_id uuid,
  p_user_id     uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid    uuid := auth.uid();
  v_owner_id    uuid;
  v_target_auth uuid;
  v_membership  uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Authority gate: the caller must hold `staff.remove` in THIS business.
  -- caller_has_permission (0135) resolves the caller by auth.uid(), returns
  -- true for the CEO, else checks role_permissions + user_permission_overrides.
  -- It only ever resolves the caller's OWN active membership, so a caller with
  -- no active membership in p_business_id gets false — this also enforces
  -- cross-business isolation (architecture invariant #5).
  IF NOT public.caller_has_permission(p_business_id, 'staff.remove') THEN
    RAISE EXCEPTION 'forbidden:not_permitted_to_remove_staff'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolve the business owner + the target's identity up front.
  SELECT owner_id INTO v_owner_id
    FROM public.businesses WHERE id = p_business_id;

  SELECT auth_user_id INTO v_target_auth
    FROM public.users
   WHERE id = p_user_id AND business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'member_not_found'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Owner protection: the business owner can never be removed. owner_id holds
  -- the owner's auth.uid() (set at onboarding, backfilled by 0028); compare it
  -- to the target's (still-present) auth link.
  IF v_owner_id IS NOT NULL AND v_target_auth IS NOT NULL
     AND v_target_auth = v_owner_id THEN
    RAISE EXCEPTION 'cannot_remove_owner'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Self-removal is out of scope (that is self-resign, #117) and would orphan
  -- the actor's own membership through the admin path — reject it.
  IF v_target_auth IS NOT NULL AND v_target_auth = v_auth_uid THEN
    RAISE EXCEPTION 'cannot_remove_self'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- (1) Terminal membership status. Stamp last_updated_at so the incremental
  --     pull ships it to every device (the client also mirrors it locally).
  UPDATE public.user_businesses
     SET status = 'removed', last_updated_at = now()
   WHERE business_id = p_business_id AND user_id = p_user_id
  RETURNING id INTO v_membership;

  IF v_membership IS NULL THEN
    RAISE EXCEPTION 'member_not_found'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- (2) Free the email: null the identity's auth link. KEEP the users row
  --     intact as an Attribution Stub — name / email / phone retained, NEVER
  --     hard-deleted — so every historical sale still renders the person's
  --     name. auth_user_id is cloud-RPC-set-only (off the client push
  --     whitelist), so this definer-side null is the authoritative writer.
  UPDATE public.users
     SET auth_user_id = NULL, last_updated_at = now()
   WHERE id = p_user_id AND business_id = p_business_id;

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'user_id', p_user_id,
    'membership_id', v_membership
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.remove_staff_member(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.remove_staff_member(uuid, uuid) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--
--   1. CHECK widened:
--      SELECT pg_get_constraintdef(c.oid)
--        FROM pg_constraint c
--       WHERE c.conrelid = 'public.user_businesses'::regclass
--         AND c.contype = 'c';
--      -- expect: CHECK (status IN ('active','suspended','removed'))
--
--   2. Permission seeded + CEO-only grant:
--      SELECT COUNT(*) FROM public.permissions WHERE key = 'staff.remove'; -- 1
--      SELECT r.slug, COUNT(*) FROM public.roles r
--        JOIN public.role_permissions rp ON rp.role_id = r.id
--       WHERE rp.permission_key = 'staff.remove'
--       GROUP BY r.slug;  -- expect only ceo, one per business
--
--   3. RPC exists with the right signature:
--      SELECT pg_get_function_arguments(oid)
--        FROM pg_proc
--       WHERE proname = 'remove_staff_member'
--         AND pronamespace = 'public'::regnamespace;
--      -- expect: p_business_id uuid, p_user_id uuid
--
--   4. Owner removal is rejected, a non-owner member is removed + email freed
--      (as a signed-in CEO):
--      SELECT public.remove_staff_member('<business>', '<owner_user_id>');
--        -- expect: ERROR cannot_remove_owner
--      SELECT public.remove_staff_member('<business>', '<staff_user_id>');
--        -- expect: {"ok": true, ...}; then:
--      SELECT status FROM public.user_businesses WHERE user_id = '<staff_user_id>';
--        -- expect: removed
--      SELECT auth_user_id, name, email FROM public.users WHERE id = '<staff_user_id>';
--        -- expect: auth_user_id NULL; name + email still present (stub kept)
-- =============================================================================
