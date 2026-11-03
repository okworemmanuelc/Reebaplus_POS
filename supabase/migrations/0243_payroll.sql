-- 0243_payroll.sql
--
-- #667 (PRD #666, ADR 0034): Payroll database, permission and private sync.
-- Cloud twin of Drift schemaVersion 101 (app_database.dart, `from < 101`).
-- Database groundwork only; no screen uses these tables yet.
--
-- WHAT THIS ADDS
--   1. Permission `payroll.manage` (category 'Payroll'), CEO + Manager by
--      default: catalogue first, then the seed (verbatim 0217 + the Manager
--      grant), then a one-off backfill for existing CEO and Manager roles.
--   2. Three business-scoped synced tables: payroll_workers, payroll_entries
--      (append-only, typed) and payroll_statements (signed, one per worker per
--      Salary Month). Money is bigint kobo. `legacy_id` keys the #672 import.
--   3. A content freeze on entries and statements (append-only, replay-safe).
--
-- THE FIRST PERMISSION-BASED ACCESS RULE (ADR 0034). Every policy requires
-- BOTH business membership (current_user_business_ids()) AND
-- caller_has_permission(business_id, 'payroll.manage'). Phones without the
-- key read nothing and cannot write.
--
-- pos_pull_snapshot is SECURITY DEFINER and bypasses RLS, so these tables are
-- deliberately NOT added to its table list (definition unchanged since 0205).
-- Clients fetch them through PostgREST, where the policies above apply.
--
-- DEPLOY ORDER (project_permission_key_cloud_fk_deploy): this must reach a
-- project BEFORE any client on Drift 101 pushes a role_permissions grant for
-- `payroll.manage` (role_permissions.permission_key FK) or a payroll row.

BEGIN;

-- =========================================================================
-- 1. Permission: catalogue, seed, backfill
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('payroll.manage', 'Manage payroll: workers, pay, allowances and staff loans',
   'Payroll')
ON CONFLICT (key) DO NOTHING;

