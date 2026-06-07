-- 0106_reconcile_pull_snapshot.sql
--
-- Reconciles pos_pull_snapshot after the 0104 / 0105 parallel-feature race.
-- Migration 0104 (store_crate_balances) added that table to the function.
-- Migration 0105 (quick_sale_requests) CREATE OR REPLACED the function but
-- did NOT carry forward store_crate_balances.  Whichever of {0104, 0105} ran
-- last would have won — meaning store_crate_balances could be absent.
-- This migration is the authoritative union: it redefines the function with
-- BOTH additions so the outcome is deterministic regardless of push order.
--
-- The body is identical to 0105 with 'store_crate_balances' inserted after
-- 'crate_ledger' (FK-safe: store_crate_balances FK → manufacturers, stores,
-- businesses — all pulled earlier in the array).

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
