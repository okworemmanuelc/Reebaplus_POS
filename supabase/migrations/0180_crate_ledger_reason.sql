-- 0180_crate_ledger_reason.sql
--
-- #297 / #299 — a damage movement carries the reason the owner picked.
--
-- Cloud twin of Drift schemaVersion 83
-- (lib/core/database/app_database.dart, the `from < 83` upgrade step).
--
-- WHAT THIS CHANGES
--
--   crate_ledger gains ONE nullable column, reason TEXT: the reason code picked
--   when crates were lost (broken, burnt, rotten_wood, expired, spilled, theft,
--   other). Set on damaged and full_crate_damage rows; NULL on every other
--   movement and on every row written before 0180.
--
-- A PURE WIDENING. No row changes and nothing is backfilled (ADR 0021).
--
-- APPEND-ONLY, SO THE NEW COLUMN IS FROZEN TOO. The DO block at the end
-- re-derives crate_ledger's enforce_append_only column list from the live schema
-- (the 0110 / 0179 logic) so reason joins the guarded set.
--
-- RLS is untouched: crate_ledger's existing policy covers every column.
--
-- DEPLOY ORDERING: deploy this BEFORE shipping the v83 client. A v83 client
-- pushes `reason`; against a table without the column the push is rejected and
-- retried, which jams that device's outbox until this lands. The reverse is
-- safe: an older client never writes the column.

BEGIN;

ALTER TABLE public.crate_ledger
  ADD COLUMN IF NOT EXISTS reason TEXT;

COMMENT ON COLUMN public.crate_ledger.reason IS
  '#297 / #299: the reason code picked when crates were lost (broken, burnt, '
  'rotten_wood, expired, spilled, theft, other). Set on damaged and '
  'full_crate_damage rows, NULL otherwise and on every row written before 0180.';

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
