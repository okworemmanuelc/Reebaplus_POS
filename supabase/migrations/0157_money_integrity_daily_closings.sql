-- 0157_money_integrity_daily_closings.sql
--
-- Reebaplus — money integrity #6: persisted day close (#174, PRD #155, ADR 0021
-- §2). The `daily_closings` table freezes the computed figure set of a FINISHED
-- calendar day the first time a permitted user (Manager+) opens its Daily
-- Reconciliation detail: ONE snapshot per (business, calendar day), captured
-- with the reviewer + timestamp. The report thereafter renders live figures
-- alongside the snapshot with a per-card delta badge when they diverge — silent
-- history mutation (late syncs, cancels, backdated entries) becomes VISIBLE.
--
-- Purely OBSERVATIONAL: writing/reading a snapshot changes no money flow and no
-- existing figure. Mirrors the Drift `DailyClosings` table (schema v68 in
-- lib/core/database/app_database.dart) and its `daily_closings` SyncedTable
-- registry entry.
--
-- FIRST-WRITER-WINS. The row id is DETERMINISTIC on the client from
-- (business_id, business_date) — UUIDv5, so two devices mint the SAME id and a
-- second push conflicts on the id PK and converges (no 2067). The natural key is
-- also enforced by UNIQUE (business_id, business_date). The row is APPEND /
-- first-write-only (never mutated after review), so it is NOT an append-only
-- ledger with void columns and is NOT hard-deleted — no immutability trigger and
-- no REPLICA IDENTITY FULL. (An offline both-write race on the same day resolves
-- last-write on the cloud upsert; the client restore is insert-or-IGNORE so each
-- device keeps the first snapshot it knows — an accepted, observational-only
-- residual. See ADR 0021.)
--
-- Money rule: every *_kobo column is BIGINT (int4 caps at ₦21,474,836.47 and
-- rejects larger amounts on push with 22003, jamming the outbox — see 0130).
-- items_sold / shortage_units are counts, so INTEGER.
--
-- DEPLOY ORDER: push this BEFORE the v68 app reaches a device, or the
-- daily_closings upserts the app enqueues would 42P01 (relation does not exist)
-- cloud-side (the land-the-migration-first rule).
--
-- MIGRATION-NUMBER LANE: renumbered to contiguous 0157 (Drift v68) at merge of
-- the parallel money-integrity branches — #170 (cost-batch coverage) took cloud
-- 0155–0156 / Drift v66–v67 immediately ahead of this one.

BEGIN;

-- ─── 1. daily_closings (one frozen snapshot per business × calendar day) ─────
CREATE TABLE IF NOT EXISTS public.daily_closings (
  id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id                 UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  business_date               TEXT        NOT NULL,                       -- YYYY-MM-DD
  -- The §12.1 active-store scope the figures were captured in (NULL = All
  -- Stores). Informational only: the natural key is (business, day).
  store_scope_id              UUID        REFERENCES public.stores(id)    ON DELETE SET NULL,
  -- ── Frozen figure set (period-scoped; see ReconData) ──
  total_sales_kobo            BIGINT      NOT NULL DEFAULT 0,
  refunds_kobo                BIGINT      NOT NULL DEFAULT 0,
  discounts_kobo              BIGINT      NOT NULL DEFAULT 0,
  cogs_kobo                   BIGINT      NOT NULL DEFAULT 0,
  gross_profit_kobo           BIGINT      NOT NULL DEFAULT 0,
  net_profit_kobo             BIGINT      NOT NULL DEFAULT 0,
  expenses_kobo               BIGINT      NOT NULL DEFAULT 0,
  damages_cost_kobo           BIGINT      NOT NULL DEFAULT 0,
  cash_sales_kobo             BIGINT      NOT NULL DEFAULT 0,
  cash_in_kobo                BIGINT      NOT NULL DEFAULT 0,
  cash_out_kobo               BIGINT      NOT NULL DEFAULT 0,
  net_cash_movement_kobo      BIGINT      NOT NULL DEFAULT 0,
  stock_cogs_kobo             BIGINT      NOT NULL DEFAULT 0,
  stock_expected_closing_kobo BIGINT      NOT NULL DEFAULT 0,
  items_sold                  INTEGER     NOT NULL DEFAULT 0,
  shortage_units              INTEGER     NOT NULL DEFAULT 0,
  -- Who reviewed (froze) the day, and when.
  reviewed_by                 UUID        REFERENCES public.users(id)     ON DELETE SET NULL,
  reviewed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Natural key: one snapshot per (business, calendar day).
  CONSTRAINT uq_daily_closings_business_date UNIQUE (business_id, business_date)
);

-- Incremental-pull cursor index (business_id, last_updated_at) — mirrors every
-- other tenant table.
CREATE INDEX IF NOT EXISTS idx_daily_closings_business_lua
  ON public.daily_closings (business_id, last_updated_at);

-- ─── 2. last_updated_at bump trigger (mirror the other tables) ──────────────
DROP TRIGGER IF EXISTS bump_daily_closings_last_updated_at ON public.daily_closings;
CREATE TRIGGER bump_daily_closings_last_updated_at
  BEFORE UPDATE ON public.daily_closings
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ─── 3. Row Level Security — profiles-based tenant scoping via
--        current_user_business_ids() (NOT an inline user_businesses subquery;
--        that hits auth_user_id-drift 42501 push failures — see 0132/0105/0102).
ALTER TABLE public.daily_closings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "daily_closings_tenant_rw" ON public.daily_closings
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- ─── 4. Realtime — INSERT/UPDATE events flow to peer devices. First-write-only
--        (never tombstoned), same as cost_batches — no REPLICA IDENTITY FULL
--        needed (the NEW record carries business_id for the realtime RLS).
ALTER PUBLICATION supabase_realtime ADD TABLE public.daily_closings;

-- ─── 5. pos_pull_snapshot — add daily_closings to the tenant-table array so a
--        fresh device's first/full sync (since=NULL) pulls the snapshots.
--        Carries forward the full 0132 union (the authoritative list) with
--        'daily_closings' inserted immediately after 'stock_counts' — FK-safe:
--        daily_closings FK → businesses + stores + users, all pulled earlier.
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
    -- 0132: per-(product, store) FIFO cost queue (ADR 0005).
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
    -- 0127: monthly spending budget (§20.1/§20.3).
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
    -- 0157: persisted day close snapshot (#174). FK → businesses + stores +
    -- users (all pulled earlier in this array).
    'daily_closings',
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

-- =============================================================================
-- Verification (run by hand after deploy):
--   \d public.daily_closings                     -- 24 cols; *_kobo all bigint
--   SELECT conname FROM pg_constraint
--     WHERE conrelid = 'public.daily_closings'::regclass AND contype = 'u';
--     -- expect: uq_daily_closings_business_date
--   SELECT polname FROM pg_policy
--     WHERE polrelid = 'public.daily_closings'::regclass;
--     -- expect: daily_closings_tenant_rw
--   SELECT 1 FROM pg_publication_tables
--     WHERE pubname = 'supabase_realtime' AND tablename = 'daily_closings';
-- =============================================================================
