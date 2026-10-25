-- 0210_online_order_changes.sql
--
-- #428 (PRD #421): change before accepting, price flag, cancel an accepted
-- order. Almost all of it already works in the cloud: 0205 lets a shop lower
-- accepted_qty (CHECK accepted_qty <= requested_qty) while an order is open,
-- and 0205/0208 already allow accepted -> cancelled_by_shop with a
-- cancel_reason. The ONE gap: a Shopper whose order was accepted has no way to
-- reach the store, because shopper_my_orders does not return a phone.
--
-- shopper_my_orders is re-issued VERBATIM from 0205 (same signature, so no
-- overload) plus one key, 'store_phone' = the store's public phone, falling
-- back to the business phone. No table, status or money-rule change.
--
-- DEPLOY: any time after 0208; the app tolerates a missing store_phone.
-- Never together with 0193.

BEGIN;

-- The Shopper's own orders, newest first (public fields only: no business id,
-- customer link or other shoppers). p_before = placed_at of the last row seen.
CREATE OR REPLACE FUNCTION public.shopper_my_orders(
  p_limit  integer     DEFAULT 30,
  p_before timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
BEGIN
  RETURN coalesce((
    SELECT jsonb_agg(q.order_json ORDER BY (q.order_json->>'placed_at')::timestamptz DESC)
    FROM (
      SELECT jsonb_build_object(
        'id', o.id,
        'store_id', o.store_id,
        'business_name', b.name,
        'store_lga', s.lga,
        'store_phone', coalesce(nullif(btrim(s.phone), ''), nullif(btrim(b.phone), '')),
        'reference', o.reference,
        'status', o.status,
        'currency', o.currency,
        'total_kobo', o.estimated_total_kobo,
        'placed_at', o.placed_at,
        'decline_reason', o.decline_reason,
        'cancel_reason', o.cancel_reason,
        'delivery_street', o.delivery_street,
        'delivery_lga', o.delivery_lga,
        'delivery_state', o.delivery_state,
        'lines', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
                   'product_id', l.product_id,
                   'name', l.product_name,
                   'unit', l.unit,
                   'unit_price_kobo', l.unit_price_kobo,
                   'requested_qty', l.requested_qty,
                   'accepted_qty', l.accepted_qty)
                 ORDER BY l.created_at, l.product_name)
            FROM public.online_order_lines l
           WHERE l.online_order_id = o.id), '[]'::jsonb)
      ) AS order_json
      FROM public.online_orders o
      JOIN public.businesses b ON b.id = o.business_id
      JOIN public.stores s ON s.id = o.store_id
      WHERE o.shopper_account_id = v_uid
        AND (p_before IS NULL OR o.placed_at < p_before)
      ORDER BY o.placed_at DESC
      LIMIT v_limit
    ) q
  ), '[]'::jsonb);
END;
$$;

COMMIT;
