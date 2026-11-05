-- 0254_storefront_free_shops.sql
--
-- Free-plan shops (status 'inactive', plan 'free', the state 0231 gives every new
-- business) can list on the storefront. Owner decision 2026-11-05, reebaplus-web#202.
-- A suspended paid plan (inactive, plan basic/premium) stays hidden.
-- Function body otherwise verbatim from 0214. Grants are kept by CREATE OR REPLACE.

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
        OR (b.subscription_status = 'inactive'
            AND coalesce(b.subscription_plan, 'free') = 'free')
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
