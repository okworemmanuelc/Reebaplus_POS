-- 0251_van_drivers.sql
--
-- #748 / PRD #139, ADR 0019 (amended) — a van driver is a plain name with no
-- user account, and each driver's debt is tracked SEPARATELY.
--
--   · public.van_drivers   id, business_id, name, phone, is_deleted — NOT a
--                          users row, NOT a customers row. No invite, no sign-in.
--   · stores.van_driver_id the van's default driver (pre-fills a load).
--   · van_trips.van_driver_id   who answers for the trip. Nullable: a van can
--                          load with no driver at all.
--   · driver_ledger_entries.van_store_id, .van_driver_id   (nullable).
--   · van_trips.driver_user_id and driver_ledger_entries.driver_user_id become
--     NULLABLE. New rows leave them null; old rows keep them. Nothing deleted.
--
-- OWNERSHIP RULE (the app and the web console must agree): a ledger row with a
-- trip belongs to the driver that TRIP names now (van_trips.van_driver_id), so
-- changing a trip's driver moves its debt with no ledger amount edited. A row
-- with no trip belongs to its own van_driver_id. Trips with no driver form the
-- "No driver assigned" group of their van (van_trips.van_store_id).
-- Balance = SUM(signed_amount_kobo) over a driver's rows; negative = owes.
-- Money rules (balance, profit, close, empties credit) are unchanged.
--
-- BACKFILL: one van_drivers row per distinct old driver_user_id on a trip or
-- ledger row, with id = that user's id (deterministic; the Drift v108 upgrade
-- does the same, so a device and the cloud agree), name/phone from the user.
-- Trips and ledger rows link to it; ledger rows also get their van (the trip's
-- van, else that driver's most recent trip's van). Old debts stay with the
-- same person.
--
-- The one-open-trip-per-van index is untouched and stays enforced. The
-- one-open-trip-per-driver index (driver_user_id) stays but is now harmless:
-- new rows leave the column null.
--
-- Mirrors Drift schemaVersion 108. DEPLOY ORDER: land this BEFORE any v108
-- client pushes (the upserts carry the new columns and the new table).
-- Money-column rule (0130) unchanged: no *_kobo column is added.
-- POS PARITY: web issues #233 / #237 assumed a driver id (users.id); see the
-- pos-parity issue on this change.

BEGIN;

-- 1. van_drivers ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.van_drivers (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  phone           text,
  is_deleted      boolean     NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_van_drivers_business_lua
  ON public.van_drivers (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_van_drivers_last_updated_at ON public.van_drivers;
CREATE TRIGGER bump_van_drivers_last_updated_at
  BEFORE UPDATE ON public.van_drivers
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

ALTER TABLE public.van_drivers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "van_drivers_tenant_rw" ON public.van_drivers;
CREATE POLICY "van_drivers_tenant_rw" ON public.van_drivers
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

ALTER TABLE public.van_drivers REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
       AND tablename = 'van_drivers'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.van_drivers;
  END IF;
END $$;

DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.van_drivers;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.van_drivers
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- 2. Columns --------------------------------------------------------------
ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS van_driver_id uuid
    REFERENCES public.van_drivers(id) ON DELETE SET NULL;

ALTER TABLE public.van_trips
  ADD COLUMN IF NOT EXISTS van_driver_id uuid
    REFERENCES public.van_drivers(id) ON DELETE RESTRICT,
  ALTER COLUMN driver_user_id DROP NOT NULL;

ALTER TABLE public.driver_ledger_entries
  ADD COLUMN IF NOT EXISTS van_store_id uuid
    REFERENCES public.stores(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS van_driver_id uuid
    REFERENCES public.van_drivers(id) ON DELETE RESTRICT,
  ALTER COLUMN driver_user_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_van_trips_business_van_driver_status
  ON public.van_trips (business_id, van_driver_id, status);
CREATE INDEX IF NOT EXISTS idx_driver_ledger_business_van_driver
  ON public.driver_ledger_entries (business_id, van_driver_id, created_at);

-- 3. Backfill (idempotent) ------------------------------------------------
INSERT INTO public.van_drivers (id, business_id, name, phone)
SELECT u.id, u.business_id, u.name, u.phone
  FROM public.users u
 WHERE u.id IN (
         SELECT driver_user_id FROM public.van_trips
          WHERE driver_user_id IS NOT NULL
         UNION
         SELECT driver_user_id FROM public.driver_ledger_entries
          WHERE driver_user_id IS NOT NULL)
ON CONFLICT (id) DO NOTHING;

UPDATE public.van_trips
   SET van_driver_id = driver_user_id
 WHERE van_driver_id IS NULL
   AND driver_user_id IN (SELECT id FROM public.van_drivers);

UPDATE public.driver_ledger_entries
   SET van_driver_id = driver_user_id
 WHERE van_driver_id IS NULL
   AND driver_user_id IN (SELECT id FROM public.van_drivers);

UPDATE public.driver_ledger_entries e
   SET van_store_id = t.van_store_id
  FROM public.van_trips t
 WHERE e.van_store_id IS NULL AND e.trip_id = t.id;

UPDATE public.driver_ledger_entries e
   SET van_store_id = (
         SELECT t.van_store_id FROM public.van_trips t
          WHERE t.driver_user_id = e.driver_user_id
          ORDER BY t.opened_at DESC, t.id DESC LIMIT 1)
 WHERE e.van_store_id IS NULL AND e.driver_user_id IS NOT NULL;

-- 4. pos_pull_snapshot — add van_drivers ------------------------------------
-- Body copied verbatim from 0245 (latest definition); the only change is the
-- one list entry marked "0251 (#748)".
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
    'profiles','users',
    -- 0251 (#748): van drivers; parent businesses only.
    'van_drivers',
    'stores',
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
