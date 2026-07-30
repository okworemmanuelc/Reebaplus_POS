-- 0173_crate_shortfall_writeoff.sql
--
-- #216 / PRD #203, ADR 0023 rules 4 and 5 — Crate deposit outflow 7/8:
-- the Crate Shortfall, and the deliberate act of accepting the loss.
--
-- Cloud twin of Drift schemaVersion 80
-- (lib/core/database/app_database.dart, the `from < 80` upgrade step).
--
-- WHAT THIS ADDS
--
--   ONE table, public.crate_shortfall_writeoffs. Nothing else — no column on an
--   existing table, no widened CHECK, no RPC.
--
-- WHAT IT DELIBERATELY DOES NOT ADD
--
--   A shortfall column. There is none, and there must never be one.
--
--   A Crate Shortfall is `crates owed − empties on hand`, valued at the
--   manufacturer's rate — DERIVED on every read from supplier_crate_ledger and
--   crate_ledger, which are already here. That is not an implementation
--   preference, it is the behaviour: a shortfall must SHRINK BY ITSELF when
--   crates turn up behind the store, when a driver returns late, when a count
--   was wrong. Storing it as an absolute would freeze a suspicion into a fact
--   and require someone to remember to un-freeze it.
--
--   What IS stored here is the DECISION: N crates, at the rate they were worth
--   that day, accepted by a named person on a named date. Same reasoning ADR
--   0019 used to make a van write-off a persisted artifact rather than a screen
--   calculation — a settlement outcome someone decided at a moment in time must
--   not be re-derivable, or a later count silently restates it.
--
-- BRAND-LEVEL, AND THERE IS NO supplier_id COLUMN
--
--   Crates are fungible. Hold 100 Coke crates from Depot A and 100 from Depot B,
--   lose ten, and nothing on earth says whose they were. Guessing — oldest-first
--   or pro-rata — manufactures a number the supplier will dispute, and a
--   pro-rata split moves one supplier's balance whenever an UNRELATED supplier's
--   count changes (ADR 0023 rule 4, and its Rejected alternatives). So the
--   schema has no field for an attribution to be written into. Attribution
--   happens exactly once: at settlement, when the business actually comes up
--   short with a specific depot.
--
-- THIS IS THE ONE THING IN PRD #203 THAT HITS PROFIT
--
--   Everything else the PRD books is a Placed Deposit (0172) — refundable money
--   of ours held elsewhere, an ASSET that changed shape, which is why it must
--   never cut profit. A write-off is the opposite: the moment an owner says the
--   crates are not coming back, so the deposit value behind them is gone. It is
--   a realized loss, booked on created_at, and it sits in the reconciliation P&L
--   beside crate damages.
--
--   Consequently there is NO payment_transactions leg here, and that absence is
--   the decision. No cash moves when an owner accepts a loss — the money left
--   (or never arrived) long ago. Writing a 'crate_deposit_out' row would show
--   cash moving that nobody handed over, breaking the spine of ADR 0023: a book
--   entry appears only when money genuinely moved.
--
-- NOTHING WRITES OFF ON A TIMER
--
--   There is no scheduled job, no trigger, no `age(...)` predicate and NO
--   BACKFILL in this migration. Profit must never be reduced by a decision
--   nobody made. An owner who ignores the shortfall keeps a silently overstated
--   profit — ADR 0023's Consequences say so explicitly, and the reconciliation
--   card exists to make ignoring it a choice rather than an accident. Do NOT add
--   a sweep that writes off shortfalls older than N days: it would cut profit on
--   a day nobody decided anything, and it would restate closed days, which ADR
--   0021 forbids.
--
-- THE RATE is manufacturers.deposit_amount_kobo (ADR 0023 rule 2), SNAPSHOTTED
-- onto the row. The loss booked is crate_count × rate_per_crate_kobo forever
-- after, never today's rate, so a rate edit next month cannot restate the profit
-- of a day already closed. crate_size_groups.deposit_amount_kobo remains a DEAD
-- column with zero readers and must not be revived.
--
-- APPEND-ONLY, WITH NO VOID COLUMNS. Like supplier_crate_deposits (0172), every
-- column but last_updated_at is frozen. A write-off taken in error — or crates
-- that turn up after being accepted as lost — is corrected by a new NEGATIVE
-- crate_count row that books a GAIN on ITS day. Never an edit, never a delete,
-- never a restatement. The CHECK is `<> 0` rather than `> 0` precisely so that
-- reversal path ships as code only: widening a CHECK on an append-only money
-- ledger costs a table rebuild on every device (the 0172 precedent).
--
-- THE RELEASE GATE IS UNTOUCHED. Every read of these rows checks the brand's
-- Crate Money Arrangement (#211, 0171) first, and EVERY existing manufacturer on
-- EVERY live tenant reads 'none'. A `none` brand has no shortfall, so it has
-- nothing to write off and contributes nothing to profit. An all-'none' business
-- produces byte-identical figures before and after this migration.
--
-- A FLOAT BRAND'S LOSSES RAISE A SHORTFALL BUT MOVE NO MONEY (#214, rule 4).
-- That holds here without a special case: this table moves no money for ANY
-- brand. Lost crates eat float headroom and raise the warning; the supplier has
-- deducted nothing, so nothing is booked until the owner accepts the loss.
--
-- ALL *_kobo COLUMNS ARE BIGINT (0130). int4 caps at ₦21.4M and jams the outbox.
--
-- RLS: current_user_business_ids(), NEVER an inline user_businesses subquery —
-- that hits auth_user_id-drift 42501 push failures (0165/0162/0157/0132/0105).
--
-- DEPLOY ORDERING: deploy this BEFORE shipping the v80 client. The client will
-- push rows to a table that must already exist; a push against a missing table
-- is rejected and retried (not corrupted), but it jams that device's outbox
-- until this lands. The reverse order is safe: a pre-v80 client never writes it.

BEGIN;

-- =========================================================================
-- 1. crate_shortfall_writeoffs — the append-only accepted-loss ledger
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.crate_shortfall_writeoffs (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         UUID        NOT NULL REFERENCES public.businesses(id)    ON DELETE CASCADE,
  -- The brand, and the ONLY axis a shortfall has. There is deliberately no
  -- supplier_id: crates are fungible and guessing whose went missing invents a
  -- fact the supplier will dispute (ADR 0023 rule 4).
  manufacturer_id     UUID        NOT NULL REFERENCES public.manufacturers(id) ON DELETE RESTRICT,
  -- The store whose device took the decision, for the audit trail only. It
  -- never scopes the figure: a shortfall is business-wide, and splitting the
  -- loss per branch would let two stores each believe the same crates were
  -- theirs to lose (CRATE_TRACKING_AUDIT C4).
  store_id            UUID        REFERENCES public.stores(id) ON DELETE SET NULL,
  -- Crates accepted as lost. SIGNED: positive is a write-off, negative is the
  -- compensating row for a reversal. `<> 0` rather than `> 0` so that path
  -- ships as code only — see the header.
  crate_count         INTEGER     NOT NULL CHECK (crate_count <> 0),
  -- manufacturers.deposit_amount_kobo as it stood when the decision was taken.
  -- The loss is crate_count × this, forever after.
  rate_per_crate_kobo BIGINT      NOT NULL DEFAULT 0 CHECK (rate_per_crate_kobo >= 0),
  note                TEXT,
  -- Who accepted the loss, and (created_at) when. Both halves of "who wrote off
  -- a shortage and when is recorded and visible".
  performed_by        UUID        REFERENCES public.users(id) ON DELETE SET NULL,
  -- THE DAY THE LOSS HITS PROFIT. Set explicitly by the client rather than left
  -- to this default, so the decision date is a fact the write path owns rather
  -- than a side effect of when a row reached the database.
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The two reads there are: the brand's net written-off COUNT (which nets out of
-- the derived shortfall on the card) and the period's booked LOSS (the one crate
-- figure that reaches profit). Both scan (business_id, manufacturer_id,
-- created_at).
CREATE INDEX IF NOT EXISTS idx_crate_shortfall_writeoffs_brand
  ON public.crate_shortfall_writeoffs (business_id, manufacturer_id, created_at);
