-- 0092_drop_funds_register.sql
--
-- Reebaplus — REMOVE the Funds Register feature entirely (master plan §23, now a
-- tombstone). The user decided (2026-06-04) to eject Funds Register: POS is now
-- gateless (no opening-cash / open-day gate), and money is tracked as recorded
-- activity (sales / expenses / supplier payments / refunds) rather than
-- per-account balances. This migration removes the cloud half. Mirrors the local
-- Drift schema bump v35 -> v36.
--
-- What this migration does:
--   1. pos_record_expense: drop the funds-account parameter and stop writing the
--      expenses.funds_account_id column (it is being dropped). Same body
--      otherwise.
--   2. expenses: drop the funds_account_id column (the FK target is going away).
--   3. pos_pull_snapshot: remove the four funds tables from v_tenant_tables so
--      devices stop pulling them (a dropped relation would otherwise raise 42P01
--      inside the dynamic per-table loop).
--   4. Drop the four funds tables (their RLS policies, triggers, indexes, and
--      realtime-publication membership drop with them).
--
-- DEPLOY ORDER (the reverse of an additive table): ship the v36 APP FIRST so it
-- stops enqueuing funds upserts and stops sending p_funds_account_id, THEN push
-- this migration. Pushing it before the app updates would 42P01 any in-flight
-- funds push from an old device. The funds tables were append-only / synced; no
-- domain RPC writes them (funds rows rode the plain table-upsert path), so only
-- pos_record_expense and pos_pull_snapshot reference them.

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. pos_record_expense — stop writing the expenses.funds_account_id column
--    (dropped in step 2). The signature is UNCHANGED (same 15 args as 0073):
--    p_funds_account_id is kept as a retained-but-ignored compatibility param so
--    any expense envelope already queued on an old device (which still carries
--    p_funds_account_id) still calls cleanly — it is simply not inserted. New
--    app builds omit the arg → it defaults to NULL. CREATE OR REPLACE only (no
--    DROP), so no arg-count mismatch can break in-flight sync. Approval columns,
--    activity-log + payment legs, and the replay guard are unchanged.
-- -----------------------------------------------------------------------------
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
  p_funds_account_id uuid       DEFAULT NULL,    -- IGNORED (Funds Register removed 2026-06-04); kept for envelope compat
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
      recorded_by, reference, store_id, status,
      approved_by, approved_at, expense_date, receipt_path,
      is_deleted, created_at, last_updated_at
    )
    VALUES (
      p_expense_id, p_business_id, p_category_id, p_amount_kobo, p_description, p_payment_method,
      p_actor_id, p_reference, p_store_id, p_status,
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

-- -----------------------------------------------------------------------------
-- 2. expenses.funds_account_id — drop the column (its FK target funds_accounts
--    is dropped in step 4). No live function references it after step 1.
-- -----------------------------------------------------------------------------
ALTER TABLE public.expenses DROP COLUMN IF EXISTS funds_account_id;

-- -----------------------------------------------------------------------------
-- 3. pos_pull_snapshot — same body as 0089, with the four funds tables removed
--    from v_tenant_tables. CREATE OR REPLACE is idempotent.
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
    -- 0092: Funds Register (funds_accounts / fund_days / fund_transactions /
    -- fund_day_closings) removed — no longer pulled.
    -- 0072: Daily Stock Count session snapshot (§17).
    'stock_counts',
    -- 0088: per-staff permission overrides (§10.2.1).
    'user_permission_overrides'
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
-- 4. Drop the four funds tables. CASCADE removes their RLS policies, triggers,
--    indexes, inter-table FKs, and realtime-publication membership. Dependency
--    order: closings -> ledger -> day header -> accounts.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS public.fund_day_closings CASCADE;
DROP TABLE IF EXISTS public.fund_transactions CASCADE;
DROP TABLE IF EXISTS public.fund_days        CASCADE;
DROP TABLE IF EXISTS public.funds_accounts   CASCADE;

COMMIT;
