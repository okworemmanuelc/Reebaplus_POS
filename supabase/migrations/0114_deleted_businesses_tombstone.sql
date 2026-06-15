-- 0114_deleted_businesses_tombstone.sql
--
-- Master plan §10.3 follow-up — propagate "Delete Business & Account" to STAFF
-- devices, not just the CEO's.
--
-- Problem: when the CEO deletes the business (delete_business, 0112/0113), the
-- whole tenant is cascade-deleted in the cloud and the CEO's own device wipes +
-- signs out. But a STAFF device is offline-first: it still holds the business's
-- local data and a valid staff JWT (only the CEO's auth.users row is deleted).
-- It has no idea the business is gone, so it loops forever on permission-denied
-- pulls ("permission denied for table profiles", 42501) and "No current
-- business" push crashes. Staff must be signed out and wiped too.
--
-- Detection needs an UNAMBIGUOUS, deterministic signal a staff device can read
-- AFTER its membership is gone — distinguishable from "I was suspended" or "I
-- was removed" (those must NOT wipe). A bare "can I still see my business?"
-- check conflates all three. So we leave a dedicated tombstone:
--
--   public.deleted_businesses(business_id, business_name, deleted_at)
--
-- The delete_business RPC writes one row here in the same transaction. A staff
-- device that still knows its business_id locally queries this table; a row
-- present == the business was genuinely DELETED == wipe + sign out. No row ==
-- never wipe (covers transient RLS / network errors → no false-positive wipe).
--
-- RLS: SELECT open to any authenticated caller (USING (true)). The table reveals
-- only the fact "business <id> was deleted at <ts>" — not sensitive — and the
-- staff querying it has lost the membership that scoped tenant RLS, so a
-- membership-based policy could never let them read it. Writes are owner-only
-- (the SECURITY DEFINER RPC, owned by postgres); no INSERT/UPDATE/DELETE grant
-- to authenticated.
--
-- No FK to businesses (it IS the tombstone — must survive the cascade).

BEGIN;

-- =========================================================================
-- 1. deleted_businesses — the per-business deletion tombstone.
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.deleted_businesses (
  business_id   uuid PRIMARY KEY,                  -- the deleted business (no FK)
  business_name text,
  deleted_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.deleted_businesses ENABLE ROW LEVEL SECURITY;

-- Any authenticated device may read the tombstone (deletion facts only).
DROP POLICY IF EXISTS deleted_businesses_select ON public.deleted_businesses;
CREATE POLICY deleted_businesses_select
  ON public.deleted_businesses
  FOR SELECT
  TO authenticated
  USING (true);

-- Reads for authenticated; full access for the SECURITY DEFINER owner / console.
REVOKE ALL    ON public.deleted_businesses FROM anon;
GRANT  SELECT ON public.deleted_businesses TO authenticated;
GRANT  ALL    ON public.deleted_businesses TO service_role;

-- =========================================================================
-- 2. delete_business — also stamp the tombstone (CREATE OR REPLACE; same
--    signature/body as 0113, with the deleted_businesses INSERT added after
--    the cascade). Owner check stays on businesses.owner_id (the 0113 fix).
-- =========================================================================
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

  -- Delete the CEO's auth identity (login gone for good). Best-effort.
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

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT relrowsecurity FROM pg_class WHERE relname = 'deleted_businesses';  -- t
--   SELECT polname FROM pg_policy WHERE polrelid = 'public.deleted_businesses'::regclass;
--     -- deleted_businesses_select
--   -- After a test delete:
--   SELECT business_id, deleted_at FROM public.deleted_businesses;
-- =============================================================================
