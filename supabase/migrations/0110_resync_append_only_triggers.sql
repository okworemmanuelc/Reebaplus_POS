-- 0110_resync_append_only_triggers.sql
--
-- Durable fix for the append-only trigger column drift (see 0109).
--
-- The append_only guard bakes its immutable-column list into TG_ARGV at CREATE
-- time. Whenever a later migration RENAMES a ledger column without recreating the
-- trigger, the baked name goes stale and enforce_append_only() raises 42703
-- ("column X not found in data type Y") on every UPDATE of that table.
--
-- Known drifts found:
--   * stock_transactions / payment_transactions: purchase_id -> shipment_id (0046)
--       — fixed in 0109.
--   * crate_ledger: crate_group_id -> crate_size_group_id (0047) — never fixed,
--       latent (fires on a crate-ledger void).
--
-- Rather than chase each rename, re-derive the append_only trigger for EVERY
-- ledger table from the LIVE schema (same logic as 0001_initial.sql §9). This
-- heals crate_ledger and re-bakes the already-correct tables to whatever columns
-- they actually have now — so this whole class of drift is closed. Idempotent.

DO $$
DECLARE
  ledger_tables text[] := ARRAY[
    'stock_transactions','wallet_transactions','payment_transactions',
    'activity_logs','crate_ledger'
  ];
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
