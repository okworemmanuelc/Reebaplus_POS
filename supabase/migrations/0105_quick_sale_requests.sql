-- 0105_quick_sale_requests.sql
--
-- Reebaplus — cashier Quick Sale approval queue (master plan §12.3.1). The old
-- CEO/Manager PIN gate for a Cashier Quick Sale is replaced by an approval
-- request: a role below Manager can no longer drop a Quick Sale straight into
-- the cart — it lands here as a `pending` request. The active selling store's
-- Manager(s) and the CEO approve in the Reports → Approvals card; on approval
-- the cashier's device drops the item into the cart. A Quick Sale bypasses
-- inventory (§26.4), so this table only records the request + its review
-- outcome (no stock moves on approval). Mirrors the local Drift
-- `QuickSaleRequests` table (schema v45) and the same async, cross-device
-- pattern as 0089_stock_adjustment_requests.sql (§16.6.1).
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- DEPLOY ORDER: push this BEFORE the v45 app reaches a device, or the
-- quick_sale_requests upserts the request/approve/reject/cancel flow enqueues
-- would 42P01 (relation does not exist) cloud-side.
--
-- !! CROSS-FEATURE NOTE: the snapshot redefinition below is rebased on the 0102
-- baseline + quick_sale_requests. A parallel in-flight migration
-- (0104_store_crate_balances.sql, §16.8.1) also CREATE OR REPLACEs
-- pos_pull_snapshot. Whichever of {0104, 0105} is applied LAST wins, so when
-- both land the final v_tenant_tables MUST be the UNION of both additions
-- (store_crate_balances AND quick_sale_requests). Reconcile at push time:
-- ensure the later-numbered file's array contains the earlier one's new table.

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.quick_sale_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id          uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  item_name         text NOT NULL,
  quantity          double precision NOT NULL,
  unit_price_kobo   integer NOT NULL,
  summary           text NOT NULL,
  requested_by      uuid REFERENCES public.users(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','approved','rejected','cancelled')),
  approved_by       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  approved_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_quick_sale_requests_business_lua
  ON public.quick_sale_requests (business_id, last_updated_at);
CREATE INDEX idx_quick_sale_requests_store
  ON public.quick_sale_requests (store_id);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — profiles-based tenant scoping. Use
--    current_user_business_ids() directly (NOT an inline user_businesses
--    subquery), which avoids the auth_user_id-drift 42501 push failures the
--    older inline policies hit (see 0050/0051/0075/0089/0102).
-- -----------------------------------------------------------------------------
ALTER TABLE public.quick_sale_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "quick_sale_requests_tenant_rw" ON public.quick_sale_requests
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 3. last_updated_at bump trigger — rows get UPDATEd when a request is
--    approved/rejected/cancelled, so keep the heartbeat (mirrors 0089).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_quick_sale_requests_last_updated_at
  BEFORE UPDATE ON public.quick_sale_requests
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Realtime publication — INSERT/UPDATE events flow to other devices.
--    REPLICA IDENTITY FULL so the approve/reject/cancel UPDATE's record carries
--    business_id for the realtime RLS authorize — this is the path that
--    releases the item into (or rejects it from) the cashier's cart on their
--    till (mirrors 0102).
-- -----------------------------------------------------------------------------
ALTER TABLE public.quick_sale_requests REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.quick_sale_requests;

-- -----------------------------------------------------------------------------
-- 5. Snapshot pull — append quick_sale_requests to pos_pull_snapshot so other
--    devices (the approver's till; a cashier's fresh device) pull pending
--    requests (same signature/body as 0102; only v_tenant_tables gains the one
--    new name). See the CROSS-FEATURE NOTE at the top re: 0104.
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
    'notifications','stock_transactions',
    -- 0089: stock-keeper adjustment approval queue (§16.6.1).
    'stock_adjustment_requests',
    -- 0105: cashier Quick Sale approval queue (§12.3.1).
    'quick_sale_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
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
