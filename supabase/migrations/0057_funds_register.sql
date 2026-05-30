-- 0057_funds_register.sql
-- Reebaplus master plan §23 (Funds Register), Phase 1. Mirrors the local Drift
-- schema bump v19 → v20 in lib/core/database/app_database.dart.
--
-- Three new tenant-scoped synced tables:
--   funds_accounts     — per-store money accounts (Cash Till / POS / Bank).
--   fund_days          — daily open/close header; existence with status='open'
--                        is the POS Opening-Cash gate (hard rule #10). Mutable.
--   fund_transactions  — append-only ledger; balance per account/day =
--                        SUM(signed_amount_kobo) of non-voided rows.
--
-- Shapes mirror the Drift tables exactly. Helper functions already exist:
--   public._bump_last_updated_at() (0042), public.enforce_append_only() /
--   public.forbid_delete() (0001).

-- -----------------------------------------------------------------------------
-- 1. CREATE TABLE — FK-respecting order: accounts → days → transactions.
-- -----------------------------------------------------------------------------
CREATE TABLE public.funds_accounts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL REFERENCES public.businesses(id),
  store_id        uuid NOT NULL REFERENCES public.stores(id),
  account_type    text NOT NULL CHECK (account_type IN ('cash_till','pos_machine','bank')),
  name            text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,
  is_deleted      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, account_type, name)
);
CREATE INDEX idx_funds_accounts_business_lua ON public.funds_accounts (business_id, last_updated_at);
CREATE INDEX idx_funds_accounts_business_deleted ON public.funds_accounts (business_id, is_deleted);
CREATE INDEX idx_funds_accounts_store ON public.funds_accounts (store_id);

CREATE TABLE public.fund_days (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL REFERENCES public.businesses(id),
  store_id        uuid NOT NULL REFERENCES public.stores(id),
  business_date   text NOT NULL,                       -- YYYY-MM-DD, local business day
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  opened_by       uuid REFERENCES public.users(id),
  opened_at       timestamptz,
  closed_by       uuid REFERENCES public.users(id),
  closed_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, business_date)
);
CREATE INDEX idx_fund_days_business_lua ON public.fund_days (business_id, last_updated_at);
CREATE INDEX idx_fund_days_store_date ON public.fund_days (store_id, business_date);

CREATE TABLE public.fund_transactions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid NOT NULL REFERENCES public.businesses(id),
  funds_account_id  uuid NOT NULL REFERENCES public.funds_accounts(id),
  store_id          uuid NOT NULL REFERENCES public.stores(id),
  business_date     text NOT NULL,
  type              text NOT NULL CHECK (type IN ('credit','debit')),
  amount_kobo       int  NOT NULL CHECK (amount_kobo >= 0),
  signed_amount_kobo int NOT NULL CHECK (
    (type = 'credit' AND signed_amount_kobo >= 0) OR
    (type = 'debit'  AND signed_amount_kobo <= 0)
  ),
  reference_type    text NOT NULL CHECK (reference_type IN ('opening','sale','void')),
  order_id          uuid REFERENCES public.orders(id),
  payment_id        uuid REFERENCES public.payment_transactions(id),
  performed_by      uuid REFERENCES public.users(id),
  voided_at         timestamptz,
  voided_by         uuid REFERENCES public.users(id),
  void_reason       text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  last_updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_fund_transactions_business_lua ON public.fund_transactions (business_id, last_updated_at);
CREATE INDEX idx_fund_txn_account_date ON public.fund_transactions (funds_account_id, business_date);

-- -----------------------------------------------------------------------------
-- 2. Row Level Security — standard "tenant member via user_businesses" policy
--    (copied from 0042). Enable first, then one FOR ALL policy per table.
-- -----------------------------------------------------------------------------
ALTER TABLE public.funds_accounts    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fund_days         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fund_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "funds_accounts_tenant_rw" ON public.funds_accounts
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

CREATE POLICY "fund_days_tenant_rw" ON public.fund_days
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

CREATE POLICY "fund_transactions_tenant_rw" ON public.fund_transactions
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

-- -----------------------------------------------------------------------------
-- 3. Realtime publication — INSERT/UPDATE/DELETE events flow to clients.
-- -----------------------------------------------------------------------------
ALTER PUBLICATION supabase_realtime ADD TABLE
  public.funds_accounts,
  public.fund_days,
  public.fund_transactions;

-- -----------------------------------------------------------------------------
-- 4. last_updated_at bump triggers (all three are synced).
-- -----------------------------------------------------------------------------
CREATE TRIGGER bump_funds_accounts_last_updated_at
  BEFORE UPDATE ON public.funds_accounts
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();
CREATE TRIGGER bump_fund_days_last_updated_at
  BEFORE UPDATE ON public.fund_days
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();
CREATE TRIGGER bump_fund_transactions_last_updated_at
  BEFORE UPDATE ON public.fund_transactions
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

-- -----------------------------------------------------------------------------
-- 5. Append-only enforcement on fund_transactions — only the void columns and
--    last_updated_at may change; deletes forbidden. Derives the immutable
--    column list from information_schema (same DO-block shape as 0001).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  cols text;
BEGIN
  SELECT string_agg(quote_literal(column_name), ',')
    INTO cols
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'fund_transactions'
      AND column_name NOT IN ('voided_at','voided_by','void_reason','last_updated_at');
  EXECUTE format(
    'CREATE TRIGGER trg_fund_transactions_append_only BEFORE UPDATE ON public.fund_transactions '
    'FOR EACH ROW EXECUTE FUNCTION public.enforce_append_only(%s)',
    cols
  );
END $$;

CREATE TRIGGER trg_fund_transactions_no_delete
  BEFORE DELETE ON public.fund_transactions
  FOR EACH ROW EXECUTE FUNCTION public.forbid_delete();
