-- 0162_van_sales_trips.sql
--
-- Reebaplus — Van Sales 2/8: load a van (#141, PRD #139 as amended by #161,
-- ADR 0019, design record `docs/design/van-sales-spec.md` §4.2–§4.4).
--
-- Three new synced tenant tables, the cloud half of Drift schema v71:
--
--   · van_trips             — the `open → closed` trip aggregate: van + driver
--                             + source warehouse + opening stamp, plus the
--                             CLOSE ARTIFACT columns that #145 writes.
--   · van_trip_lots         — the priced FIFO load layer. Carries BOTH the load
--                             price (what the driver is accountable for) and
--                             the unit cost SNAPSHOTTED from the source
--                             warehouse's FIFO batches at dispatch.
--   · driver_ledger_entries — the append-only consignment ledger. Balance =
--                             SUM(signed_amount_kobo); negative = driver owes.
--
-- ── The two rules this migration encodes ────────────────────────────────────
--
-- 1. ONE OPEN TRIP PER VAN AND PER DRIVER. The two PARTIAL UNIQUE indexes
--    (`WHERE status = 'open'`) are what make a double-open impossible across two
--    offline manager devices that never saw each other's write. The client
--    blocks locally first (VanTripsDao.dispatchLoad); this is the second line of
--    defence, and the loser's push lands in the existing orphan/reject flow with
--    a terminal reason — the Sync Issues screen is the recovery surface.
--
-- 2. COST TRAVELS WITH THE LOAD. `van_trip_lots.unit_cost_kobo` is the van's
--    cost truth (ADR 0019 decision 1) — NOT a cost_batches row on the van store,
--    which would put the same goods in two queues and make per-trip COGS depend
--    on the order offline sales sync. Nothing in this migration creates van-side
--    batches, and nothing should.
--
-- ── Money rule ──────────────────────────────────────────────────────────────
-- Every *_kobo column is BIGINT. int4 caps at ₦21,474,836.47 and rejects larger
-- amounts on push with 22003, which jams the outbox (see 0130). A full van load
-- is exactly the kind of figure that clears ₦21M.
--
-- ── Naming collision — READ THIS ────────────────────────────────────────────
-- The dormant `drivers` / `delivery_receipts` tables (registered for sync, in
-- pos_pull_snapshot, with no DAO/provider/UI on the client) are a DIFFERENT AXIS
-- and are left untouched. A van-sales driver is a `users` row holding the seeded
-- Driver role (0161), assigned to a van through `user_stores`.
-- `van_trips.driver_user_id` therefore references `public.users`, never
-- `public.drivers`. Retiring the legacy pair is a separate dead-code sweep, not
-- van-sales work (spec §14).
--
-- DEPLOY ORDER: push this BEFORE the v71 app reaches a device, or the van_trips
-- / van_trip_lots / driver_ledger_entries upserts the app enqueues would 42P01
-- (relation does not exist) cloud-side — the land-the-migration-first rule.
--
-- MIGRATION-NUMBER LANE: 0162 is #141's. 0161 is #140's (already on main).
-- Later van slices own 0163 (#144), 0164 (#142), 0165 (#143).

BEGIN;

-- ═══ 1. van_trips ═══════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.van_trips (
  id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id            UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  -- The van: a stores row with kind = 'van' (0161).
  van_store_id           UUID        NOT NULL REFERENCES public.stores(id)     ON DELETE RESTRICT,
  -- The driver: a users row holding the seeded Driver role. NOT public.drivers.
  driver_user_id         UUID        NOT NULL REFERENCES public.users(id)      ON DELETE RESTRICT,
  -- The warehouse this trip loads from. One warehouse per trip in v1.
  source_store_id        UUID        NOT NULL REFERENCES public.stores(id)     ON DELETE RESTRICT,
  status                 TEXT        NOT NULL DEFAULT 'open'
                                     CHECK (status IN ('open','closed')),
  opened_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  opened_by              UUID        REFERENCES public.users(id)               ON DELETE SET NULL,
  closed_at              TIMESTAMPTZ,
  closed_by              UUID        REFERENCES public.users(id)               ON DELETE SET NULL,
  -- True when the trip closed with a residual the driver still owes (spec
  -- §9.4 #14). The residual carries forward on their cross-trip balance.
  closed_with_balance    BOOLEAN     NOT NULL DEFAULT FALSE,
  -- Empty-crate shell memo counts (spec §11). COUNTING ONLY in v1: no deposit
  -- money, no crate_ledger writes, no crate-pool balance change. They exist so
  -- the later crate pass inherits history instead of starting blind — a
  -- 100-crate load carries ~₦180,000 of deposit-value shells.
  shells_out             INTEGER     NOT NULL DEFAULT 0 CHECK (shells_out  >= 0),
  shells_back            INTEGER     NOT NULL DEFAULT 0 CHECK (shells_back >= 0),
  -- Set when a late-syncing road sale forces a post-close restatement (spec
  -- §9.4 #15). Written by #145.
  restated_at            TIMESTAMPTZ,
  restated_reason        TEXT,
  -- ── CLOSE ARTIFACT (written once at close by #145; 0 while the trip is open)
  -- Declared NOW so #145 needs no migration of its own and cannot collide with
  -- a parallel branch over a version number. Reports READ these; they never
  -- re-derive van P&L (ADR 0019 decision 3).
  --
  -- DOUBLE-COUNT GUARD: `consumed` already includes shortage and damaged units,
  -- so their cost is inside cogs_kobo. shortage_loss_kobo / damage_loss_kobo are
  -- DISCLOSURE fields, persisted so a report can show WHY profit is what it is.
  -- Any report that subtracts them again is wrong — profit == recovered − cogs.
  cogs_kobo              BIGINT      NOT NULL DEFAULT 0,
  recovered_kobo         BIGINT      NOT NULL DEFAULT 0,
  unremitted_kobo        BIGINT      NOT NULL DEFAULT 0,
  shortage_writeoff_kobo BIGINT      NOT NULL DEFAULT 0,
  damage_writeoff_kobo   BIGINT      NOT NULL DEFAULT 0,
  shortage_loss_kobo     BIGINT      NOT NULL DEFAULT 0,
  damage_loss_kobo       BIGINT      NOT NULL DEFAULT 0,
  profit_kobo            BIGINT      NOT NULL DEFAULT 0,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- A closed trip carries its close stamp; an open one must not.
  CONSTRAINT van_trips_close_stamp CHECK (
    (status = 'closed' AND closed_at IS NOT NULL) OR
    (status = 'open'   AND closed_at IS NULL)
  )
);

-- Incremental-pull cursor index — mirrors every other tenant table.
CREATE INDEX IF NOT EXISTS idx_van_trips_business_lua
  ON public.van_trips (business_id, last_updated_at);
-- The two open-trip probes the client runs before EVERY dispatch.
CREATE INDEX IF NOT EXISTS idx_van_trips_business_van_status
  ON public.van_trips (business_id, van_store_id, status);
CREATE INDEX IF NOT EXISTS idx_van_trips_business_driver_status
  ON public.van_trips (business_id, driver_user_id, status);

-- ── THE UNIQUENESS THAT MAKES DOUBLE-OPEN IMPOSSIBLE (spec §4.2) ────────────
-- Partial, so a van/driver may hold ANY number of CLOSED trips and at most one
-- open one. Deliberately NOT business-scoped: a stores/users row belongs to
-- exactly one business already, so scoping would only weaken the guarantee.
CREATE UNIQUE INDEX IF NOT EXISTS van_trips_one_open_per_van
  ON public.van_trips (van_store_id)   WHERE status = 'open';
CREATE UNIQUE INDEX IF NOT EXISTS van_trips_one_open_per_driver
  ON public.van_trips (driver_user_id) WHERE status = 'open';

DROP TRIGGER IF EXISTS bump_van_trips_last_updated_at ON public.van_trips;
CREATE TRIGGER bump_van_trips_last_updated_at
  BEFORE UPDATE ON public.van_trips
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ═══ 2. van_trip_lots ═══════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.van_trip_lots (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  trip_id           UUID        NOT NULL REFERENCES public.van_trips(id)  ON DELETE CASCADE,
  product_id        UUID        NOT NULL REFERENCES public.products(id)   ON DELETE RESTRICT,
  quantity          INTEGER     NOT NULL CHECK (quantity > 0),
  -- The FIFO draw-down cursor for return credits (#143): a good return credits
  -- at the OLDEST remaining lot's price first and decrements this. The ONLY
  -- column of a lot that is ever mutated after dispatch.
  qty_remaining     INTEGER     NOT NULL CHECK (qty_remaining >= 0),
  -- Per unit. What the driver is accountable for: defaults to the retail tier
  -- at the picker, editable per line before dispatch, and the single valuation
  -- for the whole reconciliation (loads, returns, shortages, write-offs).
  load_price_kobo   BIGINT      NOT NULL CHECK (load_price_kobo >= 0),
  -- Per unit, SNAPSHOTTED at dispatch from the warehouse's FIFO draw-down. 0
  -- ONLY when the source batches were genuinely uncosted — such a lot flows
  -- into the app's existing Uncosted transparency bucket and must never
  -- silently become free goods (spec §9.1 #2).
  unit_cost_kobo    BIGINT      NOT NULL DEFAULT 0 CHECK (unit_cost_kobo >= 0),
  dispatched_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- The CLIENT IDEMPOTENCY KEY for the dispatch event (spec §7.1). One dispatch
  -- = one id across all its lines; a retry after a timeout or a double-tap
  -- re-uses it and the whole write is a no-op — never a second ledger debit.
  dispatch_event_id UUID        NOT NULL,
  -- Shell memo count for this line (spec §11). Counting only.
  shells_out        INTEGER     NOT NULL DEFAULT 0 CHECK (shells_out >= 0),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT van_trip_lots_cursor CHECK (qty_remaining <= quantity),
  -- The idempotency contract, ENFORCED: one dispatch event contributes at most
  -- one lot per product (the client collapses duplicate product lines before
  -- writing). Without this the key would only be a convention.
  CONSTRAINT uq_van_trip_lots_dispatch_product UNIQUE (dispatch_event_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_van_trip_lots_business_lua
  ON public.van_trip_lots (business_id, last_updated_at);
-- Oldest-lot-first scan — the FIFO cursor a good return credits against.
CREATE INDEX IF NOT EXISTS idx_van_trip_lots_trip_dispatched
  ON public.van_trip_lots (trip_id, dispatched_at, id);
-- The idempotency probe: "has this dispatch event already been applied?"
CREATE INDEX IF NOT EXISTS idx_van_trip_lots_dispatch_event
  ON public.van_trip_lots (business_id, dispatch_event_id);

DROP TRIGGER IF EXISTS bump_van_trip_lots_last_updated_at ON public.van_trip_lots;
CREATE TRIGGER bump_van_trip_lots_last_updated_at
  BEFORE UPDATE ON public.van_trip_lots
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ═══ 3. driver_ledger_entries ═══════════════════════════════════════════════
-- Modelled directly on supplier_ledger_entries (0102): append-only, signed,
-- void by an opposite-sign COMPENSATING row — the original is marked, never
-- edited or deleted. `scrubCreatedAt: true` on the client side (the cloud owns
-- created_at; a void re-push that carried it would trip the immutable-column
-- guard, P0001, and orphan the row).
--
-- A SALE WRITES NO ROW HERE. That is the invariant that makes the balance a
-- clean measure of `loaded − returned − paid`: loading debits the full
-- load-price value ("they signed for the van"), and only returns, remittances
-- and write-offs credit it back. Road takings live on the trip, not here.
CREATE TABLE IF NOT EXISTS public.driver_ledger_entries (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  -- The balance axis, and it is CROSS-TRIP: a residual from a closed trip
  -- follows the person onto their next run.
  driver_user_id     UUID        NOT NULL REFERENCES public.users(id)      ON DELETE RESTRICT,
  -- Nullable only for a cross-trip correction; normally set.
  trip_id            UUID        REFERENCES public.van_trips(id)           ON DELETE SET NULL,
  -- The EVENT, not the sign. Declared with the full v1 set now so no later
  -- slice has to widen this CHECK (which on the client is a table rebuild of an
  -- append-only table carrying two triggers). #141 writes only 'load'.
  type               TEXT        NOT NULL CHECK (type IN (
                       'load','restock','return_good','payment_cash',
                       'payment_transfer','shortage_writeoff','damage_writeoff',
                       'restatement','void')),
  amount_kobo        BIGINT      NOT NULL CHECK (amount_kobo >= 0),
  -- Debits negative, credits positive. Balance = SUM of this column.
  signed_amount_kobo BIGINT      NOT NULL,
  -- WHAT caused the row, so a balance line traces back to the physical event.
  reference_type     TEXT        NOT NULL CHECK (reference_type IN (
                       'van_trip_lot','van_return_event','payment_transaction',
                       'van_trip','driver_ledger_entry')),
  reference_id       UUID,
  -- Remittance proof (#144), mirroring the supplier payment flow. receipt_path
  -- is a DEVICE-LOCAL file path: the string syncs, the image does not.
  payment_method     TEXT,
  receipt_path       TEXT,
  reference_note     TEXT,
  -- Dispatch date (load) | paid-on date (remittance) | recorded date (return).
  activity_date      TIMESTAMPTZ NOT NULL,
  performed_by       UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  voided_at          TIMESTAMPTZ,
  voided_by          UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  void_reason        TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- The sign invariant: a signed amount is the amount or its negation and
  -- nothing else, so no row can contribute a figure its amount doesn't account
  -- for.
  CONSTRAINT driver_ledger_signed_matches_amount CHECK (
    signed_amount_kobo = amount_kobo OR signed_amount_kobo = -amount_kobo
  )
);

CREATE INDEX IF NOT EXISTS idx_driver_ledger_entries_business_lua
  ON public.driver_ledger_entries (business_id, last_updated_at);
-- Driver ledger history, newest first (mirrors the supplier ledger's index).
CREATE INDEX IF NOT EXISTS idx_driver_ledger_business_driver_time
  ON public.driver_ledger_entries (business_id, driver_user_id, created_at);
-- The per-trip ledger slice #145's close artifact sums.
CREATE INDEX IF NOT EXISTS idx_driver_ledger_business_trip
  ON public.driver_ledger_entries (business_id, trip_id);

DROP TRIGGER IF EXISTS bump_driver_ledger_entries_last_updated_at ON public.driver_ledger_entries;
CREATE TRIGGER bump_driver_ledger_entries_last_updated_at
  BEFORE UPDATE ON public.driver_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- ═══ 4. Row Level Security ══════════════════════════════════════════════════
-- current_user_business_ids(), NEVER an inline user_businesses subquery — that
-- hits auth_user_id-drift 42501 push failures (see 0157/0132/0105/0102).
ALTER TABLE public.van_trips             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.van_trip_lots         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.driver_ledger_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "van_trips_tenant_rw" ON public.van_trips
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

CREATE POLICY "van_trip_lots_tenant_rw" ON public.van_trip_lots
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

CREATE POLICY "driver_ledger_entries_tenant_rw" ON public.driver_ledger_entries
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- ═══ 5. Realtime ════════════════════════════════════════════════════════════
-- van_trips and van_trip_lots are UPDATEd after insert (the close artifact and
-- the return cursor), driver_ledger_entries on a void — so all three get
-- REPLICA IDENTITY FULL, which makes an UPDATE's record carry business_id for
-- the realtime RLS authorize (and future-proofs any DELETE). None of the three
-- is ever hard-deleted, so none is in the enqueueDelete / realtime-DELETE set.
ALTER TABLE public.van_trips             REPLICA IDENTITY FULL;
ALTER TABLE public.van_trip_lots         REPLICA IDENTITY FULL;
ALTER TABLE public.driver_ledger_entries REPLICA IDENTITY FULL;

ALTER PUBLICATION supabase_realtime ADD TABLE public.van_trips;
ALTER PUBLICATION supabase_realtime ADD TABLE public.van_trip_lots;
ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_ledger_entries;

-- ═══ 6. pos_pull_snapshot ═══════════════════════════════════════════════════
-- Add the three tables to the tenant-table array so a FRESH DEVICE's first/full
-- sync (since = NULL) pulls them. Omit this and the tables sync incrementally
-- forever but never arrive on a new device.
--
-- Carries forward the full 0157 union (the authoritative list) with the three
-- names inserted immediately after 'daily_closings', in FK-safe order among
-- themselves: van_trips → van_trip_lots → driver_ledger_entries. Their other
-- parents (stores, users, products) all appear far earlier in the array.
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
    'van_trips','van_trip_lots','driver_ledger_entries',
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
--   \d public.van_trips              -- close-artifact *_kobo all BIGINT
--   \d public.van_trip_lots          -- load_price_kobo + unit_cost_kobo BIGINT
--   \d public.driver_ledger_entries  -- amount/signed BIGINT
--
--   -- The two partial-unique indexes exist and are partial:
--   SELECT indexname, indexdef FROM pg_indexes
--     WHERE tablename = 'van_trips' AND indexname LIKE 'van_trips_one_open%';
--     -- expect both defs to end in: WHERE ((status = 'open'::text))
--
--   -- The idempotency constraint:
--   SELECT conname FROM pg_constraint
--     WHERE conrelid = 'public.van_trip_lots'::regclass AND contype = 'u';
--     -- expect: uq_van_trip_lots_dispatch_product
--
--   SELECT polname FROM pg_policy WHERE polrelid IN (
--     'public.van_trips'::regclass, 'public.van_trip_lots'::regclass,
--     'public.driver_ledger_entries'::regclass);
--     -- expect the three *_tenant_rw policies
--
--   SELECT tablename FROM pg_publication_tables
--     WHERE pubname = 'supabase_realtime'
--       AND tablename IN ('van_trips','van_trip_lots','driver_ledger_entries');
--     -- expect all three
--
--   -- Double-open is impossible (run as a tenant; the second must fail 23505):
--   --   INSERT INTO van_trips (...same van..., status) VALUES (..., 'open');
-- =============================================================================
