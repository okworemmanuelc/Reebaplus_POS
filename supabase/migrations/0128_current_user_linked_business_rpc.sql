-- 0128_current_user_linked_business_rpc.sql
--
-- Adds public.current_user_linked_business() — the authoritative answer to
-- "is the currently authenticated identity already linked to a business, and
-- if so, which one?" Used by the post-verification router (AuthService.
-- fetchSupabaseAccount) so a cross-device existing account is detected at the
-- OTP/Google boundary (→ ExistingAccountScreen) instead of slipping through to
-- CeoSignUpScreen and only failing late at complete_onboarding (P0001
-- "already linked to another business") on the Create-PIN step.
--
-- Why a dedicated SECURITY DEFINER RPC instead of a direct REST SELECT:
--   * complete_onboarding's §9 one-email-one-business guard (migration 0121)
--     keys off public.users.auth_user_id:
--         EXISTS (SELECT 1 FROM public.users u
--                  WHERE u.auth_user_id = auth.uid()
--                    AND u.business_id <> p_business_id)
--     Detection MUST use the SAME authority as enforcement, or the two can
--     disagree and the rejection lands late.
--   * A client REST SELECT on public.users is gated by its tenant_select RLS
--     (business_id = business_id()), and business_id() reads
--     profiles.business_id. When this auth identity's profiles row has no
--     business_id (or is unreadable in this just-verified session), the REST
--     read returns ZERO rows even though a linked users row exists — exactly
--     the state that produced the late-failure bug. SECURITY DEFINER bypasses
--     RLS and answers deterministically in one round-trip.
--   * Mirrors the established public.am_i_a_member(uuid) pattern (migration
--     0038), which used SECURITY DEFINER for the same auth.uid() → users join.
--
-- Returns at most one row: the linked business id + name and the caller's role
-- (name + slug) for the ExistingAccountScreen card. Joins public.businesses for
-- the display name; an orphaned users row pointing at a deleted business yields
-- no row (no regression — that already falls through to onboarding today).
--
-- NOTE: intentionally NOT filtered on users.is_deleted, to stay byte-for-byte
-- consistent with the complete_onboarding guard (which has no is_deleted
-- filter). If that guard ever adds one, add the matching filter here too so
-- detection and enforcement never diverge.

BEGIN;

CREATE OR REPLACE FUNCTION public.current_user_linked_business()
RETURNS TABLE (
  business_id   uuid,
  business_name text,
  role_name     text,
  role_slug     text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT b.id   AS business_id,
         b.name AS business_name,
         r.name AS role_name,
         r.slug AS role_slug
    FROM public.users u
    JOIN public.businesses b
      ON b.id = u.business_id
    LEFT JOIN public.user_businesses ub
      ON ub.user_id = u.id
     AND ub.business_id = u.business_id
    LEFT JOIN public.roles r
      ON r.id = ub.role_id
   WHERE u.auth_user_id = auth.uid()
     AND u.business_id IS NOT NULL
   ORDER BY u.last_updated_at DESC NULLS LAST
   LIMIT 1;
$$;

REVOKE ALL    ON FUNCTION public.current_user_linked_business() FROM public;
GRANT EXECUTE ON FUNCTION public.current_user_linked_business() TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification:
--
--   1. Function exists with the right signature:
--      SELECT pg_get_function_arguments(oid)
--      FROM pg_proc
--      WHERE proname='current_user_linked_business'
--        AND pronamespace='public'::regnamespace;
--      -- expect: (no arguments)
--
--   2. Null auth.uid returns no rows (service-role caller has auth.uid()=NULL):
--      SELECT * FROM public.current_user_linked_business();
--      -- expect: 0 rows
--
--   3. As a signed-in user linked to a business:
--      SELECT * FROM public.current_user_linked_business();
--      -- expect: 1 row (their business + role)
-- =============================================================================
