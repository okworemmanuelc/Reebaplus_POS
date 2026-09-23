-- 0179_crate_count_movements.sql
--
-- #290 / PRD #284 decision 15 — the whole manufacturer-screen PRD's schema in
-- one migration, so its later slices never fight over a number.
--
-- Cloud twin of Drift schemaVersion 82
-- (lib/core/database/app_database.dart, the `from < 82` upgrade step).
--
-- WHAT THIS CHANGES
--
--   1. crate_ledger.movement_type CHECK widened for
--        count              a Crate Count Correction (store-stamped, attributed)
--        opening_count      the first count of a brand at a store
--        full_crate_damage  the crate leg of a damaged full crate (#299)
--        purchase           crates bought from a manufacturer (#294)
--   2. crate_ledger gains ONE nullable column, rate_per_crate_kobo BIGINT, CHECK
--      >= 0. It holds the per-crate value snapshotted on damage and
--      full-crate-damage rows and the price paid on purchase rows. BIGINT, never
--      int4: an int4 kobo column caps at ₦21.4M and rejects a larger push with
--      22003, which jams the outbox (see 0130).
--   3. crate_shortfall_writeoffs.source CHECK widened for count_shortage — a
--      write-off taken against the count-based Crate Shortage (#296).
--
-- A PURE WIDENING. No row changes: every count written before this stays the
-- `adjusted` it was (ADR 0021 — history is never restated), and the new column
-- is NULL on every existing row. Nothing is backfilled.
--
-- APPEND-ONLY, SO THE NEW COLUMN IS FROZEN TOO. The DO block at the end
-- re-derives crate_ledger's enforce_append_only column list from the live schema
-- (the 0110 logic) so rate_per_crate_kobo joins the guarded set — an edited
-- snapshot would restate a booked loss.
--
-- RLS is untouched: crate_ledger's existing policy covers every column.
--
-- DEPLOY ORDERING: deploy this BEFORE shipping the v82 client. A v82 client
-- pushes `opening_count` / `count` rows; against the old CHECK they are rejected
-- and retried, which jams that device's outbox until this lands. The reverse is
-- safe: an older client never writes the new values or the column.

BEGIN;

-- =========================================================================
-- 1. crate_ledger.movement_type — drop the CHECK by DEFINITION (it was declared
--    inline in 0001, so its name is generated), then re-add it by name.
-- =========================================================================
DO $$
DECLARE
  c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.crate_ledger'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%movement_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.crate_ledger DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

ALTER TABLE public.crate_ledger
  ADD CONSTRAINT crate_ledger_movement_type_check
  CHECK (movement_type IN (
    'issued','returned','damaged','adjusted','transferred_in','transferred_out',
    'count','opening_count','full_crate_damage','purchase'
  ));

-- =========================================================================
-- 2. The per-crate value snapshot
-- =========================================================================
ALTER TABLE public.crate_ledger
  ADD COLUMN IF NOT EXISTS rate_per_crate_kobo BIGINT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'crate_ledger_rate_per_crate_kobo_check'
       AND conrelid = 'public.crate_ledger'::regclass
  ) THEN
    ALTER TABLE public.crate_ledger
      ADD CONSTRAINT crate_ledger_rate_per_crate_kobo_check
      CHECK (rate_per_crate_kobo IS NULL OR rate_per_crate_kobo >= 0);
  END IF;
END $$;

COMMENT ON COLUMN public.crate_ledger.rate_per_crate_kobo IS
  '#290 / PRD #284: one per-crate value in kobo, snapshotted when the row is '
  'written. The crate value on damaged and full_crate_damage rows (so a later '
  'crate value change never restates a booked loss), the price paid on '
  'purchase rows, NULL otherwise and on every row written before 0179.';

-- =========================================================================
-- 3. crate_shortfall_writeoffs.source — + count_shortage
-- =========================================================================
ALTER TABLE public.crate_shortfall_writeoffs
  DROP CONSTRAINT IF EXISTS crate_shortfall_writeoffs_source_check;

ALTER TABLE public.crate_shortfall_writeoffs
  ADD CONSTRAINT crate_shortfall_writeoffs_source_check
  CHECK (source IN ('manual','customer_forfeit','count_shortage'));

-- =========================================================================
-- 4. Re-derive crate_ledger's append-only guard so the new column is frozen
--    (the 0110 logic, for this one table).
-- =========================================================================
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(quote_literal(column_name), ',')
    INTO cols
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name   = 'crate_ledger'
     AND column_name  NOT IN ('voided_at','voided_by','void_reason','last_updated_at');

  EXECUTE 'DROP TRIGGER IF EXISTS trg_crate_ledger_append_only ON public.crate_ledger';
  EXECUTE format(
    'CREATE TRIGGER trg_crate_ledger_append_only BEFORE UPDATE ON public.crate_ledger '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

COMMIT;
