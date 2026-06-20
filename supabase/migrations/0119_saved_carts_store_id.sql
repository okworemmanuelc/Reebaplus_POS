-- 0119_saved_carts_store_id.sql
--
-- §12.1 — store-gate saved carts. Add the nullable store_id to saved_carts
-- (created in 0001). Each saved cart is stamped with the store it was saved
-- under so recall restores it into the right store's cart bucket and the Recall
-- list is filtered to the active store. Legacy rows keep store_id NULL ("All
-- Stores" — visible from every store).
--
-- Mirrors the client Drift schema v55 (app_database.dart): the column is part of
-- the saved_carts row and syncs like the others. pos_pull_snapshot serializes
-- whole rows (to_jsonb) and saved_carts is already in v_tenant_tables
-- (0060/0106), so the new column flows to other devices with no snapshot change.

ALTER TABLE public.saved_carts
  ADD COLUMN IF NOT EXISTS store_id uuid REFERENCES public.stores(id);
