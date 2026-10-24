-- 0188_products_unit_kg_litre.sql
--
-- #490 / #492 G4: widen products.unit CHECK to include Kg and Litre.
--
-- Cloud twin of Drift schemaVersion 85
-- (lib/core/database/app_database.dart, the `from < 85` upgrade step).
--
-- Widens products_unit_check to admit 'Kg' and 'Litre' alongside the 13
-- existing units. NULL remains allowed (#108 / 0151).
--
-- DEPLOY ORDERING: deploy this BEFORE shipping any client that writes 'Kg'
-- or 'Litre' units. A client pushing a product with unit='Kg' against a table
-- with the old CHECK constraint will fail the insert / push.

BEGIN;

DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.products'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%unit%'
      AND pg_get_constraintdef(oid) NOT ILIKE '%unit_price%'
      AND pg_get_constraintdef(oid) NOT ILIKE '%units_per_pack%'
  LOOP
    EXECUTE format('ALTER TABLE public.products DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

ALTER TABLE public.products
  ADD CONSTRAINT products_unit_check
  CHECK (unit IS NULL OR unit IN ('Bottle','Can','PET','Sachet','Keg','Crate','Pack','Carton','Piece','Bag','Box','Tin','Other','Kg','Litre'));

COMMIT;
