-- 0187_products_units_per_pack.sql
--
-- #487 — "how many in one": a product can say how many it holds (12 bottles in
-- one crate, 6 pieces in one pack).
--
-- Cloud twin of Drift schemaVersion 84
-- (lib/core/database/app_database.dart, the `from < 84` upgrade step).
--
-- WHAT THIS CHANGES
--
--   products gains ONE nullable column, units_per_pack INTEGER, with a CHECK
--   that a given value is positive. NULL = not given, which is every row
--   written before 0187.
--
-- DISPLAY ONLY. The app shows it ("Crate of 12"); it never feeds stock,
-- prices, crate counts or any money. No RPC reads it and nothing is
-- backfilled.
--
-- RLS is untouched: products' existing policies cover every column. The
-- products sync path is pass-through (no push-column whitelist), and
-- pos_pull_snapshot returns whole rows, so the column round-trips with no
-- other change.
--
-- DEPLOY ORDERING: deploy this BEFORE shipping any client that writes the
-- column. A client pushing `units_per_pack` against a table without it is
-- rejected and retried, which jams that device's outbox until this lands. The
-- reverse is safe: an older client never writes the column, and a v84 client
-- only pushes it once a value is set (nulls are left out of the payload).

BEGIN;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS units_per_pack integer
  CHECK (units_per_pack IS NULL OR units_per_pack > 0);

COMMENT ON COLUMN public.products.units_per_pack IS
  '#487: how many in one (12 bottles in one crate). Display only; never feeds '
  'stock, prices, crate counts or money. NULL = not given.';

COMMIT;
