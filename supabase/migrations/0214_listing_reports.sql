-- 0214_listing_reports.sql
--
-- #478 (Online ordering 27/28, PRD #421, ADRs 0029 s6 / 0031): a Shopper can
-- report a product or a store; an admin (console, service_role) can block a
-- product or a store so it vanishes from the storefront. Cloud-only: no Drift
-- change, no sync. Blocked items keep working at the till (no tenant table is
-- touched). New table/status values -> a pos-parity issue in reebaplus-web.
--
-- RE-ISSUED VERBATIM (same signature + grants), adding only the block filter:
--   _storefront_stores        from 0202 (store block; also hides the store page,
--                             search, feed, photos and stops new orders)
--   _storefront_cards         from 0211 (product block)
--   storefront_product_photos from 0204 (product block)

BEGIN;

CREATE TABLE IF NOT EXISTS public.listing_reports (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_auth_id uuid NOT NULL,
  target_type      text NOT NULL CHECK (target_type IN ('product', 'store')),
  target_id        uuid NOT NULL,
  reason           text NOT NULL CHECK (reason IN
    ('wrong_item', 'offensive', 'illegal_or_restricted', 'scam', 'other')),
  details          text CHECK (details IS NULL OR char_length(details) <= 500),
  status           text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'reviewed')),
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_listing_reports_reporter
  ON public.listing_reports (reporter_auth_id, created_at DESC);
-- One OPEN report per shopper per target.
CREATE UNIQUE INDEX IF NOT EXISTS uq_listing_reports_open
  ON public.listing_reports (reporter_auth_id, target_type, target_id)
  WHERE status = 'open';

CREATE TABLE IF NOT EXISTS public.storefront_blocks (
  target_type text NOT NULL CHECK (target_type IN ('product', 'store')),
  target_id   uuid NOT NULL,
  reason      text,
  blocked_at  timestamptz NOT NULL DEFAULT now(),
  blocked_by  text,
  PRIMARY KEY (target_type, target_id)
);

-- Cloud-only, service_role only: RLS on with NO policies, no client grants.
ALTER TABLE public.listing_reports   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.storefront_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listing_reports   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.storefront_blocks FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.listing_reports   TO service_role;
GRANT ALL ON public.storefront_blocks TO service_role;

