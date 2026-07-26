-- 0163_van_sales_remittance.sql
--
-- Reebaplus — Van Sales 5/8: driver payments (#144, PRD #139 as amended by
-- #161, ADR 0019 decision 2, design record `docs/design/van-sales-spec.md`
-- §4.7 / §5.3 / §8.2).
--
-- The cloud half of Drift schema v72. No new table: `payment_transactions`
-- grows a SIXTH parent and a SEVENTH type.
--
--   · van_trip_id  — a nullable FK to van_trips, joined into the hard
--                    exactly-one-parent CHECK.
--   · type         — widened with 'van_remittance'.
--
-- ── Why a remittance is a payment row at all ────────────────────────────────
--
-- ADR 0019 decision 2, "cash follows custody": a road sale writes NO payment
-- row (that lands in #142, the next slice). The manager-recorded remittance is
-- therefore the ONE moment van money enters the cash books — and it enters on
-- the day the money physically arrived, store-stamped to the SOURCE WAREHOUSE
-- (never the van, which is excluded from every per-store figure). Before this
-- migration the remittance existed only on the driver ledger, which the Daily
-- Reconciliation never reads, so remitted cash was invisible to the owner.
--
-- It is deliberately NOT type 'sale'. "Cash sales" stays sale-only; these rows
-- feed the separate "Cash from drivers" line (#147). Any report that folds
-- van_remittance into a sales figure double-counts road revenue that was
-- already recognised when the driver rang it.
--
-- ── Why the remittance needed a new parent ──────────────────────────────────
--
-- The table's exactly-one-parent CHECK (0001) admits order / shipment /
-- expense / wallet_txn / delivery. A remittance is none of those — the TRIP is
-- its cause — so the row could not be written at all without the sixth column.
-- Widening the CHECK rather than relaxing it to `<= 1` keeps the invariant that
-- every payment row is traceable to exactly one source record.
--
-- ── Ordering rule this migration obeys ──────────────────────────────────────
-- Both CHECK edits are WIDENINGS, so every existing row stays valid: a row that
-- satisfied "exactly one of five" still satisfies "exactly one of six", because
-- van_trip_id is NULL on all of them. Nothing is rewritten, no data moves.
-- Postgres alters a CHECK in place (unlike SQLite, where the client side of
-- this change is a full table rebuild — Drift's v72 step), so there are no
-- index or trigger concerns beyond re-baking the append-only guard below.
--
-- DEPLOY ORDER: push this BEFORE any v72 client pushes a payment row carrying
-- `van_trip_id` or a row of type `van_remittance` — otherwise the upsert
-- references an unknown column / trips the old CHECK and jams the outbox
-- (the land-the-migration-first rule).
--
-- MIGRATION-NUMBER LANE: 0163 is #144's. 0161 (#140) and 0162 (#141) precede
-- it. Later van slices own 0164 (#142) and 0165 (#143).
--
-- All *_kobo columns are untouched here and remain BIGINT (0130).
--
-- pos_pull_snapshot is deliberately NOT re-declared: `payment_transactions` is
-- already in its tenant-table array (0001, carried forward through 0162), and a
-- new COLUMN rides along in `SELECT *`. Only a new TABLE needs the array edit.

BEGIN;

-- ═══ 1. payment_transactions.van_trip_id ════════════════════════════════════
-- Nullable + additive: existing rows are untouched and stay NULL, which is
-- exactly what the widened parent CHECK expects of them.
ALTER TABLE public.payment_transactions
  ADD COLUMN IF NOT EXISTS van_trip_id uuid REFERENCES public.van_trips(id);

-- "Cash from drivers" (#147) and a trip's remittance list (#145) both scan by
-- trip. Mirrors the client's idx_payment_txn_van_trip.
CREATE INDEX IF NOT EXISTS idx_payment_txn_van_trip
  ON public.payment_transactions (business_id, van_trip_id);

-- ═══ 2. Widen the type CHECK with 'van_remittance' ══════════════════════════
-- The constraint was named `payment_transactions_type_check` by 0153; before
-- that it was the unnamed inline CHECK from 0001. Look it up by definition so
-- this works against either shape, then re-add the widened form under the
-- stable name. Idempotent: a CHECK that already admits van_remittance is left
-- alone. (Same pattern as 0153 / 0149.)
DO $$
DECLARE
  v_conname text;
  v_def     text;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%type%'
     AND pg_get_constraintdef(c.oid) ILIKE '%sale%'
   LIMIT 1;

  -- Already widened (idempotent re-run) — nothing to do.
  IF v_def IS NOT NULL AND v_def ILIKE '%van_remittance%' THEN
    RETURN;
  END IF;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_conname
    );
  END IF;

  ALTER TABLE public.payment_transactions
    ADD CONSTRAINT payment_transactions_type_check
    CHECK (type IN
      ('sale','purchase','expense','refund','wallet_topup','crate_deposit',
       'van_remittance'));
END $$;

-- ═══ 3. Widen the exactly-one-parent CHECK with van_trip_id ═════════════════
-- The parent CHECK is the unnamed inline one from 0001 (its column list was
-- rewritten in place by 0046's purchase_id → shipment_id rename, so it reads
-- shipment_id today). Find it by definition — it is the only CHECK on this
-- table mentioning wallet_txn_id — drop it, and re-add the six-way form under
-- a stable name so a future slice can find it by name. Idempotent: a CHECK
-- that already counts van_trip_id is left alone.
DO $$
DECLARE
  v_conname text;
  v_def     text;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%wallet_txn_id%'
   LIMIT 1;

  -- Already widened (idempotent re-run) — nothing to do.
  IF v_def IS NOT NULL AND v_def ILIKE '%van_trip_id%' THEN
    RETURN;
  END IF;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_conname
    );
  END IF;

  ALTER TABLE public.payment_transactions
    ADD CONSTRAINT payment_transactions_one_parent_check
    CHECK (
      (order_id      IS NOT NULL)::int +
      (shipment_id   IS NOT NULL)::int +
      (expense_id    IS NOT NULL)::int +
      (wallet_txn_id IS NOT NULL)::int +
      (delivery_id   IS NOT NULL)::int +
      (van_trip_id   IS NOT NULL)::int = 1
    );
END $$;

-- ═══ 4. Re-bake the append-only trigger so van_trip_id is guarded ═══════════
-- The append-only guard bakes its column list into TG_ARGV at CREATE time
-- (0110), so a newly-added column is otherwise unguarded and could be edited
-- after insert. Rebuild from information_schema minus the void columns — the
-- exact 0110/0153 recipe, scoped to this one table. Idempotent.
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(quote_literal(column_name), ',' ORDER BY ordinal_position)
    INTO cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'payment_transactions'
     AND column_name NOT IN
         ('voided_at','voided_by','void_reason','last_updated_at');

  EXECUTE format(
    'DROP TRIGGER IF EXISTS trg_payment_transactions_append_only '
    'ON public.payment_transactions'
  );
  EXECUTE format(
    'CREATE TRIGGER trg_payment_transactions_append_only '
    'BEFORE UPDATE ON public.payment_transactions '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   \d public.payment_transactions
--     -- van_trip_id present, uuid, FK → van_trips(id)
--
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conname = 'payment_transactions_type_check';
--     -- expect 7 values, ending in 'van_remittance'
--
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conname = 'payment_transactions_one_parent_check';
--     -- expect the six-way sum = 1
--
--   -- Teeth: a parentless row and a two-parent row must both be rejected.
--   INSERT INTO public.payment_transactions
--     (business_id, amount_kobo, method, type)
--     VALUES ('<biz>', 1, 'cash', 'van_remittance');           -- expect 23514
--
--   -- And every EXISTING row still satisfies the widened parent CHECK:
--   SELECT count(*) FROM public.payment_transactions
--    WHERE ((order_id IS NOT NULL)::int + (shipment_id IS NOT NULL)::int +
--           (expense_id IS NOT NULL)::int + (wallet_txn_id IS NOT NULL)::int +
--           (delivery_id IS NOT NULL)::int + (van_trip_id IS NOT NULL)::int) <> 1;
--     -- expect 0
-- =============================================================================
