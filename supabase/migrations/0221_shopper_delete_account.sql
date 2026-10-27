-- 0221_shopper_delete_account.sql
--
-- #438 (Online ordering 17/28, PRD #421, ADR 0030): a Shopper deletes their
-- account from the app. One RPC, shopper_delete_account(), acting on
-- auth.uid() only (no parameters), in one transaction:
--
--   1. CANCEL the caller's Online Orders still `new` -> cancelled_by_customer
--      (the same single-column update shopper_cancel_order makes; the 0208
--      guard allows it for definer code). A shop is never left answering an
--      order from a deleted account. Answered orders keep their status.
--   2. ERASE the caller's shopper_* rows: shopper_profiles (incl. marketing
--      consent, 0209), shopper_phones, shopper_addresses,
--      shopper_age_confirmations (0206), and the Shopper-only push rows in
--      devices (business_id IS NULL, 0200). The cart lives on the phone only
--      (ADR 0031), so the app clears it.
--   3. UNLINK: customers.shopper_account_id and online_orders.shopper_account_id
--      -> NULL for the caller. Shops keep their Customers, Orders, Online Orders
--      and every placement snapshot (name, phone, address, prices). Both
--      tables are synced: last_updated_at is advanced so shop phones pull it.
--   4. LOGIN: kept when the login still belongs to a business (owns one, or
--      has any public.users row — the exact guard of the
--      reconcile-account-deletions Edge Function). Otherwise the existing
--      delete_business pattern (0112/0125): a best-effort in-DB
--      `DELETE FROM auth.users` with the failure captured, plus an
--      account_deletion_events row that reconcile-account-deletions finishes
--      through the Auth Admin API.
--
-- account_deletion_events gains `kind` ('business' | 'shopper') and its
-- business_id becomes nullable (a Shopper has no business). The reconcile
-- function reads neither column, so it needs no change.
--
-- listing_reports (0214) keep reporter_auth_id: moderation records, no
-- personal details, no FK.
--
-- The account_deleted email is sent from this RPC by 0229.
--
-- DEPLOY: after 0205, 0206, 0208, 0209, 0200 and 0112/0125. Additive. Never
-- together with 0193.

BEGIN;

ALTER TABLE public.account_deletion_events
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'business';
ALTER TABLE public.account_deletion_events
  DROP CONSTRAINT IF EXISTS account_deletion_events_kind_check;
ALTER TABLE public.account_deletion_events
  ADD CONSTRAINT account_deletion_events_kind_check
  CHECK (kind IN ('business', 'shopper'));
ALTER TABLE public.account_deletion_events
  ALTER COLUMN business_id DROP NOT NULL;

COMMENT ON COLUMN public.account_deletion_events.kind IS
  '#438: business = delete_business (CEO); shopper = shopper_delete_account '
  '(business_id NULL).';

CREATE OR REPLACE FUNCTION public.shopper_delete_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid            uuid := public._shopper_uid();
  v_email          text;
  v_cancelled      integer := 0;
  v_unlinked       integer := 0;
  v_keep_login     boolean;
  v_auth_deleted   boolean := false;
  v_auth_err       text := NULL;
  v_auth_err_state text := NULL;
BEGIN
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
    SELECT au.email INTO v_email FROM auth.users au WHERE au.id = v_uid;

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

COMMENT ON FUNCTION public.shopper_delete_account() IS
  '#438: cancel new Online Orders, erase shopper_* rows, unlink Customers; '
  'the login goes via account_deletion_events unless it belongs to a business.';

COMMIT;
