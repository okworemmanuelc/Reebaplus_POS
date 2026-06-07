-- 0111_supplier_ledger_store_id.sql
--
-- §21.11 — per-store supplier ledgers. Add the nullable store_id to
-- supplier_ledger_entries (created in 0102). Suppliers stay business-wide; only
-- each ledger entry is stamped with the store that recorded it. Legacy rows keep
-- store_id NULL ("unassigned" — shown only in the "All Stores" aggregate).
--
-- Mirrors the client Drift schema v47 (app_database.dart): the column is part of
-- the append-only entry and syncs like the others. pos_pull_snapshot serializes
-- whole rows (to_jsonb) and supplier_ledger_entries is already in v_tenant_tables
-- (0102/0106), so the new column flows to other devices with no snapshot change.
--
-- supplier_ledger_entries has no cloud append-only trigger (0102 added only the
-- bump trigger), so there is no immutable-column list to update here.

ALTER TABLE public.supplier_ledger_entries
  ADD COLUMN IF NOT EXISTS store_id uuid REFERENCES public.stores(id);
