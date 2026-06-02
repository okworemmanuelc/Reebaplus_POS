-- 0073_expenses_full.sql
--
-- Reebaplus — Expenses full implementation (§20, Ring 1). Mirrors the local
-- Drift schema v31. Four deltas, all additive + backward-compatible:
--   1. expenses: add the §20.4 approval columns (status / rejection_reason /
--      approved_by / approved_at), the §20.2 user-picked expense_date and local
--      receipt_path, and the §20.5 funds_account_id + a status CHECK.
--   2. fund_transactions: widen the reference_type CHECK to allow 'expense'
--      (§20.5 funds debit — same machinery as a refund 'void'). Matches the
--      local v31 CHECK widen.
--   3. expense_budgets: new synced tenant table (§20.1/§20.3 monthly budget —
--      one live row per business / store).
--   4. pos_record_expense: add p_status / p_funds_account_id / p_expense_date /
--      p_receipt_path so the domain-RPC path writes the same shape the table
--      path does. (The funds debit itself always rides the table-upsert path,
--      like a refund — no RPC change needed for fund_transactions.)
--
-- DEPLOY ORDER: push this BEFORE the v31 app reaches a device. The expenses
-- upserts (status / funds_account_id / expense_date / receipt_path) and the
-- expense_budgets upserts the new flow enqueues would 42703 (undefined column)
-- / 42P01 (undefined relation) cloud-side otherwise.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. expenses columns
-- -----------------------------------------------------------------------------
ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS funds_account_id uuid REFERENCES public.funds_accounts(id),
  ADD COLUMN IF NOT EXISTS status           text NOT NULL DEFAULT 'approved',
  ADD COLUMN IF NOT EXISTS rejection_reason text,
  ADD COLUMN IF NOT EXISTS approved_by      uuid REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS approved_at      timestamptz,
  ADD COLUMN IF NOT EXISTS expense_date     timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS receipt_path     text;

-- Pre-existing rows: the ALTER's DEFAULT now() jumps expense_date to the
-- migration instant — backfill it from the real created_at instead. All
-- pre-existing expenses are 'approved' (the prior model had no approval), which
-- the status DEFAULT already gives them.
UPDATE public.expenses SET expense_date = created_at WHERE expense_date <> created_at;

-- status CHECK (matches the local Drift customConstraint).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.expenses'::regclass
      AND conname = 'expenses_status_check'
  ) THEN
    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_status_check
      CHECK (status IN ('approved','pending','rejected'));
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. fund_transactions.reference_type — widen to add 'expense'
--    (drop the old CHECK by definition, re-add widened — same pattern as 0063).
-- -----------------------------------------------------------------------------
DO $$
DECLARE c text;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.fund_transactions'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%reference_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.fund_transactions DROP CONSTRAINT %I', c);
  END LOOP;
END $$;
ALTER TABLE public.fund_transactions
  ADD CONSTRAINT fund_transactions_reference_type_check
  CHECK (reference_type IN ('opening','sale','void','topup','expense'));

-- -----------------------------------------------------------------------------
-- 3. expense_budgets — new synced tenant table (§20.1/§20.3).
--    One live row per (business, store-or-null): null store_id = business-wide
--    goal. Partial unique indexes enforce one live goal per scope.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.expense_budgets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL REFERENCES public.businesses(id),
  store_id        uuid REFERENCES public.stores(id),   -- null = business-wide goal
  amount_kobo     int  NOT NULL CHECK (amount_kobo >= 0),
  is_deleted      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_expense_budgets_business_lua
  ON public.expense_budgets (business_id, last_updated_at);
CREATE INDEX IF NOT EXISTS idx_expense_budgets_business_deleted
  ON public.expense_budgets (business_id, is_deleted);
CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_budgets_business
  ON public.expense_budgets (business_id) WHERE store_id IS NULL AND is_deleted = false;
CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_budgets_store
  ON public.expense_budgets (business_id, store_id) WHERE store_id IS NOT NULL AND is_deleted = false;

