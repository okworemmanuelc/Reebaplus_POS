-- 0072_stock_counts.sql
--
-- Reebaplus — Daily Stock Count (§17). Per-session stock-audit snapshot,
-- written when a count is saved (Save Count). One row per saved count:
-- `products_counted` (how many products were in the session), the shortage /
-- surplus roll-up, and `lines_json` (the itemized changed products
-- [{p,n,s,a,d}] = product id / name / system / actual / diff). This is the
-- stock-audit half of the Daily Reconciliation Report (§25.9), symmetric to
-- fund_day_closings (the cash-audit half, 0068). Written once per Save Count,
-- so a normal synced tenant table, not an append-only ledger.
-- Mirrors the local Drift `StockCounts` table (schema v30).
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- DEPLOY ORDER: push this BEFORE the v30 app reaches a device, or the
-- stock_counts upserts the Save Count flow enqueues would 42P01 (relation
-- does not exist) cloud-side. (The stock_adjustments / stock_transactions the
-- adjust loop writes are unchanged.)

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.stock_counts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id),
  store_id          uuid REFERENCES public.stores(id),    -- null = all-stores count
  business_date     text NOT NULL,                        -- YYYY-MM-DD
  products_counted  int  NOT NULL,
  shortage_count    int  NOT NULL,                        -- # products short (diff<0)
  surplus_count     int  NOT NULL,                        -- # products over  (diff>0)
  shortage_units    int  NOT NULL,                        -- sum |diff| where diff<0
  surplus_units     int  NOT NULL,                        -- sum  diff  where diff>0
  lines_json        text NOT NULL,                        -- [{p,n,s,a,d}] changed lines
  counted_by        uuid REFERENCES public.users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_stock_counts_business_lua ON public.stock_counts (business_id, last_updated_at);
CREATE INDEX idx_stock_counts_store_date   ON public.stock_counts (store_id, business_date);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — standard "tenant member via user_businesses" policy
--    (mirrors 0068's fund_day_closings_tenant_rw).
-- -----------------------------------------------------------------------------
ALTER TABLE public.stock_counts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stock_counts_tenant_rw" ON public.stock_counts
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

-- -----------------------------------------------------------------------------
-- 3. Realtime publication — INSERT/UPDATE events flow to other devices.
-- -----------------------------------------------------------------------------
ALTER PUBLICATION supabase_realtime ADD TABLE public.stock_counts;

-- -----------------------------------------------------------------------------
-- 4. Snapshot pull — append stock_counts to pos_pull_snapshot so other devices
--    pull saved counts (same signature/body as 0068; only v_tenant_tables
--    gains the one new name).
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
    'stock_counts'
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
