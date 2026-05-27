-- 0043_seed_permissions_and_backfill_businesses.sql
--
-- Two passes:
--   1. Seed the global `permissions` table with the 30 default keys.
--      Mirror this list in lib/core/database/app_database.dart
--      (`_defaultPermissionRows`) so client and cloud stay in step.
--   2. Backfill every existing business with 4 system-default roles,
--      63 role_permissions rows (CEO 30 + Manager 24 + Cashier 6 +
--      Stock keeper 3), 8 role_settings rows, plus 1 user_businesses
--      row for the lone CEO user and 1 user_stores row linking that
--      user to the business's single warehouse.
--
-- Idempotent: re-running this migration is a no-op (every INSERT
-- uses ON CONFLICT DO NOTHING).

BEGIN;

-- =========================================================================
-- 1. Seed permissions (30 rows). Categories group toggles in the
--    CEO Settings > Roles & Permissions sub-page.
-- =========================================================================

INSERT INTO public.permissions (key, description, category) VALUES
  -- Sales
  ('sales.make',                  'Make a sale',                                   'Sales'),
  ('sales.cancel',                'Cancel a sale',                                 'Sales'),
  ('sales.discount.give',         'Give a discount on a sale',                     'Sales'),
  -- Products
  ('products.add',                'Add a new product',                             'Products'),
  ('products.edit_price',         'Edit product prices',                           'Products'),
  ('products.edit_buying_price',  'Edit product buying price',                     'Products'),
  ('products.delete',             'Delete a product',                              'Products'),
  -- Stock
  ('stock.add',                   'Add stock to existing products',                'Stock'),
  ('stock.view',                  'View stock levels',                             'Stock'),
  ('stock.adjust',                'Adjust stock quantities (damages, theft, count)','Stock'),
  -- Expenses
  ('expenses.create',             'Record a new expense',                          'Expenses'),
  ('expenses.approve',            'Approve or reject pending expenses',            'Expenses'),
  -- Reports
  ('reports.see_sales',           'See sales reports',                             'Reports'),
  ('reports.see_profit',          'See profit reports',                            'Reports'),
  ('reports.see_cost_prices',     'See buying prices in reports',                  'Reports'),
  ('reports.see_expenses',        'See expense reports',                           'Reports'),
  -- Customers
  ('customers.add',               'Add a new customer',                            'Customers'),
  ('customers.update',            'Update customer details',                       'Customers'),
  ('customers.delete',            'Soft-delete a customer',                        'Customers'),
  ('customers.wallet.update',     'Add funds to customer wallets',                 'Customers'),
  -- Suppliers / Shipments
  ('suppliers.manage',            'Manage suppliers and payments',                 'Suppliers'),
  ('shipments.manage',            'Manage incoming shipments',                     'Suppliers'),
  -- Staff
  ('staff.invite',                'Generate staff invite codes',                   'Staff'),
  ('staff.suspend',               'Suspend or reactivate staff',                   'Staff'),
  ('staff.change_role',           'Change a staff member''s role',                 'Staff'),
  -- System
  ('activity_logs.view',          'View activity logs',                            'System'),
  ('settings.manage',             'Manage business settings',                      'System'),
  -- Funds Register
  ('funds.open_day',              'Open the day in Funds Register',                'Funds'),
  ('funds.close_day',             'Close the day in Funds Register',               'Funds'),
  ('funds.view',                  'View Funds Register balances',                  'Funds')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. Helper function: seed default roles + permissions + settings for
--    one business. Idempotent. Used by:
--      * The backfill loop below (existing businesses).
--      * The `complete_onboarding` RPC (new businesses) — see 0044.
--
-- Returns the four role ids as a record so callers can chain (e.g.
-- complete_onboarding seeds user_businesses for the CEO role id).
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
  -- 2a. Insert the four roles. ON CONFLICT (business_id, slug) is
  -- the natural idempotency key.
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

  -- 2b. Default permission matrix — 63 grants total.
  -- CEO: all 30 keys.
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: 24 keys (all except expenses.approve, reports.see_profit,
  -- suppliers.manage, shipments.manage, activity_logs.view, settings.manage).
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
    (p_business_id, v_mgr, 'staff.invite'),
    (p_business_id, v_mgr, 'staff.suspend'),
    (p_business_id, v_mgr, 'staff.change_role'),
    (p_business_id, v_mgr, 'funds.open_day'),
    (p_business_id, v_mgr, 'funds.close_day'),
    (p_business_id, v_mgr, 'funds.view')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: 6 keys.
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_cash, 'sales.make'),
    (p_business_id, v_cash, 'stock.view'),
    (p_business_id, v_cash, 'reports.see_sales'),
    (p_business_id, v_cash, 'customers.add'),
    (p_business_id, v_cash, 'customers.update'),
    (p_business_id, v_cash, 'customers.wallet.update')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Stock keeper: 3 keys. NB: products.add is intentionally NOT
  -- granted — only CEO and Manager can add new products. Stock
  -- keeper can only add stock and adjust quantities on existing
  -- products (master plan §16.7).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_sk, 'stock.add'),
    (p_business_id, v_sk, 'stock.view'),
    (p_business_id, v_sk, 'stock.adjust')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- 2c. Default role_settings — 8 rows (2 per role).
  --   max_discount_percent: CEO 100, Manager 10, Cashier 0, Stock 0.
  --   max_expense_approval_kobo: CEO NULL (unlimited), others 0.
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
-- 3. Backfill every existing business. For each business:
--    * Seed default roles + permissions + settings (via helper above).
--    * For the lone CEO user (whoever has a `users` row pointing at
--      the business), insert a user_businesses row with role=CEO,
--      status=active.
--    * For the same user, insert a user_stores row linking them to
--      the business's single warehouse (whichever warehouse the
--      user already had via the soon-to-be-dropped users.warehouse_id
--      column, or any non-deleted warehouse for the business).
--
-- Pre-pivot state: each business has exactly one user (the CEO) per
-- the staff cleanup in commit 38ea06b / migration 0041.
-- =========================================================================

