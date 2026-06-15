-- 0113_fix_delete_business_owner_check.sql
--
-- BUG: delete_business (0112) failed at runtime with
--   PostgrestException(code 42703, message: column "u.role" does not exist)
-- The 0112 authority gate joined public.users and filtered `u.role = 'ceo'`,
-- but the cloud `users` table has no `role` column (role lives per-membership,
-- not on the users row). CREATE FUNCTION did not catch it (plpgsql column
-- references resolve at first execution), so 0112 deployed clean and only broke
-- when a CEO actually tapped Delete.
--
-- FIX: identify the owner/CEO by `businesses.owner_id` instead — it holds the
-- owner's `auth.uid()` (set at onboarding in 0018, backfilled by 0028). The
-- users row is still looked up (without a role filter) purely to populate the
-- console-notification fields (owner_user_id + owner_email), best-effort.
--
-- CREATE OR REPLACE only — same signature, no other object changes.

BEGIN;

CREATE OR REPLACE FUNCTION public.delete_business(
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_auth_uid     uuid := auth.uid();
  v_ceo_id       uuid;
  v_biz_name     text;
  v_owner_email  text;
  v_sub_status   text;
  v_sub_plan     text;
  v_auth_deleted boolean := false;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Authority gate: caller must be the OWNER (CEO) of THIS business. The cloud
  -- `users` table has no `role` column — ownership is `businesses.owner_id`,
  -- which holds the CEO's auth.uid() (set at onboarding, backfilled by 0028).
  -- Only the CEO ever holds settings.delete_business, so owner_id is the
  -- server-side mirror of that gate. Snapshot the subscription state for the
  -- console in the same query (it is destroyed by the cascade below).
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
  -- No role filter — the users table has none; auth_user_id + business_id is the
  -- unique membership key.
  SELECT id, email
    INTO v_ceo_id, v_owner_email
    FROM public.users
   WHERE auth_user_id = v_auth_uid
     AND business_id  = p_business_id
   LIMIT 1;

  -- Disable the append-only delete guards so the FK cascade can remove ledger
  -- rows. DISABLE TRIGGER USER takes an ACCESS EXCLUSIVE lock (no concurrent
  -- append-only bypass) and is transactional — a rollback restores the guards.
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

  -- Delete the CEO's auth identity (login gone for good). Best-effort: if the
  -- project's `postgres` role lacks DELETE on auth.users, the business is still
  -- gone and the console finishes the job via the account_deletion_events row.
  BEGIN
    DELETE FROM auth.users WHERE id = v_auth_uid;
    v_auth_deleted := true;
  EXCEPTION WHEN OTHERS THEN
    v_auth_deleted := false;
  END;

  -- Notify the console. Survives the cascade (no FK to businesses).
  INSERT INTO public.account_deletion_events (
    business_id, business_name, owner_user_id, owner_auth_user_id,
    owner_email, subscription_status, subscription_plan, auth_user_deleted
  ) VALUES (
    p_business_id, v_biz_name, v_ceo_id, v_auth_uid,
    v_owner_email, v_sub_status, v_sub_plan, v_auth_deleted
  );

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'auth_user_deleted', v_auth_deleted
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.delete_business(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.delete_business(uuid) TO authenticated, service_role;

COMMIT;
