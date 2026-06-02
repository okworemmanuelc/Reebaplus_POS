-- 0069_customers_wallet_totals_view_permission.sql
--
-- Adds the `customers.wallet.totals.view` permission (master plan §18.4: the
-- Total In / Total Out tiles on a customer's Wallet tab are hidden for roles
-- below Manager unless the CEO grants this key. Manager + CEO always see them
-- via a role-rank check in code, so this grant only matters for Cashier /
-- Stock keeper).
--
-- Three idempotent passes (same shape as 0061):
--   1. Insert the key into the global `permissions` catalog.
--   2. CREATE OR REPLACE seed_default_roles_for_business so NEW businesses grant
--      it to Manager. CEO already receives every key via
--      `SELECT key FROM permissions`, so only the Manager list needs the line.
--   3. Backfill every EXISTING business: grant it to all CEO and Manager roles,
--      stamping last_updated_at so the incremental pull (0048) ships it to
--      devices on their next sync.
--
-- Mirror the catalog row in lib/core/database/app_database.dart
-- (`_defaultPermissionRows`, + the v28 onUpgrade INSERT OR IGNORE) so client and
-- cloud stay in step.

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('customers.wallet.totals.view', 'View wallet Total In / Total Out on a customer', 'Customers')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. New-business seed. Verbatim copy of the 0061 function with one added
--    Manager grant line (customers.wallet.totals.view). CEO still gets every
--    key via the SELECT, so its block is unchanged.
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

  -- CEO: all keys (now includes customers.wallet.totals.view via the SELECT).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: explicit list + customers.wallet.totals.view (§18.4).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_mgr, 'sales.make'),
    (p_business_id, v_mgr, 'sales.cancel'),
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
    (p_business_id, v_mgr, 'staff.invite'),
    (p_business_id, v_mgr, 'staff.suspend'),
    (p_business_id, v_mgr, 'staff.change_role'),
    (p_business_id, v_mgr, 'funds.open_day'),
    (p_business_id, v_mgr, 'funds.close_day'),
    (p_business_id, v_mgr, 'funds.view')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: 6 keys (unchanged — wallet totals stay hidden until the CEO grants).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_cash, 'sales.make'),
    (p_business_id, v_cash, 'stock.view'),
    (p_business_id, v_cash, 'reports.see_sales'),
    (p_business_id, v_cash, 'customers.add'),
    (p_business_id, v_cash, 'customers.update'),
    (p_business_id, v_cash, 'customers.wallet.update')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Stock keeper: 3 keys (unchanged).
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
-- 3. Backfill existing businesses. Grant the new key to every CEO and Manager
--    role. last_updated_at = now() so the incremental pull (0048) ships it.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'customers.wallet.totals.view', now()
    FROM public.roles
   WHERE slug IN ('ceo', 'manager')
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT COUNT(*) FROM public.permissions WHERE key = 'customers.wallet.totals.view'; -- 1
--   SELECT r.slug, COUNT(*) FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key = 'customers.wallet.totals.view'
--    GROUP BY r.slug;  -- expect only ceo + manager, one per business each
-- =============================================================================
