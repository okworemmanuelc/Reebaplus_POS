-- 0095_add_stores_manage_permission.sql
--
-- Adds the `stores.manage` permission (master plan §10.2: the "Add, edit, and
-- remove stores" toggle in CEO Settings > Roles & Permissions, Stores section).
-- It gates the sidebar Stores screen (add / edit / delete / stock transfer) and
-- the Settings > Stores name/address editor, which previously rode on the
-- generic `settings.manage` key.
--
-- CEO-ONLY by default (store management has always been CEO-only). The CEO can
-- grant it to other roles via the role page. So, unlike 0069, the
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
-- (`_defaultPermissionRows`, + the v38 onUpgrade INSERT OR IGNORE) so client and
-- cloud stay in step.

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('stores.manage', 'Add, edit, and remove stores', 'Stores')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. Backfill existing businesses. Grant the new key to every CEO role.
--    last_updated_at = now() so the incremental pull (0048) ships it.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'stores.manage', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT COUNT(*) FROM public.permissions WHERE key = 'stores.manage'; -- 1
--   SELECT r.slug, COUNT(*) FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key = 'stores.manage'
--    GROUP BY r.slug;  -- expect only ceo, one per business
-- =============================================================================
