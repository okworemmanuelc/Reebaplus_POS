-- Read-only catalogue assertion for #468. Expected remaining anon definers:
-- accept_invite_preview, accept_invite_preview_by_code, lookup_invite_code,
-- console_get_trial_days (bootstrap reasons in0194).
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS arguments,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef
  AND has_function_privilege('anon', p.oid, 'EXECUTE')
ORDER BY p.proname;
