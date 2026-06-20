-- 0117_supplier_crate_tracking.sql
--
-- Reebaplus — per-supplier empty-crate tracking (master plan §3.13). The
-- supplier-side mirror of the customer crate subsystem: a customer owes US
-- empties (customer_crate_balances, fed by crate_ledger); here WE owe the
-- SUPPLIER empties for the full crates they delivered, and we pay them a
-- refundable deposit for crates we keep.
--
-- Two new tables, mirroring the local Drift tables (schema v53):
--   * supplier_crate_ledger    — append-only movement log. `received` (+) = full
--                                crates arrived (we now owe N empties); `returned`
--                                (−) = empties handed back. `deposit_paid_kobo`
--                                is the refundable deposit money that moved on the
--                                row (paid out on a receipt, refunded on a return).
--                                One new synced tenant table (business_id + lua).
--   * supplier_crate_balances  — per-(supplier, manufacturer) balance cache.
--                                balance = SUM(quantity_delta); positive = we owe
--                                the supplier that many empties. Upsert cache,
--                                same class as store_crate_balances / mfr cache.
--
-- The ledger is append-only (never hard-deleted from the app), so it is NOT in
-- the enqueueDelete / realtime-DELETE sets and carries no cloud append-only
-- trigger (matches error_logs / store_crate_balances; the local Drift no-delete
-- trigger guards on-device deletion).
--
-- DEPLOY ORDER: push this BEFORE the v53 app reaches a device, or the
-- supplier_crate_ledger / supplier_crate_balances upserts the app enqueues would
-- 42P01 (relation does not exist) cloud-side.

BEGIN;

-- ─── 1. supplier_crate_ledger (append-only movement log) ────────────────────
CREATE TABLE IF NOT EXISTS public.supplier_crate_ledger (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  supplier_id       UUID        NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  manufacturer_id   UUID        NOT NULL REFERENCES public.manufacturers(id) ON DELETE CASCADE,
  store_id          UUID        REFERENCES public.stores(id) ON DELETE SET NULL,
  quantity_delta    INTEGER     NOT NULL,  -- + = received from supplier, − = returned to supplier
  movement_type     TEXT        NOT NULL CHECK (movement_type IN ('received','returned','adjusted')),
  deposit_paid_kobo INTEGER     NOT NULL DEFAULT 0 CHECK (deposit_paid_kobo >= 0),
  note              TEXT,
  performed_by      UUID        REFERENCES public.users(id),
  voided_at         TIMESTAMPTZ,
  voided_by         UUID        REFERENCES public.users(id),
  void_reason       TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_supplier_crate_ledger_business_lua
  ON public.supplier_crate_ledger (business_id, last_updated_at);
CREATE INDEX IF NOT EXISTS idx_supplier_crate_ledger_owner
  ON public.supplier_crate_ledger (business_id, supplier_id, manufacturer_id, created_at);

-- ─── 2. supplier_crate_balances (per-supplier, per-manufacturer cache) ──────
CREATE TABLE IF NOT EXISTS public.supplier_crate_balances (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  supplier_id       UUID        NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  manufacturer_id   UUID        NOT NULL REFERENCES public.manufacturers(id) ON DELETE CASCADE,
  balance           INTEGER     NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, supplier_id, manufacturer_id)
);

CREATE INDEX IF NOT EXISTS idx_supplier_crate_balances_business_lua
  ON public.supplier_crate_balances (business_id, last_updated_at);

-- ─── 3. last_updated_at bump triggers (mirror the other tables) ─────────────
DROP TRIGGER IF EXISTS bump_supplier_crate_ledger_last_updated_at ON public.supplier_crate_ledger;
CREATE TRIGGER bump_supplier_crate_ledger_last_updated_at
  BEFORE UPDATE ON public.supplier_crate_ledger
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

DROP TRIGGER IF EXISTS bump_supplier_crate_balances_last_updated_at ON public.supplier_crate_balances;
CREATE TRIGGER bump_supplier_crate_balances_last_updated_at
  BEFORE UPDATE ON public.supplier_crate_balances
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ─── 4. Row Level Security — profiles-based tenant scoping via
--        current_user_business_ids() (NOT an inline user_businesses subquery;
--        that hits auth_user_id-drift 42501 push failures — see 0102/0104/0108).
ALTER TABLE public.supplier_crate_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_crate_ledger_tenant_rw" ON public.supplier_crate_ledger
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

ALTER TABLE public.supplier_crate_balances ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_crate_balances_tenant_rw" ON public.supplier_crate_balances
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- ─── 5. Realtime — INSERT/UPDATE events flow to peer devices. REPLICA IDENTITY
--        FULL so the record carries business_id for the realtime RLS authorize.
ALTER TABLE public.supplier_crate_ledger REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.supplier_crate_ledger;
-- The balance cache is upsert-only (never tombstoned), same as
-- store_crate_balances — no REPLICA IDENTITY FULL needed.
ALTER PUBLICATION supabase_realtime ADD TABLE public.supplier_crate_balances;

-- ─── 6. pos_pull_snapshot — add both tables to the tenant-table list so a fresh
--        device's first sync pulls supplier crate history. Carries forward the
--        full 0108 union (the authoritative list). supplier_crate_ledger is
--        inserted after supplier_ledger_entries (FK-safe: suppliers/manufacturers/
--        stores pulled earlier); supplier_crate_balances after store_crate_balances.
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
    -- 0117: per-supplier append-only empty-crate ledger (§3.13).
    'supplier_crate_ledger',
    'orders','order_items',
    -- 0093: per-order, per-brand crate deposit lines (§13.4).
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    -- 0108: crash/error diagnostic log (§33).
    'error_logs',
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
    -- 0117: per-(supplier, manufacturer) empty crate balance cache (§3.13).
    'supplier_crate_balances',
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

COMMIT;
