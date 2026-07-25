-- 0161_van_sales_prefactor.sql
--
-- #140 / PRD #139, ADR 0019 — Van Sales 1/8: van-as-location + Driver role.
-- Design record: docs/design/van-sales-spec.md §4.1, §10, §14.
--
-- This is the prefactor every later van slice inherits. It ships NO selling and
-- NO reconciliation — only the schema, the role and the permission keys, landed
-- migration-first so nothing downstream has to invent them.
--
-- Four idempotent passes:
--   1. stores.kind — 'store' | 'van'. A van is a `stores` row so it inherits
--      inventory, transfers, FIFO costing and offline sync for free; `kind` is
--      the one field that keeps it out of every normal store surface.
--   2. Catalogue — the `van.manage` and `van.sell` permission keys.
--   3. New-business seed — seed_default_roles_for_business gains the Driver
--      role plus the van grants (CEO via its all-keys SELECT, Manager and
--      Driver explicitly).
--   4. Backfill — a Driver role + its `van.sell` grant, and `van.manage` for
--      every existing CEO and Manager.
--
-- DEPLOY-ORDERING (project_permission_key_cloud_fk_deploy). This must land on
-- the cloud BEFORE any client on Drift schema v70 pushes a role_permissions
-- grant for `van.manage` / `van.sell` — the catalogue key must exist first
-- (role_permissions.permission_key FK) or the grant upsert fails and jams the
-- outbox. The client mirrors the catalogue rows in
-- lib/core/database/app_database.dart (`_defaultPermissionRows` + the v70
-- onUpgrade INSERT OR IGNORE); role rows are NEVER minted by the client, they
-- arrive here and sync down.
--
-- NAMING COLLISION — READ THIS BEFORE THE NEXT VAN SLICE (spec §14). The
-- dormant `drivers` and `delivery_receipts` tables (registered for sync, in
-- pos_pull_snapshot, with NO DAO, provider or UI on the client) are a DIFFERENT
-- AXIS and are deliberately left untouched here. A van-sales driver is a
-- `users` row holding the seeded Driver role, assigned to a van through
-- `user_stores`. `van_trips.driver_user_id` (#141) references `users`, never
-- `drivers`. Retiring the legacy pair is a separate dead-code sweep.
--
-- No pos_pull_snapshot change is needed: `stores` is already in the
-- v_tenant_tables array and the RPC ships whole rows (`to_jsonb(t)`), so the
-- new column rides along. `stores` is likewise a pass-through push entry in the
-- client's sync registry, so no registry or golden-test change either.

BEGIN;

-- =========================================================================
-- 1. stores.kind
--    TEXT NOT NULL DEFAULT 'store' — every existing row becomes a normal
--    store. The CHECK is added separately (and guarded) because ADD COLUMN
--    IF NOT EXISTS is not re-runnable together with a named constraint.
-- =========================================================================
ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'store';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.stores'::regclass
       AND conname  = 'stores_kind_check'
  ) THEN
    ALTER TABLE public.stores
      ADD CONSTRAINT stores_kind_check CHECK (kind IN ('store','van'));
  END IF;
END
$$;

COMMENT ON COLUMN public.stores.kind IS
  '#140 van sales: ''store'' (a normal location) or ''van'' (holds stock on the '
  'road). A van is hidden from every normal store picker, store list and '
  'per-store report; its stock still counts as company stock in All-Stores '
  'inventory value and business worth. See docs/design/van-sales-spec.md §4.1.';

-- Vans are read on every van surface and are a tiny slice of the table; the
-- partial index keeps "list this business's vans" a lookup rather than a scan.
CREATE INDEX IF NOT EXISTS idx_stores_business_van
  ON public.stores (business_id)
  WHERE kind = 'van';

-- =========================================================================
-- 2. Permission catalogue.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('van.manage', 'Set up vans and run driver reconciliation', 'Van Sales'),
  ('van.sell',   'Sell from a van on the road',                'Van Sales')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 3. New-business seed. Verbatim copy of the 0154 function with:
