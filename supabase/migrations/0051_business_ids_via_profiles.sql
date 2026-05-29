-- 0051_business_ids_via_profiles.sql
--
-- Reebaplus — align the membership-table RLS with the rest of the app's
-- identity resolution, fixing 42501 "new row violates row-level security
-- policy" on invite_codes / user_businesses / roles / role_permissions /
-- role_settings / user_stores.
--
-- Background: the whole app resolves "which business is this caller in" via
-- public.business_id() (0002): SELECT business_id FROM public.profiles WHERE
-- id = auth.uid(). profiles.business_id is NOT NULL and is written for both
-- the CEO (complete_onboarding) and staff (redeem_invite_code, 0049). Every
-- legacy table's RLS uses this path, and it works.
--
-- The membership tables added in 0042 (and the helper introduced in 0050)
-- instead resolve via a SECOND path: auth.uid() -> users.auth_user_id ->
-- user_businesses. When users.auth_user_id has drifted away from the caller's
-- auth.uid() (a profiles/users divergence — the same class of problem 0028 /
-- 0039 addressed), that lookup returns empty, so every USING / WITH CHECK on
-- the membership tables fails with 42501 even though the profiles path is
-- intact (hence: legacy tables sync, only the new tables are rejected).
--
-- Fix: redefine current_user_business_ids() to resolve the caller's business
-- via profiles — the canonical, reliably-populated path — instead of
-- users.auth_user_id. The six policies from 0050 call this helper by name, so
-- no policy changes are needed; CREATE OR REPLACE FUNCTION keeps the same
-- signature and the policies immediately pick up the new body.
--
-- Phase-1 note: profiles is one-business-per-user, so the SETOF now yields a
-- single business id. The 0050 join was forward-looking for the Phase-2
-- multi-business model; Phase 1 is one business per user, so this is correct
-- for now and should be revisited when multi-business lands. The helper stays
-- SECURITY DEFINER, but its body is constrained to WHERE id = auth.uid() — it
-- can only ever return the caller's own business, so there is no data-leak
-- risk from the definer privilege.
--
-- No schema changes; this only redefines one function.

BEGIN;

CREATE OR REPLACE FUNCTION public.current_user_business_ids()
RETURNS SETOF uuid
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public
AS $$
  SELECT business_id FROM public.profiles WHERE id = auth.uid();
$$;

-- Re-assert least privilege (authenticated already holds EXECUTE from 0050;
-- harmless to restate, and keeps the grant correct if this runs standalone).
REVOKE ALL ON FUNCTION public.current_user_business_ids() FROM public;
GRANT EXECUTE ON FUNCTION public.current_user_business_ids() TO authenticated;

COMMIT;
