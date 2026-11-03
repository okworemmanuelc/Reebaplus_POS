-- #667 tier-2 SQL companion (reebaplus-dev ONLY, after applying 0243). One
-- transaction, rolled back; fixture names are made up.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/payroll_rls.sql
-- Asserts (ADR 0034):
--   * a Manager (role grant) reads and writes payroll rows;
--   * a Cashier of the SAME business reads nothing and cannot insert;
--   * a force-revoke override takes the Manager's access away;
--   * an allowance re-pushed under the same id stays ONE row and keeps the
--     first writer's amount (0243 freeze trigger);
--   * pos_pull_snapshot does not return the payroll tables.
BEGIN;

SELECT set_config('t.biz',  gen_random_uuid()::text, true),
       set_config('t.store', gen_random_uuid()::text, true),
       set_config('t.r_mgr', gen_random_uuid()::text, true),
       set_config('t.r_cash', gen_random_uuid()::text, true),
       set_config('t.a_mgr', gen_random_uuid()::text, true),
       set_config('t.a_cash', gen_random_uuid()::text, true),
       set_config('t.u_mgr', gen_random_uuid()::text, true),
       set_config('t.u_cash', gen_random_uuid()::text, true),
       set_config('t.worker', gen_random_uuid()::text, true),
       set_config('t.entry', gen_random_uuid()::text, true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.a_mgr')::uuid,  current_setting('t.a_mgr')  || '@example.invalid'),
  (current_setting('t.a_cash')::uuid, current_setting('t.a_cash') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Payroll RLS fixture', 'trial');  -- trial = premium limits, so two staff fit
INSERT INTO public.stores (id, business_id, name)
VALUES (current_setting('t.store')::uuid, current_setting('t.biz')::uuid, 'Main');
INSERT INTO public.roles (id, business_id, name, slug) VALUES
  (current_setting('t.r_mgr')::uuid,  current_setting('t.biz')::uuid, 'Manager', 'manager'),
  (current_setting('t.r_cash')::uuid, current_setting('t.biz')::uuid, 'Cashier', 'cashier');
INSERT INTO public.role_permissions (business_id, role_id, permission_key)
VALUES (current_setting('t.biz')::uuid, current_setting('t.r_mgr')::uuid, 'payroll.manage');
INSERT INTO public.users (id, business_id, name, auth_user_id) VALUES
  (current_setting('t.u_mgr')::uuid,  current_setting('t.biz')::uuid, 'Test Manager', current_setting('t.a_mgr')::uuid),
  (current_setting('t.u_cash')::uuid, current_setting('t.biz')::uuid, 'Test Cashier', current_setting('t.a_cash')::uuid);
INSERT INTO public.user_businesses (business_id, user_id, role_id, status) VALUES
  (current_setting('t.biz')::uuid, current_setting('t.u_mgr')::uuid,  current_setting('t.r_mgr')::uuid,  'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_cash')::uuid, current_setting('t.r_cash')::uuid, 'active');
INSERT INTO public.profiles (id, business_id, name) VALUES
  (current_setting('t.a_mgr')::uuid,  current_setting('t.biz')::uuid, 'Test Manager'),
  (current_setting('t.a_cash')::uuid, current_setting('t.biz')::uuid, 'Test Cashier')
ON CONFLICT (id) DO UPDATE SET business_id = EXCLUDED.business_id;

-- Act as the Manager.
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('t.a_mgr'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
INSERT INTO public.payroll_workers (id, business_id, store_id, name, daily_allowance_kobo)
VALUES (current_setting('t.worker')::uuid, current_setting('t.biz')::uuid,
        current_setting('t.store')::uuid, 'Test Worker', 5000);
INSERT INTO public.payroll_entries
  (id, business_id, worker_id, store_id, type, amount_kobo, entry_date)
VALUES (current_setting('t.entry')::uuid, current_setting('t.biz')::uuid,
        current_setting('t.worker')::uuid, current_setting('t.store')::uuid,
        'allowance', 5000, DATE '2026-11-03');
-- A second phone posts the same allowance id with a stale amount (upsert).
INSERT INTO public.payroll_entries
  (id, business_id, worker_id, store_id, type, amount_kobo, entry_date)
VALUES (current_setting('t.entry')::uuid, current_setting('t.biz')::uuid,
        current_setting('t.worker')::uuid, current_setting('t.store')::uuid,
        'allowance', 4000, DATE '2026-11-03')
ON CONFLICT (id) DO UPDATE SET amount_kobo = EXCLUDED.amount_kobo;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.payroll_workers) <> 1 THEN
    RAISE EXCEPTION 'manager cannot read the worker';
  END IF;
  IF (SELECT count(*) FROM public.payroll_entries) <> 1
     OR (SELECT amount_kobo FROM public.payroll_entries) <> 5000 THEN
    RAISE EXCEPTION 'allowance replay did not land as one frozen row';
  END IF;
END $$;
RESET ROLE;

-- Act as the Cashier: same business, no permission.
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('t.a_cash'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.payroll_workers) <> 0
     OR (SELECT count(*) FROM public.payroll_entries) <> 0
     OR (SELECT count(*) FROM public.payroll_statements) <> 0 THEN
    RAISE EXCEPTION 'cashier can read payroll rows';
  END IF;
  BEGIN
    INSERT INTO public.payroll_workers (business_id, store_id, name)
    VALUES (current_setting('t.biz')::uuid, current_setting('t.store')::uuid, 'Test Worker 2');
    RAISE EXCEPTION 'cashier inserted a payroll worker';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF (public.pos_pull_snapshot(current_setting('t.biz')::uuid, NULL)
        ?| ARRAY['payroll_workers','payroll_entries','payroll_statements']) THEN
    RAISE EXCEPTION 'pos_pull_snapshot returns payroll tables';
  END IF;
END $$;
RESET ROLE;

-- Revoke the Manager by override: access is gone.
INSERT INTO public.user_permission_overrides (business_id, user_id, permission_key, is_granted)
VALUES (current_setting('t.biz')::uuid, current_setting('t.u_mgr')::uuid, 'payroll.manage', false);
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('t.a_mgr'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.payroll_workers) <> 0 THEN
    RAISE EXCEPTION 'revoked manager can still read payroll rows';
  END IF;
END $$;
RESET ROLE;

SELECT 'payroll RLS: manager rw, cashier denied, revoke denied, replay frozen, '
       'snapshot excludes payroll — passed' AS checks;
ROLLBACK;