-- The sync push cursor, the shape every synced table carries.
CREATE INDEX IF NOT EXISTS idx_crate_shortfall_writeoffs_business_lua
  ON public.crate_shortfall_writeoffs (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_crate_shortfall_writeoffs_last_updated_at
  ON public.crate_shortfall_writeoffs;
CREATE TRIGGER bump_crate_shortfall_writeoffs_last_updated_at
  BEFORE UPDATE ON public.crate_shortfall_writeoffs
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- Append-only enforcement. No void columns, so EVERY column but last_updated_at
-- is immutable: a reversal is a new negative row, never an edit of a booked
-- loss. Column list derived from information_schema, the 0001/0057/0163/0172
-- recipe.
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(quote_literal(column_name), ',' ORDER BY ordinal_position)
    INTO cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'crate_shortfall_writeoffs'
     AND column_name  NOT IN ('last_updated_at');

  EXECUTE 'DROP TRIGGER IF EXISTS trg_crate_shortfall_writeoffs_append_only '
          'ON public.crate_shortfall_writeoffs';
  EXECUTE format(
    'CREATE TRIGGER trg_crate_shortfall_writeoffs_append_only '
    'BEFORE UPDATE ON public.crate_shortfall_writeoffs '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

DROP TRIGGER IF EXISTS trg_crate_shortfall_writeoffs_no_delete
  ON public.crate_shortfall_writeoffs;
CREATE TRIGGER trg_crate_shortfall_writeoffs_no_delete
  BEFORE DELETE ON public.crate_shortfall_writeoffs
  FOR EACH ROW EXECUTE FUNCTION public.forbid_delete();

COMMENT ON TABLE public.crate_shortfall_writeoffs IS
  '#216 crate deposit outflow (ADR 0023 rules 4 and 5): the deliberate, dated '
  'act of accepting that missing crates are not coming back. The SHORTFALL '
  'itself is never stored — it is crates owed minus empties on hand, derived on '
  'every read, which is what lets it shrink by itself when crates reappear. '
  'This table stores only the DECISION, brand-level and unattributed to any '
  'supplier because crates are fungible. It is the one figure in PRD #203 that '
  'hits profit, on the day it was taken, at the rate snapshotted then. No cash '
  'leg: no money moves when an owner accepts a loss. Nothing writes off on a '
  'timer — profit must never be reduced by a decision nobody made.';

-- =========================================================================
-- 2. Row Level Security
--    current_user_business_ids(), NEVER an inline user_businesses subquery.
-- =========================================================================
ALTER TABLE public.crate_shortfall_writeoffs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "crate_shortfall_writeoffs_tenant_rw"
  ON public.crate_shortfall_writeoffs;
CREATE POLICY "crate_shortfall_writeoffs_tenant_rw"
  ON public.crate_shortfall_writeoffs
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- =========================================================================
-- 3. Realtime
--    The table never hard-deletes (append-only, forbid_delete trigger), so it
--    is not in the client's enqueueDelete / realtime-DELETE set. REPLICA
--    IDENTITY FULL all the same, matching 0165/0172: it costs nothing and
--    future-proofs the realtime RLS authorize, which reads business_id out of
--    the OLD record.
-- =========================================================================
ALTER TABLE public.crate_shortfall_writeoffs REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'crate_shortfall_writeoffs'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.crate_shortfall_writeoffs;
  END IF;
END $$;

COMMIT;
