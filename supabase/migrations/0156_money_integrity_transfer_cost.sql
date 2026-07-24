-- 0156_money_integrity_transfer_cost.sql
--
-- #170 / PRD #155 — money-integrity #7b: transfers move cost with quantity.
-- Additive + nullable: dispatch draws the source's FIFO batches down and the
-- drawn cost RIDES the transfer, so the destination's Cost Batch is created at
-- that value on receipt (real COGS at the receiving store) and
-- dispatched-not-received stock surfaces in Business worth. Mirrors the Drift
-- schemaVersion 67 upgrade step in lib/core/database/app_database.dart.
--
-- Deploy-ordering: this must land on the cloud BEFORE any client on Drift
-- schema v67 pushes a stock_transfers row carrying `cost_kobo` — otherwise the
-- upsert references an unknown column and jams the outbox.
--
-- Money-column rule (0130): the `*_kobo` column is bigint, never int4.

-- =========================================================================
-- stock_transfers.cost_kobo — the total FIFO cost drawn from the source at
-- dispatch. NULL for a `pending` request (nothing dispatched yet) and for every
-- legacy transfer written before #170 (its receipt creates an Uncosted batch,
-- as before). Additive + nullable, so existing rows are untouched.
-- =========================================================================
ALTER TABLE public.stock_transfers
  ADD COLUMN IF NOT EXISTS cost_kobo bigint;
