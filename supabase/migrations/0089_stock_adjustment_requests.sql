-- 0089_stock_adjustment_requests.sql
--
-- Reebaplus — stock-keeper adjustment approval queue (master plan §16.6.1). A
-- stock keeper's Add/Remove does NOT touch inventory directly; it lands here as
-- a `pending` request. The affected store's Manager(s) and the CEO approve in
-- the Reports hub; on approval the app runs the real adjustment via the
-- existing pos_inventory_delta_v2 envelope (this table only records the request
-- + its review outcome). Mirrors the local Drift `StockAdjustmentRequests`
-- table (schema v34).
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- DEPLOY ORDER: push this BEFORE the v34 app reaches a device, or the
-- stock_adjustment_requests upserts the request/approve/reject flow enqueues
-- would 42P01 (relation does not exist) cloud-side.

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.stock_adjustment_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  product_id        uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  store_id          uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  quantity_diff     integer NOT NULL,
  reason            text NOT NULL,
  summary           text NOT NULL,
  requested_by      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected')),
  approved_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  approved_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_stock_adjustment_requests_business_lua
  ON public.stock_adjustment_requests (business_id, last_updated_at);
CREATE INDEX idx_stock_adjustment_requests_store
  ON public.stock_adjustment_requests (store_id);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — profiles-based tenant scoping. Use
--    current_user_business_ids() directly (NOT an inline user_businesses
--    subquery), which avoids the auth_user_id-drift 42501 push failures the
--    older inline policies hit (see 0050/0051/0075/0088).
-- -----------------------------------------------------------------------------
ALTER TABLE public.stock_adjustment_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stock_adjustment_requests_tenant_rw" ON public.stock_adjustment_requests
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 3. last_updated_at bump trigger — rows get UPDATEd when a request is
--    approved/rejected, so keep the heartbeat (mirrors 0088).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_stock_adjustment_requests_last_updated_at
  BEFORE UPDATE ON public.stock_adjustment_requests
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Realtime publication — INSERT/UPDATE/DELETE events flow to other devices.
-- -----------------------------------------------------------------------------
ALTER PUBLICATION supabase_realtime ADD TABLE public.stock_adjustment_requests;

-- -----------------------------------------------------------------------------
-- 5. Snapshot pull — append stock_adjustment_requests to pos_pull_snapshot so
--    other devices (the approver's till) pull pending requests (same
--    signature/body as 0088; only v_tenant_tables gains the one new name).
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
    -- 0089: stock-keeper adjustment approval queue (§16.6.1).
    'stock_adjustment_requests',
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
