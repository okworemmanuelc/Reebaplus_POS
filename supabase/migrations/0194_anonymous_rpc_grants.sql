-- #468: signed-out RPC surface, audited against live catalogue2026-10-23.
-- Deploy AFTER the web console removes its pre-OTP is_console_admin_email probe.
-- This migration changes ACLs only; signatures and authenticated flows stay intact.
-- Intentional remaining anon SECURITY DEFINER entry points:
-- accept_invite_preview(text): bearer-token invitation preview before OTP.
-- accept_invite_preview_by_code(text): code invitation preview before OTP.
-- lookup_invite_code(text): mobile staff signup checks its code before OTP.
-- console_get_trial_days(): public scalar trial duration consumed during signup.
-- These expose only their existing bootstrap contract; no new grant is added.
BEGIN;
REVOKE EXECUTE ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, integer, integer,
  integer, text, text, text, integer, boolean, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, integer, integer,
  integer, text, text, text, integer, boolean, uuid, integer
) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid, boolean
) FROM PUBLIC, anon;
-- This function previously inherited its authenticated access from PUBLIC.
GRANT EXECUTE ON FUNCTION public.complete_onboarding(
  uuid, uuid, text, text, text, text, text, jsonb, jsonb, uuid, boolean
) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.is_console_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_console_admin() TO authenticated, service_role;
-- No application, function or policy caller remains after the companion web fix.
-- Signed-in Shoppers must not gain an arbitrary admin-email probe either.
REVOKE EXECUTE ON FUNCTION public.is_console_admin_email(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_console_admin_email(text) TO service_role;

-- Trigger execution does not require the inserting client to execute its function.
REVOKE EXECUTE ON FUNCTION public.send_invite_email_on_insert()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_invite_email_on_insert() TO service_role;
COMMIT;
