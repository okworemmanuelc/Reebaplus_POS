-- 0220_drop_legacy_invite_preview.sql
--
-- #506 (follow-up to #468): drop the two broken pre-OTP invite preview
-- functions. Both reference public.invites / public.warehouses, which no longer
-- exist, so every call fails with 42P01, yet anon could still execute them.
--
-- CALLER AUDIT (2026-10-26, read-only):
--   * POS lib/, supabase/functions, tests: no calls (only a comment in
--     test/integration/rpcs/anonymous_rpc_grants_test.dart).
--   * okworemmanuelc/reebaplus-web: no references (GitHub code search).
--   * Production: no other function body, policy or view mentions them;
--     to_regclass('public.invites') and ('public.warehouses') are NULL.
-- The live invite flow (lookup_invite_code / redeem_invite_code) is untouched.
--
-- Independent of 0193 and 0194 (0194 only names these in comments).
-- Recovery: none needed; the functions could not run. Their old bodies are in
-- the migration history if ever wanted for reference.

BEGIN;

DROP FUNCTION IF EXISTS public.accept_invite_preview(text);
DROP FUNCTION IF EXISTS public.accept_invite_preview_by_code(text);

COMMIT;
