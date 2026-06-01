-- 0068_fund_day_closings.sql
--
-- Reebaplus — Funds Register Close Day (§23.6). Per-account reconciliation
-- snapshot, written when a day is closed: `expected_kobo` (the account's running
-- balance = SUM(signed_amount_kobo) at close), `counted_kobo` (the actual the
-- user entered — cash counted for the Cash Till, amount withdrawn for POS/bank),
-- and `variance_kobo` = counted − expected (non-zero flags a shortage/surplus).
-- This is the cash-audit half of the Daily Reconciliation Report (§25.9).
-- Mirrors the local Drift `FundDayClosings` table (schema v27).
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- DEPLOY ORDER: push this BEFORE the v27 app reaches a device, or the
-- fund_day_closings upserts the Close Day flow enqueues would 42P01 (relation
-- does not exist) cloud-side. (The closed fund_days upsert itself is unchanged.)

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.fund_day_closings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id),
  fund_day_id       uuid NOT NULL REFERENCES public.fund_days(id),
  funds_account_id  uuid NOT NULL REFERENCES public.funds_accounts(id),
  store_id          uuid NOT NULL REFERENCES public.stores(id),
  business_date     text NOT NULL,                       -- YYYY-MM-DD
  account_type      text NOT NULL CHECK (account_type IN ('cash_till','pos_machine','bank')),
  expected_kobo     int  NOT NULL,
  counted_kobo      int  NOT NULL,
  variance_kobo     int  NOT NULL,                        -- counted − expected
  performed_by      uuid REFERENCES public.users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fund_day_id, funds_account_id)
);
CREATE INDEX idx_fund_day_closings_business_lua ON public.fund_day_closings (business_id, last_updated_at);
CREATE INDEX idx_fund_day_closings_store_date ON public.fund_day_closings (store_id, business_date);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — standard "tenant member via user_businesses" policy
--    (mirrors 0057's fund_days_tenant_rw).
-- -----------------------------------------------------------------------------
ALTER TABLE public.fund_day_closings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fund_day_closings_tenant_rw" ON public.fund_day_closings
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
ALTER PUBLICATION supabase_realtime ADD TABLE public.fund_day_closings;

-- -----------------------------------------------------------------------------
-- 4. Snapshot pull — append fund_day_closings to pos_pull_snapshot so other
--    devices pull a closed day's reconciliation (same signature/body as 0060;
--    only v_tenant_tables gains the one new name).
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
    'fund_day_closings'
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
