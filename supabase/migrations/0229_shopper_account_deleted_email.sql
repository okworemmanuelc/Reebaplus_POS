-- 0229_shopper_account_deleted_email.sql
--
-- #438 (Part of): email the Shopper an `account_deleted` confirmation when
-- shopper_delete_account() runs. Same mechanism as #434's order emails
-- (0218): pg_net POST to the `send-email` Edge Function with the shared
-- push_hook_secret. The address is read inside the RPC BEFORE the erase /
-- auth.users delete, so it is never lost. Best-effort: errors are swallowed.
--
-- Replaces shopper_delete_account() (0221 untouched); adds one helper.
-- No table, status or money change.
--
-- DEPLOY: after 0221 + 0218. `send-email` must already be deployed with
-- --no-verify-jwt. Never together with 0193.

BEGIN;

CREATE OR REPLACE FUNCTION public._notify_shopper_account_deleted(
  p_email text,
  p_name  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_base_url text;
  v_secret   text;
BEGIN
  IF nullif(btrim(p_email), '') IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets WHERE name = 'project_url';
    SELECT decrypted_secret INTO v_secret
      FROM vault.decrypted_secrets WHERE name = 'push_hook_secret';
    IF v_base_url IS NULL OR v_secret IS NULL THEN
      RETURN;
    END IF;
    PERFORM net.http_post(
      url     := v_base_url || '/functions/v1/send-email',
      headers := jsonb_build_object(
        'content-type',       'application/json',
        'x-push-hook-secret', v_secret
      ),
      body    := jsonb_build_object(
        'template', 'account_deleted',
        'to',       p_email,
        'data',     jsonb_build_object('shopper_name', coalesce(p_name, ''))
      )
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public._notify_shopper_account_deleted(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._notify_shopper_account_deleted(text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.shopper_delete_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := public._shopper_uid();
  v_email          text;
  v_name           text;
  v_cancelled      integer := 0;
  v_unlinked       integer := 0;
  v_keep_login     boolean;
  v_auth_deleted   boolean := false;
  v_auth_err       text := NULL;
  v_auth_err_state text := NULL;
BEGIN
  -- 0. Capture the address + name BEFORE anything is erased (the login and
  --    the profile row go below), then send the confirmation. Best-effort:
  --    a failed email never blocks the deletion.
  SELECT au.email INTO v_email FROM auth.users au WHERE au.id = v_uid;
  SELECT sp.name INTO v_name
    FROM public.shopper_profiles sp WHERE sp.auth_user_id = v_uid;
  PERFORM public._notify_shopper_account_deleted(v_email, v_name);

  -- 1. Unanswered orders: cancelled, as if the Shopper pressed Cancel.
  UPDATE public.online_orders
     SET status = 'cancelled_by_customer'
   WHERE shopper_account_id = v_uid
     AND status = 'new';
  GET DIAGNOSTICS v_cancelled = ROW_COUNT;

  -- 3. Unlink (shops keep their records and snapshots).
  UPDATE public.customers
     SET shopper_account_id = NULL,
         last_updated_at = now()
   WHERE shopper_account_id = v_uid;
  GET DIAGNOSTICS v_unlinked = ROW_COUNT;

  UPDATE public.online_orders
     SET shopper_account_id = NULL,
         last_updated_at = now()
   WHERE shopper_account_id = v_uid;

  -- 2. Erase the Shopper's own rows.
  DELETE FROM public.shopper_phones           WHERE auth_user_id = v_uid;
  DELETE FROM public.shopper_addresses        WHERE auth_user_id = v_uid;
  DELETE FROM public.shopper_age_confirmations WHERE auth_user_id = v_uid;
  DELETE FROM public.shopper_profiles         WHERE auth_user_id = v_uid;
  DELETE FROM public.devices
   WHERE auth_user_id = v_uid
     AND business_id IS NULL;

  -- 4. The login. Same guard as reconcile-account-deletions: a login that
  --    owns a business or has any users row is never removed.
  v_keep_login :=
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.owner_id = v_uid)
    OR EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = v_uid);

  IF NOT v_keep_login THEN
    -- Best-effort, exactly like delete_business (0125): managed Supabase
    -- usually refuses this, and the event row below finishes the job.
    BEGIN
      DELETE FROM auth.users WHERE id = v_uid;
      v_auth_deleted := true;
    EXCEPTION WHEN OTHERS THEN
      v_auth_deleted := false;
      GET STACKED DIAGNOSTICS
        v_auth_err_state = RETURNED_SQLSTATE,
        v_auth_err       = MESSAGE_TEXT;
      v_auth_err := v_auth_err_state || ': ' || v_auth_err;
    END;

    INSERT INTO public.account_deletion_events (
      kind, business_id, owner_auth_user_id, owner_email,
      auth_user_deleted, auth_delete_error
    ) VALUES (
      'shopper', NULL, v_uid, v_email,
      v_auth_deleted, v_auth_err
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cancelled_orders', v_cancelled,
    'unlinked_customers', v_unlinked,
    'login_kept', v_keep_login,
    'auth_user_deleted', v_auth_deleted
  );
END;
$$;

REVOKE ALL ON FUNCTION public.shopper_delete_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shopper_delete_account() TO authenticated, service_role;

COMMIT;
