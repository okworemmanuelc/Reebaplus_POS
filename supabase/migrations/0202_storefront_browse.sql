-- 0202_storefront_browse.sql
--
-- #425 (PRD #421, ADR 0031): Browse is the front door. The signed-out
-- storefront contract: one ranked product feed across shops, cross-store
-- search, and a store page. Cloud only — no Drift change, no synced table,
-- no new column or status value (pos-parity issue opened for the RPCs).
--
-- WHAT THIS ADDS
--   1. pg_trgm + unaccent (schema `extensions`) and an IMMUTABLE search key
--      `storefront_search_key(text)` = lower(unaccent(text)), with a trigram
--      GIN index on product names limited to listable products.
--   2. Internal helpers (NOT callable by clients):
--        _storefront_stores(p_store_id)      eligible, not-hidden stores
--        _storefront_reach(country, state, lga)  per-store area rank
--        _storefront_cards(mode, ...)        the shared card query
--   3. Public SECURITY DEFINER RPCs, granted to anon + authenticated:
--        storefront_feed(...)            ranked feed, in-stock items only
--        storefront_search(...)          name search (out-of-stock greyed)
--        storefront_store(...)           one store's header
--        storefront_store_products(...)  one store's catalogue + search
--
-- ELIGIBILITY (every RPC, enforced here, never by the client):
--   product: show_online AND is_available AND NOT is_deleted; its Reebaplus
--            category is not 'prescription' (unmapped = Other).
--   store:   online_ordering_enabled, kind = 'store' (never a van), not
--            deleted, synced within 7 days.
--   business: row exists (deleted businesses cascade away), not tombstoned
--            in deleted_businesses, subscription Active or an unexpired
--            trial (a trial with no end date is the app's grace = shown).
--   area:    feed/search need a non-deleted delivery area covering the
--            shopper's area; a store page opens regardless and says whether
--            the store delivers there.
--   #478 (admin-blocked listings) adds its filter in _storefront_cards and
--   _storefront_stores when it lands; #461 fills `sponsored` (always false
--   here — no promotion logic in this slice).
--
-- STOCK FRESHNESS. Cloud stock is only as fresh as the shop's last sync.
-- A store's "last synced" moment is the newest of: the store row's
-- last_updated_at, its inventory rows' last_updated_at (every stock push),
-- and the business's devices.last_seen_at (presence on sign-in / app open /
-- reconnect). Older than 72 h → demoted below fresher stores and flagged
-- "Stock may be out of date"; older than 7 days → hidden (PRD value).
--
-- STOCK LABEL (never the raw count), checked in this order:
--   0 or less → out_of_stock; 1–3 → only_few_left (+ only_left = N);
--   at or below the product's low_stock_threshold → low_stock;
--   above it → in_stock. (Only-N wins over "above the threshold" when a
--   threshold is below 3, so scarcity is always told.)
--
-- RANKING (organic): stale stores last, then delivery to the shopper's LGA
-- before whole-state coverage, then In stock > Low > Only N > Out, then has
-- a photo, then most recently updated product, then product id. One card per
-- business per product in feed/search (DISTINCT ON product; a product belongs
-- to one business) from its best store by the same order. Pagination is
-- keyset on those rank values (opaque `cursor`), never OFFSET.
--
-- LISTING CONTENT (#473, 0201): online_description, brand and the order
-- quantity rule (min_order_qty / order_step / max_order_qty) ride on every
-- card so the #426 cart can enforce them; this slice builds no cart.
--
-- PUBLIC FIELDS ONLY. Cards never carry buying price, cost, raw stock,
-- customers, business id or tenant category id. Prices are the Retailer
-- price in the store's currency (settings.default_currency, default NGN);
-- the linked-customer tier arrives in #429.
--
-- DEPLOY: after 0201 (reads its listing columns); independent of any app build (nothing calls these until the
-- Browse switch is on). Run test/integration/sql/storefront_browse.sql on
-- reebaplus-dev after applying (EXPLAIN ANALYZE + EXECUTE boundaries).

BEGIN;

-- =========================================================================
-- 1. Text search
-- =========================================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.storefront_search_key(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT lower(extensions.unaccent('extensions.unaccent'::regdictionary, p_text));
$$;

COMMENT ON FUNCTION public.storefront_search_key(text) IS
  '#425: lower(unaccent(text)) — the storefront name-search key (trigram indexed).';

CREATE INDEX IF NOT EXISTS idx_products_storefront_name_trgm
  ON public.products
  USING gin (public.storefront_search_key(name) extensions.gin_trgm_ops)
  WHERE show_online AND is_available AND NOT is_deleted;

-- Freshness: newest inventory write per store.
CREATE INDEX IF NOT EXISTS idx_inventory_store_lua
  ON public.inventory (store_id, last_updated_at DESC);

-- =========================================================================
-- 2. Internal helpers — server-only
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
  )
  SELECT e.id, e.business_id, e.name, e.logo_url, e.state, e.lga,
         e.online_note, e.tracks_empty_crates, e.currency,
         CASE WHEN e.synced_at < now() - interval '72 hours' THEN 1 ELSE 0 END
  FROM eligible e
  WHERE e.synced_at >= now() - interval '7 days';
$$;

-- Per-store area rank for the shopper's area: 0 = delivers to the shopper's
-- LGA (or covers their whole chosen state / "All of Nigeria"), 1 = covers the
-- whole state only (or part of the state when the shopper picked a whole
-- state). Stores with no matching delivery area are absent.
CREATE OR REPLACE FUNCTION public._storefront_reach(
  p_country text,
  p_state   text,
  p_lga     text
)
RETURNS TABLE (store_id uuid, area_rank integer)
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  WITH shopper AS (
    SELECT
      lower(btrim(coalesce(nullif(btrim(p_country), ''), 'Nigeria'))) AS country,
      lower(nullif(btrim(p_state), '')) AS state,
      CASE WHEN nullif(btrim(p_state), '') IS NULL THEN NULL
           ELSE lower(nullif(btrim(p_lga), '')) END AS lga
  ),
  ranked AS (
    SELECT d.store_id,
      CASE
        WHEN sh.state IS NULL THEN 0
        WHEN lower(btrim(d.state)) <> sh.state THEN NULL
        WHEN sh.lga IS NOT NULL AND d.lga IS NOT NULL
             AND lower(btrim(d.lga)) = sh.lga THEN 0
        WHEN sh.lga IS NOT NULL AND d.lga IS NULL THEN 1
        WHEN sh.lga IS NOT NULL THEN NULL
        WHEN d.lga IS NULL THEN 0
        ELSE 1
      END AS area_rank
    FROM public.store_delivery_areas d, shopper sh
    WHERE NOT d.is_deleted
      AND lower(btrim(d.country)) = sh.country
  )
  SELECT r.store_id, min(r.area_rank)::integer
  FROM ranked r
  WHERE r.area_rank IS NOT NULL
  GROUP BY r.store_id;
$$;

-- The one card query behind feed, search and the store page.
--   p_mode 'feed'   — area-filtered, out-of-stock hidden, one card per product
--   p_mode 'search' — area-filtered, name required, out-of-stock included
--   p_mode 'store'  — one store, no area filter, out-of-stock included
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
           CASE WHEN p_mode = 'store' THEN 0 ELSE r.area_rank END AS area_rank
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
      coalesce(p.retailer_price_kobo, 0)::bigint AS price_kobo,
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

REVOKE ALL ON FUNCTION public._storefront_stores(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._storefront_reach(text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._storefront_cards(
  text, text, text, text, uuid, text, text, text, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._storefront_stores(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._storefront_reach(text, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public._storefront_cards(
  text, text, text, text, uuid, text, text, text, integer
) TO service_role;

-- =========================================================================
-- 3. Public storefront RPCs (signed-out callable)
-- =========================================================================

-- The ranked cross-shop feed for the shopper's area. In-stock items only.
-- p_state NULL = "All of Nigeria" (every online store in p_country).
CREATE OR REPLACE FUNCTION public.storefront_feed(
  p_country  text    DEFAULT NULL,
  p_state    text    DEFAULT NULL,
  p_lga      text    DEFAULT NULL,
  p_category text    DEFAULT NULL,
  p_after    text    DEFAULT NULL,
  p_limit    integer DEFAULT 24
)
RETURNS TABLE (
  product_id uuid, store_id uuid, name text, image_url text, unit text,
  units_per_pack integer, category text, price_kobo bigint, currency text,
  crate_deposit_kobo bigint, stock_label text, only_left integer,
  age_restricted boolean, stock_may_be_stale boolean, business_name text,
  store_lga text, online_description text, brand text, min_order_qty integer,
  order_step integer, max_order_qty integer, sponsored boolean, cursor text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT * FROM public._storefront_cards(
    'feed', p_country, p_state, p_lga, NULL, p_category, NULL, p_after, p_limit);
$$;

-- Cross-store search by product name (+ optional category). Out-of-stock
-- items are included so the app can show them greyed.
CREATE OR REPLACE FUNCTION public.storefront_search(
  p_query    text,
  p_country  text    DEFAULT NULL,
  p_state    text    DEFAULT NULL,
  p_lga      text    DEFAULT NULL,
  p_category text    DEFAULT NULL,
  p_after    text    DEFAULT NULL,
  p_limit    integer DEFAULT 24
)
RETURNS TABLE (
  product_id uuid, store_id uuid, name text, image_url text, unit text,
  units_per_pack integer, category text, price_kobo bigint, currency text,
  crate_deposit_kobo bigint, stock_label text, only_left integer,
  age_restricted boolean, stock_may_be_stale boolean, business_name text,
  store_lga text, online_description text, brand text, min_order_qty integer,
  order_step integer, max_order_qty integer, sponsored boolean, cursor text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT * FROM public._storefront_cards(
    'search', p_country, p_state, p_lga, NULL, p_category, p_query, p_after,
    p_limit);
$$;

-- One store's header. No row = the store is not listed (offline, van,
-- hidden business, stale for 7 days, or unknown). A listed store outside the
-- shopper's area still returns, with delivers_to_area = false.
CREATE OR REPLACE FUNCTION public.storefront_store(
  p_store_id uuid,
  p_country  text DEFAULT NULL,
  p_state    text DEFAULT NULL,
  p_lga      text DEFAULT NULL
)
RETURNS TABLE (
  store_id           uuid,
  business_name      text,
  logo_url           text,
  store_state        text,
  store_lga          text,
  online_note        text,
  currency           text,
  delivers_to_area   boolean,
  stock_may_be_stale boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT s.store_id, s.business_name, s.logo_url, s.store_state, s.store_lga,
         s.online_note, s.currency,
         EXISTS (SELECT 1 FROM public._storefront_reach(p_country, p_state, p_lga) r
                  WHERE r.store_id = s.store_id),
         s.stale_rank = 1
  FROM public._storefront_stores(p_store_id) s
  WHERE p_store_id IS NOT NULL;
$$;

-- One store's catalogue (+ its own search and category filter). Out-of-stock
-- items included (shown greyed). Empty when the store is not listed.
CREATE OR REPLACE FUNCTION public.storefront_store_products(
  p_store_id uuid,
  p_query    text    DEFAULT NULL,
  p_category text    DEFAULT NULL,
  p_after    text    DEFAULT NULL,
  p_limit    integer DEFAULT 24
)
RETURNS TABLE (
  product_id uuid, store_id uuid, name text, image_url text, unit text,
  units_per_pack integer, category text, price_kobo bigint, currency text,
  crate_deposit_kobo bigint, stock_label text, only_left integer,
  age_restricted boolean, stock_may_be_stale boolean, business_name text,
  store_lga text, online_description text, brand text, min_order_qty integer,
  order_step integer, max_order_qty integer, sponsored boolean, cursor text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT * FROM public._storefront_cards(
    'store', NULL, NULL, NULL, p_store_id, p_category, p_query, p_after,
    p_limit);
$$;

REVOKE ALL ON FUNCTION public.storefront_feed(text, text, text, text, text, integer)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.storefront_search(text, text, text, text, text, text, integer)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.storefront_store(uuid, text, text, text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.storefront_store_products(uuid, text, text, text, integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.storefront_feed(text, text, text, text, text, integer)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.storefront_search(text, text, text, text, text, text, integer)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.storefront_store(uuid, text, text, text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.storefront_store_products(uuid, text, text, text, integer)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.storefront_feed(text, text, text, text, text, integer) IS
  '#425: signed-out ranked cross-shop feed (public listing fields only).';
COMMENT ON FUNCTION public.storefront_search(text, text, text, text, text, text, integer) IS
  '#425: signed-out cross-store name search (public listing fields only).';
COMMENT ON FUNCTION public.storefront_store(uuid, text, text, text) IS
  '#425: signed-out store page header (public fields only).';
COMMENT ON FUNCTION public.storefront_store_products(uuid, text, text, text, integer) IS
  '#425: signed-out one-store catalogue (public listing fields only).';

COMMIT;
