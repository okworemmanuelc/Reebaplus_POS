-- 0204_product_photos.sql
--
-- #474 (PRD #421): up to 5 photos per product.
-- Cloud twin of Drift schemaVersion 91 (app_database.dart, `from < 91`).
--
-- THE MODEL
--   Gallery position 1 is the cover photo and stays in products.image_url —
--   every existing screen, the till, the barcode-catalogue share (#322,
--   share-barcode-photo) and the storefront cards keep reading it unchanged.
--   product_photos holds gallery positions 2-5 (at most 4 rows live per
--   product), so a product shows at most 5 photos.
--
--   Each (product, position) is a SLOT with a deterministic client id
--   (uuid v5 of product + position). Reordering or removing a photo moves
--   image_url values between slot rows and soft-deletes the slots left over;
--   positions never change on a row. That keeps the unique live (product,
--   position) index below free of transient collisions during a batched
--   upsert, and two phones editing the same slot offline converge by
--   last-write-wins on the same row instead of jamming the outbox with 23505.
--
--   Objects live in bucket product-images at
--   <businessId>/<productId>/<photoId>.jpg (a fresh photoId per photo, never
--   overwritten). The existing 0144 write policies already gate on the first
--   folder segment, and 0186's 1 MB / image-type limits apply unchanged, so
--   no storage policy changes. A photo added offline is written with its
--   final public URL before the bytes upload; the storefront RPC below only
--   returns a gallery photo once its object exists.
--
-- WHAT THIS ADDS
--   1. product_photos (synced, soft-deleted, RLS current_user_business_ids(),
--      realtime publication, zz_broadcast_sync_signal, bump trigger).
--   2. pos_pull_snapshot re-issued VERBATIM from 0203 with product_photos
--      added after products (its FK parent).
--   3. storefront_product_photos(p_store_id, p_product_id): signed-out,
--      ordered photo URLs of one listed product. It reuses 0202's server-only
--      _storefront_stores() for the store/business hide rules, so DEPLOY 0204
--      AFTER 0202 (plpgsql resolves it at call time; the migration itself
--      applies either way).
--
-- DEPLOY ORDERING: deploy BEFORE the schema-91 app. An older cloud rejects
-- pushes of product_photos and jams the outbox until this lands. The reverse
-- order is safe (old apps never write it). Never together with 0193.

BEGIN;