ALTER TABLE public.expense_budgets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "expense_budgets_tenant_rw" ON public.expense_budgets;
CREATE POLICY "expense_budgets_tenant_rw" ON public.expense_budgets
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

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'expense_budgets'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.expense_budgets;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 4a. pos_pull_snapshot — add expense_budgets to the tenant table list
--     (same signature/body as 0072; only v_tenant_tables gains one name).
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
    'orders','order_items','shipments','purchase_items',
    'expenses','expense_categories','expense_budgets',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'notifications','stock_transactions',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    'funds_accounts','fund_days','fund_transactions',
    'fund_day_closings',
    'stock_counts'
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

-- -----------------------------------------------------------------------------
-- 4b. pos_record_expense — add p_status / p_funds_account_id / p_expense_date /
--     p_receipt_path. Signature changes (new IN params), so DROP + recreate.
--     Sets approved_by/approved_at when the expense lands already approved.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pos_record_expense(
  uuid, uuid, uuid, uuid, uuid, int, text, uuid, text, text, uuid
);

CREATE OR REPLACE FUNCTION public.pos_record_expense(
  p_business_id     uuid,
  p_actor_id        uuid,
  p_expense_id      uuid,
  p_payment_id      uuid,
  p_activity_log_id uuid,
  p_amount_kobo     int,
  p_description     text,
  p_category_id     uuid        DEFAULT NULL,
  p_payment_method  text        DEFAULT NULL,    -- 'cash'|'transfer'|'card'|'pos'|'other'
  p_reference       text        DEFAULT NULL,
  p_store_id        uuid        DEFAULT NULL,
  p_status          text        DEFAULT 'approved',
  p_funds_account_id uuid       DEFAULT NULL,
  p_expense_date    timestamptz DEFAULT NULL,
  p_receipt_path    text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now            timestamptz := now();
  v_already        bool;
  v_expense_row    jsonb;
  v_activity_row   jsonb;
  v_payment_row    jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_amount_kobo <= 0 THEN
    RAISE EXCEPTION 'amount_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.expenses WHERE id = p_expense_id) INTO v_already;

  IF NOT v_already THEN
    INSERT INTO public.expenses (
      id, business_id, category_id, amount_kobo, description, payment_method,
      recorded_by, reference, store_id, funds_account_id, status,
      approved_by, approved_at, expense_date, receipt_path,
      is_deleted, created_at, last_updated_at
    )
    VALUES (
      p_expense_id, p_business_id, p_category_id, p_amount_kobo, p_description, p_payment_method,
      p_actor_id, p_reference, p_store_id, p_funds_account_id, p_status,
      CASE WHEN p_status = 'approved' THEN p_actor_id ELSE NULL END,
      CASE WHEN p_status = 'approved' THEN v_now ELSE NULL END,
      COALESCE(p_expense_date, v_now), p_receipt_path,
      false, v_now, v_now
    );

    INSERT INTO public.activity_logs (
      id, business_id, user_id, action, description, expense_id,
      created_at, last_updated_at
    )
    VALUES (
      p_activity_log_id, p_business_id, p_actor_id,
      'expense_recorded', p_description, p_expense_id, v_now, v_now
    );

    IF p_payment_method IS NOT NULL THEN
      INSERT INTO public.payment_transactions (
        id, business_id, amount_kobo, method, type,
        expense_id, performed_by, created_at, last_updated_at
      )
      VALUES (
        p_payment_id, p_business_id, p_amount_kobo, p_payment_method, 'expense',
        p_expense_id, p_actor_id, v_now, v_now
      );
    END IF;
  END IF;

  SELECT to_jsonb(e.*)  INTO v_expense_row  FROM public.expenses e        WHERE e.id = p_expense_id;
  SELECT to_jsonb(a.*)  INTO v_activity_row FROM public.activity_logs a   WHERE a.id = p_activity_log_id;
  SELECT to_jsonb(pt.*) INTO v_payment_row  FROM public.payment_transactions pt WHERE pt.id = p_payment_id;

  RETURN jsonb_build_object(
    'expense',             v_expense_row,
    'activity_log',        v_activity_row,
    'payment_transaction', v_payment_row,
    'replayed',            v_already
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pos_record_expense(
  uuid, uuid, uuid, uuid, uuid, int, text, uuid, text, text, uuid, text, uuid, timestamptz, text
) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_record_expense(
  uuid, uuid, uuid, uuid, uuid, int, text, uuid, text, text, uuid, text, uuid, timestamptz, text
) TO authenticated, service_role;

COMMIT;
