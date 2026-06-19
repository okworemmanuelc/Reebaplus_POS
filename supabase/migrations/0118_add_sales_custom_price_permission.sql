-- 0118_add_sales_custom_price_permission.sql
--
-- Adds the `sales.set_custom_price` permission — gates setting a custom unit
-- price on a cart line at the point of sale (selling an item for a price other
-- than its designated selling price). This is distinct from
-- `sales.discount.give` (which is governed by the per-role discount slider):
-- a custom price overrides the unit price itself, while a discount subtracts
-- from the line total.
--
-- CEO-ONLY by default. The CEO can grant it to other roles (e.g. a trusted
-- Manager) via the role page or per-store overrides (§10.2.1). It surfaces as
-- a normal toggle on the Roles & Permissions screen (NOT hidden).
--
-- Two idempotent passes (mirrors 0103_add_stores_receive_transfer_permission.sql):
--   1. Insert the key into the global `permissions` catalog.
--   2. Backfill every existing business: grant it to all CEO roles, stamping
--      last_updated_at so the incremental pull ships it to devices on next sync.
--      New businesses get it automatically via the CEO's dynamic SELECT in
--      seed_default_roles_for_business.
--
-- Mirror the catalog row in lib/core/database/app_database.dart
-- (`_defaultPermissionRows` + the v54 onUpgrade INSERT OR IGNORE) so client
-- and cloud stay in step.

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('sales.set_custom_price', 'Set a custom price on a cart item', 'Sales')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. Backfill existing businesses. Grant the new key to every CEO role.
--    last_updated_at = now() so the incremental pull (0048) ships it.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'sales.set_custom_price', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT COUNT(*) FROM public.permissions WHERE key = 'sales.set_custom_price'; -- 1
--   SELECT r.slug, COUNT(*) FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key = 'sales.set_custom_price'
--    GROUP BY r.slug;  -- expect only ceo, one per business
-- =============================================================================
