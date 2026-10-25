-- 0207 (#479): Place order refuses an 18+ line from a login that never
-- confirmed its age. Same signature as 0205, so this replaces the function
-- (no overload). The only change is one check in the per-line chain, after the
-- product / quantity / stock checks and before the line is inserted:
-- shopper_age_confirmation_missing (0206) -> store code
-- 'age_confirmation_required'. That rolls back this store's order only.
-- DEPLOY: after 0205 and 0206. Never together with 0193.

BEGIN;

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
                   p.max_order_qty, coalesce(p.retailer_price_kobo, 0)::bigint AS price
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
            v_product.unit, v_product.price, 'retailer', v_qty);
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
  'needs the login''s age confirmation (age_confirmation_required).';

COMMIT;
