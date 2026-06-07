-- 0109_fix_append_only_purchase_id.sql
--
-- BUG: payment_transactions / stock_transactions upserts fail on every
-- ON CONFLICT DO UPDATE (retry of an already-inserted row, or a void) with:
--   PostgrestException(code 42703,
--     message: column "purchase_id" not found in data type payment_transactions)
--
-- ROOT CAUSE: the append-only guard trigger bakes its immutable-column list into
-- TG_ARGV at CREATE time (0001_initial.sql §9 read information_schema then). At
-- that time the FK column was `purchase_id`. Migration 0046 renamed
-- purchase_id -> shipment_id on both stock_transactions and payment_transactions
-- but never recreated the two append_only triggers, so their TG_ARGV still lists
-- 'purchase_id'. enforce_append_only() does `EXECUTE format('SELECT ($1).%I ...',
-- col)` per column, so reading a column that no longer exists raises 42703 on the
-- BEFORE UPDATE — which fires for every upsert that resolves to an UPDATE.
--
-- FIX: drop and recreate the append_only trigger for those two tables, re-deriving
-- the immutable-column list from the LIVE schema (same DO-block logic as 0001), so
-- it now bakes `shipment_id` in place of `purchase_id`. Idempotent and safe — a
-- no-op for the column set beyond the rename.
--
-- The client-side mirror of this guard (app_database.dart `_ledgerTables`) already
-- uses `shipment_id`, so only the cloud trigger was drifted.

DO $$
DECLARE
  ledger_tables text[] := ARRAY['stock_transactions','payment_transactions'];
  t    text;
  cols text;
BEGIN
  FOREACH t IN ARRAY ledger_tables LOOP
    SELECT string_agg(quote_literal(column_name), ',')
      INTO cols
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = t
        AND column_name NOT IN ('voided_at','voided_by','void_reason','last_updated_at');

    EXECUTE format('DROP TRIGGER IF EXISTS trg_%I_append_only ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%I_append_only BEFORE UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
      t, t, cols
    );
  END LOOP;
END $$;
