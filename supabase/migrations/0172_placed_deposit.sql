-- 0172_placed_deposit.sql
--
-- #212 / PRD #203, ADR 0023 rules 1, 2 and 6 — Crate deposit outflow 3/8:
-- the Placed Deposit, and the manager who confirms it.
--
-- Cloud twin of Drift schemaVersion 79
-- (lib/core/database/app_database.dart, the `from < 79` upgrade step).
--
-- The first slice of PRD #203 where crate money actually moves.
--
-- WHAT THIS ADDS
--
--   1. public.supplier_crate_deposit_requests — the APPROVAL QUEUE. A stock
--      keeper may receive a delivery (Gates.receiveStock is stock.add OR
--      products.add), so the crate COUNT lands the instant they type it; the
--      MONEY lands here as a `pending` row and waits for a money-permitted
--      role, who may confirm it, adjust the amount first (a part payment, a
--      waived deposit) or reject it. Rejecting NEVER touches the crate counts —
--      the crates physically arrived whatever anyone decides about the cash.
--      Nothing in this table is money that has moved.
--
--   2. public.supplier_crate_deposits — the PLACED DEPOSIT LEDGER, append-only.
--      Balance = SUM(signed_amount_kobo) per (supplier, manufacturer):
--      + = money placed with the supplier, − = money back to us. It is the
--      mirror of the customer's held deposit with the sign flipped — ours drops
--      cash and raises an ASSET, because the money is still ours.
--
--   3. public.payment_transactions.crate_deposit_id — the SEVENTH parent, plus
--      a widened `type` CHECK admitting 'crate_deposit_out' and a widened
--      exactly-one-parent CHECK. Confirming writes BOTH legs in one
--      transaction: the cash out of the drawer and the asset raised (ADR 0019's
--      both-or-neither rule).
--
-- THE MONEY FAMILY — the reason 'crate_deposit_out' is its own type.
--
-- A Placed Deposit is never a `refund`, never an `expense`, never a `void`. It
-- is refundable, so it must never cut profit; booking it as an expense was
-- considered and REJECTED in ADR 0023 because profit would sag on delivery days
-- and spike inexplicably on the day a supplier relationship ends. Releasing held
-- money in the wrong family is not hypothetical: it is exactly the defect #190
-- and #201 had to fix on the CUSTOMER side, where a deposit coming back was
-- typed `refund` and read as a flat loss in every report while "deposits held"
-- never netted down.
--
-- ONE type covers all of PRD #203 because the SIGN carries the direction —
-- positive = out of the drawer to the supplier (a placement #212, a float
-- top-up #214), negative = back to us (a settlement #213, a float payout #214).
-- That is the in-family reversal rule #190 established, and it works because
-- payment_transactions.amount_kobo carries no >= 0 CHECK (unlike
-- wallet_transactions and supplier_ledger_entries, which do).
--
-- THE RELEASE GATE IS UNTOUCHED. Nothing here moves a figure by itself. Every
-- write path checks the manufacturer's Crate Money Arrangement (#211, 0171)
-- first, and EVERY existing manufacturer on EVERY live tenant reads 'none'. An
-- all-'none' business produces byte-identical figures before and after this
-- migration. Do NOT add a backfill of historic supplier_crate_ledger rows into
-- the new ledger — it would invent money movements that never happened and
-- restate closed days, which ADR 0021 forbids.
--
-- THE RATE is manufacturers.deposit_amount_kobo, the single canonical per-crate
-- rate (ADR 0023 rule 2), SNAPSHOTTED onto every request and every ledger row so
-- a rate edit next month cannot restate money that already moved.
-- crate_size_groups.deposit_amount_kobo is a DEAD column with zero readers and
-- must not be revived as a second, per-size rate.
--
-- THE PAIR is (supplier, manufacturer) — how supplier_crate_balances is already
-- keyed — because only the supplier you actually paid can pay you back, while
-- the rate belongs to the brand.
--
-- ALL *_kobo COLUMNS ARE BIGINT (0130). int4 caps at ₦21.4M and jams the outbox.
--
-- BUILT FOR #213 AND #214 TOO. The movement_type and kind CHECKs already admit
-- 'release' (#213 — empties going back, recording the amount ACTUALLY refunded,
-- which may be less than what was placed) and 'float_topup' / 'float_payout'
-- (#214). Widening a CHECK on an append-only money ledger costs a table rebuild
-- on every device, so the whole set is declared now and those slices ship as
-- code only. `crate_count` is 0 on the float movements and on a standalone
-- settlement that carries no goods.
--
-- RLS: both new tables get a tenant policy built on current_user_business_ids(),
-- NEVER an inline user_businesses subquery — that hits auth_user_id-drift 42501
-- push failures (see 0165/0162/0157/0132/0105/0102).
--
-- DEPLOY ORDERING: deploy this BEFORE shipping the v79 client. The client will
-- push rows to two tables and a column that must already exist; a push against a
-- missing table is rejected and retried (not corrupted), but it jams that
-- device's outbox until this lands. The reverse order is safe: a pre-v79 client
-- simply never writes any of it, and the widened CHECKs reject nothing it sends.

BEGIN;

-- =========================================================================
-- 1. supplier_crate_deposit_requests — the approval queue
--    Created FIRST: supplier_crate_deposits FK-references it.
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.supplier_crate_deposit_requests (
  id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id              UUID        NOT NULL REFERENCES public.businesses(id)    ON DELETE CASCADE,
  supplier_id              UUID        NOT NULL REFERENCES public.suppliers(id)     ON DELETE RESTRICT,
  manufacturer_id          UUID        NOT NULL REFERENCES public.manufacturers(id) ON DELETE RESTRICT,
  -- The store the delivery landed in. NOT NULL because it is the approver
  -- scoping axis: a Manager sees their own stores' requests, the CEO sees all —
  -- exactly how stock_adjustment_requests scopes (0089).
  store_id                 UUID        NOT NULL REFERENCES public.stores(id)        ON DELETE RESTRICT,
  -- #212 writes 'placement'. #213 writes 'release'; #214 the two float kinds.
  kind                     TEXT        NOT NULL
    CHECK (kind IN ('placement','release','float_topup','float_payout')),
  crate_count              INTEGER     NOT NULL DEFAULT 0 CHECK (crate_count >= 0),
  -- manufacturers.deposit_amount_kobo as it stood when the request was raised.
  rate_per_crate_kobo      BIGINT      NOT NULL DEFAULT 0 CHECK (rate_per_crate_kobo >= 0),
  -- crate_count × rate_per_crate_kobo — what the receipt implies is owed.
  requested_amount_kobo    BIGINT      NOT NULL DEFAULT 0 CHECK (requested_amount_kobo >= 0),
  -- What the approver ACTUALLY confirmed, which may be less (a part payment, a
  -- waived deposit) or more. NULL until a decision, and NULL forever on a
  -- rejected request — nothing moved, so there is no amount to record.
  settled_amount_kobo      BIGINT      CHECK (settled_amount_kobo IS NULL OR settled_amount_kobo >= 0),
  -- One of payment_transactions.method, chosen at confirmation.
  payment_method           TEXT,
  -- Denormalised human headline so the approval card renders with no joins.
  summary                  TEXT        NOT NULL,
  -- The crate-count ledger row that raised this. The link is what makes both
  -- halves of ADR 0023 rule 6 auditable as ONE delivery.
  supplier_crate_ledger_id UUID        REFERENCES public.supplier_crate_ledger(id) ON DELETE SET NULL,
  note                     TEXT,
  requested_by             UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  -- Monotonic: pending → confirmed/rejected, never back. The client's
  -- Restore.monotonicStatus enforces the same rule on the way down, so a stale
  -- snapshot cannot resurrect a decided request and invite a second payment
  -- (issue #115).
  status                   TEXT        NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','confirmed','rejected')),
  decided_by               UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  decided_at               TIMESTAMPTZ,
  decision_note            TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_supplier_crate_deposit_requests_business_lua
  ON public.supplier_crate_deposit_requests (business_id, last_updated_at);
CREATE INDEX IF NOT EXISTS idx_supplier_crate_deposit_requests_status
  ON public.supplier_crate_deposit_requests (business_id, status, created_at);

DROP TRIGGER IF EXISTS bump_supplier_crate_deposit_requests_last_updated_at
  ON public.supplier_crate_deposit_requests;
CREATE TRIGGER bump_supplier_crate_deposit_requests_last_updated_at
  BEFORE UPDATE ON public.supplier_crate_deposit_requests
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

COMMENT ON TABLE public.supplier_crate_deposit_requests IS
  '#212 crate deposit outflow (ADR 0023 rule 6): the approval queue for crate '
  'deposit MONEY. A stock keeper may record the crate COUNT; the cash waits for '
  'a money-permitted role, who may confirm, adjust the amount, or reject. '
  'Rejecting never touches the crate counts. Nothing here is money that moved — '
  'the movement is written on confirmation into supplier_crate_deposits plus '
  'its payment_transactions cash leg, in ONE transaction.';

-- =========================================================================
-- 2. supplier_crate_deposits — the append-only Placed Deposit ledger
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.supplier_crate_deposits (
  id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id              UUID        NOT NULL REFERENCES public.businesses(id)    ON DELETE CASCADE,
  supplier_id              UUID        NOT NULL REFERENCES public.suppliers(id)     ON DELETE RESTRICT,
  manufacturer_id          UUID        NOT NULL REFERENCES public.manufacturers(id) ON DELETE RESTRICT,
  -- Nullable, matching supplier_crate_ledger: a standing-float top-up (#214)
  -- belongs to the business, not to a store.
  store_id                 UUID        REFERENCES public.stores(id) ON DELETE SET NULL,
  movement_type            TEXT        NOT NULL
    CHECK (movement_type IN ('placement','release','float_topup','float_payout','adjustment')),
  -- + = money placed with the supplier; − = money back to us. The balance is
  -- the signed sum of this column and nothing else — there is no balance cache
  -- for it to disagree with, deliberately (#160 demoted supplier_crate_balances
  -- to a local-only projection for exactly that reason).
  signed_amount_kobo       BIGINT      NOT NULL,
  -- Crates this movement covers, signed the same way. 0 on the float movements
  -- and on a standalone settlement that carries no goods.
  crate_count              INTEGER     NOT NULL DEFAULT 0,
  rate_per_crate_kobo      BIGINT      NOT NULL DEFAULT 0 CHECK (rate_per_crate_kobo >= 0),
  -- The approved request this came from, when there was one. NULL for a
  -- movement a money-permitted role posted directly and for corrections.
  request_id               UUID        REFERENCES public.supplier_crate_deposit_requests(id) ON DELETE SET NULL,
  supplier_crate_ledger_id UUID        REFERENCES public.supplier_crate_ledger(id)           ON DELETE SET NULL,
  note                     TEXT,
  performed_by             UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_supplier_crate_deposits_business_lua
  ON public.supplier_crate_deposits (business_id, last_updated_at);
-- The balance read: SUM(signed_amount_kobo) over one (supplier, manufacturer)
-- pair — what computeCrateDepositPosition is fed.
CREATE INDEX IF NOT EXISTS idx_supplier_crate_deposits_pair
  ON public.supplier_crate_deposits (business_id, supplier_id, manufacturer_id, created_at);
-- The brand-level roll-up (ADR 0023 rule 4: a shortfall belongs to a brand,
-- across every supplier, because crates are fungible).
CREATE INDEX IF NOT EXISTS idx_supplier_crate_deposits_manufacturer
  ON public.supplier_crate_deposits (business_id, manufacturer_id);

DROP TRIGGER IF EXISTS bump_supplier_crate_deposits_last_updated_at
  ON public.supplier_crate_deposits;
CREATE TRIGGER bump_supplier_crate_deposits_last_updated_at
  BEFORE UPDATE ON public.supplier_crate_deposits
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- Append-only enforcement. This table carries NO void columns, so EVERY column
-- but last_updated_at is immutable: a correction is a new, opposite-signed
-- 'adjustment' row, never an edit of a money row and never a delete. Column
-- list derived from information_schema, the 0001/0057/0163 recipe.
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(quote_literal(column_name), ',' ORDER BY ordinal_position)
    INTO cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'supplier_crate_deposits'
     AND column_name  NOT IN ('last_updated_at');

  EXECUTE 'DROP TRIGGER IF EXISTS trg_supplier_crate_deposits_append_only '
          'ON public.supplier_crate_deposits';
  EXECUTE format(
    'CREATE TRIGGER trg_supplier_crate_deposits_append_only '
    'BEFORE UPDATE ON public.supplier_crate_deposits '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

DROP TRIGGER IF EXISTS trg_supplier_crate_deposits_no_delete
  ON public.supplier_crate_deposits;
CREATE TRIGGER trg_supplier_crate_deposits_no_delete
  BEFORE DELETE ON public.supplier_crate_deposits
  FOR EACH ROW EXECUTE FUNCTION public.forbid_delete();

COMMENT ON TABLE public.supplier_crate_deposits IS
  '#212 crate deposit outflow (ADR 0023 rule 1): the append-only Placed Deposit '
  'ledger. Balance = SUM(signed_amount_kobo) per (supplier, manufacturer); '
  '+ = money placed with the supplier, − = money back to us. It is an ASSET, '
  'never an expense and never a refund — the money is refundable, so it must '
  'never cut profit. Valued at manufacturers.deposit_amount_kobo, snapshotted '
  'per row. A correction is a new opposite-signed ''adjustment'' row.';

-- =========================================================================
-- 3. Row Level Security
--    current_user_business_ids(), NEVER an inline user_businesses subquery.
-- =========================================================================
ALTER TABLE public.supplier_crate_deposit_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "supplier_crate_deposit_requests_tenant_rw"
  ON public.supplier_crate_deposit_requests;
CREATE POLICY "supplier_crate_deposit_requests_tenant_rw"
  ON public.supplier_crate_deposit_requests
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

ALTER TABLE public.supplier_crate_deposits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "supplier_crate_deposits_tenant_rw"
  ON public.supplier_crate_deposits;
CREATE POLICY "supplier_crate_deposits_tenant_rw"
  ON public.supplier_crate_deposits
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- =========================================================================
-- 4. Realtime
--    NEITHER table hard-deletes (the queue is status-flipped; the ledger is
--    append-only and carries a forbid_delete trigger), so neither is in the
--    client's enqueueDelete / realtime-DELETE set. REPLICA IDENTITY FULL all
--    the same, matching 0165: it costs nothing and future-proofs the realtime
--    RLS authorize, which reads business_id out of the OLD record.
-- =========================================================================
ALTER TABLE public.supplier_crate_deposit_requests REPLICA IDENTITY FULL;
ALTER TABLE public.supplier_crate_deposits         REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'supplier_crate_deposit_requests'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.supplier_crate_deposit_requests;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'supplier_crate_deposits'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.supplier_crate_deposits;
  END IF;
END $$;

-- =========================================================================
-- 5. payment_transactions.crate_deposit_id — the SEVENTH parent
--    A supplier crate deposit has no order, no shipment, no expense, no wallet
--    transaction, no delivery and no trip. The deposit IS its cause, and it
--    must not be forced under any of the other six — least of all expense_id,
--    which is the exact mistake ADR 0023 rejects. So the exactly-one-parent
--    CHECK grows rather than the row being left parentless.
-- =========================================================================
ALTER TABLE public.payment_transactions
  ADD COLUMN IF NOT EXISTS crate_deposit_id uuid
    REFERENCES public.supplier_crate_deposits(id);

CREATE INDEX IF NOT EXISTS idx_payment_txn_crate_deposit
  ON public.payment_transactions (business_id, crate_deposit_id);

COMMENT ON COLUMN public.payment_transactions.crate_deposit_id IS
  '#212 (ADR 0023 rule 1): the Placed Deposit ledger row this cash movement is '
  'the other leg of. Set on ''crate_deposit_out'' rows only; NULL on every '
  'other type. The seventh member of the exactly-one-parent CHECK.';

-- =========================================================================
-- 6. Widen the type CHECK with 'crate_deposit_out'
--    Found by definition (0169 gave it the stable name
--    payment_transactions_type_check). Idempotent: a CHECK that already admits
--    the value is left alone.
-- =========================================================================
DO $$
DECLARE
  v_conname text;
  v_def     text;
  v_legacy  bigint;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%wallet_topup%'
   LIMIT 1;

  IF v_def IS NOT NULL AND v_def ILIKE '%crate_deposit_out%' THEN
    RETURN;
  END IF;

  -- 0169's guard, inherited. That migration SKIPPED its narrowing (leaving the
  -- CHECK wide, `purchase` and all) on any database that still held a
  -- `type = 'purchase'` row, because a money row is never deleted to satisfy a
  -- constraint. On such a database this ADD CONSTRAINT would validate against
  -- live data, raise 23514, and — since this whole file is one BEGIN…COMMIT —
  -- roll back the ENTIRE migration, tables and all.
  --
  -- So keep `purchase` in the set when it is still in use. The result is a
  -- CHECK that is wide by one retired value and correct for everything that
  -- matters, on a database that is already in that state. The Drift side takes
  -- the same decision in the v79 upgrade step (`hasPurchasePaymentsAtV79`),
  -- and 0169's own advice still applies: reclassify the rows, then ship the
  -- narrowing as a NEW migration.
  SELECT count(*) INTO v_legacy
    FROM public.payment_transactions
   WHERE type = 'purchase';

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_conname
    );
  END IF;

  IF v_legacy > 0 THEN
    RAISE WARNING
      '0172: % payment_transactions row(s) still have type = ''purchase''; '
      'keeping that value in the CHECK so the deploy does not abort. See 0169.',
      v_legacy;
    ALTER TABLE public.payment_transactions
      ADD CONSTRAINT payment_transactions_type_check
      CHECK (type IN
        ('sale','expense','refund','wallet_topup','crate_deposit',
         'van_remittance','crate_deposit_out','purchase'));
  ELSE
    ALTER TABLE public.payment_transactions
      ADD CONSTRAINT payment_transactions_type_check
      CHECK (type IN
        ('sale','expense','refund','wallet_topup','crate_deposit',
         'van_remittance','crate_deposit_out'));
  END IF;
END $$;

-- =========================================================================
-- 7. Widen the exactly-one-parent CHECK with crate_deposit_id
--    0163 gave it the stable name payment_transactions_one_parent_check; this
--    still finds it by definition so a database that somehow carries the older
--    unnamed inline CHECK is handled too. Both edits are WIDENINGS, so every
--    existing row stays valid (crate_deposit_id is NULL on all of them) and
--    nothing is rewritten.
-- =========================================================================
DO $$
DECLARE
  v_conname text;
  v_def     text;
  v_orphans bigint;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%wallet_txn_id%'
   LIMIT 1;

  IF v_def IS NOT NULL AND v_def ILIKE '%crate_deposit_id%' THEN
    RETURN;
  END IF;

  -- Same refusal-to-abort rule as the type CHECK above. 0163 already enforces
  -- exactly-one-parent, so a violating row should be impossible — but a
  -- DROP-then-ADD that validates against live data is exactly the shape that
  -- rolls the whole migration back if that assumption is ever wrong, and the
  -- post-deploy verification query at the bottom of this file finds out far too
  -- late to help. Check BEFORE dropping.
  SELECT count(*) INTO v_orphans
    FROM public.payment_transactions
   WHERE ((order_id      IS NOT NULL)::int +
          (shipment_id   IS NOT NULL)::int +
          (expense_id    IS NOT NULL)::int +
          (wallet_txn_id IS NOT NULL)::int +
          (delivery_id   IS NOT NULL)::int +
          (van_trip_id   IS NOT NULL)::int) <> 1;

  IF v_orphans > 0 THEN
    RAISE WARNING
      '0172: % payment_transactions row(s) do not satisfy exactly-one-parent; '
      'leaving the six-way CHECK in place rather than aborting the deploy. '
      'Crate deposits cannot be recorded until those rows are reclassified.',
      v_orphans;
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
      (order_id         IS NOT NULL)::int +
      (shipment_id      IS NOT NULL)::int +
      (expense_id       IS NOT NULL)::int +
      (wallet_txn_id    IS NOT NULL)::int +
      (delivery_id      IS NOT NULL)::int +
      (van_trip_id      IS NOT NULL)::int +
      (crate_deposit_id IS NOT NULL)::int = 1
    );
END $$;

-- =========================================================================
-- 8. Re-bake the append-only trigger so crate_deposit_id is guarded
--    The guard bakes its column list into TG_ARGV at CREATE time (0110), so a
--    newly-added column is otherwise unguarded and could be edited after
--    insert. The exact 0110/0153/0163 recipe, scoped to this one table.
-- =========================================================================
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

  EXECUTE 'DROP TRIGGER IF EXISTS trg_payment_transactions_append_only '
          'ON public.payment_transactions';
  EXECUTE format(
    'CREATE TRIGGER trg_payment_transactions_append_only '
    'BEFORE UPDATE ON public.payment_transactions '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

-- =========================================================================
-- 9. pos_pull_snapshot — add both tables to the tenant-table array
--    Omit this and they sync incrementally forever but never arrive on a NEW
--    device. Carries forward the full 0165 list (the authoritative one) with
--    the two new tables inserted after supplier_crate_ledger — FK-safe: their
--    parents are businesses, suppliers, manufacturers, stores, users and
--    supplier_crate_ledger, all pulled earlier, and the requests table precedes
--    the ledger that references it.
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
    'profiles','users','stores','manufacturers','crate_size_groups',
    'categories','products','inventory',
    -- 0132: per-(product, store) FIFO cost queue (ADR 0005).
    'cost_batches',
    'customers','suppliers',
    -- 0101: per-supplier append-only ledger (§21.10).
    'supplier_ledger_entries',
    -- 0117: per-supplier append-only empty-crate ledger (§3.13).
    'supplier_crate_ledger',
    -- 0172 (#212): the crate-deposit approval queue and the append-only Placed
    -- Deposit ledger. The queue precedes the ledger, which FK-references it.
    'supplier_crate_deposit_requests','supplier_crate_deposits',
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
    'saved_carts',
    -- 0093: per-order crate deposit + return queue (§13.4).
    'pending_crate_returns','crate_ledger','manufacturer_crate_balances',
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

-- =============================================================================
-- Verification (run by hand after deploy):
--
--   -- 1. Both tables exist with bigint money columns.
--   SELECT table_name, column_name, data_type
--     FROM information_schema.columns
--    WHERE table_name IN ('supplier_crate_deposits',
--                         'supplier_crate_deposit_requests')
--      AND column_name LIKE '%_kobo'
--    ORDER BY table_name, column_name;
--   -- expect: every row bigint. An int4 caps at ₦21.4M and jams the outbox.
--
--   -- 2. RLS on, and built on current_user_business_ids().
--   SELECT tablename, policyname, qual
--     FROM pg_policies
--    WHERE tablename IN ('supplier_crate_deposits',
--                        'supplier_crate_deposit_requests');
--   -- expect: 2 rows, each qual mentioning current_user_business_ids and NOT
--   -- user_businesses.
--
--   -- 3. The seventh parent, and both widened CHECKs.
--   SELECT conname, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid = 'public.payment_transactions'::regclass
--      AND contype = 'c';
--   -- expect: payment_transactions_type_check listing crate_deposit_out, and
--   -- payment_transactions_one_parent_check summing SEVEN columns.
--
--   -- 4. No existing payment row was invalidated by the widening.
--   SELECT COUNT(*) FROM public.payment_transactions
--    WHERE ((order_id IS NOT NULL)::int + (shipment_id IS NOT NULL)::int +
--           (expense_id IS NOT NULL)::int + (wallet_txn_id IS NOT NULL)::int +
--           (delivery_id IS NOT NULL)::int + (van_trip_id IS NOT NULL)::int +
--           (crate_deposit_id IS NOT NULL)::int) <> 1;
--   -- expect: 0
--
--   -- 5. THE RELEASE GATE — nothing was backfilled and no money has moved.
--   SELECT COUNT(*) FROM public.supplier_crate_deposits;
--   SELECT COUNT(*) FROM public.supplier_crate_deposit_requests;
--   SELECT COUNT(*) FROM public.payment_transactions
--    WHERE type = 'crate_deposit_out';
--   -- expect: 0, 0, 0 immediately after deploy. Every manufacturer is on
--   -- 'none' (0171), so no receipt can raise a deposit until an owner
--   -- deliberately switches a brand on.
--
--   -- 6. Both tables ride the fresh-device snapshot.
--   SELECT prosrc LIKE '%supplier_crate_deposits%' AS ledger_in_snapshot,
--          prosrc LIKE '%supplier_crate_deposit_requests%' AS queue_in_snapshot
--     FROM pg_proc WHERE proname = 'pos_pull_snapshot';
--   -- expect: t | t
--
--   -- 7. Append-only really is enforced on the new ledger.
--   --    (run in a transaction and ROLL BACK)
--   -- UPDATE public.supplier_crate_deposits SET signed_amount_kobo = 1;
--   -- expect: ERROR from enforce_append_only
-- =============================================================================
