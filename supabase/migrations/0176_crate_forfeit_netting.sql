-- 0176_crate_forfeit_netting.sql
--
-- #217 / PRD #203, ADR 0023 finding #4 and rule 5 — Crate deposit outflow 8/8:
-- a forfeit that gained nothing stops being reported as a gain.
--
-- Cloud twin of Drift schemaVersion 81
-- (lib/core/database/app_database.dart, the `from < 81` upgrade step).
--
-- WHAT THIS ADDS
--
--   ONE column, public.crate_shortfall_writeoffs.source, NOT NULL DEFAULT
--   'manual', CHECK IN ('manual','customer_forfeit'). Nothing else — no table,
--   no RPC, no backfill, no trigger beyond re-deriving the append-only guard so
--   the new column is frozen with the rest.
--
-- WHY THE SLICE NEEDS A COLUMN AT ALL
--
--   A kept customer crate deposit has booked as INCOME since #176. But the crate
--   belonged to a manufacturer, and the app charges the customer the SAME
--   manufacturers.deposit_amount_kobo it owes that manufacturer's depot. So on a
--   brand where a deposit was genuinely placed, a forfeit nets to ZERO: the
--   customer's money is kept, and the crate that will never come back costs
--   exactly the same amount. The client therefore raises a matching Crate
--   Shortfall write-off in the same transaction as the forfeit, and the two
--   cancel.
--
--   Both origins book the same money on the same P&L line, so the column moves
--   no figure. What it buys is the ability to SAY WHICH — "₦14,000 of this is
--   deposits customers kept; the crates they kept cost you the same" — because a
--   correct figure an owner cannot account for is how a correct figure gets
--   reported as a bug. It also keeps "who accepted this loss and when" naming
--   the person who stood in front of the shortfall card, rather than whichever
--   cashier last confirmed an order.
--
-- ON A 'none' BRAND A FORFEIT STAYS PURE INCOME
--
--   No deposit was ever placed for those crates — they were the business's own
--   to lose — so keeping the customer's money is a REAL gain and it reads
--   exactly as it did before PRD #203 existed. The client's write path checks
--   the brand's Crate Money Arrangement (0171) and writes NO row at all for a
--   'none' brand. Every existing manufacturer on every live tenant is 'none', so
--   this migration cannot move a single tenant's profit.
--
-- HISTORY IS NEVER RESTATED — AND THAT IS WHY THERE IS NO BACKFILL
--
--   The netting applies from the moment an owner switches a brand on, FORWARD
--   ONLY. Whether a given forfeit was netted is settled once, at the instant it
--   was settled, by whether a row was written — never re-decided later from
--   today's setting. A setting flipped on a Tuesday therefore cannot change last
--   March's profit, because there is no pass over history to change it with.
--
--   Do NOT add an UPDATE that raises netting rows for past forfeits, and do NOT
--   relabel existing rows. Both would rewrite closed days, which ADR 0021
--   forbids outright and which #155's persisted day-close snapshots exist to
--   prevent. Reports spanning a brand's switch-on date will show BOTH treatments
--   — pure income before, netted after. That is correct, and it is by design.
--
-- APPEND-ONLY, SO THE NEW COLUMN IS FROZEN TOO. The DO block below re-derives
-- the enforce_append_only column list from information_schema so `source` joins
-- the guarded set. A netting row relabelled 'manual' afterwards would hand an
-- owner a loss nobody took responsibility for; a manual one relabelled
-- 'customer_forfeit' would blame a customer for a decision the owner made.
--
-- NO *_kobo COLUMN IS ADDED, so the 0130 int4 trap does not apply here. RLS is
-- untouched: the table's existing current_user_business_ids() policy already
-- covers every column.
--
-- DEPLOY ORDERING: deploy this BEFORE shipping the v81 client. The client pushes
-- the full row including `source`; a push carrying an unknown column is rejected
-- and retried (not corrupted), but it jams that device's outbox until this
-- lands. The reverse order is safe: a v80 client never writes the column, and
-- the DEFAULT gives its rows the value they always had.

BEGIN;

-- =========================================================================
-- 1. The origin column
-- =========================================================================
ALTER TABLE public.crate_shortfall_writeoffs
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'manual';

-- The value set. Added separately and idempotently so a re-run is a no-op.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'crate_shortfall_writeoffs_source_check'
       AND conrelid = 'public.crate_shortfall_writeoffs'::regclass
  ) THEN
    ALTER TABLE public.crate_shortfall_writeoffs
      ADD CONSTRAINT crate_shortfall_writeoffs_source_check
      CHECK (source IN ('manual','customer_forfeit'));
  END IF;
END $$;

COMMENT ON COLUMN public.crate_shortfall_writeoffs.source IS
  '#217: where this booked crate loss came from. ''manual'' = an owner accepted '
  'it on the Crate Shortfall card. ''customer_forfeit'' = a customer kept the '
  'crates and their deposit with them, so the kept deposit and the lost crate '
  'cancel out (ADR 0023 finding #4). Both book the same money on the same P&L '
  'line; the split exists so the reconciliation can explain to the owner why a '
  'kept deposit no longer reads as profit. Written only on brands whose Crate '
  'Money Arrangement moves money — a ''none'' brand''s forfeit stays pure '
  'income. Never backfilled: the netting applies from switch-on forward only.';

-- =========================================================================
-- 2. Re-derive the append-only guard so `source` is immutable too
--    (the 0175 DO block, re-run now that the column list has grown).
-- =========================================================================
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

COMMIT;
