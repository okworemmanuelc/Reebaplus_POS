-- 0096_add_staff_assign_stores_permission.sql
--
-- Adds the `staff.assign_stores` permission (master plan §9.5: the "Assign staff
-- to stores" capability on a staff member's profile). It gates the CEO adding /
-- removing the stores a staff member works at — the `user_stores` set the Home
-- store-lock reads. Separate from `staff.change_role` / `staff.suspend`.
--
-- CEO-ONLY by default (store assignment has always been a CEO concern). The CEO
-- can grant it to other roles via the role page. So, like 0095, the
-- seed_default_roles_for_business function needs NO change: the CEO already
-- receives every catalog key via its `SELECT key FROM permissions` grant, and no
-- other role gets it by default.
--
-- Two idempotent passes:
--   1. Insert the key into the global `permissions` catalog.
--   2. Backfill every EXISTING business: grant it to all CEO roles, stamping
--      last_updated_at so the incremental pull (0048) ships it to devices on
--      their next sync. (New businesses get it automatically via the CEO's
--      dynamic SELECT in seed_default_roles_for_business.)
--
-- Mirror the catalog row in lib/core/database/app_database.dart
-- (`_defaultPermissionRows`, + the v39 onUpgrade INSERT OR IGNORE) so client and
-- cloud stay in step.

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('staff.assign_stores', 'Assign staff to stores', 'Staff')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. Backfill existing businesses. Grant the new key to every CEO role.
--    last_updated_at = now() so the incremental pull (0048) ships it.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'staff.assign_stores', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT COUNT(*) FROM public.permissions WHERE key = 'staff.assign_stores'; -- 1
--   SELECT r.slug, COUNT(*) FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key = 'staff.assign_stores'
--    GROUP BY r.slug;  -- expect only ceo, one per business
-- =============================================================================
