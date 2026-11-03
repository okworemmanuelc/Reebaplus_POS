-- 0245_staff_pay_totals.sql
--
-- #669 (PRD #666, ADR 0034): the automatic Daily Allowance's combined line.
-- Cloud twin of Drift schemaVersion 103 (app_database.dart, `from < 103`).
--
-- WHY A TABLE OF ITS OWN
--   Payroll rows reach only phones with `payroll.manage` (0243), but Daily
--   Reconciliation, Expenses and Profit on EVERY phone must count the till
--   cash Daily Allowances take. ADR 0034: they receive one combined line per
--   store and day ("Daily allowances") that names no worker and syncs as
--   normal. That line is a DERIVED total that keeps changing (a missed day is
--   filled in later, a late change lands on the day it is made), so it cannot
--   live in payment_transactions (append-only) or expenses (amount immutable,
--   approvals, edit/delete by staff). staff_pay_totals holds it instead:
--   one row per (business, store, kind, day) under a deterministic client id,
--   always written as the full recomputed figure by a Payroll phone, so two
--   phones converge by last-write-wins. kind 'salaries' is reserved for the
--   payday line (#671).
--
-- WHAT THIS ADDS
--   1. staff_pay_totals (business-scoped, bigint kobo, bump trigger, realtime,
--      zz_broadcast_sync_signal). Every member READS it; only a caller holding
--      `payroll.manage` may INSERT or UPDATE it. No DELETE.
--   2. pos_pull_snapshot re-issued VERBATIM from 0205 with staff_pay_totals
--      added after expense_budgets (it is not permission-gated).
--
-- DEPLOY ORDER: after 0243 (caller_has_permission + payroll.manage) and
-- BEFORE any client on Drift 103 pushes a staff_pay_totals row (an older
-- cloud rejects the push and jams that outbox row). Never together with 0193.

BEGIN;

-- =========================================================================
-- 1. staff_pay_totals
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.staff_pay_totals (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id         uuid        NOT NULL REFERENCES public.stores(id),
  kind             text        NOT NULL CHECK (kind IN ('daily_allowances','salaries')),
  -- The day the money left that store's till.
  total_date       date        NOT NULL,
  amount_kobo      bigint      NOT NULL DEFAULT 0,
  -- The part paid in till cash (all of it for Daily Allowances).
  cash_kobo        bigint      NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Backstop to the deterministic id: one line per store, kind and day.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_pay_totals_store_kind_day
  ON public.staff_pay_totals (business_id, store_id, kind, total_date);
CREATE INDEX IF NOT EXISTS idx_staff_pay_totals_business_lua
  ON public.staff_pay_totals (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_staff_pay_totals_last_updated_at
  ON public.staff_pay_totals;
CREATE TRIGGER bump_staff_pay_totals_last_updated_at
  BEFORE UPDATE ON public.staff_pay_totals
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

COMMENT ON TABLE public.staff_pay_totals IS
  '#669 (ADR 0034): one combined pay line per store, kind and day, with no '
  'worker named. Derived by Payroll phones; read by every phone.';

ALTER TABLE public.staff_pay_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_pay_totals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_pay_totals FROM anon;

DROP POLICY IF EXISTS "staff_pay_totals_member_select" ON public.staff_pay_totals;
CREATE POLICY "staff_pay_totals_member_select" ON public.staff_pay_totals
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS "staff_pay_totals_payroll_insert" ON public.staff_pay_totals;
CREATE POLICY "staff_pay_totals_payroll_insert" ON public.staff_pay_totals
  FOR INSERT TO authenticated
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));

DROP POLICY IF EXISTS "staff_pay_totals_payroll_update" ON public.staff_pay_totals;
CREATE POLICY "staff_pay_totals_payroll_update" ON public.staff_pay_totals
  FOR UPDATE TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));
-- No DELETE policy: a cancelled day reads 0, it is never removed.

ALTER TABLE public.staff_pay_totals REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
       AND tablename = 'staff_pay_totals'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.staff_pay_totals;
  END IF;
END $$;

DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.staff_pay_totals;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.staff_pay_totals
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- =========================================================================
-- 2. pos_pull_snapshot — add staff_pay_totals (after expense_budgets)
--    Body copied verbatim from 0205 (latest definition); the only change is
--    the one list entry marked "0245 (#669)".
-- =========================================================================
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
    'profiles','users','stores',
    -- 0199 (#423): per-store delivery areas; parent stores is just above.
    'store_delivery_areas',
    'manufacturers','crate_size_groups',
    'categories','products',
    -- 0204 (#474): gallery photos; parent products is just above.
    'product_photos',
    'inventory',
    'cost_batches',
    'customers','suppliers',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    'supplier_crate_deposit_requests','supplier_crate_deposits',
    'orders','order_items',
    'order_crate_lines',
    -- 0205 (#426): Online Orders + lines; parents stores, customers,
    -- products and orders are all listed above.
    'online_orders','online_order_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'expense_budgets',
    -- 0245 (#669): combined pay lines (no worker named); parent stores is
    -- listed above.
    'staff_pay_totals',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'error_logs',
    'notifications','stock_transactions',
    'stock_adjustment_requests',
    'quick_sale_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts',
    'pending_crate_returns','crate_ledger','manufacturer_crate_balances',
    'store_crate_balances',
    -- 0175 (#517): crate shortfall write-offs; parents businesses,
    -- manufacturers, stores and users are all listed above.
    'crate_shortfall_writeoffs',
    'supplier_crate_balances',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    'stock_counts',
    'daily_closings',
    'van_trips','van_trip_lots','van_return_events','driver_ledger_entries',
    'user_permission_overrides',
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

COMMIT;
