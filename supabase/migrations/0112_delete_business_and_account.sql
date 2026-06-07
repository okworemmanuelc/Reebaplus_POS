-- 0112_delete_business_and_account.sql
--
-- Master plan §10.3 — "Delete Business & Account" (the last Phase 1 item).
-- A CEO permanently deletes their account, their business, and EVERY
-- business-scoped row, in one atomic server-side transaction. This is the
-- single deliberate exception to hard rule #9 (no hard deletes): a soft delete
-- would leave a tombstoned-but-recoverable business, which defeats the purpose.
--
-- This migration delivers four things in one transaction:
--
--   1. NEW cloud-only audit table public.account_deletion_events.
--      The operator's web admin console ("Admin Hub", §32) must learn that a
--      business was deleted so it can reconcile billing (cancel Paystack, etc.)
--      and keep a compliance record. Since the business row is destroyed, the
--      delete_business RPC writes one row here IN THE SAME TRANSACTION. It is
--      NOT a synced tenant table (the POS app never reads it) and has NO FK to
--      businesses, so it survives the cascade. RLS restricts it to service_role
--      (the console's key); the SECURITY DEFINER RPC inserts regardless of RLS.
--
--   2. FK cascade backfill on stock_counts + expense_budgets. Every other
--      business-scoped table already declares
--          business_id ... REFERENCES businesses(id) ON DELETE CASCADE
--      so a single `DELETE FROM businesses` fans out to all of them. These two
--      were created without ON DELETE CASCADE (0072 / 0073); we add it here so
--      the cascade is complete. (Audited 2026-06-07 — these were the only gaps.)
--
--   3. NEW RPC public.delete_business(p_business_id).
--      SECURITY DEFINER. Verifies the caller is the active CEO of the business
--      (the server-side mirror of the CEO-only settings.delete_business gate;
--      the client confirms with the CEO's PIN). Snapshots the
--      console-notification fields, disables the
--      append-only ledger forbid_delete guards (DISABLE TRIGGER USER — the
--      function owner `postgres` owns the tables; session_replication_role is
--      denied on Supabase), cascade-deletes the business, re-enables the guards,
--      deletes the CEO's auth.users row (best-effort, recorded), and writes the
--      account_deletion_events row. Called DIRECTLY online by the client, never
--      enqueued as a `domain:` envelope (the §6 queue would retry it blindly on
--      reconnect, after the account is already gone).
--
--   4. settings.delete_business permission — catalog row + CEO backfill.
--      Gates the Danger Zone. CEO-only; hidden from the per-role toggle list
--      (kHiddenPermissionKeys on the client). Mirrors 0103.
--
-- Mirror the catalog row + schema bump in lib/core/database/app_database.dart.

BEGIN;

-- =========================================================================
-- 1. account_deletion_events — cloud-only console-notification audit log.
--    No FK to businesses (must survive the cascade). Not synced to the app.
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.account_deletion_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         uuid NOT NULL,                 -- the deleted business (no FK)
  business_name       text,
  owner_user_id       uuid,                          -- public.users.id of the CEO
  owner_auth_user_id  uuid,                           -- auth.users.id of the CEO
  owner_email         text,
  subscription_status text,                           -- snapshot at deletion time
  subscription_plan   text,                           -- snapshot at deletion time
  auth_user_deleted   boolean NOT NULL DEFAULT false, -- did the in-RPC auth delete run?
  deleted_at          timestamptz NOT NULL DEFAULT now(),
  acknowledged_at     timestamptz                     -- console stamps when reconciled
);

CREATE INDEX IF NOT EXISTS idx_account_deletion_events_unack
  ON public.account_deletion_events (deleted_at)
  WHERE acknowledged_at IS NULL;

-- Console reads with the service_role key, which bypasses RLS. Lock everyone
-- else out: enable RLS with no policies, and revoke the PostgREST grants so the
-- table is never exposed to anon / authenticated callers.
ALTER TABLE public.account_deletion_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_deletion_events FROM anon, authenticated;
GRANT ALL  ON public.account_deletion_events TO service_role;

-- =========================================================================
-- 2. Backfill ON DELETE CASCADE on the two tables that lack it, so
--    `DELETE FROM businesses` cascades the whole tenant. Robust to constraint
--    name drift: drop whatever FK references businesses, re-add with CASCADE.
-- =========================================================================
DO $$
DECLARE
  t text;
  c text;
  tbls text[] := ARRAY['stock_counts','expense_budgets'];
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    FOR c IN
      SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class     rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
       WHERE con.contype  = 'f'
         AND nsp.nspname  = 'public'
         AND rel.relname  = t
         AND con.confrelid = 'public.businesses'::regclass
    LOOP
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', t, c);
    END LOOP;
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I '
      'FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE',
      t, t || '_business_id_fkey'
    );
  END LOOP;
END $$;

-- =========================================================================
-- 3. public.delete_business(p_business_id uuid) -> jsonb
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

  -- Authority gate: caller must be the ACTIVE CEO of THIS business. Only the
  -- CEO ever holds settings.delete_business (locked on, hidden, never granted to
  -- any other role), so the CEO check is the server-side mirror of that gate.
  SELECT u.id, u.email, b.name
    INTO v_ceo_id, v_owner_email, v_biz_name
    FROM public.users u
    JOIN public.businesses b ON b.id = u.business_id
   WHERE u.auth_user_id = v_auth_uid
     AND u.business_id  = p_business_id
     AND u.role         = 'ceo'
     AND u.is_deleted   = false
   LIMIT 1;

  IF v_ceo_id IS NULL THEN
    RAISE EXCEPTION 'forbidden:not_ceo_of_business'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Snapshot the subscription state for the console BEFORE the cascade.
  SELECT subscription_status, subscription_plan
    INTO v_sub_status, v_sub_plan
    FROM public.businesses
   WHERE id = p_business_id;

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

-- =========================================================================
-- 4. settings.delete_business permission — catalog + CEO backfill (mirrors 0103).
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('settings.delete_business', 'Delete the business and account', 'System')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'settings.delete_business', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT COUNT(*) FROM public.permissions WHERE key = 'settings.delete_business'; -- 1
--   SELECT conname, confdeltype FROM pg_constraint
--    WHERE conrelid IN ('public.stock_counts'::regclass,'public.expense_budgets'::regclass)
--      AND contype = 'f' AND confrelid = 'public.businesses'::regclass;  -- confdeltype = 'c'
--   SELECT proname FROM pg_proc WHERE proname = 'delete_business';        -- 1
--   SELECT relrowsecurity FROM pg_class WHERE relname = 'account_deletion_events'; -- t
-- =============================================================================
