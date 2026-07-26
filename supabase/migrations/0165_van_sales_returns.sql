-- 0165_van_sales_returns.sql
--
-- Reebaplus — Van Sales 4/8: restocks & returns (#143, PRD #139 as amended by
-- #161, ADR 0019, design record `docs/design/van-sales-spec.md` §4.5, §5.2,
-- §5.5, §7.3, §9.3).
--
-- ONE new synced tenant table, the cloud half of Drift schema v74:
--
--   · van_return_events — a dated drop-off of goods coming back off a van.
--                         Partial or final; a trip may have any number.
--
-- The RESTOCK half of this slice needs no schema at all. A restock is the SAME
-- dispatch #141 already writes, against an already-open trip, typed `restock` in
-- the driver-ledger `type` CHECK that 0162 declared in full for exactly this
-- reason — so no append-only ledger table is rebuilt here.
--
-- ── The rule this migration encodes ─────────────────────────────────────────
--
-- A RETURN'S TWO CONDITIONS ARE DIFFERENT MONEY EVENTS, and the difference is
-- in the schema, not just in the client:
--
--   · GOOD    — the driver is CREDITED at the LOAD PRICE of the lots the return
--               draws down (FIFO, oldest first), the units go back into
--               sellable warehouse stock, and the warehouse is re-batched at
--               each drawn lot's SNAPSHOTTED cost — one batch per lot segment,
--               each at its own cost, never a blended average (spec §5.2). That
--               re-batch is what makes those units' next sale book real COGS
--               instead of zero.
--   · DAMAGED — NO credit whatsoever (the driver signed for the goods and still
--               owes for them), the units never re-enter sellable stock, and the
--               company loss is booked at the SNAPSHOTTED COST, not the load
--               price (spec §5.5): the business lost the goods, not the margin
--               it never earned. `van_return_events_damaged_no_credit` below is
--               that rule as a CHECK, so no client version — present or future —
--               can quietly forgive a driver by writing a credit on a damaged
--               row.
--
-- `credit_kobo` and `cost_kobo` are both WRITTEN ONCE, from the lot snapshots on
-- `van_trip_lots`, and never re-derived. #145's close artifact and #147's rollup
-- read them; a later cost-price edit must not be able to restate a settled
-- return.
--
-- ── Money rule ──────────────────────────────────────────────────────────────
-- Every *_kobo column is BIGINT. int4 caps at ₦21,474,836.47 and rejects larger
-- amounts on push with 22003, which jams the outbox (see 0130). A full van
-- return is exactly the kind of figure that clears ₦21M.
--
-- ── The crate seam ──────────────────────────────────────────────────────────
-- `crate_shells` is NULLABLE and WRITE-ONLY: no v1 UI sets it. It exists so the
-- later crate pass can backfill deposit liability from real history instead of
-- starting blind. NULL means "never captured", which is deliberately different
-- from 0. `shells_back` next to it is the v1 swap-only memo count (spec §11) —
-- counting only, no deposit money, no crate-pool writes.
--
-- DEPLOY ORDER: push this BEFORE the v74 app reaches a device, or the
-- van_return_events upserts the app enqueues would 42P01 (relation does not
-- exist) cloud-side — the land-the-migration-first rule.
--
-- MIGRATION-NUMBER LANE: 0165 is #143's. 0161 (#140), 0162 (#141), 0163 (#144)
-- and 0164 (#142) are already on main.

BEGIN;

-- ═══ 1. van_return_events ═══════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.van_return_events (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  trip_id         UUID        NOT NULL REFERENCES public.van_trips(id)  ON DELETE CASCADE,
  product_id      UUID        NOT NULL REFERENCES public.products(id)   ON DELETE RESTRICT,
  -- Units as the manager PHYSICALLY COUNTED them. The return form never
  -- pre-fills a system-derived figure (spec §7.3): with unsynced driver sales in
  -- flight, "everything the system thinks is left" turns those sales into
  -- over-returns and misstates the shortage. The client blocks a count above
  -- what is still out on the trip's lots (spec §9.3 #11).
  quantity        INTEGER     NOT NULL CHECK (quantity > 0),
  condition       TEXT        NOT NULL CHECK (condition IN ('good','damaged')),
  -- The load-price value credited to the driver — the FIFO sum over the lot
  -- segments this return consumed. 0 for damaged, enforced below.
  credit_kobo     BIGINT      NOT NULL DEFAULT 0 CHECK (credit_kobo >= 0),
  -- The SNAPSHOTTED cost basis drawn from those same segments. For a good
  -- return it is what the warehouse re-batches at; for a damaged one it is the
  -- company loss. 0 only when the consumed lots were themselves uncosted.
  cost_kobo       BIGINT      NOT NULL DEFAULT 0 CHECK (cost_kobo >= 0),
  -- Empty-crate shells coming back with this line (spec §11). COUNTING ONLY.
  shells_back     INTEGER     NOT NULL DEFAULT 0 CHECK (shells_back >= 0),
  -- Write-only seam for the later crate pass. No v1 UI sets it; NULL means
  -- "never captured", deliberately different from 0.
  crate_shells    INTEGER     CHECK (crate_shells IS NULL OR crate_shells >= 0),
  recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  recorded_by     UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- §5.5 in the schema: a damaged return can NEVER carry a credit.
  CONSTRAINT van_return_events_damaged_no_credit CHECK (
    condition = 'good' OR credit_kobo = 0
  )
);

-- Incremental-pull cursor index — mirrors every other tenant table.
CREATE INDEX IF NOT EXISTS idx_van_return_events_business_lua
  ON public.van_return_events (business_id, last_updated_at);
-- A trip's returns in the order they were recorded (the reconcile list, #145).
CREATE INDEX IF NOT EXISTS idx_van_return_events_trip_recorded
  ON public.van_return_events (trip_id, recorded_at);
-- #145 splits a trip's returns by condition: good returns are half of
-- recovered_kobo, damaged ones are the damage-loss disclosure at cost.
CREATE INDEX IF NOT EXISTS idx_van_return_events_business_trip_condition
  ON public.van_return_events (business_id, trip_id, condition);

DROP TRIGGER IF EXISTS bump_van_return_events_last_updated_at ON public.van_return_events;
CREATE TRIGGER bump_van_return_events_last_updated_at
  BEFORE UPDATE ON public.van_return_events
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ═══ 2. Row Level Security ══════════════════════════════════════════════════
-- current_user_business_ids(), NEVER an inline user_businesses subquery — that
-- hits auth_user_id-drift 42501 push failures (see 0162/0157/0132/0105/0102).
ALTER TABLE public.van_return_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "van_return_events_tenant_rw" ON public.van_return_events
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- ═══ 3. Realtime ════════════════════════════════════════════════════════════
-- Insert-only in v1 (a return is never edited; a correction is a new event), so
-- it is NOT in the enqueueDelete / realtime-DELETE set. REPLICA IDENTITY FULL
-- all the same, matching its three siblings from 0162: it costs nothing on an
-- insert-only table and future-proofs any UPDATE/DELETE against the realtime RLS
-- authorize, which reads business_id out of the old record.
ALTER TABLE public.van_return_events REPLICA IDENTITY FULL;

ALTER PUBLICATION supabase_realtime ADD TABLE public.van_return_events;

-- ═══ 4. pos_pull_snapshot ═══════════════════════════════════════════════════
-- Add the table to the tenant-table array so a FRESH DEVICE's first/full sync
-- (since = NULL) pulls it. Omit this and the table syncs incrementally forever
-- but never arrives on a new device.
--
-- Carries forward the full 0162 union (the authoritative list) with
-- 'van_return_events' inserted immediately after 'van_trip_lots' — FK-safe: its
-- parents are van_trips (right before it) and products (far earlier).
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
    -- 0157: persisted day close snapshot (#174).
    'daily_closings',
    -- 0162: Van Sales (#141). FK-safe among themselves in this order; their
    -- other parents (stores, users, products) are pulled far earlier above.
    -- 0165 (#143) inserts van_return_events after its parent van_trip_lots'
    -- sibling van_trips, and before the ledger rows that reference it.
    'van_trips','van_trip_lots','van_return_events','driver_ledger_entries',
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

GRANT EXECUTE ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz)
  TO authenticated;

COMMIT;
