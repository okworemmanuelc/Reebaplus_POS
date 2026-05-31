-- 0062_businesses_owner_fallback_rls.sql
--
-- Reebaplus — fix the 42501 "new row violates row-level security policy for
-- table businesses" lockout, and make a CEO un-lockable from a business they
-- own regardless of where the single profiles.business_id pointer has drifted.
--
-- Background (the bug):
--   businesses RLS resolves the caller's business through ONE mutable pointer:
--     public.business_id() = (SELECT business_id FROM profiles WHERE id = auth.uid())   (0002:28-34)
--   businesses_select / businesses_update both gate on `id = public.business_id()`
--   (0002:152-163). businesses_insert was later tightened to
--   `owner_id = auth.uid() AND onboarding_complete = false` (0004:58-64), so an
--   INSERT can never 42501 for a normal edit — the 42501 is provably the UPDATE
--   branch of the queued businesses upsert (the row already exists, onboarding
--   complete).
--   Three SECURITY DEFINER RPCs destructively relocate that single pointer with
--   `ON CONFLICT (id) DO UPDATE SET business_id = EXCLUDED.business_id`:
--     start_onboarding (0004:106), complete_onboarding (0045), redeem_invite_code (0052).
--   So when one auth account onboards/joins a SECOND business, profiles.business_id
--   moves to B while the account still OWNS A. A later edit of business A
--   (BusinessesDao.updateInfo -> enqueueUpsert('businesses', rowA)) is pushed and
--   evaluated against businesses_update USING (id = public.business_id() = B != A)
--   -> 42501. The sync queue marks it failed non-permanently, so it retries forever
--   and the CEO is permanently locked out of editing their own business.
--
-- Fix:
--   Add an OWNER escape-hatch to businesses_select / businesses_update so the
--   owner can always read and edit a business they own, irrespective of the
--   profiles pointer. owner_id is set once at start_onboarding (0004:103) /
--   complete_onboarding (0045) to the CEO's auth.uid() and is never reassigned
--   in Phase 1 (no ownership-transfer feature exists), so this widening only
--   ever (re)admits the legitimate owner. WITH CHECK on update keeps the same
--   guard, so a non-owner whose pointer doesn't match still cannot touch the row.
--
--   This is the minimal, additive, backward-compatible fix:
--   - Single-business clients are unaffected (owner_id matches the pointer on
--     the happy path; the OR-branch is inert).
--   - Any pre-existing locked-out business-A push backlog flushes the moment this
--     deploys — those rows are still `pending` in sync_queue (markFailed was
--     non-permanent), not orphaned, so no manual replay is needed.
--
-- Scope:
--   businesses_insert is left EXACTLY as 0004 tightened it (owner_id = auth.uid()
--   AND onboarding_complete = false) — do not touch. No DELETE policy (unchanged).
--   The tenant_* policies on the 31 business_id-scoped tables are NOT changed
--   here; their pointer-based scope is correct once the client binds the active
--   business consistently (handled client-side in the same release).
--
-- KNOWN RESIDUAL / future dependency:
--   1. RLS still trusts profiles.business_id as the sole authority for the
--      tenant tables (a stale-but-still-pointed profile keeps tenant access until
--      the next deliberate pointer move). Closing that fully requires the
--      membership-set RLS rewrite, deferred with the Phase-2 business switcher.
--   2. OWNERSHIP TRANSFER: if a Phase-2 feature ever lets owner_id be reassigned,
--      this owner-fallback must be revisited — a former owner would otherwise
--      retain select/update on a business they no longer own. There is no such
--      feature in Phase 1 (owner_id is write-once at onboarding), so this is
--      currently inert. Gate any ownership-transfer work on revisiting this policy.
--
-- Idempotent (DROP ... IF EXISTS first), matching the 0002 style. No schema change.

BEGIN;

DROP POLICY IF EXISTS businesses_select ON public.businesses;
CREATE POLICY businesses_select ON public.businesses
  FOR SELECT TO authenticated
  USING (id = public.business_id() OR owner_id = auth.uid());

DROP POLICY IF EXISTS businesses_update ON public.businesses;
CREATE POLICY businesses_update ON public.businesses
  FOR UPDATE TO authenticated
  USING (id = public.business_id() OR owner_id = auth.uid())
  WITH CHECK (id = public.business_id() OR owner_id = auth.uid());

-- businesses_insert intentionally untouched (stays as 0004: owner_id = auth.uid()
-- AND onboarding_complete = false). No businesses_delete policy ⇒ DELETE denied.

COMMIT;
