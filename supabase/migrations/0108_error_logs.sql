-- 0108_error_logs.sql
--
-- Reebaplus — crash/error diagnostic log (master plan §33, Reliability and
-- Crash Handling). A business-scoped, append-only log of caught/uncaught
-- errors written by the app's global crash safety net. It syncs to the
-- business's OWN cloud (no third-party crash service) so the CEO/operator can
-- review crashes across every till in one place. PII-minimal by design (§33.1):
-- it stores the error type, a short message, the stack trace, the screen/
-- context, the active user's id + role, and the app version — NOT customer
-- names/phones/amounts.
--
-- Mirrors the local Drift `ErrorLogs` table (schema v46). One new synced tenant
-- table + RLS + realtime + snapshot pull. The log is append-only (never
-- hard-deleted from the app), so it is NOT in the enqueueDelete / realtime-
-- DELETE sets.
--
-- Local `business_id` is nullable (a pre-login crash has no tenant); such rows
-- stay LOCAL-ONLY and are never pushed, so `business_id` is NOT NULL cloud-side
-- (RLS needs it; only tenant-scoped rows ever reach the cloud).
--
-- DEPLOY ORDER: push this BEFORE the v46 app reaches a device, or the
-- error_logs upserts the app enqueues would 42P01 (relation does not exist)
-- cloud-side.

-- -----------------------------------------------------------------------------
-- 1. Table — mirrors the Drift ErrorLogs columns (snake_case).
-- -----------------------------------------------------------------------------
CREATE TABLE public.error_logs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  user_id         uuid REFERENCES public.users(id) ON DELETE SET NULL,
  role            text,           -- active user's role at crash time (no name)
  context         text,           -- route/screen name or logical tag
  error_type      text NOT NULL,  -- exception runtimeType
  message         text NOT NULL,  -- short, truncated (§33.1 — not field values)
  stack_trace     text,
  is_fatal        boolean NOT NULL DEFAULT false,  -- true = uncaught (global)
  app_version     text,
  platform        text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_error_logs_business_lua
  ON public.error_logs (business_id, last_updated_at);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — profiles-based tenant scoping via
--    current_user_business_ids() (NOT an inline user_businesses subquery; that
--    hit auth_user_id-drift 42501 push failures — see 0050/0051/0075/0099/0102).
-- -----------------------------------------------------------------------------
ALTER TABLE public.error_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "error_logs_tenant_rw" ON public.error_logs
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 3. last_updated_at bump trigger (mirrors the local generic bump trigger).
--    The log is append-only, so this rarely fires; kept for parity/safety.
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_error_logs_last_updated_at
  BEFORE UPDATE ON public.error_logs
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Realtime publication — INSERT events flow to other devices in the same
--    business. REPLICA IDENTITY FULL so the record carries business_id for the
--    realtime RLS authorize.
-- -----------------------------------------------------------------------------
ALTER TABLE public.error_logs REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.error_logs;

-- -----------------------------------------------------------------------------
-- 5. pos_pull_snapshot — add 'error_logs' to the tenant-table list so a fresh
--    device's first-sync also pulls existing crash logs. Carries forward the
--    full 0106 union (the authoritative list); 'error_logs' is inserted after
--    'activity_logs' (FK-safe: error_logs FK → businesses, users — both pulled
--    earlier in the array), matching the client _pullOrder position.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_pull_snapshot(
  p_business_id uuid,
  p_since       timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid;
  v_result          jsonb := '{}'::jsonb;
  v_table           text;
  v_rows            jsonb;
  v_query           text;
  v_tenant_tables   text[] := ARRAY[
    'profiles','users','stores','manufacturers','crate_size_groups',
    'categories','products','inventory','customers','suppliers',
    -- 0101: per-supplier append-only ledger (§21.10).
    'supplier_ledger_entries',
    'orders','order_items',
    -- 0093: per-order, per-brand crate deposit lines (§13.4).
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    -- 0108: crash/error diagnostic log (§33).
    'error_logs',
    'notifications','stock_transactions',
    -- 0089: stock-keeper adjustment approval queue (§16.6.1).
    'stock_adjustment_requests',
    -- 0105: cashier Quick Sale approval queue (§12.3.1).
    'quick_sale_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    -- 0104: per-store empty crate balance cache (§16.8.1 Phase 2).
    'store_crate_balances',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    -- 0072: Daily Stock Count session snapshot (§17).
    'stock_counts',
    -- 0088: per-staff permission overrides (§10.2.1).
    'user_permission_overrides',
    -- 0099: per-store role permission overrides (§10.2.1 Store scope).
    'store_role_permissions'
  ];
BEGIN
  v_caller_business := public.business_id();
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'no_business_for_caller'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_caller_business <> p_business_id THEN
    RAISE EXCEPTION 'tenant_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    INTO v_rows
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND (p_since IS NULL OR b.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('businesses', v_rows);

  FOREACH v_table IN ARRAY v_tenant_tables LOOP
    v_query := format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)
         FROM public.%I t
         WHERE t.business_id = $1
           AND ($2::timestamptz IS NULL OR t.last_updated_at > $2)',
      v_table
    );
    EXECUTE v_query INTO v_rows USING p_business_id, p_since;
    v_result := v_result || jsonb_build_object(v_table, v_rows);
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
    INTO v_rows
    FROM public.system_config s
    WHERE (p_since IS NULL OR s.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('system_config', v_rows);

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz)
  TO authenticated, service_role;
