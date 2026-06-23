-- 0125_delete_business_capture_auth_delete_error.sql
--
-- delete_business (§10.3) deletes the tenant via `DELETE FROM businesses`
-- (cascade) and then best-effort deletes the CEO's `auth.users` login. That
-- auth-delete was wrapped in `EXCEPTION WHEN OTHERS` and the only signal it
-- left was the boolean `auth_user_deleted = false` — the actual SQLSTATE/message
-- was discarded. Field data showed it failing on EVERY deletion (a
-- `postgres`-owned SECURITY DEFINER cannot reliably delete from `auth.users`
-- on managed Supabase — that path belongs to the Auth Admin API), so the email's
-- login lingered after a "delete" with no diagnostics.
--
-- This migration makes the failure VISIBLE without changing the (correct)
-- business-cascade behaviour:
--   1. add `auth_delete_error text` to account_deletion_events;
--   2. capture RETURNED_SQLSTATE + MESSAGE_TEXT in the EXCEPTION handler and
--      persist them on the audit row.
--
-- It does NOT itself perform the auth deletion via the Admin API — that is a
-- follow-up (an Edge Function / console job keyed off account_deletion_events).
-- The audit row already records owner_auth_user_id + owner_email for that job;
-- now it also records WHY the in-DB attempt failed.
--
-- Body is otherwise identical to the deployed 0113 definition.

BEGIN;

ALTER TABLE public.account_deletion_events
  ADD COLUMN IF NOT EXISTS auth_delete_error text;

CREATE OR REPLACE FUNCTION public.delete_business(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_auth_uid        uuid := auth.uid();
  v_ceo_id          uuid;
  v_biz_name        text;
  v_owner_email     text;
  v_sub_status      text;
  v_sub_plan        text;
  v_auth_deleted    boolean := false;
  v_auth_err        text := NULL;
  v_auth_err_state  text := NULL;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Authority gate: caller must be the OWNER (CEO) of THIS business.
  SELECT name, subscription_status, subscription_plan
    INTO v_biz_name, v_sub_status, v_sub_plan
    FROM public.businesses
   WHERE id       = p_business_id
     AND owner_id = v_auth_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden:not_owner_of_business'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Best-effort: the CEO's users row (id + email) for the console notification.
  SELECT id, email
    INTO v_ceo_id, v_owner_email
    FROM public.users
   WHERE auth_user_id = v_auth_uid
     AND business_id  = p_business_id
   LIMIT 1;

  -- Disable the append-only delete guards so the FK cascade can remove ledger
  -- rows (transactional — a rollback restores them).
  ALTER TABLE public.stock_transactions   DISABLE TRIGGER USER;
  ALTER TABLE public.wallet_transactions  DISABLE TRIGGER USER;
  ALTER TABLE public.payment_transactions DISABLE TRIGGER USER;
  ALTER TABLE public.activity_logs        DISABLE TRIGGER USER;
  ALTER TABLE public.crate_ledger         DISABLE TRIGGER USER;

  -- The whole tenant goes in one statement (FK ON DELETE CASCADE fans out to
  -- every business-scoped table, incl. public.users for this business).
  DELETE FROM public.businesses WHERE id = p_business_id;

  ALTER TABLE public.stock_transactions   ENABLE TRIGGER USER;
  ALTER TABLE public.wallet_transactions  ENABLE TRIGGER USER;
  ALTER TABLE public.payment_transactions ENABLE TRIGGER USER;
  ALTER TABLE public.activity_logs        ENABLE TRIGGER USER;
  ALTER TABLE public.crate_ledger         ENABLE TRIGGER USER;

  -- Leave the tombstone so STAFF devices learn the business is gone and wipe +
  -- sign out (no FK to businesses, so it survives the cascade above).
  INSERT INTO public.deleted_businesses (business_id, business_name)
  VALUES (p_business_id, v_biz_name)
  ON CONFLICT (business_id) DO NOTHING;

  -- Delete the CEO's auth identity (login gone for good). Best-effort — and now
  -- the failure reason is captured instead of silently swallowed.
  BEGIN
    DELETE FROM auth.users WHERE id = v_auth_uid;
    v_auth_deleted := true;
  EXCEPTION WHEN OTHERS THEN
    v_auth_deleted := false;
    GET STACKED DIAGNOSTICS
      v_auth_err_state = RETURNED_SQLSTATE,
      v_auth_err       = MESSAGE_TEXT;
    v_auth_err := v_auth_err_state || ': ' || v_auth_err;
  END;

  -- Notify the console. Survives the cascade (no FK to businesses).
  INSERT INTO public.account_deletion_events (
    business_id, business_name, owner_user_id, owner_auth_user_id,
    owner_email, subscription_status, subscription_plan, auth_user_deleted,
    auth_delete_error
  ) VALUES (
    p_business_id, v_biz_name, v_ceo_id, v_auth_uid,
    v_owner_email, v_sub_status, v_sub_plan, v_auth_deleted,
    v_auth_err
  );

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'auth_user_deleted', v_auth_deleted,
    'auth_delete_error', v_auth_err
  );
END;
$function$;

COMMIT;
