-- 0211_shopper_tier_price.sql
--
-- #429 (Online ordering 8/28, PRD #421, ADR 0031): a Shopper linked to a
-- shop's Customer (customers.shopper_account_id, 0208/#427) sees that shop's
-- price at the Customer's tier; everyone else sees Retailer. Cloud only: no
-- Drift change, no new table, column or status value. Money rule -> a
-- pos-parity issue is opened in reebaplus-web.
--
-- THE TIER RULE (mirrors the till exactly). The till prices a line at
-- products.wholesaler_price_kobo when the selected customer's price_tier is
-- 'wholesaler' and the business does NOT sell one price
-- (PosController.selectedGroup + CartService.addItem; no fallback to the
-- retailer price), else at products.retailer_price_kobo. So the caller's tier
-- at a business is 'wholesaler' only when auth.uid() is the
-- shopper_account_id of a live (NOT is_deleted) customer of that business
-- whose price_tier = 'wholesaler' and businesses.sells_one_price is false.
-- Otherwise 'retailer' -- including every anonymous caller (auth.uid() NULL).
--
-- WHAT THIS DOES
--   1. _shopper_price_tier(business) -- server-only helper (no client grant).
--   2. _storefront_cards re-issued VERBATIM from 0202 (same signature, same
--      grants) with price_kobo picked by that tier. storefront_feed,
--      storefront_search and storefront_store_products are thin SECURITY
--      DEFINER wrappers that SELECT * FROM _storefront_cards at call time, so
--      they pick the tier up unchanged and are not re-issued. storefront_store
--      (header) and storefront_product_photos (0204) carry no price.
--   3. shopper_place_orders re-issued VERBATIM from 0207 (same signature, same
--      grants): each store's lines are re-priced at the caller's tier there and
--      online_order_lines.price_tier snapshots that tier ('retailer' or
--      'wholesaler'). A cart price saved before linking is only an estimate;
--      this re-price is what the order records.
--
-- Anonymous storefront access is unchanged: the same grants, and anon always
-- resolves to 'retailer'.
--
-- DEPLOY: after 0202, 0207 and 0208 (reads customers.shopper_account_id).
-- Independent of any app build. Never together with 0193. Then run
-- test/integration/sql/shopper_tier_price.sql on reebaplus-dev.

BEGIN;

