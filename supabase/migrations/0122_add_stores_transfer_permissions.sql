-- 0122_add_stores_transfer_permissions.sql
--
-- Adds the two store-transfer permissions for the requester-initiated transfer
-- flow (store-scoped Stock Transfer redesign):
--   * stores.request_transfer  — "Request stock from another store" (a store
--     raises a pending request to a holder store).
--   * stores.dispatch_transfer — "Approve and dispatch stock requests from your
--     store" (the holder store accepts a request, may alter the quantity, and
--     dispatches — decrementing its own stock and putting the transfer
--     in_transit).
--
-- Both are CEO + Manager by default. This migration ALSO grants the existing
-- `stores.receive_transfer` (added CEO-only in 0103) to Manager, so a Manager
-- can run the full request → dispatch → receive loop for their store.
-- `stores.manage` is intentionally untouched — it stays CEO-only and now means
-- store CRUD only (Add/Edit/Delete a store), not transfers.
--
-- Four idempotent passes (same shape as 0098 / 0103):
--   1. Insert the two keys into the global `permissions` catalog.
--   2. CREATE OR REPLACE seed_default_roles_for_business so NEW businesses grant
--      the three keys to Manager. CEO already receives every key via
--      `SELECT key FROM permissions`, so its block is unchanged.
--   3. Backfill every EXISTING business: grant the two NEW keys to all CEO +
--      Manager roles, and grant the existing receive_transfer to Manager,
--      stamping last_updated_at so the incremental pull (0048) ships them.
--
-- The Manager grant list below is copied VERBATIM from 0098 with three added
-- lines (stores.request_transfer, stores.dispatch_transfer,
-- stores.receive_transfer). The `funds.*` rows are dead grants left from the
-- removed Funds Register — preserved unchanged to keep this a surgical clone.
--
-- Mirror the catalog rows in lib/core/database/app_database.dart
-- (`_defaultPermissionRows` + the v56 onUpgrade INSERT OR IGNORE) so client and
-- cloud stay in step. Deploy this BEFORE any client grants reference the keys
-- (catalog rows must exist for the role_permissions FK).

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('stores.request_transfer',  'Request stock from another store',                      'Stores'),
  ('stores.dispatch_transfer', 'Approve and dispatch stock requests from your store',   'Stores')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. New-business seed. Verbatim copy of the 0098 function with three added
--    Manager grant lines. CEO still gets every key via the SELECT, so its
--    block is unchanged.
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

  -- CEO: all keys (includes the new store-transfer keys via the SELECT).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: explicit list + the three store-transfer keys (store-scoped
  -- Stock Transfer redesign). Manager runs request → dispatch → receive.
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

  -- Cashier: 6 keys (unchanged).
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
-- 3. Backfill existing businesses.
--    a) The two NEW keys → every CEO + Manager role.
--    b) The existing receive_transfer → every Manager role (0103 gave it to
--       CEO only). last_updated_at = now() so the incremental pull ships them.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'stores.request_transfer', now()
    FROM public.roles
   WHERE slug IN ('ceo', 'manager')
ON CONFLICT (role_id, permission_key) DO NOTHING;

INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'stores.dispatch_transfer', now()
    FROM public.roles
   WHERE slug IN ('ceo', 'manager')
ON CONFLICT (role_id, permission_key) DO NOTHING;

INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'stores.receive_transfer', now()
    FROM public.roles
   WHERE slug = 'manager'
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT key FROM public.permissions
--    WHERE key IN ('stores.request_transfer','stores.dispatch_transfer'); -- 2 rows
--   SELECT r.slug, rp.permission_key, COUNT(*)
--     FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key IN
--          ('stores.request_transfer','stores.dispatch_transfer','stores.receive_transfer')
--    GROUP BY r.slug, rp.permission_key ORDER BY rp.permission_key, r.slug;
--   -- expect: request/dispatch → ceo + manager; receive → ceo + manager
-- =============================================================================
