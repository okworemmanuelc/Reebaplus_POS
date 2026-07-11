-- 0152_resign_own_membership.sql
--
-- Staff offboarding — self-resign (issue #117). The companion to
-- 0149_remove_staff_member: where 0149 lets an ADMIN remove SOMEONE ELSE (and
-- deliberately REJECTS self-removal via `cannot_remove_self`), this lets a
-- non-owner staff member remove THEIR OWN membership — "Leave / delete my
-- account" from Profile. No permission is required (a person may always leave),
-- but the business OWNER can never resign (their exit is Delete Business), so
-- the owner is rejected here just as they are in 0149.
--
-- Create public.resign_own_membership(p_business_id). The app calls it DIRECTLY
-- (supabase.rpc), NOT through the §6 sync outbox, exactly like
-- remove_staff_member / delete_business, because it must be server-confirmed and
-- the queue would retry it blindly. In one transaction it, for the CALLER's own
-- identity (resolved by auth.uid()): (1) sets the membership status to `removed`,
-- and (2) nulls users.auth_user_id so the email frees up — the
-- one-email-one-business guard in complete_onboarding (0121) and the
-- existing-account router current_user_linked_business (0128) both key off
-- users.auth_user_id, so nulling it lets the freed email create a brand-new
-- business. The users row is KEPT intact as an Attribution Stub (name / email /
-- phone retained, NEVER hard-deleted) so every historical sale still renders the
-- person's name — identical to 0149. The business owner is rejected.
--
-- Nothing else changes: the `removed` membership CHECK value and the client-side
-- pieces already shipped with 0149 / #107. No new permission key is added
-- (resign needs no grant).
--
-- NOTE: the issue references "ADR 0016", but that ADR file does not exist yet;
-- this migration implements the acceptance criteria directly (no ADR is written
-- here, to avoid colliding with open docs PRs), mirroring the 0149 note.

BEGIN;

-- =========================================================================
-- resign_own_membership(p_business_id) — server-authoritative self-resign.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.resign_own_membership(
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid   uuid := auth.uid();
  v_owner_id   uuid;
  v_user_id    uuid;
  v_membership uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolve the CALLER's own identity within this business from auth.uid().
  -- auth_user_id is the canonical live link (0028/0121); a caller who has
  -- already been removed has it nulled and resolves to nothing here — treated
  -- as an idempotent "already gone". This also enforces cross-business
  -- isolation (architecture invariant #5): a caller with no live membership in
  -- p_business_id resolves no user row and is rejected below.
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = v_auth_uid
     AND business_id  = p_business_id;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'no_active_membership'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Owner protection: the business owner can NEVER resign (their exit is Delete
  -- Business — the delete_business RPC). owner_id holds the owner's auth.uid()
  -- (set at onboarding, backfilled by 0028); compare it to the caller's uid.
  SELECT owner_id INTO v_owner_id
    FROM public.businesses WHERE id = p_business_id;

  IF v_owner_id IS NOT NULL AND v_owner_id = v_auth_uid THEN
    RAISE EXCEPTION 'cannot_resign_owner'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- (1) Terminal membership status. Stamp last_updated_at so the incremental
  --     pull ships it to every device the caller shares this business with (a
  --     shared till), and so the caller's own device converges its local mirror.
  UPDATE public.user_businesses
     SET status = 'removed', last_updated_at = now()
   WHERE business_id = p_business_id AND user_id = v_user_id
  RETURNING id INTO v_membership;

  IF v_membership IS NULL THEN
    RAISE EXCEPTION 'no_active_membership'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- (2) Free the email: null the caller's own auth link. KEEP the users row
  --     intact as an Attribution Stub — name / email / phone retained, NEVER
  --     hard-deleted — so every historical sale still renders the person's name.
  --     auth_user_id is cloud-RPC-set-only (off the client push whitelist), so
  --     this definer-side null is the authoritative writer.
  UPDATE public.users
     SET auth_user_id = NULL, last_updated_at = now()
   WHERE id = v_user_id AND business_id = p_business_id;

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'user_id', v_user_id,
    'membership_id', v_membership
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.resign_own_membership(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.resign_own_membership(uuid) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--
--   1. RPC exists with the right signature:
--      SELECT pg_get_function_arguments(oid)
--        FROM pg_proc
--       WHERE proname = 'resign_own_membership'
--         AND pronamespace = 'public'::regnamespace;
--      -- expect: p_business_id uuid
--
--   2. The owner is rejected, a non-owner member resigns + email freed
--      (each run as the signed-in member in question):
--      SELECT public.resign_own_membership('<business>');  -- as the OWNER
--        -- expect: ERROR cannot_resign_owner
--      SELECT public.resign_own_membership('<business>');  -- as a STAFF member
--        -- expect: {"ok": true, ...}; then:
--      SELECT status FROM public.user_businesses WHERE user_id = '<staff_user_id>';
--        -- expect: removed
--      SELECT auth_user_id, name, email FROM public.users WHERE id = '<staff_user_id>';
--        -- expect: auth_user_id NULL; name + email still present (stub kept)
-- =============================================================================