--      * the Driver role INSERT (slug 'driver'),
--      * `van.manage` added to the Manager grant list,
--      * a new Driver grant block (`van.sell` only),
--      * Driver role_settings rows (no discount, no expense approval).
--    CEO still receives every key via its SELECT, so its block is unchanged.
--
--    The signature and RETURNS TABLE shape are UNCHANGED on purpose — Postgres
--    cannot CREATE OR REPLACE a function whose return type changed, and every
--    caller (complete_onboarding, the backfills) only needs the CEO role id.
--    The Driver role id is therefore seeded but not returned. This also keeps
--    us clear of the parameter-overload trap: same signature, plain replace.
-- =========================================================================
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
  -- them and records remittances; they never sell from one).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_mgr, 'sales.make'),
    (p_business_id, v_mgr, 'sales.cancel'),
    (p_business_id, v_mgr, 'sales.confirm'),
    (p_business_id, v_mgr, 'sales.discount.give'),
    (p_business_id, v_mgr, 'products.add'),
    (p_business_id, v_mgr, 'products.edit_price'),
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
    (p_business_id, v_mgr, 'funds.view')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: unchanged.
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_cash, 'sales.make'),
    (p_business_id, v_cash, 'sales.confirm'),
    (p_business_id, v_cash, 'stock.view'),
    (p_business_id, v_cash, 'reports.see_sales'),
    (p_business_id, v_cash, 'customers.add'),
    (p_business_id, v_cash, 'customers.update'),
    (p_business_id, v_cash, 'customers.wallet.update')
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

REVOKE ALL    ON FUNCTION public.seed_default_roles_for_business(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.seed_default_roles_for_business(uuid) TO authenticated, service_role;

-- =========================================================================
-- 4. Backfill existing businesses.
--    last_updated_at = now() everywhere so the incremental pull (0048) ships
--    the new rows to devices.
-- =========================================================================

-- 4a. A Driver role per business that doesn't have one.
INSERT INTO public.roles (id, business_id, name, slug, is_system_default, last_updated_at)
  SELECT gen_random_uuid(), b.id, 'Driver', 'driver', true, now()
    FROM public.businesses b
ON CONFLICT (business_id, slug) DO NOTHING;

-- 4b. `van.sell` for every Driver role.
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'van.sell', now()
    FROM public.roles
   WHERE slug = 'driver'
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- 4c. `van.manage` for every CEO + Manager role.
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'van.manage', now()
    FROM public.roles
   WHERE slug IN ('ceo', 'manager')
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- 4d. The CEO holds every key by definition, so it also gets `van.sell`
--     (locked all-on client-side; this keeps the row set consistent with the
--     "CEO: all keys" invariant the seed function asserts).
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'van.sell', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- 4e. Default role_settings for the backfilled Driver roles.
INSERT INTO public.role_settings (business_id, role_id, setting_key, setting_value, last_updated_at)
  SELECT business_id, id, 'max_discount_percent', '0', now()
    FROM public.roles WHERE slug = 'driver'
ON CONFLICT (role_id, setting_key) DO NOTHING;

INSERT INTO public.role_settings (business_id, role_id, setting_key, setting_value, last_updated_at)
  SELECT business_id, id, 'max_expense_approval_kobo', '0', now()
    FROM public.roles WHERE slug = 'driver'
ON CONFLICT (role_id, setting_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--
--   -- 1. Column + constraint.
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_name = 'stores' AND column_name = 'kind';
--   -- expect: kind | text | NO | 'store'::text
--
--   SELECT conname FROM pg_constraint
--    WHERE conrelid = 'public.stores'::regclass AND conname = 'stores_kind_check';
--   -- expect: 1 row
--
--   SELECT kind, COUNT(*) FROM public.stores GROUP BY kind;
--   -- expect: store | <every existing row>
--
--   -- 2. Catalogue.
--   SELECT key, category FROM public.permissions WHERE key LIKE 'van.%';
--   -- expect: van.manage + van.sell, both category 'Van Sales'
--
--   -- 3/4. Roles + grants, one row per business each.
--   SELECT COUNT(*) FROM public.businesses;
--   SELECT COUNT(*) FROM public.roles WHERE slug = 'driver';
--   -- expect: equal
--
--   SELECT r.slug, rp.permission_key, COUNT(*)
--     FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key LIKE 'van.%'
--    GROUP BY r.slug, rp.permission_key ORDER BY r.slug, rp.permission_key;
--   -- expect: ceo(van.manage, van.sell), manager(van.manage), driver(van.sell);
--   --         NOT cashier, NOT stock_keeper
-- =============================================================================
