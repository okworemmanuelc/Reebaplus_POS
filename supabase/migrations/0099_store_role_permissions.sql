-- 0099_store_role_permissions.sql
--
-- Reebaplus — per-store role permission overrides (master plan §10.2.1, Store
-- scope). A row means a role's effective permission for `permission_key` is
-- forced for everyone working in `store_id`: `is_granted` true = force-grant,
-- false = force-revoke. No row = inherit the role's business default. The
-- runtime resolver (currentUserPermissionsProvider) applies these between the
-- business (role) grants and the per-user overrides — most-specific wins,
-- User > Store > Business; the CEO is never overridable. Mirrors the local Drift
-- `StoreRolePermissions` table (schema v41). Same override shape as
-- `user_permission_overrides` (0088) but keyed by store+role.
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- REPLICA IDENTITY FULL is set here at creation (this is a hard-delete table —
-- the `enqueueDelete` + realtime-DELETE + reconcile set — so its delete events
-- must carry business_id for the RLS authorize, see 0064 / 0090).
-- DEPLOY ORDER: push this BEFORE the v41 app reaches a device, or the
-- store_role_permissions upserts the role-page store editor enqueues would 42P01
-- (relation does not exist) cloud-side.

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.store_role_permissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id          uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  role_id           uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  permission_key    text NOT NULL REFERENCES public.permissions(key) ON DELETE RESTRICT,
  is_granted        boolean NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, role_id, permission_key)
);
CREATE INDEX idx_store_role_permissions_business_lua
  ON public.store_role_permissions (business_id, last_updated_at);
CREATE INDEX idx_store_role_permissions_store_role
  ON public.store_role_permissions (store_id, role_id);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — profiles-based tenant scoping. Use
--    current_user_business_ids() directly (NOT an inline user_businesses
--    subquery), which avoids the auth_user_id-drift 42501 push failures the
--    older inline policies hit (see 0050/0051/0075).
-- -----------------------------------------------------------------------------
ALTER TABLE public.store_role_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "store_role_permissions_tenant_rw" ON public.store_role_permissions
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 3. last_updated_at bump trigger — rows get UPDATEd when an override flips
--    grant<->revoke, so keep the heartbeat (mirrors role_permissions / 0088).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_store_role_permissions_last_updated_at
  BEFORE UPDATE ON public.store_role_permissions
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Realtime publication — INSERT/UPDATE/DELETE events flow to other devices.
--    REPLICA IDENTITY FULL so a DELETE's old record carries business_id and the
--    realtime RLS authorize passes (else the DELETE is dropped — see 0090).
-- -----------------------------------------------------------------------------
ALTER TABLE public.store_role_permissions REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.store_role_permissions;

-- -----------------------------------------------------------------------------
-- 5. Snapshot pull — append store_role_permissions to pos_pull_snapshot so other
--    devices pull a store's overrides (same signature/body as 0093; only
--    v_tenant_tables gains the one new name).
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
    'orders','order_items',
    -- 0093: per-order, per-brand crate deposit lines (§13.4).
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'notifications','stock_transactions',
    -- 0089: stock-keeper adjustment approval queue (§16.6.1).
    'stock_adjustment_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    -- 0092: Funds Register removed — no longer pulled.
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
