-- 0132_cost_batches.sql
--
-- Reebaplus — Epic 2 / FIFO batch costing (master plan ADR 0005, issue #37, F1).
--
-- The `cost_batches` table is the per-(product, store) FIFO cost queue. Each
-- Receive Stock (and Add Product's opening stock) pushes one batch
-- {qty_remaining, qty_original, cost_kobo, received_at}; sales draw it down
-- oldest-first by received_at. cost_kobo = 0 marks an UNCOSTED batch (sales from
-- it snapshot 0 and are excluded from COGS until a cost is backfilled).
--
-- A normal MUTABLE synced tenant table (qty_remaining is drawn down in place) —
-- NOT an append-only ledger and NOT hard-deleted (a spent batch stays at qty 0
-- for history). So no append-only trigger, and — like the upsert-only balance
-- caches (store_crate_balances) — no REPLICA IDENTITY FULL: it is never
-- tombstoned, and realtime INSERT/UPDATE events carry the full NEW record
-- (with business_id) for the RLS authorize.
--
-- Money rule: cost_kobo is a *_kobo column, so it MUST be BIGINT (int4 caps at
-- ₦21,474,836.47 and rejects larger amounts on push with 22003, jamming the
-- outbox — see 0130). qty_remaining / qty_original are counts, so INTEGER.
--
-- This is F1 of Epic 2: the table, its RLS/realtime membership, and its
-- pos_pull_snapshot entry only — no consumer draw-down logic. The per-device
-- opening-batch seed is done client-side by the v58 Drift migration (with a
-- deterministic id so devices converge); there is no server-side backfill here.
--
-- DEPLOY ORDER: push this BEFORE the v58 app reaches a device, or the
-- cost_batches upserts the app enqueues would 42P01 (relation does not exist)
-- cloud-side (the land-the-migration-first rule).

BEGIN;

-- ─── 1. cost_batches (per-(product, store) FIFO cost queue) ─────────────────
CREATE TABLE IF NOT EXISTS public.cost_batches (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  product_id      UUID        NOT NULL REFERENCES public.products(id)   ON DELETE CASCADE,
  store_id        UUID        NOT NULL REFERENCES public.stores(id)     ON DELETE CASCADE,
  qty_remaining   INTEGER     NOT NULL CHECK (qty_remaining >= 0),
  qty_original    INTEGER     NOT NULL CHECK (qty_original  >= 0),
  cost_kobo       BIGINT      NOT NULL DEFAULT 0 CHECK (cost_kobo >= 0),
  received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Incremental-pull cursor index (business_id, last_updated_at) — mirrors every
-- other tenant table.
CREATE INDEX IF NOT EXISTS idx_cost_batches_business_lua
  ON public.cost_batches (business_id, last_updated_at);
-- FIFO oldest-first scan per (product, store).
CREATE INDEX IF NOT EXISTS idx_cost_batches_product_store_received
  ON public.cost_batches (business_id, product_id, store_id, received_at);

-- ─── 2. last_updated_at bump trigger (mirror the other tables) ──────────────
DROP TRIGGER IF EXISTS bump_cost_batches_last_updated_at ON public.cost_batches;
CREATE TRIGGER bump_cost_batches_last_updated_at
  BEFORE UPDATE ON public.cost_batches
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ─── 3. Row Level Security — profiles-based tenant scoping via
--        current_user_business_ids() (NOT an inline user_businesses subquery;
--        that hits auth_user_id-drift 42501 push failures — see 0102/0108/0117).
ALTER TABLE public.cost_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cost_batches_tenant_rw" ON public.cost_batches
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- ─── 4. Realtime — INSERT/UPDATE events flow to peer devices. Upsert/update-only
--        (never tombstoned), same as store_crate_balances — no REPLICA IDENTITY
--        FULL needed (the NEW record carries business_id for the realtime RLS).
ALTER PUBLICATION supabase_realtime ADD TABLE public.cost_batches;

-- ─── 5. pos_pull_snapshot — add cost_batches to the tenant-table array so a
--        fresh device's first/full sync (since=NULL) pulls the cost queue.
--        Carries forward the full 0127 union (the authoritative list) with
--        'cost_batches' inserted immediately after 'inventory' — FK-safe:
--        cost_batches FK → businesses + products + stores, all pulled earlier.
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
    'categories','products','inventory',
    -- 0132: per-(product, store) FIFO cost queue (ADR 0005). FK → businesses +
    -- products + stores (all pulled earlier in this array).
    'cost_batches',
    'customers','suppliers',
    -- 0101: per-supplier append-only ledger (§21.10).
    'supplier_ledger_entries',
    -- 0117: per-supplier append-only empty-crate ledger (§3.13).
    'supplier_crate_ledger',
    'orders','order_items',
    -- 0093: per-order, per-brand crate deposit lines (§13.4).
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    -- 0127: monthly spending budget (§20.1/§20.3). FK → businesses + stores
    -- (both pulled earlier in this array).
    'expense_budgets',
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
