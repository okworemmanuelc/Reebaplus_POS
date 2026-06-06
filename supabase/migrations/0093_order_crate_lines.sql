-- 0093_order_crate_lines.sql
--
-- Reebaplus — per-order, per-brand crate deposit lines (master plan §13.4). For
-- any order carrying tracked crate items, one row per (order, manufacturer/brand)
-- records: crates taken, the deposit rate snapshot at sale, and the deposit
-- actually paid. The Confirm Crate Returns modal reads this to know, per brand,
-- whether the deposit was full / part / none (which decides pre-fill + how a
-- shortage settles). Mirrors the local Drift `OrderCrateLines` table (schema v37).
--
-- Additive: one new synced tenant table + RLS + realtime + snapshot pull.
-- DEPLOY ORDER: push this BEFORE the crate-deposit app build reaches a device, or
-- the order_crate_lines upserts the checkout flow enqueues would 42P01 (relation
-- does not exist) cloud-side.

-- -----------------------------------------------------------------------------
-- 1. Table
-- -----------------------------------------------------------------------------
CREATE TABLE public.order_crate_lines (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  order_id          uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  manufacturer_id   uuid NOT NULL REFERENCES public.manufacturers(id) ON DELETE CASCADE,
  crates_taken      integer NOT NULL,
  -- Deposit rate per crate, snapshotted from manufacturers.deposit_amount_kobo at
  -- sale time so a later CEO rate edit doesn't change historic settlements.
  deposit_rate_kobo integer NOT NULL DEFAULT 0,
  deposit_paid_kobo integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, order_id, manufacturer_id)
);
CREATE INDEX idx_order_crate_lines_business_lua
  ON public.order_crate_lines (business_id, last_updated_at);
CREATE INDEX idx_order_crate_lines_order
  ON public.order_crate_lines (order_id);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — profiles-based tenant scoping via
--    current_user_business_ids() (NOT an inline user_businesses subquery, which
--    hits the auth_user_id-drift 42501 push failures; see 0074/0088/0089).
-- -----------------------------------------------------------------------------
ALTER TABLE public.order_crate_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "order_crate_lines_tenant_rw" ON public.order_crate_lines
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 3. last_updated_at bump trigger — deposit_paid_kobo may be UPDATEd before the
--    order is finalized, so keep the sync heartbeat (mirrors 0089).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_order_crate_lines_last_updated_at
  BEFORE UPDATE ON public.order_crate_lines
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 4. Realtime publication — INSERT/UPDATE/DELETE events flow to other devices.
-- -----------------------------------------------------------------------------
ALTER PUBLICATION supabase_realtime ADD TABLE public.order_crate_lines;

-- -----------------------------------------------------------------------------
-- 5. Snapshot pull — append order_crate_lines to pos_pull_snapshot so other
--    devices pull the per-order deposit lines. Same body as 0092 (the funds
--    tables stay removed); only v_tenant_tables gains the one new name, placed
--    right after order_items (FK-safe: orders + manufacturers precede it).
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
