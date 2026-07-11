-- 0151_products_unit_nullable.sql
--
-- Reebaplus (#108) — optional product units. A product may have NO unit; when
-- absent it renders nothing anywhere and crate-eligibility treats it as "not a
-- bottle". This makes products.unit nullable cloud-side, matching the local
-- Drift change (schema v62, products table rebuild in app_database.dart
-- onUpgrade from < 62).
--
-- Background:
--   0001 declared the column
--     unit text NOT NULL DEFAULT 'Bottle'
--       CHECK (unit IN (...))                                   (0001:277-278)
--   and 0065 widened the CHECK to the current 13 units (products_unit_check).
--
-- Fix (all additive / backward-compatible — every existing value still
-- validates, only NULL becomes newly legal; no data change, no backfill):
--   1. DROP NOT NULL so a product may carry no unit.
--   2. DROP DEFAULT so an omitted unit stays NULL ("no unit") rather than
--      silently becoming 'Bottle'. Every product-insert path (mobile outbox
--      upserts, pos_upsert_product, web pos_create_product) supplies unit
--      explicitly, so the column default is not load-bearing — the app sends an
--      explicit null for a unitless product.
--   3. Relax the CHECK to admit NULL.
-- Idempotent.

BEGIN;

ALTER TABLE public.products ALTER COLUMN unit DROP NOT NULL;
ALTER TABLE public.products ALTER COLUMN unit DROP DEFAULT;

-- Drop whatever CHECK constraint currently governs unit, regardless of its
-- auto-generated name (match by definition, not name — a wrong name would
-- silently leave the old NOT-NULL-implying constraint in place and still reject
-- NULL). Excludes the unit_price checks on line-item tables via the table
-- filter (conrelid) and the '%unit_price%' guard.
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
  CHECK (unit IS NULL OR unit IN ('Bottle','Can','PET','Sachet','Keg','Crate','Pack','Carton','Piece','Bag','Box','Tin','Other'));

COMMIT;