-- Verbatim latest seed (0217) + `payroll.manage` for the Manager. The CEO
-- already receives every catalogue key through its SELECT. Same signature and
-- return shape (no overload).
CREATE OR REPLACE FUNCTION public.seed_default_roles_for_business(
  p_business_id uuid
)
RETURNS TABLE (
  ceo_role_id          uuid,
  manager_role_id      uuid,
  cashier_role_id      uuid,
  stock_keeper_role_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ceo  uuid;
  v_mgr  uuid;
  v_cash uuid;
  v_sk   uuid;
  v_drv  uuid;
BEGIN
  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'CEO',          'ceo',          true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_ceo;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Manager',      'manager',      true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_mgr;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Cashier',      'cashier',      true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_cash;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Stock keeper', 'stock_keeper', true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_sk;

  -- #140 — the fifth system role. Last in tier order (CEO → Manager → Cashier
  -- → Stock keeper → Driver), which is how every role list is sorted.
  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Driver',       'driver',       true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_drv;

  -- CEO: all keys (includes the new van.manage / van.sell via the SELECT).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: explicit list + van.manage (#140 — a manager sets up vans, loads
  -- them and records remittances; they never sell from one) + payroll.manage
  -- (#667: CEO and Manager run Payroll by default).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_mgr, 'sales.make'),
    (p_business_id, v_mgr, 'sales.cancel'),
    (p_business_id, v_mgr, 'sales.confirm'),
    (p_business_id, v_mgr, 'sales.discount.give'),
    (p_business_id, v_mgr, 'products.add'),
    (p_business_id, v_mgr, 'products.edit_price'),
    (p_business_id, v_mgr, 'products.manage_listing'),
    (p_business_id, v_mgr, 'online_orders.view'),
    (p_business_id, v_mgr, 'online_orders.answer'),
    (p_business_id, v_mgr, 'products.edit_buying_price'),
    (p_business_id, v_mgr, 'products.delete'),
    (p_business_id, v_mgr, 'stock.add'),
    (p_business_id, v_mgr, 'stock.view'),
    (p_business_id, v_mgr, 'stock.adjust'),
    (p_business_id, v_mgr, 'expenses.create'),
    (p_business_id, v_mgr, 'reports.see_sales'),
    (p_business_id, v_mgr, 'reports.see_cost_prices'),
    (p_business_id, v_mgr, 'reports.see_expenses'),
    (p_business_id, v_mgr, 'customers.add'),
    (p_business_id, v_mgr, 'customers.update'),
    (p_business_id, v_mgr, 'customers.delete'),
    (p_business_id, v_mgr, 'customers.wallet.update'),
    (p_business_id, v_mgr, 'customers.set_debt_limit'),
    (p_business_id, v_mgr, 'customers.wallet.totals.view'),
    (p_business_id, v_mgr, 'customers.wallet.withdraw'),
    (p_business_id, v_mgr, 'stores.request_transfer'),
    (p_business_id, v_mgr, 'stores.dispatch_transfer'),
    (p_business_id, v_mgr, 'stores.receive_transfer'),
    (p_business_id, v_mgr, 'staff.invite'),
    (p_business_id, v_mgr, 'staff.suspend'),
    (p_business_id, v_mgr, 'staff.change_role'),
    (p_business_id, v_mgr, 'van.manage'),
    (p_business_id, v_mgr, 'funds.open_day'),
    (p_business_id, v_mgr, 'funds.close_day'),
    (p_business_id, v_mgr, 'funds.view'),
    (p_business_id, v_mgr, 'payroll.manage')                 -- 0243 (#667)
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: + online_orders.view / .answer (#427).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_cash, 'sales.make'),
    (p_business_id, v_cash, 'sales.confirm'),
    (p_business_id, v_cash, 'stock.view'),
    (p_business_id, v_cash, 'reports.see_sales'),
    (p_business_id, v_cash, 'customers.add'),
    (p_business_id, v_cash, 'customers.update'),
    (p_business_id, v_cash, 'customers.wallet.update'),
    (p_business_id, v_cash, 'online_orders.view'),
    (p_business_id, v_cash, 'online_orders.answer')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Stock keeper: unchanged.
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_sk, 'stock.add'),
    (p_business_id, v_sk, 'stock.view'),
    (p_business_id, v_sk, 'stock.adjust')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Driver: `van.sell` only. Deliberately NOT `sales.make` — a driver sells
  -- through the van terminal (#142), not the store POS — and deliberately NOT
  -- `van.manage`, which is what makes "a driver records their own remittance"
  -- impossible by construction (spec §9.5, edge case 21).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_drv, 'van.sell')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  INSERT INTO public.role_settings (business_id, role_id, setting_key, setting_value)
  VALUES
    (p_business_id, v_ceo,  'max_discount_percent',        '100'),
    (p_business_id, v_ceo,  'max_expense_approval_kobo',   NULL),
    (p_business_id, v_mgr,  'max_discount_percent',        '10'),
    (p_business_id, v_mgr,  'max_expense_approval_kobo',   '0'),
    (p_business_id, v_cash, 'max_discount_percent',        '0'),
    (p_business_id, v_cash, 'max_expense_approval_kobo',   '0'),
    (p_business_id, v_sk,   'max_discount_percent',        '0'),
    (p_business_id, v_sk,   'max_expense_approval_kobo',   '0'),
    (p_business_id, v_drv,  'max_discount_percent',        '0'),
    (p_business_id, v_drv,  'max_expense_approval_kobo',   '0')
  ON CONFLICT (role_id, setting_key) DO NOTHING;

  RETURN QUERY SELECT v_ceo, v_mgr, v_cash, v_sk;
END;
$function$;


-- Existing businesses receive the new default once (CEO + Manager). Do not
-- rewrite this migration to re-grant an intentionally revoked permission.
INSERT INTO public.role_permissions (business_id, role_id, permission_key)
SELECT r.business_id, r.id, 'payroll.manage'
  FROM public.roles r
 WHERE r.slug IN ('ceo', 'manager')
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- =========================================================================
-- 2. Tables, indexes, access rules, live-sync triggers
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.payroll_workers (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id              uuid        NOT NULL REFERENCES public.stores(id),
  -- Optional login; a worker need not have one. SET NULL keeps pay history
  -- when a staff login is permanently removed.
  user_id               uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  name                  text        NOT NULL,
  monthly_salary_kobo   bigint      NOT NULL DEFAULT 0 CHECK (monthly_salary_kobo >= 0),
  daily_allowance_kobo  bigint      NOT NULL DEFAULT 0 CHECK (daily_allowance_kobo >= 0),
  -- The first day the allowance applies; never backdated.
  allowance_start_date  date,
  is_removed            boolean     NOT NULL DEFAULT false,
  removed_at            timestamptz,
  created_by            uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  legacy_id             text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  last_updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.payroll_entries (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  worker_id          uuid        NOT NULL REFERENCES public.payroll_workers(id),
  store_id           uuid        NOT NULL REFERENCES public.stores(id),
  type               text        NOT NULL CHECK (type IN (
                       'salary_payment','allowance','bonus','advance',
                       'loan_given','loan_repaid')),
  amount_kobo        bigint      NOT NULL,
  entry_date         date        NOT NULL,
  -- The Salary Month ('YYYY-MM') a salary payment or advance belongs to.
  salary_month       text        CHECK (salary_month IS NULL
                                        OR salary_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  payment_method     text        NOT NULL DEFAULT 'cash'
                                 CHECK (payment_method IN ('cash','transfer','other')),
  note               text,
  -- A correction is a NEW entry naming the entry it corrects (never an edit).
  corrects_entry_id  uuid        REFERENCES public.payroll_entries(id),
  recorded_by        uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  legacy_id          text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_entries_salary_month_required
    CHECK (type <> 'salary_payment' OR salary_month IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.payroll_statements (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  worker_id             uuid        NOT NULL REFERENCES public.payroll_workers(id),
  store_id              uuid        NOT NULL REFERENCES public.stores(id),
  salary_month          text        NOT NULL
                                    CHECK (salary_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  salary_kobo           bigint      NOT NULL DEFAULT 0,
  allowances_kobo       bigint      NOT NULL DEFAULT 0,
  bonuses_kobo          bigint      NOT NULL DEFAULT 0,
  advances_kobo         bigint      NOT NULL DEFAULT 0,
  loan_repaid_kobo      bigint      NOT NULL DEFAULT 0,
  cash_paid_kobo        bigint      NOT NULL DEFAULT 0,
  total_pay_kobo        bigint      NOT NULL DEFAULT 0,
  salary_entry_id       uuid        REFERENCES public.payroll_entries(id),
  -- Both signatures as base64 PNG. Nullable only for imported history (#672);
  -- the app requires both before it saves.
  worker_signature_png  text,
  payer_signature_png   text,
  signed_by             uuid        REFERENCES public.users(id) ON DELETE SET NULL,
  signed_at             timestamptz,
  legacy_id             text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  last_updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_statements_worker_month_key UNIQUE (worker_id, salary_month)
);

-- One allowance per worker per day: the backstop to the deterministic id the
-- phones mint (payrollAllowanceId). A correction carries corrects_entry_id.
CREATE UNIQUE INDEX IF NOT EXISTS uq_payroll_entries_allowance_day
  ON public.payroll_entries (worker_id, entry_date)
  WHERE type = 'allowance' AND corrects_entry_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_payroll_entries_worker_date
  ON public.payroll_entries (business_id, worker_id, entry_date);
-- The old-POS import (#672) is safe to re-run: one row per legacy id.
CREATE UNIQUE INDEX IF NOT EXISTS uq_payroll_workers_legacy
  ON public.payroll_workers (business_id, legacy_id) WHERE legacy_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_payroll_entries_legacy
  ON public.payroll_entries (business_id, legacy_id) WHERE legacy_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_payroll_statements_legacy
  ON public.payroll_statements (business_id, legacy_id) WHERE legacy_id IS NOT NULL;

-- payroll_workers
CREATE INDEX IF NOT EXISTS idx_payroll_workers_business_lua
  ON public.payroll_workers (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_payroll_workers_last_updated_at ON public.payroll_workers;
CREATE TRIGGER bump_payroll_workers_last_updated_at
  BEFORE UPDATE ON public.payroll_workers
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

ALTER TABLE public.payroll_workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_workers FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_workers FROM anon;

DROP POLICY IF EXISTS "payroll_workers_payroll_select" ON public.payroll_workers;
CREATE POLICY "payroll_workers_payroll_select" ON public.payroll_workers
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'));

DROP POLICY IF EXISTS "payroll_workers_payroll_insert" ON public.payroll_workers;
CREATE POLICY "payroll_workers_payroll_insert" ON public.payroll_workers
  FOR INSERT TO authenticated
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));

-- UPDATE is allowed so the outbox upsert (INSERT ... ON CONFLICT DO UPDATE)
-- can replay; entries and statements freeze their content (section 3).
DROP POLICY IF EXISTS "payroll_workers_payroll_update" ON public.payroll_workers;
CREATE POLICY "payroll_workers_payroll_update" ON public.payroll_workers
  FOR UPDATE TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));
-- No DELETE policy: payroll history is never removed by a client.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
       AND tablename = 'payroll_workers'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.payroll_workers;
  END IF;
END $$;

DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.payroll_workers;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.payroll_workers
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- payroll_entries
CREATE INDEX IF NOT EXISTS idx_payroll_entries_business_lua
  ON public.payroll_entries (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_payroll_entries_last_updated_at ON public.payroll_entries;
CREATE TRIGGER bump_payroll_entries_last_updated_at
  BEFORE UPDATE ON public.payroll_entries
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

ALTER TABLE public.payroll_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_entries FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_entries FROM anon;

DROP POLICY IF EXISTS "payroll_entries_payroll_select" ON public.payroll_entries;
CREATE POLICY "payroll_entries_payroll_select" ON public.payroll_entries
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'));

DROP POLICY IF EXISTS "payroll_entries_payroll_insert" ON public.payroll_entries;
CREATE POLICY "payroll_entries_payroll_insert" ON public.payroll_entries
  FOR INSERT TO authenticated
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));

-- UPDATE is allowed so the outbox upsert (INSERT ... ON CONFLICT DO UPDATE)
-- can replay; entries and statements freeze their content (section 3).
DROP POLICY IF EXISTS "payroll_entries_payroll_update" ON public.payroll_entries;
CREATE POLICY "payroll_entries_payroll_update" ON public.payroll_entries
  FOR UPDATE TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));
-- No DELETE policy: payroll history is never removed by a client.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
       AND tablename = 'payroll_entries'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.payroll_entries;
  END IF;
END $$;

DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.payroll_entries;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.payroll_entries
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- payroll_statements
CREATE INDEX IF NOT EXISTS idx_payroll_statements_business_lua
  ON public.payroll_statements (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_payroll_statements_last_updated_at ON public.payroll_statements;
CREATE TRIGGER bump_payroll_statements_last_updated_at
  BEFORE UPDATE ON public.payroll_statements
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

ALTER TABLE public.payroll_statements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_statements FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.payroll_statements FROM anon;

DROP POLICY IF EXISTS "payroll_statements_payroll_select" ON public.payroll_statements;
CREATE POLICY "payroll_statements_payroll_select" ON public.payroll_statements
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'));

DROP POLICY IF EXISTS "payroll_statements_payroll_insert" ON public.payroll_statements;
CREATE POLICY "payroll_statements_payroll_insert" ON public.payroll_statements
  FOR INSERT TO authenticated
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));

-- UPDATE is allowed so the outbox upsert (INSERT ... ON CONFLICT DO UPDATE)
-- can replay; entries and statements freeze their content (section 3).
DROP POLICY IF EXISTS "payroll_statements_payroll_update" ON public.payroll_statements;
CREATE POLICY "payroll_statements_payroll_update" ON public.payroll_statements
  FOR UPDATE TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids())
         AND public.caller_has_permission(business_id, 'payroll.manage'))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids())
              AND public.caller_has_permission(business_id, 'payroll.manage'));