DO $$
DECLARE
  v_business RECORD;
  v_user     RECORD;
  v_ceo_id   uuid;
  v_wh_id    uuid;
  v_seed_row RECORD;
BEGIN
  FOR v_business IN SELECT id FROM public.businesses LOOP
    -- Seed roles + permissions + settings. Capture the CEO role id
    -- for the user_businesses insert below.
    SELECT * INTO v_seed_row
      FROM public.seed_default_roles_for_business(v_business.id);
    v_ceo_id := v_seed_row.ceo_role_id;

    -- Find the lone user for this business. If none (orphan business),
    -- skip the membership rows — there's nobody to bind.
    FOR v_user IN
      SELECT id, warehouse_id FROM public.users
       WHERE business_id = v_business.id
       LIMIT 1
    LOOP
      -- user_businesses: bind user → business → CEO role.
      INSERT INTO public.user_businesses (
        business_id, user_id, role_id, status
      ) VALUES (
        v_business.id, v_user.id, v_ceo_id, 'active'
      )
      ON CONFLICT (user_id, business_id) DO NOTHING;

      -- user_stores: bind user → warehouse. Prefer the user's existing
      -- warehouse_id; fall back to any non-deleted warehouse for the
      -- business. Skip silently if the business has no warehouses.
      v_wh_id := v_user.warehouse_id;
      IF v_wh_id IS NULL THEN
        SELECT id INTO v_wh_id FROM public.warehouses
         WHERE business_id = v_business.id AND is_deleted = false
         LIMIT 1;
      END IF;

      IF v_wh_id IS NOT NULL THEN
        INSERT INTO public.user_stores (
          business_id, user_id, warehouse_id
        ) VALUES (
          v_business.id, v_user.id, v_wh_id
        )
        ON CONFLICT (user_id, warehouse_id) DO NOTHING;
      END IF;
    END LOOP;
  END LOOP;
END $$;

COMMIT;

-- =============================================================================
-- Verification queries (run by hand after deploy). Replace
-- '<BUSINESS_ID>' with a real id from `SELECT id FROM businesses`.
--
--   -- Permissions seeded:
--   SELECT COUNT(*) FROM public.permissions;          -- expect 30
--
--   -- Per-business sanity for any one business:
--   SELECT COUNT(*) FROM public.roles WHERE business_id = '<BUSINESS_ID>';
--     -- expect 4
--   SELECT slug FROM public.roles WHERE business_id = '<BUSINESS_ID>'
--     ORDER BY slug;
--     -- expect: cashier, ceo, manager, stock_keeper
--
--   SELECT r.slug, COUNT(rp.id) FROM public.roles r
--     LEFT JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE r.business_id = '<BUSINESS_ID>'
--    GROUP BY r.slug ORDER BY r.slug;
--     -- expect: cashier 6, ceo 30, manager 24, stock_keeper 3
--
--   SELECT r.slug, rs.setting_key, rs.setting_value
--     FROM public.roles r JOIN public.role_settings rs ON rs.role_id = r.id
--    WHERE r.business_id = '<BUSINESS_ID>' ORDER BY r.slug, rs.setting_key;
--     -- expect 8 rows; CEO max_expense_approval_kobo IS NULL;
--     -- Manager max_discount_percent = '10'; rest as documented.
--
--   SELECT COUNT(*) FROM public.user_businesses WHERE business_id = '<BUSINESS_ID>';
--     -- expect 1 (the CEO)
--   SELECT COUNT(*) FROM public.user_stores WHERE business_id = '<BUSINESS_ID>';
--     -- expect 1 (CEO → single warehouse)
-- =============================================================================
