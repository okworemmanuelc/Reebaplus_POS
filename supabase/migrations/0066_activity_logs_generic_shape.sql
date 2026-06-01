-- 0066_activity_logs_generic_shape.sql
--
-- Reebaplus — Ring 0 #2 foundation. Land the FINAL activity_logs shape BEFORE
-- building any feature that logs, so each feature logs once against generic
-- columns (no later re-migration), and add notifications.severity so the §26.2
-- colour UI + §26.4 firing pass have a real column.
--
-- activity_logs (§24.4): add a generic (entity_type, entity_id) pair plus
-- before_json/after_json for the §24.4 before/after detail view, and backfill
-- entity_type/entity_id from the existing per-entity FK columns. store_id is
-- KEPT (the §24.2 store filter needs it).
--
-- ADDITIVE ONLY on the cloud (the six per-entity FK columns + the "<=1 set"
-- CHECK are NOT dropped here). The LOCAL Drift schema (v25) DOES drop them —
-- that's the final local shape and removes the local delivery_id FK that blocks
-- the future Deliveries-table removal. The cloud columns are left as vestigial
-- nullable columns ON PURPOSE: the `pos_record_expense` RPC (0011/0045) still
-- INSERTs activity_logs(..., expense_id, ...), so dropping expense_id cloud-side
-- would break it. The cloud-side column drop + RPC rewrite is a deliberate
-- follow-up (bundle with the Ring 1 Expenses RPC pass / Ring 3 Deliveries
-- removal). Sync is unaffected: activity_logs is not in the push column
-- whitelist, so the v25 app simply pushes the new column set and ignores the
-- vestigial cloud columns on pull.
--
-- notifications (§26.2 / §1.3): add severity ('info'/'warning'/'alert'),
-- replacing the overloaded `type` string for the card colour.
--
-- DEPLOY ORDER: apply this BEFORE the v25 app build pushes rows — the new app's
-- payload includes entity_type/severity, which must already exist cloud-side.
--
-- Additive + backfill; idempotent; before/after carry no existing data.

BEGIN;

-- 1. activity_logs: add the generic columns.
ALTER TABLE public.activity_logs
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id   uuid,
  ADD COLUMN IF NOT EXISTS before_json text,
  ADD COLUMN IF NOT EXISTS after_json  text;

-- 2. The append-only trigger blocks UPDATEs — and worse, its immutable-column
--    list still names `warehouse_id` (renamed to store_id in migration 0045 but
--    the trigger's arg list was never updated), so it raises 42703 on ANY
--    activity_logs UPDATE. Drop it for the backfill and re-create it (section 4)
--    with the corrected, new-shape column list. This also repairs that latent
--    bug, which would otherwise break any future activity_logs void/update.
DROP TRIGGER IF EXISTS trg_activity_logs_append_only ON public.activity_logs;

-- 3. Backfill entity_type/entity_id from whichever per-entity FK was set
--    (the old CHECK guaranteed at most one). Idempotent via COALESCE.
UPDATE public.activity_logs SET
  entity_type = COALESCE(entity_type, CASE
    WHEN order_id      IS NOT NULL THEN 'order'
    WHEN product_id    IS NOT NULL THEN 'product'
    WHEN customer_id   IS NOT NULL THEN 'customer'
    WHEN expense_id    IS NOT NULL THEN 'expense'
    WHEN delivery_id   IS NOT NULL THEN 'delivery'
    WHEN wallet_txn_id IS NOT NULL THEN 'wallet_transaction'
    ELSE NULL END),
  entity_id = COALESCE(entity_id, order_id, product_id, customer_id,
                       expense_id, delivery_id, wallet_txn_id);

-- 4. Re-create the append-only trigger with the corrected immutable-column list
--    (store_id, not warehouse_id; + the new generic columns). Matches the local
--    _LedgerImmutability('activity_logs', …) set — only voided_at/voided_by/
--    void_reason/last_updated_at may change after insert.
CREATE TRIGGER trg_activity_logs_append_only
  BEFORE UPDATE ON public.activity_logs
  FOR EACH ROW EXECUTE FUNCTION enforce_append_only(
    'id', 'business_id', 'user_id', 'action', 'description',
    'entity_type', 'entity_id', 'before_json', 'after_json',
    'store_id', 'created_at');

-- 5. notifications: severity column for the §26.2 card colour.
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS severity text NOT NULL DEFAULT 'info';
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_severity_check;
ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_severity_check
  CHECK (severity IN ('info', 'warning', 'alert'));

COMMIT;
