-- 0065_widen_product_unit_check.sql
--
-- Reebaplus — widen products.unit so non-bottle units can be created (§16.5).
-- Businesses sell in Can / PET / Sachet / Keg / Box / Tin etc., but the Add /
-- Edit Product dropdown offered units the CHECK rejected, so creating a
-- non-bottle product failed the insert and the product never reached
-- inventory. The matching local Drift CHECK is widened in the same release
-- (schema v24, products table rebuild in app_database.dart onUpgrade from < 24).
--
-- Background:
--   0001 declared the column with an inline CHECK
--     unit text NOT NULL DEFAULT 'Bottle'
--       CHECK (unit IN ('Bottle','Crate','Pack','Carton','Piece','Bag','Other'))
--   (0001:277-278), which Postgres auto-named products_unit_check.
--
-- Fix:
--   Drop the old CHECK and re-add it widened. Additive and backward-compatible
--   — every existing value still validates; only new values become legal.
--   Idempotent. No data change.

BEGIN;

-- Drop whatever CHECK constraint currently governs unit, regardless of its
-- auto-generated name (0001 declared it inline → products_unit_check, but match
-- by definition to be safe: a wrong name would silently leave the old
-- constraint in place and still reject the new units).
DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.products'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%unit%'
      AND pg_get_constraintdef(oid) NOT ILIKE '%unit_price%'
  LOOP
    EXECUTE format('ALTER TABLE public.products DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

ALTER TABLE public.products
  ADD CONSTRAINT products_unit_check
  CHECK (unit IN ('Bottle','Can','PET','Sachet','Keg','Crate','Pack','Carton','Piece','Bag','Box','Tin','Other'));

COMMIT;
