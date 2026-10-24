-- Tier2 companion to the signed-out HTTP tests. No data writes; rollback only.
BEGIN;
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.send_invite_email_on_insert();
    RAISE EXCEPTION 'Trigger function unexpectedly executable by anon';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- Expected: function body is never reached.
  END;
  IF has_function_privilege('authenticated',
      'public.send_invite_email_on_insert()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Trigger function unexpectedly executable by authenticated';
  END IF;
END;
$$;
ROLLBACK;
