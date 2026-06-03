-- 0087_rename_permission_labels.sql
--
-- Label-only renames of three permission catalogue entries (user request):
--   products.edit_price        : 'Edit product prices'        -> 'Edit product'
--   products.edit_buying_price : 'Edit product buying price'  -> 'View buying price'
--   stock.view                 : 'View stock levels'          -> 'View Inventory'
--
-- Enforcement is unchanged — only the displayed `description` text differs.
-- The keys, categories, grants and dependencies all stay the same.
--
-- Mirrors the client-side change in lib/core/database/app_database.dart
-- (`_defaultPermissionRows` + the v32 onUpgrade UPDATEs). Existing devices pick
-- up the new labels via that local v32 migration (the `permissions` catalogue is
-- seeded once per device, not re-synced); this cloud change keeps the catalogue
-- in step and stamps last_updated_at so any incremental pull also ships it.
--
-- Idempotent: re-running just re-sets the same descriptions.

BEGIN;

UPDATE public.permissions
   SET description = 'Edit product', last_updated_at = now()
 WHERE key = 'products.edit_price';

UPDATE public.permissions
   SET description = 'View buying price', last_updated_at = now()
 WHERE key = 'products.edit_buying_price';

UPDATE public.permissions
   SET description = 'View Inventory', last_updated_at = now()
 WHERE key = 'stock.view';

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--   SELECT key, description FROM public.permissions
--    WHERE key IN ('products.edit_price', 'products.edit_buying_price', 'stock.view');
--   -- expect: Edit product / View buying price / View Inventory
-- =============================================================================
