-- 0088_user_permission_overrides.sql
--
-- Reebaplus — per-staff permission overrides (master plan §10.2.1). A row
-- means a user's effective permission for `permission_key` is forced:
-- `is_granted` true = force-grant, false = force-revoke. No row = inherit the
-- role default. The runtime resolver (currentUserPermissionsProvider) applies
-- these on top of the user's role grants; the CEO is never overridable.
-- Mirrors the local Drift `UserPermissionOverrides` table (schema v33).
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- DEPLOY ORDER: push this BEFORE the v33 app reaches a device, or the
-- user_permission_overrides upserts the override editor enqueues would 42P01
-- (relation does not exist) cloud-side.

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.user_permission_overrides (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  permission_key    text NOT NULL REFERENCES public.permissions(key) ON DELETE RESTRICT,
  is_granted        boolean NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, user_id, permission_key)
);
CREATE INDEX idx_user_permission_overrides_business_lua
  ON public.user_permission_overrides (business_id, last_updated_at);
CREATE INDEX idx_user_permission_overrides_user
  ON public.user_permission_overrides (user_id);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — profiles-based tenant scoping. Use
--    current_user_business_ids() directly (NOT an inline user_businesses
--    subquery), which avoids the auth_user_id-drift 42501 push failures the
--    older inline policies hit (see 0050/0051/0075).
-- -----------------------------------------------------------------------------
ALTER TABLE public.user_permission_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_permission_overrides_tenant_rw" ON public.user_permission_overrides
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 3. last_updated_at bump trigger — rows get UPDATEd when an override flips
--    grant<->revoke, so keep the heartbeat (mirrors role_permissions, 0042).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_user_permission_overrides_last_updated_at
  BEFORE UPDATE ON public.user_permission_overrides
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Realtime publication — INSERT/UPDATE/DELETE events flow to other devices.
-- -----------------------------------------------------------------------------
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_permission_overrides;

-- -----------------------------------------------------------------------------
-- 5. Snapshot pull — append user_permission_overrides to pos_pull_snapshot so
--    other devices pull a staff member's overrides (same signature/body as
--    0072; only v_tenant_tables gains the one new name).
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
    'orders','order_items','shipments','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'notifications','stock_transactions',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    -- 0060: Funds Register (§23) — accounts, daily open/close header, ledger.
    'funds_accounts','fund_days','fund_transactions',
    -- 0068: Close Day per-account reconciliation snapshot (§23.6).
    'fund_day_closings',
    -- 0072: Daily Stock Count session snapshot (§17).
    'stock_counts',
    -- 0088: per-staff permission overrides (§10.2.1).
    'user_permission_overrides'
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