-- =========================================================================
-- 1. product_photos — synced gallery slots 2-5
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.product_photos (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  product_id      UUID        NOT NULL REFERENCES public.products(id)   ON DELETE CASCADE,
  -- Gallery position; 1 is the cover (products.image_url), never a row here.
  position        INTEGER     NOT NULL CHECK (position BETWEEN 2 AND 5),
  image_url       TEXT        NOT NULL,
  is_deleted      BOOLEAN     NOT NULL DEFAULT false,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- The photo must be one of this business's own objects.
  CONSTRAINT product_photos_url_in_business_folder CHECK (
    strpos(image_url, '/object/public/product-images/' || business_id::text || '/') > 0
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_product_photos_live_position
  ON public.product_photos (product_id, position) WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_product_photos_business_lua
  ON public.product_photos (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_product_photos_last_updated_at
  ON public.product_photos;
CREATE TRIGGER bump_product_photos_last_updated_at
  BEFORE UPDATE ON public.product_photos
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

COMMENT ON TABLE public.product_photos IS
  '#474: product gallery photos at positions 2-5 (position 1 = '
  'products.image_url). Synced, soft-deleted. Deterministic slot ids per '
  '(product, position); a reorder moves image_url between slots.';

ALTER TABLE public.product_photos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "product_photos_tenant_rw" ON public.product_photos;
CREATE POLICY "product_photos_tenant_rw"
  ON public.product_photos
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

ALTER TABLE public.product_photos REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'product_photos'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.product_photos;
  END IF;
END $$;

-- Live-sync signal (0147 does not cover tables created after it; #470).
DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.product_photos;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.product_photos
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- =========================================================================
-- 2. pos_pull_snapshot — add product_photos (after products)
--    Body copied verbatim from 0203 (latest definition); the only change is
--    the one list entry marked "0204 (#474)".
-- =========================================================================
CREATE OR REPLACE FUNCTION public.pos_pull_snapshot(
  p_business_id uuid,
  p_since       timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid;
  v_result          jsonb := '{}'::jsonb;
  v_table           text;
  v_rows            jsonb;
  v_query           text;
  v_tenant_tables   text[] := ARRAY[
    'profiles','users','stores',
    -- 0199 (#423): per-store delivery areas; parent stores is just above.
    'store_delivery_areas',
    'manufacturers','crate_size_groups',
    'categories','products',
    -- 0204 (#474): gallery photos; parent products is just above.
    'product_photos',
    'inventory',
    'cost_batches',
    'customers','suppliers',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    'supplier_crate_deposit_requests','supplier_crate_deposits',
    'orders','order_items',
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'expense_budgets',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'error_logs',
    'notifications','stock_transactions',
    'stock_adjustment_requests',
    'quick_sale_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts',
    'pending_crate_returns','crate_ledger','manufacturer_crate_balances',
    'store_crate_balances',
    -- 0175 (#517): crate shortfall write-offs; parents businesses,
    -- manufacturers, stores and users are all listed above.
    'crate_shortfall_writeoffs',
    'supplier_crate_balances',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    'stock_counts',
    'daily_closings',
    'van_trips','van_trip_lots','van_return_events','driver_ledger_entries',
    'user_permission_overrides',
    'store_role_permissions'
  ];
BEGIN
  v_caller_business := public.business_id();
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'no_business_for_caller'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_caller_business <> p_business_id THEN
    RAISE EXCEPTION 'tenant_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    INTO v_rows
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND (p_since IS NULL OR b.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('businesses', v_rows);

  FOREACH v_table IN ARRAY v_tenant_tables LOOP
    v_query := format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)
         FROM public.%I t
         WHERE t.business_id = $1
           AND ($2::timestamptz IS NULL OR t.last_updated_at > $2)',
      v_table
    );
    EXECUTE v_query INTO v_rows USING p_business_id, p_since;
    v_result := v_result || jsonb_build_object(v_table, v_rows);
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
    INTO v_rows
    FROM public.system_config s
    WHERE (p_since IS NULL OR s.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('system_config', v_rows);

  RETURN v_result;
END;
$$;

-- =========================================================================
-- 3. storefront_product_photos — one listed product's photos, in order
-- =========================================================================
-- Signed-out callable. Returns nothing unless the store is listed (0202's
-- _storefront_stores: online, kind=store, not deleted, business Active or in
-- trial, not deleted, synced within 7 days) and the product is listable
-- there (same business, Show online on, not archived, not deleted, not a
-- prescription category — the same product rules as _storefront_cards).
-- Position 1 = the cover (products.image_url); then live gallery slots by
-- position, only once their Storage object exists (a photo added offline
-- carries its URL before its bytes land). Public URLs only — no ids.
CREATE OR REPLACE FUNCTION public.storefront_product_photos(
  p_store_id   uuid,
  p_product_id uuid
)
RETURNS TABLE (photo_position integer, image_url text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF p_store_id IS NULL OR p_product_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH listed AS (
    SELECT p.id, nullif(btrim(p.image_url), '') AS cover
    FROM public._storefront_stores(p_store_id) s
    JOIN public.products p
      ON p.business_id = s.business_id AND p.id = p_product_id
    LEFT JOIN public.categories c
      ON c.id = p.category_id AND c.business_id = p.business_id
     AND NOT c.is_deleted
    LEFT JOIN public.marketplace_categories mc
      ON mc.slug = c.marketplace_category
    LEFT JOIN public.marketplace_categories parent
      ON parent.slug = mc.parent_slug
    WHERE p.show_online AND p.is_available AND NOT p.is_deleted
      AND mc.restricted IS DISTINCT FROM 'prescription'
      AND parent.restricted IS DISTINCT FROM 'prescription'
  ),
  photos AS (
    SELECT 1 AS photo_position, l.cover AS image_url
    FROM listed l
    WHERE l.cover IS NOT NULL
    UNION ALL
    SELECT ph.position, ph.image_url
    FROM listed l
    JOIN public.product_photos ph
      ON ph.product_id = l.id AND NOT ph.is_deleted
    WHERE EXISTS (
      SELECT 1 FROM storage.objects o
       WHERE o.bucket_id = 'product-images'
         AND o.name = split_part(
               split_part(ph.image_url, '/object/public/product-images/', 2),
               '?', 1)
    )
  )
  SELECT ph.photo_position, ph.image_url
  FROM photos ph
  ORDER BY ph.photo_position;
END;
$$;

REVOKE ALL ON FUNCTION public.storefront_product_photos(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.storefront_product_photos(uuid, uuid)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.storefront_product_photos(uuid, uuid) IS
  '#474: signed-out ordered photo URLs (cover first) of one listed product.';

COMMIT;
