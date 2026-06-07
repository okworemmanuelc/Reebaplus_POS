-- 0103_add_stores_receive_transfer_permission.sql
--
-- Adds the `stores.receive_transfer` permission (master plan §16.8.1: the
-- "Confirm receipt of an incoming stock transfer" action, distinct from
-- `stores.manage` which gates create/cancel).
--
-- CEO-ONLY by default. The CEO can grant it to other roles (e.g. Manager or
-- Stock keeper at the destination store) via the role page or per-store
-- overrides (§10.2.1). Unlike `stores.manage`, confirming receipt is a
-- routine destination-store action that managers/stock keepers may need.
--
-- Two idempotent passes (mirrors 0095_add_stores_manage_permission.sql):
--   1. Insert the key into the global `permissions` catalog.
--   2. Backfill every existing business: grant it to all CEO roles, stamping
--      last_updated_at so the incremental pull ships it to devices on next sync.
--      New businesses get it automatically via the CEO's dynamic SELECT in
--      seed_default_roles_for_business.
--
-- Mirror the catalog row in lib/core/database/app_database.dart
-- (`_defaultPermissionRows` + the v44 onUpgrade INSERT OR IGNORE) so client
-- and cloud stay in step.

BEGIN;

-- =========================================================================
-- 1. Catalog.
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('stores.receive_transfer', 'Confirm receipt of incoming stock transfers', 'Stores')
ON CONFLICT (key) DO NOTHING;

-- =========================================================================
-- 2. Backfill existing businesses. Grant the new key to every CEO role.
--    last_updated_at = now() so the incremental pull (0048) ships it.
-- =========================================================================
INSERT INTO public.role_permissions (business_id, role_id, permission_key, last_updated_at)
  SELECT business_id, id, 'stores.receive_transfer', now()
    FROM public.roles
   WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT COUNT(*) FROM public.permissions WHERE key = 'stores.receive_transfer'; -- 1
--   SELECT r.slug, COUNT(*) FROM public.roles r
--     JOIN public.role_permissions rp ON rp.role_id = r.id
--    WHERE rp.permission_key = 'stores.receive_transfer'
--    GROUP BY r.slug;  -- expect only ceo, one per business
-- =============================================================================