-- =========================================================================
-- shopper_report_listing
-- =========================================================================
CREATE OR REPLACE FUNCTION public.shopper_report_listing(
  p_target_type text,
  p_target_id   uuid,
  p_reason      text,
  p_details     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := public._shopper_uid();
  v_details text := nullif(btrim(p_details), '');
BEGIN
  IF p_target_type IS NULL OR p_target_type NOT IN ('product', 'store') THEN
    RAISE EXCEPTION 'unknown report target' USING ERRCODE = '22023';
  END IF;
  IF p_target_id IS NULL THEN
    RAISE EXCEPTION 'report needs a target' USING ERRCODE = '22023';
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN
     ('wrong_item', 'offensive', 'illegal_or_restricted', 'scam', 'other') THEN
    RAISE EXCEPTION 'unknown report reason' USING ERRCODE = '22023';
  END IF;
  IF char_length(coalesce(v_details, '')) > 500 THEN
    RAISE EXCEPTION 'details are too long' USING ERRCODE = '22023';
  END IF;

  -- Same shopper + same target already open: idempotent, no new row.
  IF EXISTS (SELECT 1 FROM public.listing_reports r
              WHERE r.reporter_auth_id = v_uid
                AND r.target_type = p_target_type
                AND r.target_id = p_target_id
                AND r.status = 'open') THEN
    RETURN jsonb_build_object('ok', true, 'duplicate', true);
  END IF;

  IF (SELECT count(*) FROM public.listing_reports r
       WHERE r.reporter_auth_id = v_uid
         AND r.created_at > now() - interval '1 hour') >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'rate_limited');
  END IF;

  INSERT INTO public.listing_reports
    (reporter_auth_id, target_type, target_id, reason, details)
  VALUES (v_uid, p_target_type, p_target_id, p_reason, v_details)
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.shopper_report_listing(text, uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shopper_report_listing(text, uuid, text, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.shopper_report_listing(text, uuid, text, text) IS
  '#478: store a Shopper report of a product or store; 10/hour, one open '
  'report per target. Cloud-only, no client read.';

-- =========================================================================
-- _storefront_stores -- verbatim from 0202, minus blocked stores
-- =========================================================================
-- Eligible stores that are not hidden. p_store_id NULL = every store.
CREATE OR REPLACE FUNCTION public._storefront_stores(p_store_id uuid)
RETURNS TABLE (
  store_id            uuid,
  business_id         uuid,
  business_name       text,
  logo_url            text,
  store_state         text,
  store_lga           text,
  online_note         text,
  tracks_empty_crates boolean,
  currency            text,
  stale_rank          integer
)
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  WITH eligible AS (
    SELECT
      s.id,
      s.business_id,
      b.name,
      nullif(btrim(b.logo_url), '') AS logo_url,
      s.state,
      s.lga,
      s.online_note,
      b.tracks_empty_crates,
      coalesce(
        (SELECT nullif(btrim(st.value), '') FROM public.settings st
          WHERE st.business_id = b.id AND st.key = 'default_currency'
          LIMIT 1),
        'NGN') AS currency,
      GREATEST(
        s.last_updated_at,
        (SELECT max(i.last_updated_at) FROM public.inventory i
          WHERE i.store_id = s.id),
        (SELECT max(dv.last_seen_at) FROM public.devices dv
          WHERE dv.business_id = s.business_id)
      ) AS synced_at
    FROM public.stores s
    JOIN public.businesses b ON b.id = s.business_id
    WHERE s.online_ordering_enabled
      AND s.kind = 'store'
      AND NOT s.is_deleted
      AND (p_store_id IS NULL OR s.id = p_store_id)
      AND (
        b.subscription_status = 'active'
        OR (b.subscription_status = 'trial'
            AND (b.trial_ends_at IS NULL OR b.trial_ends_at > now()))
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.deleted_businesses d WHERE d.business_id = b.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.storefront_blocks sb
         WHERE sb.target_type = 'store' AND sb.target_id = s.id
      )
  )
  SELECT e.id, e.business_id, e.name, e.logo_url, e.state, e.lga,
         e.online_note, e.tracks_empty_crates, e.currency,
         CASE WHEN e.synced_at < now() - interval '72 hours' THEN 1 ELSE 0 END
  FROM eligible e
  WHERE e.synced_at >= now() - interval '7 days';
$$;

-- Per-store area rank for the shopper's area: 0 = delivers to the shopper's
-- LGA (or covers their whole chosen state / "All of Nigeria"), 1 = covers the

REVOKE ALL ON FUNCTION public._storefront_stores(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._storefront_stores(uuid) TO service_role;


-- =========================================================================
-- _storefront_cards -- verbatim from 0211, minus blocked products
-- =========================================================================
CREATE OR REPLACE FUNCTION public._storefront_cards(
  p_mode     text,
  p_country  text,
  p_state    text,
  p_lga      text,
  p_store_id uuid,
  p_category text,
  p_query    text,
  p_after    text,
  p_limit    integer
)
RETURNS TABLE (
  product_id         uuid,
  store_id           uuid,
  name               text,
  image_url          text,
  unit               text,
  units_per_pack     integer,
  category           text,
  price_kobo         bigint,
  currency           text,
  crate_deposit_kobo bigint,
  stock_label        text,
  only_left          integer,
  age_restricted     boolean,
  stock_may_be_stale boolean,
  business_name      text,
  store_lga          text,
  online_description text,
  brand              text,
  min_order_qty      integer,
  order_step         integer,
  max_order_qty      integer,
  sponsored          boolean,
  cursor             text
)
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_category text := lower(nullif(btrim(p_category), ''));
  v_query    text := nullif(btrim(p_query), '');
  v_pattern  text;
  v_limit    integer := least(greatest(coalesce(p_limit, 24), 1), 50);
  c_stale    integer;
  c_area     integer;
  c_stock    integer;
  c_nophoto  integer;
  c_recency  bigint;
  c_id       uuid;
BEGIN
  IF p_mode IS NULL OR p_mode NOT IN ('feed', 'search', 'store') THEN
    RAISE EXCEPTION 'unknown storefront mode' USING ERRCODE = '22023';
  END IF;
  IF p_mode = 'search' AND v_query IS NULL THEN
    RAISE EXCEPTION 'search needs a product name' USING ERRCODE = '22023';
  END IF;
  IF p_mode = 'store' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'store page needs a store' USING ERRCODE = '22023';
  END IF;
  IF char_length(coalesce(v_query, '')) > 100 THEN
    RAISE EXCEPTION 'search is too long' USING ERRCODE = '22023';
  END IF;

  IF v_query IS NOT NULL THEN
    v_pattern := '%' || replace(replace(replace(
      public.storefront_search_key(v_query),
      '\', '\\'), '%', '\%'), '_', '\_') || '%';
  END IF;

  IF p_after IS NOT NULL THEN
    IF p_after !~ ('^[01]:[0-9]{1,2}:[0-3]:[01]:-?[0-9]{1,20}:'
        || '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'invalid cursor' USING ERRCODE = '22023';
    END IF;
    c_stale   := split_part(p_after, ':', 1)::integer;
    c_area    := split_part(p_after, ':', 2)::integer;
    c_stock   := split_part(p_after, ':', 3)::integer;
    c_nophoto := split_part(p_after, ':', 4)::integer;
    c_recency := split_part(p_after, ':', 5)::bigint;
    c_id      := split_part(p_after, ':', 6)::uuid;
  END IF;

  RETURN QUERY
  WITH placed AS (
    SELECT s.*,
           CASE WHEN p_mode = 'store' THEN 0 ELSE r.area_rank END AS area_rank,
           public._shopper_price_tier(s.business_id) AS shopper_tier
    FROM public._storefront_stores(
           CASE WHEN p_mode = 'store' THEN p_store_id END) s
    LEFT JOIN public._storefront_reach(p_country, p_state, p_lga) r
      ON r.store_id = s.store_id
    WHERE p_mode = 'store' OR r.area_rank IS NOT NULL
  ),
  lines AS (
    SELECT
      p.id                                     AS product_id,
      pl.store_id                              AS store_id,
      p.name                                   AS name,
      nullif(btrim(p.image_url), '')           AS image_url,
      p.unit                                   AS unit,
      p.units_per_pack                         AS units_per_pack,
      coalesce(mc.slug, 'other')               AS category,
      -- Online, an unset (0) wholesale price falls back to Retail so a
      -- Wholesaler can never order at 0 (supervisor decision, #429).
      CASE WHEN pl.shopper_tier = 'wholesaler'
                AND coalesce(p.wholesaler_price_kobo, 0) > 0
           THEN p.wholesaler_price_kobo
           ELSE coalesce(p.retailer_price_kobo, 0)
      END::bigint                              AS price_kobo,
      pl.currency                              AS currency,
      CASE
        WHEN pl.tracks_empty_crates AND p.track_empties
             AND lower(coalesce(p.unit, '')) = 'bottle'
        THEN nullif(coalesce(nullif(m.deposit_amount_kobo, 0),
                             p.empty_crate_value_kobo, 0), 0)::bigint
      END                                      AS crate_deposit_kobo,
      CASE
        WHEN coalesce(i.quantity, 0) <= 0 THEN 3
        WHEN i.quantity <= 3 THEN 2
        WHEN i.quantity <= p.low_stock_threshold THEN 1
        ELSE 0
      END                                      AS stock_rank,
      CASE WHEN i.quantity BETWEEN 1 AND 3 THEN i.quantity END AS only_left,
      coalesce(mc.restricted = 'age_18'
               OR parent.restricted = 'age_18', false) AS age_restricted,
      pl.stale_rank                            AS stale_rank,
      pl.business_name                         AS business_name,
      pl.store_lga                             AS store_lga,
      nullif(btrim(p.online_description), '')  AS online_description,
      nullif(btrim(p.brand), '')               AS brand,
      p.min_order_qty                          AS min_order_qty,
      p.order_step                             AS order_step,
      p.max_order_qty                          AS max_order_qty,
      pl.area_rank                             AS area_rank,
      CASE WHEN nullif(btrim(p.image_url), '') IS NULL THEN 1 ELSE 0 END
                                               AS nophoto,
      -floor(extract(epoch FROM p.last_updated_at) * 1000000)::bigint
                                               AS recency
    FROM placed pl
    JOIN public.products p ON p.business_id = pl.business_id
    LEFT JOIN public.inventory i
      ON i.product_id = p.id AND i.store_id = pl.store_id
    LEFT JOIN public.categories c
      ON c.id = p.category_id AND c.business_id = p.business_id
     AND NOT c.is_deleted
    LEFT JOIN public.marketplace_categories mc ON mc.slug = c.marketplace_category
    LEFT JOIN public.marketplace_categories parent ON parent.slug = mc.parent_slug
    LEFT JOIN public.manufacturers m
      ON m.id = p.manufacturer_id AND NOT m.is_deleted
    WHERE p.show_online AND p.is_available AND NOT p.is_deleted
      AND NOT EXISTS (
        SELECT 1 FROM public.storefront_blocks sb
         WHERE sb.target_type = 'product' AND sb.target_id = p.id
      )
      AND mc.restricted IS DISTINCT FROM 'prescription'
      AND parent.restricted IS DISTINCT FROM 'prescription'
      AND (v_pattern IS NULL
           OR public.storefront_search_key(p.name) LIKE v_pattern)
      AND (v_category IS NULL
           OR coalesce(mc.slug, 'other') = v_category
           OR mc.parent_slug = v_category)
  ),
  visible AS (
    SELECT * FROM lines l WHERE p_mode <> 'feed' OR l.stock_rank < 3
  ),
  one_per_product AS (
    SELECT DISTINCT ON (v.product_id) v.*
    FROM visible v
    ORDER BY v.product_id, v.stale_rank, v.area_rank, v.stock_rank, v.store_id
  )
  SELECT
    o.product_id, o.store_id, o.name, o.image_url, o.unit, o.units_per_pack,
    o.category, o.price_kobo, o.currency, o.crate_deposit_kobo,
    CASE o.stock_rank
      WHEN 0 THEN 'in_stock'
      WHEN 1 THEN 'low_stock'
      WHEN 2 THEN 'only_few_left'
      ELSE 'out_of_stock'
    END,
    o.only_left,
    o.age_restricted,
    o.stale_rank = 1,
    o.business_name,
    o.store_lga,
    o.online_description,
    o.brand,
    o.min_order_qty,
    o.order_step,
    o.max_order_qty,
    false,
    concat_ws(':', o.stale_rank, o.area_rank, o.stock_rank, o.nophoto,
              o.recency, o.product_id)
  FROM one_per_product o
  WHERE p_after IS NULL
     OR (o.stale_rank, o.area_rank, o.stock_rank, o.nophoto, o.recency,
         o.product_id)
        > (c_stale, c_area, c_stock, c_nophoto, c_recency, c_id)
  ORDER BY o.stale_rank, o.area_rank, o.stock_rank, o.nophoto, o.recency,
           o.product_id
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public._storefront_cards(
  text, text, text, text, uuid, text, text, text, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._storefront_cards(
  text, text, text, text, uuid, text, text, text, integer
) TO service_role;

-- =========================================================================
-- storefront_product_photos -- verbatim from 0204, minus blocked products
-- =========================================================================
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
      AND NOT EXISTS (
        SELECT 1 FROM public.storefront_blocks sb
         WHERE sb.target_type = 'product' AND sb.target_id = p.id
      )
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
