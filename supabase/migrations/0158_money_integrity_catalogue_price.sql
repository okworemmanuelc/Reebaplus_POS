-- 0158_money_integrity_catalogue_price.sql
--
-- #176 / PRD #155 — money-integrity report-truth: catalogue-price snapshot on
-- order lines so custom-price concessions are derivable in margin review.
-- Additive + nullable: when a cashier overrides a line's price at checkout
-- (`sales.set_custom_price`), `unit_price_kobo` holds the CHARGED price and
-- this holds the tier list price it deviated from, so `catalogue − charged`
-- per unit is the recorded concession. Mirrors the Drift schemaVersion 69
-- upgrade step in lib/core/database/app_database.dart.
--
-- Deploy-ordering: this must land on the cloud BEFORE any client on Drift
-- schema v69 pushes an order_items row carrying `catalogue_price_kobo` —
-- otherwise the upsert references an unknown column and jams the outbox.
--
-- Money-column rule (0130): every `*_kobo` column MUST be bigint, never int4
-- (int4 caps at ₦21,474,836.47 and rejects larger pushes with 22003, jamming
-- the outbox). The new column is bigint.
--
-- No sync_registry / pos_pull_snapshot change: order_items restores via
-- Restore.plain (pass-through) and the snapshot RPC emits to_jsonb(t), so the
-- new column flows to peers automatically once it exists.

-- =========================================================================
-- order_items.catalogue_price_kobo — the tier list price of the line at sale
-- time. NULL when no override was applied (charged == catalogue) and for
-- quick-sale lines (no catalogue price). Additive + nullable, so existing rows
-- are untouched.
-- =========================================================================
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS catalogue_price_kobo bigint;
