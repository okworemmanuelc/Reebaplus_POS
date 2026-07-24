-- 0154_money_integrity_confirm_gate.sql
--
-- #171 / PRD #155 — Confirm safety. Adds the `sales.confirm` permission that
-- gates the Confirm ceremony (crate-deposit settlement + pending→completed flip)
-- on the Orders Pending tab. Confirm moves real money (deposit forfeit / refund /
-- shortfall), so it is no longer ungated: it is granted **Cashier-tier and
-- above** by default (CEO + Manager + Cashier; a Stock keeper does NOT get it).
-- The cash-refund branch additionally requires the existing
-- `customers.wallet.withdraw` key — enforced client-side by the composite gate,
-- no separate key needed here.
--
-- Deploy-ordering: this must land on the cloud BEFORE any client on Drift
-- schema v65 pushes a role_permissions grant for `sales.confirm` — the catalog
-- key must exist first (role_permissions.permission_key FK), or the grant upsert
-- fails and jams the outbox. Mirror the catalog row in
-- lib/core/database/app_database.dart (`_defaultPermissionRows` + the v65
-- onUpgrade INSERT OR IGNORE) so client and cloud stay in step.
--
-- Three idempotent passes (same shape as 0122):
--   1. Insert the `sales.confirm` key into the global `permissions` catalog.
--   2. CREATE OR REPLACE seed_default_roles_for_business so NEW businesses grant
--      the key to Manager + Cashier. CEO already receives every key via
--      `SELECT key FROM permissions`, so its block is unchanged. The signature is
--      unchanged, so this is a plain replace (no overload).
--   3. Backfill every EXISTING business: grant `sales.confirm` to all CEO +
--      Manager + Cashier roles, stamping last_updated_at so the incremental pull
--      (0048) ships them to devices.
--
-- The Manager + Cashier grant lists below are copied VERBATIM from 0122 with one
-- added line each (`sales.confirm`). The `funds.*` rows are dead grants left from
-- the removed Funds Register — preserved unchanged to keep this a surgical clone.

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('sales.confirm', 'Confirm an order and settle crate deposits', 'Sales')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. New-business seed. Verbatim copy of the 0122 function with one added
--    Manager grant line and one added Cashier grant line (`sales.confirm`).
--    CEO still gets every key via the SELECT, so its block is unchanged.
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

  -- CEO: all keys (includes the new sales.confirm key via the SELECT).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: explicit list + sales.confirm (#171 Confirm gate).
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
    (p_business_id, v_mgr, 'funds.open_day'),
    (p_business_id, v_mgr, 'funds.close_day'),
    (p_business_id, v_mgr, 'funds.view')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: 6 keys + sales.confirm (#171 — Cashier-tier and above can Confirm).
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

  -- Stock keeper: 3 keys (unchanged — a stock keeper canNOT Confirm).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_sk, 'stock.add'),
    (p_business_id, v_sk, 'stock.view'),
    (p_business_id, v_sk, 'stock.adjust')
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
    (p_business_id, v_sk,   'max_expense_approval_kobo',   '0')
  ON CONFLICT (role_id, setting_key) DO NOTHING;

  RETURN QUERY SELECT v_ceo, v_mgr, v_cash, v_sk;
END;
$function$;

REVOKE ALL    ON FUNCTION public.seed_default_roles_for_business(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.seed_default_roles_for_business(uuid) TO authenticated, service_role;

-- =========================================================================
-- 3. Backfill existing businesses: grant sales.confirm to every CEO + Manager +
--    Cashier role (Cashier-tier and above). last_updated_at = now() so the
--    incremental pull (0048) ships the grants to devices.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'sales.confirm', now()
    FROM public.roles
   WHERE slug IN ('ceo', 'manager', 'cashier')
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT key FROM public.permissions WHERE key = 'sales.confirm'; -- 1 row
--   SELECT r.slug, COUNT(*)
--     FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key = 'sales.confirm'
--    GROUP BY r.slug ORDER BY r.slug;
--   -- expect: ceo + manager + cashier (one per business); NOT stock_keeper
-- =============================================================================
