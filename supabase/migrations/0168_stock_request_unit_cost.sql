-- 0168_stock_request_unit_cost.sql
--
-- #197 (PRD #155 US 22, slice #170) — a stock-adjustment request records WHAT
-- THE GOODS COST, so the increase it authorises stops selling at a guessed COGS.
--
-- ── The gap ─────────────────────────────────────────────────────────────────
--
-- US 22: "As a manager, I want an approved stock increase to record what the
-- goods cost, so that their later sales carry real COGS instead of zero." It was
-- never built. `stock_adjustment_requests` (0089) had nowhere to put a cost, so
-- `StockAdjustmentRequestsDao.approveRequest` called the central mutator with no
-- `inflowUnitCostKobo` at all and the FIFO batch it minted was priced at 0
-- (#189 later softened that to the product's recorded scalar price — a sane
-- default, but still an inference). The person filing the request is the one
-- holding the invoice; this column is the only place that number can enter the
-- system.
--
-- ── The change ──────────────────────────────────────────────────────────────
--
-- ONE nullable column. NULLABLE is load-bearing, not laziness: a request may
-- legitimately not know the cost (a recount that simply found more units on the
-- shelf has no invoice behind it), and NULL is what makes the client fall back
-- to the recorded price (#189) instead of asserting a made-up 0. A stated cost
-- always wins over that fallback.
--
-- `bigint`, NOT `integer`: an int4 `_kobo` column caps at ₦21,474,836.47 and any
-- larger amount is rejected on push with `22003 out of range`, permanently
-- jamming that device's outbox (SQLite/Dart ints are 64-bit, so the row stores
-- fine locally and only ever fails cloud-side). That bit this project once and
-- was fixed wholesale in 0130; every new `_kobo` column is bigint.
--
-- Only meaningful on an INCREASE (`quantity_diff > 0`). A decrease is valued by
-- drawing the store's FIFO queue at approval time and snapshotting what it drew
-- (#7a / 0155) — the requester is not the authority on what a loss cost — so the
-- client writes NULL there. Deliberately NOT enforced by a CHECK: the rule lives
-- with the cost logic, and a CHECK here would reject an otherwise-valid legacy
-- row on a re-push for a value that is simply ignored.
--
-- Additive and backward-compatible in both directions:
--  * `pos_pull_snapshot` (0089 §5) serialises with `to_jsonb(t)`, so the new
--    column reaches devices with no function change;
--  * `stock_adjustment_requests` has no `pushColumns` whitelist entry in
--    `sync_registry.dart` (pass-through), so the client pushes it with no
--    whitelist change;
--  * `request_stock_adjustment` / `approve_stock_adjustment` (0141, the WEB arm)
--    INSERT with explicit column lists, so they keep compiling and simply leave
--    the cost NULL. Teaching the web RPCs to capture and apply a cost is out of
--    scope here for the same reason the rest of the #170 cost pass is (flagged
--    to the reebaplus-web repo); its golden scenarios stay `dart_arm_only`.
--
-- Mirrors the local Drift `StockAdjustmentRequests.unitCostKobo` (schema v76).
-- DEPLOY ORDER: push this BEFORE the v76 app reaches a device, or the
-- stock_adjustment_requests upserts carrying `unit_cost_kobo` would be rejected
-- cloud-side (PGRST204 — column not found in the schema cache).
--
-- No data repair is needed or possible: nothing on file ever captured a cost, so
-- every existing row is correctly NULL. To size how many past approvals were
-- batched on an inferred cost rather than a stated one, this is READ-ONLY:
--
--   -- SELECT date_trunc('month', approved_at) AS month,
--   --        count(*) FILTER (WHERE quantity_diff > 0) AS approved_increases
--   --   FROM public.stock_adjustment_requests
--   --  WHERE status = 'approved'
--   --  GROUP BY 1 ORDER BY 1;

ALTER TABLE public.stock_adjustment_requests
  ADD COLUMN IF NOT EXISTS unit_cost_kobo bigint;

COMMENT ON COLUMN public.stock_adjustment_requests.unit_cost_kobo IS
  'What the goods cost, per unit, in kobo (#197, PRD #155 US 22). Captured on '
  'the request and used to price the FIFO cost batch the approval mints. NULL = '
  'not stated, which makes the client fall back to the product''s recorded '
  'buying price (#189). Only meaningful when quantity_diff > 0.';
