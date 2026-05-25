-- 0038_am_i_a_member_rpc.sql
--
-- Adds public.am_i_a_member(p_business_id uuid) RETURNS boolean — the
-- canonical "is the currently authenticated user still a member of
-- business X?" check used by the client-side dashboard gate
-- (AuthService._refreshActiveMember).
--
-- Why a dedicated RPC instead of a direct REST SELECT:
--   * The client previously did
--       SELECT id FROM business_members
--        WHERE business_id = X AND user_id = LOCAL_USER_ID
--     keyed on the LOCAL users.id. But during fresh CEO onboarding the
--     local-mirror users.id (client-minted UUIDv7 from the wizard draft)
--     and the cloud users.id (server-generated default in
--     complete_onboarding) are different values — three distinct ids end
--     up in play, see DEFERRED.md "Three-id mismatch on fresh CEO
--     onboarding". The local-keyed query returned 0 rows even though
--     the cloud had the membership, triggering a false-positive
--     membership-revoked kick and crashing the dashboard mount.
--
--   * The correct identity key is auth.uid() (the Supabase Auth user),
--     which is unambiguous and server-side. Resolving auth.uid() →
--     users.id → business_members on the server bypasses the id
--     mismatch entirely.
--
--   * SECURITY DEFINER is required because the join goes through public.users
--     and public.business_members. RLS on those tables would otherwise
--     scope the SELECT to rows the caller can already see — fine for the
--     "true" path (caller IS a member, so they see their own rows) but
--     undefined for edge cases where the profiles → business_id() join
--     races the just-completed onboarding. SECURITY DEFINER gives a
--     deterministic answer in one round-trip.
--
-- Returns:
--   true  — caller's auth.uid maps to a users row in p_business_id that
--           has a business_members entry.
--   false — auth.uid is null OR no users row OR no business_members row.
--
-- A null auth.uid returns false (not raises) so the client gate can
-- treat unauthenticated and not-a-member identically — both mean "do
-- not show the dashboard."

BEGIN;

CREATE OR REPLACE FUNCTION public.am_i_a_member(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.business_members bm
      JOIN public.users u
        ON u.id = bm.user_id
     WHERE u.auth_user_id = auth.uid()
       AND bm.business_id = p_business_id
  );
$$;

REVOKE ALL    ON FUNCTION public.am_i_a_member(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.am_i_a_member(uuid) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification:
--
--   1. Function exists with the right signature:
--      SELECT pg_get_function_arguments(oid)
--      FROM pg_proc
--      WHERE proname='am_i_a_member' AND pronamespace='public'::regnamespace;
--      -- expect: p_business_id uuid
--
--   2. Null auth.uid returns false (service-role caller has auth.uid()=NULL):
--      SELECT public.am_i_a_member('00000000-0000-0000-0000-000000000000'::uuid);
--      -- expect: false
--
--   3. As a signed-in CEO calling for their own business:
--      SELECT public.am_i_a_member('<their business_id>'::uuid);
--      -- expect: true
--
--   4. Same CEO asking about a business they don't belong to:
--      SELECT public.am_i_a_member('<some other business_id>'::uuid);
--      -- expect: false
-- =============================================================================
