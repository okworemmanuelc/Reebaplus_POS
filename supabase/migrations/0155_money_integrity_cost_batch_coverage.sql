-- 0155_money_integrity_cost_batch_coverage.sql
--
-- #170 / PRD #155 — money-integrity #7a: full cost-batch coverage (valued
-- losses). Additive + nullable: the central stock mutator now SNAPSHOTS the
-- FIFO cost a decrease drew down onto its stock_adjustments row, so a later
-- cost-price edit can never restate a past loss. Mirrors the Drift
-- schemaVersion 66 upgrade step in lib/core/database/app_database.dart.
--
-- Deploy-ordering: this must land on the cloud BEFORE any client on Drift
-- schema v66 pushes a stock_adjustments row carrying `unit_cost_kobo` /
-- `value_kobo` — otherwise the upsert references an unknown column and jams the
-- outbox.
--
-- Money-column rule (0130): every `*_kobo` column MUST be bigint, never int4
-- (int4 caps at ₦21,474,836.47 and rejects larger pushes with 22003, jamming
-- the outbox). Both new columns are bigint.
--
-- The #7b transfer-cost column (stock_transfers.cost_kobo) and any #7c change
-- ship in their own later migrations.

-- =========================================================================
-- stock_adjustments.unit_cost_kobo / value_kobo — the FIFO cost drawn down by
-- a decrease (damage / count-shortage / product-delete write-off), snapshotted
-- at write time. `value_kobo` is the whole-adjustment total; `unit_cost_kobo`
-- its per-unit figure. NULL for an increase (an inflow carries no loss) and for
-- every legacy quantity-only row (reports fall back to current cost, labelled).
-- Additive + nullable, so existing rows are untouched.
-- =========================================================================
ALTER TABLE public.stock_adjustments
  ADD COLUMN IF NOT EXISTS unit_cost_kobo bigint;

ALTER TABLE public.stock_adjustments
  ADD COLUMN IF NOT EXISTS value_kobo bigint;