-- =========================================================================
-- 1. _shopper_price_tier -- the caller's price tier at one business
-- =========================================================================
CREATE OR REPLACE FUNCTION public._shopper_price_tier(p_business_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE WHEN EXISTS (
    SELECT 1
      FROM public.customers c
      JOIN public.businesses b ON b.id = c.business_id
     WHERE c.business_id = p_business_id
       AND c.shopper_account_id = auth.uid()
       AND NOT c.is_deleted
       AND c.price_tier = 'wholesaler'
       AND NOT b.sells_one_price
  ) THEN 'wholesaler' ELSE 'retailer' END;
$$;

REVOKE ALL ON FUNCTION public._shopper_price_tier(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._shopper_price_tier(uuid) TO service_role;

COMMENT ON FUNCTION public._shopper_price_tier(uuid) IS
  '#429: ''wholesaler'' when auth.uid() is linked to a live Wholesaler customer '
  'of the business and it does not sell one price; else ''retailer'' (anon too).';

-- =========================================================================
-- 2. _storefront_cards -- verbatim from 0202, price at the caller's tier
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
      CASE WHEN pl.shopper_tier = 'wholesaler'
           THEN coalesce(p.wholesaler_price_kobo, 0)
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
-- 3. shopper_place_orders -- verbatim from 0207, re-priced at the tier
-- =========================================================================
CREATE OR REPLACE FUNCTION public.shopper_place_orders(
  p_orders  jsonb,
  p_phone   text,
  p_address jsonb,
  p_note    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := public._shopper_uid();
  v_name     text;
  v_phone    text := btrim(coalesce(p_phone, ''));
  v_country  text := coalesce(nullif(btrim(p_address->>'country'), ''), 'Nigeria');
  v_state    text := btrim(coalesce(p_address->>'state', ''));
  v_lga      text := btrim(coalesce(p_address->>'lga', ''));
  v_street   text := btrim(coalesce(p_address->>'street', ''));
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_results  jsonb := '[]'::jsonb;
  v_order    jsonb;
  v_line     jsonb;
  v_order_id uuid;
  v_store_id uuid;
  v_store    record;
  v_product  record;
  v_existing record;
  v_qty      integer;
  v_stock    integer;
  v_total    bigint;
  v_ref      text;
  v_code     text;
  v_bad_product uuid;
  v_seen     uuid[];
  v_tier     text;
BEGIN
  SELECT p.name INTO v_name FROM public.shopper_profiles p
   WHERE p.auth_user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopper_profile_required' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_orders) = 0 OR jsonb_array_length(p_orders) > 20 THEN
    RAISE EXCEPTION 'invalid_orders' USING ERRCODE = '22023';
  END IF;
  IF v_phone = '' OR char_length(v_phone) > 30 THEN
    RAISE EXCEPTION 'invalid_phone' USING ERRCODE = '22023';
  END IF;
  IF v_state = '' OR v_lga = '' OR v_street = '' OR char_length(v_street) > 200
     OR char_length(v_state) > 100 OR char_length(v_lga) > 100
     OR char_length(v_country) > 100 THEN
    RAISE EXCEPTION 'invalid_address' USING ERRCODE = '22023';
  END IF;
  IF char_length(coalesce(v_note, '')) > 500 THEN
    RAISE EXCEPTION 'note_too_long' USING ERRCODE = '22023';
  END IF;

  FOR v_order IN SELECT value FROM jsonb_array_elements(p_orders) LOOP
    v_order_id := NULL;
    v_store_id := NULL;
    v_code := NULL;
    v_bad_product := NULL;
    BEGIN
      v_order_id := (v_order->>'id')::uuid;
      v_store_id := (v_order->>'store_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_code := 'invalid';
    END;
    IF v_order_id IS NULL OR v_store_id IS NULL
       OR jsonb_typeof(v_order->'lines') IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_order->'lines') = 0
       OR jsonb_array_length(v_order->'lines') > 100 THEN
      v_code := 'invalid';
    END IF;

    -- Idempotent retry: the order already exists.
    IF v_code IS NULL THEN
      SELECT o.shopper_account_id, o.reference, o.status,
             o.estimated_total_kobo, o.currency, o.store_id
        INTO v_existing
        FROM public.online_orders o WHERE o.id = v_order_id;
      IF FOUND THEN
        IF v_existing.shopper_account_id IS DISTINCT FROM v_uid
           OR v_existing.store_id <> v_store_id THEN
          v_code := 'invalid';
        ELSE
          v_results := v_results || jsonb_build_array(jsonb_build_object(
            'id', v_order_id, 'store_id', v_store_id, 'ok', true,
            'reference', v_existing.reference, 'status', v_existing.status,
            'total_kobo', v_existing.estimated_total_kobo,
            'currency', v_existing.currency));
          CONTINUE;
        END IF;
      END IF;
    END IF;

    IF v_code IS NULL AND (
      SELECT count(*) FROM public.online_orders o
       WHERE o.shopper_account_id = v_uid
         AND o.placed_at > now() - interval '1 hour') >= 20 THEN
      v_code := 'rate_limited';
    END IF;

    IF v_code IS NULL THEN
      SELECT s.store_id, s.business_id, s.currency INTO v_store
        FROM public._storefront_stores(v_store_id) s;
      IF NOT FOUND THEN
        v_code := 'store_unavailable';
      ELSIF EXISTS (SELECT 1 FROM public.businesses b
                     WHERE b.id = v_store.business_id AND b.owner_id = v_uid) THEN
        v_code := 'own_business';
      ELSIF NOT EXISTS (
        SELECT 1 FROM public._storefront_reach(v_country, v_state, v_lga) r
         WHERE r.store_id = v_store_id) THEN
        v_code := 'out_of_area';
      END IF;
    END IF;

    -- #429: the caller's tier at this shop (Wholesaler only when linked to a
    -- live Wholesaler customer there and the shop sells more than one price).
    IF v_code IS NULL THEN
      v_tier := public._shopper_price_tier(v_store.business_id);
    END IF;

    IF v_code IS NULL THEN
      BEGIN
        v_ref := 'ON-' || upper(substr(md5(v_order_id::text), 1, 8));
        INSERT INTO public.online_orders (
          id, business_id, store_id, shopper_account_id, status, reference,
          currency, estimated_total_kobo, shopper_name, delivery_phone,
          delivery_country, delivery_state, delivery_lga, delivery_street, note)
        VALUES (
          v_order_id, v_store.business_id, v_store_id, v_uid, 'new', v_ref,
          v_store.currency, 0, v_name, v_phone,
          v_country, v_state, v_lga, v_street, v_note);

        v_total := 0;
        v_seen := ARRAY[]::uuid[];
        FOR v_line IN SELECT value FROM jsonb_array_elements(v_order->'lines') LOOP
          v_bad_product := NULL;
          BEGIN
            v_bad_product := (v_line->>'product_id')::uuid;
            v_qty := (v_line->>'quantity')::integer;
          EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            v_code := 'invalid';
          END;
          IF v_code IS NULL AND (v_bad_product IS NULL OR v_qty IS NULL
             OR v_bad_product = ANY (v_seen)) THEN
            v_code := 'invalid';
          END IF;
          IF v_code IS NULL THEN
            v_seen := v_seen || v_bad_product;
            SELECT p.id, p.name, p.unit, p.min_order_qty, p.order_step,
                   p.max_order_qty,
                   CASE WHEN v_tier = 'wholesaler'
                        THEN coalesce(p.wholesaler_price_kobo, 0)
                        ELSE coalesce(p.retailer_price_kobo, 0)
                   END::bigint AS price
              INTO v_product
              FROM public.products p
              LEFT JOIN public.categories c
                ON c.id = p.category_id AND c.business_id = p.business_id
               AND NOT c.is_deleted
              LEFT JOIN public.marketplace_categories mc
                ON mc.slug = c.marketplace_category
              LEFT JOIN public.marketplace_categories parent
                ON parent.slug = mc.parent_slug
             WHERE p.id = v_bad_product
               AND p.business_id = v_store.business_id
               AND p.show_online AND p.is_available AND NOT p.is_deleted
               AND mc.restricted IS DISTINCT FROM 'prescription'
               AND parent.restricted IS DISTINCT FROM 'prescription';
            IF NOT FOUND THEN
              v_code := 'product_unavailable';
            ELSIF NOT public.order_quantity_allowed(
                v_qty, v_product.min_order_qty, v_product.order_step,
                v_product.max_order_qty) THEN
              v_code := 'quantity_rule';
            ELSE
              SELECT coalesce(i.quantity, 0) INTO v_stock
                FROM public.inventory i
               WHERE i.product_id = v_bad_product AND i.store_id = v_store_id;
              IF coalesce(v_stock, 0) < v_qty THEN
                v_code := 'not_enough_stock';
              END IF;
            END IF;
            IF v_code IS NULL
               AND public.shopper_age_confirmation_missing(v_uid, ARRAY[v_product.id]) THEN
              v_code := 'age_confirmation_required';
            END IF;
          END IF;
          EXIT WHEN v_code IS NOT NULL;

          INSERT INTO public.online_order_lines (
            business_id, online_order_id, product_id, product_name, unit,
            unit_price_kobo, price_tier, requested_qty)
          VALUES (
            v_store.business_id, v_order_id, v_product.id, v_product.name,
            v_product.unit, v_product.price, v_tier, v_qty);
          v_total := v_total + v_product.price * v_qty;
        END LOOP;

        IF v_code IS NOT NULL THEN
          -- Undo this store's order only (the sub-transaction).
          RAISE EXCEPTION USING ERRCODE = 'OO426', MESSAGE = 'store_failed';
        END IF;

        UPDATE public.online_orders SET estimated_total_kobo = v_total
         WHERE id = v_order_id;
        -- Runs as the owner: the guard's client-only "total may only go
        -- down" rule does not apply to this first write.
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'id', v_order_id, 'store_id', v_store_id, 'ok', true,
          'reference', v_ref, 'status', 'new', 'total_kobo', v_total,
          'currency', v_store.currency));
        CONTINUE;
      EXCEPTION
        WHEN SQLSTATE 'OO426' THEN
          NULL; -- v_code / v_bad_product already say why
        WHEN unique_violation THEN
          v_code := 'invalid';
          v_bad_product := NULL;
      END;
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'id', v_order_id, 'store_id', v_store_id, 'ok', false, 'code', v_code,
      'product_id', CASE WHEN v_code IN ('product_unavailable', 'quantity_rule',
                                         'not_enough_stock')
                         THEN v_bad_product END)));
  END LOOP;

  RETURN v_results;
END;
$$;

REVOKE ALL ON FUNCTION public.shopper_place_orders(jsonb, text, jsonb, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shopper_place_orders(jsonb, text, jsonb, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.shopper_place_orders(jsonb, text, jsonb, text) IS
  '#426: one Online Order per store, each placed independently; server '
  're-prices and re-checks every rule. No stock movement. #479: an 18+ line '
  'needs the login''s age confirmation (age_confirmation_required). #429: '
  'lines are priced and snapshot at the caller''s tier (_shopper_price_tier).';


COMMIT;
