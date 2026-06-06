-- 0102_supplier_ledger_entries.sql
--
-- Reebaplus — Supplier Accounts ledger (master plan §21). A per-supplier,
-- append-only ledger that mirrors wallet_transactions but inverted: an
-- `invoice` is a debit (goods received — we owe the supplier, shown
-- red/negative in the app), a `payment_*` is a credit (money paid). Balance =
-- SUM(signed_amount_kobo); negative = we owe. Corrections are made by a `void`
-- compensating entry, never an edit/delete. Mirrors the local Drift
-- `SupplierLedgerEntries` table (schema v42). Receipts are stored as a local
-- file path only (Phase 1, like expenses) — the `receipt_path` string syncs but
-- the image does not.
--
-- Also: adds supplier bank/notes columns (§21.5), and defensively drops the
-- stale `supplier_payments` table left by abandoned parallel work (it carried a
-- funds_account_id FK to the dropped funds_accounts — see local migration v36).
--
-- This supersedes the former §22 "Track Shipments" feature: invoice totals are
-- now recorded here, not via a separate Mark-Received flow (§22 removed).
--
-- Additive: 4 new suppliers columns + one new synced tenant table + RLS +
-- realtime + snapshot pull. The ledger is append-only (never hard-deleted), so
-- this is NOT in the enqueueDelete/realtime-DELETE set.
-- DEPLOY ORDER: push this BEFORE the v42 app reaches a device, or the
-- supplier_ledger_entries upserts the app enqueues would 42P01 (relation does
-- not exist) cloud-side, and the new suppliers columns would be dropped on push.

-- -----------------------------------------------------------------------------
-- 1. Supplier bank/notes columns (§21.5). All nullable — no backfill.
-- -----------------------------------------------------------------------------
ALTER TABLE public.suppliers
  ADD COLUMN IF NOT EXISTS bank_account_name   text,
  ADD COLUMN IF NOT EXISTS bank_account_number text,
  ADD COLUMN IF NOT EXISTS bank_name           text,
  ADD COLUMN IF NOT EXISTS notes               text;

-- -----------------------------------------------------------------------------
-- 2. Drop the stale supplier_payments table (abandoned parallel work). CASCADE
--    clears its funds_account_id FK. No live code path ever wrote it.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS public.supplier_payments CASCADE;

-- -----------------------------------------------------------------------------
-- 3. Table — same shape/CHECKs as wallet_transactions (0001), inverted meaning.
-- -----------------------------------------------------------------------------
CREATE TABLE public.supplier_ledger_entries (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  supplier_id        uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  type               text NOT NULL CHECK (type IN ('credit','debit')),
  amount_kobo        int  NOT NULL CHECK (amount_kobo >= 0),
  signed_amount_kobo int  NOT NULL,  -- payment = +amount, invoice = -amount; the sum is the balance
  reference_type     text NOT NULL CHECK (reference_type IN
                       ('invoice','payment_cash','payment_transfer','payment_pos','payment_other','void')),
  payment_method     text,           -- payments only: cash|transfer|pos|other
  receipt_path       text,           -- local file path (proof) — image not synced
  reference_note     text,           -- bank ref / cheque no / explanation (proof)
  activity_date      timestamptz NOT NULL,  -- goods-received date (invoice) | paid-on date (payment)
  performed_by       uuid REFERENCES public.users(id),
  voided_at          timestamptz,
  voided_by          uuid REFERENCES public.users(id),
  void_reason        text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (signed_amount_kobo > 0 AND type = 'credit') OR
    (signed_amount_kobo < 0 AND type = 'debit')  OR
    (signed_amount_kobo = 0)
  )
);
CREATE INDEX idx_supplier_ledger_entries_business_lua
  ON public.supplier_ledger_entries (business_id, last_updated_at);
CREATE INDEX idx_supplier_ledger_business_supplier_time
  ON public.supplier_ledger_entries (business_id, supplier_id, created_at);

-- -----------------------------------------------------------------------------
-- 4. Row Level Security — profiles-based tenant scoping via
--    current_user_business_ids() (NOT an inline user_businesses subquery; that
--    hit auth_user_id-drift 42501 push failures — see 0050/0051/0075/0099).
-- -----------------------------------------------------------------------------
ALTER TABLE public.supplier_ledger_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_ledger_entries_tenant_rw" ON public.supplier_ledger_entries
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

-- -----------------------------------------------------------------------------
-- 5. last_updated_at bump trigger — rows get UPDATEd on void (mirrors
--    wallet_transactions / role_permissions).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_supplier_ledger_entries_last_updated_at
  BEFORE UPDATE ON public.supplier_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 6. Realtime publication — INSERT/UPDATE events flow to other devices. REPLICA
--    IDENTITY FULL so a void UPDATE's record carries business_id for the
--    realtime RLS authorize (and future-proofs any DELETE).
-- -----------------------------------------------------------------------------
ALTER TABLE public.supplier_ledger_entries REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.supplier_ledger_entries;

-- -----------------------------------------------------------------------------
-- 7. Snapshot pull — append supplier_ledger_entries to pos_pull_snapshot so
--    other devices pull a supplier's ledger (same signature/body as 0099; only
--    v_tenant_tables gains the one new name).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_pull_snapshot(
  p_business_id uuid,
  p_since       timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid;
  v_result          jsonb := '{}'::jsonb;
  v_table           text;
  v_rows            jsonb;
  v_query           text;
  v_tenant_tables   text[] := ARRAY[
    'profiles','users','stores','manufacturers','crate_size_groups',
    'categories','products','inventory','customers','suppliers',
    -- 0101: per-supplier append-only ledger (§21.10).
    'supplier_ledger_entries',
    'orders','order_items',
    -- 0093: per-order, per-brand crate deposit lines (§13.4).
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'notifications','stock_transactions',
    -- 0089: stock-keeper adjustment approval queue (§16.6.1).
    'stock_adjustment_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    -- 0092: Funds Register removed — no longer pulled.
    -- 0072: Daily Stock Count session snapshot (§17).
    'stock_counts',
    -- 0088: per-staff permission overrides (§10.2.1).
    'user_permission_overrides',
    -- 0099: per-store role permission overrides (§10.2.1 Store scope).
    'store_role_permissions'
  ];
BEGIN
  v_caller_business := public.business_id();
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'no_business_for_caller'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_caller_business <> p_business_id THEN
    RAISE EXCEPTION 'tenant_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    INTO v_rows
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND (p_since IS NULL OR b.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('businesses', v_rows);

  FOREACH v_table IN ARRAY v_tenant_tables LOOP
    v_query := format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)
         FROM public.%I t
         WHERE t.business_id = $1
           AND ($2::timestamptz IS NULL OR t.last_updated_at > $2)',
      v_table
    );
    EXECUTE v_query INTO v_rows USING p_business_id, p_since;
    v_result := v_result || jsonb_build_object(v_table, v_rows);
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
    INTO v_rows
    FROM public.system_config s
    WHERE (p_since IS NULL OR s.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('system_config', v_rows);

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz)
  TO authenticated, service_role;
