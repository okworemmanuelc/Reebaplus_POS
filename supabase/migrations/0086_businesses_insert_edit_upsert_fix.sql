-- 0086_businesses_insert_edit_upsert_fix.sql
--
-- Reebaplus — finish fixing the 42501 "new row violates row-level security
-- policy for table businesses" lockout that 0062 only half-closed.
--
-- Background (why 0062 was insufficient):
--   Business edits (BusinessesDao.updateInfo -> enqueueUpsert('businesses', row))
--   are pushed by the sync engine as a PostgREST `.upsert()`, i.e.
--   `INSERT ... ON CONFLICT (id) DO UPDATE`. PostgreSQL evaluates the INSERT
--   policy's WITH CHECK against the *candidate* row on EVERY upsert — even when
--   the row already exists and the conflict routes to the UPDATE branch. 0062's
--   header assumed the opposite ("an INSERT can never 42501 for a normal edit")
--   and so only widened businesses_update. That left the real wall standing:
--
--     businesses_insert (0004): WITH CHECK (owner_id = auth.uid()
--                                           AND onboarding_complete = false)
--
--   For any post-onboarding edit the candidate row fails this two ways:
--     1. onboarding_complete is true on an established business, so
--        `onboarding_complete = false` is false; and
--     2. owner_id has NO cloud default (0004:24) and the local `businesses`
--        Drift table has no owner_id column at all, so owner_id is never in the
--        pushed payload — the candidate's owner_id defaults to NULL and
--        `NULL = auth.uid()` is null/false.
--   Either way the INSERT WITH CHECK rejects → 42501, retried forever, and the
--   CEO can never edit their own business name/type/currency/phone.
--
-- Fix:
--   Relax businesses_insert WITH CHECK to mirror the businesses_update policy
--   0062 already ships:
--
--     WITH CHECK (owner_id = auth.uid() OR id = public.business_id())
--
--   - `owner_id = auth.uid()` still covers the genuine first INSERT during
--     onboarding (start_onboarding / complete_onboarding set owner_id to the
--     CEO's auth.uid()).
--   - `id = public.business_id()` covers the edit-upsert: the candidate's id is
--     always in the payload, and business_id() is the caller's bound business
--     pointer (profiles.business_id), so the owner editing their active business
--     passes regardless of whether owner_id reached the candidate.
--
--   The dropped `onboarding_complete = false` constraint only ever prevented an
--   authenticated user from inserting a *pre-completed* business they own — a
--   non-threat, since an owner can flip onboarding_complete via UPDATE anyway.
--
-- Security:
--   A caller can only "insert" (upsert) a row whose id equals their own pointer
--   or which they own. They still cannot insert a business belonging to anyone
--   else. This is strictly the legitimate owner/active-business path.
--
-- Scope:
--   businesses_select / businesses_update are left exactly as 0062 set them.
--   No businesses_delete policy (DELETE stays denied). No schema change.
--
-- Idempotent (DROP ... IF EXISTS first), matching the 0002 / 0062 style.

BEGIN;

DROP POLICY IF EXISTS businesses_insert ON public.businesses;
CREATE POLICY businesses_insert ON public.businesses
  FOR INSERT TO authenticated
  WITH CHECK (
    owner_id = auth.uid()
    OR id = public.business_id()
  );

COMMIT;