-- No DELETE policy: payroll history is never removed by a client.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
       AND tablename = 'payroll_statements'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.payroll_statements;
  END IF;
END $$;

DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.payroll_statements;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.payroll_statements
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- =========================================================================
-- 3. Append-only: entries and statements never change after insert.
--    An UPDATE (a phone replaying its upsert, or a second phone posting the
--    same deterministic allowance or statement id) keeps the FIRST writer's
--    content and only moves last_updated_at forward, so the losing phone's
--    next pull converges on the first writer (timestamp LWW). It never
--    raises, so a replay can never jam an outbox. It sorts after bump_*
--    (BEFORE triggers fire alphabetically), so its last_updated_at wins.
-- =========================================================================
CREATE OR REPLACE FUNCTION public._payroll_freeze_row()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW := OLD;
  NEW.last_updated_at := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._payroll_freeze_row() FROM public;

DROP TRIGGER IF EXISTS payroll_freeze_row ON public.payroll_entries;
CREATE TRIGGER payroll_freeze_row
  BEFORE UPDATE ON public.payroll_entries
  FOR EACH ROW EXECUTE FUNCTION public._payroll_freeze_row();

DROP TRIGGER IF EXISTS payroll_freeze_row ON public.payroll_statements;
CREATE TRIGGER payroll_freeze_row
  BEFORE UPDATE ON public.payroll_statements
  FOR EACH ROW EXECUTE FUNCTION public._payroll_freeze_row();

COMMIT;
