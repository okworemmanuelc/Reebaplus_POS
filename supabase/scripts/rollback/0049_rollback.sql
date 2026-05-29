-- =============================================================================
-- 0049_rollback.sql — reverse of 0049_invite_redemption.sql.
--
-- Drops the two SECURITY DEFINER RPCs added in 0049: the anon-callable
-- lookup_invite_code(text) pre-flight and the authenticated
-- redeem_invite_code(text, uuid, text) redemption. No data is touched —
-- invite_codes / users / user_businesses / user_stores remain; only the
-- functions are removed.
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.lookup_invite_code(text);
DROP FUNCTION IF EXISTS public.redeem_invite_code(text, uuid, text);

COMMIT;
