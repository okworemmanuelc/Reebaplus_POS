-- 0209_shopper_data_rights.sql
-- #477 (PRD #421, Nigeria Data Protection Act): Shopper data rights.
--
--   1. shopper_profiles.marketing_opt_in (default false) + marketing_consent_at.
--      Only transactional order emails / pushes go out without it.
--   2. shopper_export()  — the caller's profile, phones, addresses and own
--      Online Orders with their lines, as one jsonb. Caller's rows ONLY
--      (identity is auth.uid(); no parameters).
--   3. shopper_set_marketing_opt_in(p_opt_in) — sets the flag; consent_at =
--      now() when true, NULL when false.
--   4. shopper_get_profile() re-issued VERBATIM from 0205 (same signature, no
--      new parameter, so no overload) plus one key: 'marketing_opt_in'.
--
-- DEPLOY: after 0205. Additive; old clients ignore the extra key.

BEGIN;

ALTER TABLE public.shopper_profiles
  ADD COLUMN IF NOT EXISTS marketing_opt_in boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS marketing_consent_at timestamptz;

-- Re-issued verbatim from 0205 + the 'marketing_opt_in' key.
CREATE OR REPLACE FUNCTION public.shopper_get_profile()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
  v_name text;
  v_opt_in boolean;
BEGIN
  SELECT p.name, p.marketing_opt_in INTO v_name, v_opt_in
    FROM public.shopper_profiles p
   WHERE p.auth_user_id = v_uid;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'name', v_name,
    'marketing_opt_in', v_opt_in,
    'phones', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', ph.id, 'phone', ph.phone, 'is_default', ph.is_default)
             ORDER BY ph.is_default DESC, ph.created_at)
        FROM public.shopper_phones ph
       WHERE ph.auth_user_id = v_uid AND NOT ph.is_deleted), '[]'::jsonb),
    'addresses', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id, 'country', a.country, 'state', a.state,
               'lga', a.lga, 'street', a.street, 'is_default', a.is_default)
             ORDER BY a.is_default DESC, a.created_at)
        FROM public.shopper_addresses a
       WHERE a.auth_user_id = v_uid AND NOT a.is_deleted), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.shopper_set_marketing_opt_in(p_opt_in boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
  v_on  boolean := coalesce(p_opt_in, false);
BEGIN
  UPDATE public.shopper_profiles
     SET marketing_opt_in = v_on,
         marketing_consent_at = CASE WHEN v_on THEN now() ELSE NULL END
   WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'shopper_profile_required' USING ERRCODE = 'P0001';
  END IF;
  RETURN v_on;
END;
$$;

-- Everything we hold about the caller, as JSON. Own rows only: every
-- subquery is keyed on auth.uid(); no business id, customer link or other
-- shopper is ever included.
CREATE OR REPLACE FUNCTION public.shopper_export()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
BEGIN
  RETURN jsonb_build_object(
    'exported_at', now(),
    'profile', (
      SELECT jsonb_build_object(
               'name', p.name,
               'marketing_opt_in', p.marketing_opt_in,
               'marketing_consent_at', p.marketing_consent_at,
               'created_at', p.created_at)
        FROM public.shopper_profiles p
       WHERE p.auth_user_id = v_uid),
    'phones', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'phone', ph.phone, 'is_default', ph.is_default,
               'created_at', ph.created_at)
             ORDER BY ph.created_at)
        FROM public.shopper_phones ph
       WHERE ph.auth_user_id = v_uid AND NOT ph.is_deleted), '[]'::jsonb),
    'addresses', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'country', a.country, 'state', a.state, 'lga', a.lga,
               'street', a.street, 'is_default', a.is_default,
               'created_at', a.created_at)
             ORDER BY a.created_at)
        FROM public.shopper_addresses a
       WHERE a.auth_user_id = v_uid AND NOT a.is_deleted), '[]'::jsonb),
    'orders', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'reference', o.reference,
               'status', o.status,
               'currency', o.currency,
               'total_kobo', o.estimated_total_kobo,
               'placed_at', o.placed_at,
               'shop', b.name,
               'shopper_name', o.shopper_name,
               'delivery_phone', o.delivery_phone,
               'delivery_country', o.delivery_country,
               'delivery_state', o.delivery_state,
               'delivery_lga', o.delivery_lga,
               'delivery_street', o.delivery_street,
               'note', o.note,
               'decline_reason', o.decline_reason,
               'cancel_reason', o.cancel_reason,
               'lines', coalesce((
                 SELECT jsonb_agg(jsonb_build_object(
                          'name', l.product_name,
                          'unit', l.unit,
                          'unit_price_kobo', l.unit_price_kobo,
                          'requested_qty', l.requested_qty,
                          'accepted_qty', l.accepted_qty)
                        ORDER BY l.created_at, l.product_name)
                   FROM public.online_order_lines l
                  WHERE l.online_order_id = o.id), '[]'::jsonb))
             ORDER BY o.placed_at DESC)
        FROM public.online_orders o
        JOIN public.businesses b ON b.id = o.business_id
       WHERE o.shopper_account_id = v_uid), '[]'::jsonb)
  );
END;
$$;

DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.shopper_get_profile()',
    'public.shopper_export()',
    'public.shopper_set_marketing_opt_in(boolean)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END LOOP;
END $$;

COMMENT ON FUNCTION public.shopper_export() IS
  '#477: the caller''s own data (profile, phones, addresses, Online Orders + lines) as JSON.';
COMMENT ON FUNCTION public.shopper_set_marketing_opt_in(boolean) IS
  '#477: marketing consent; consent_at = now() on, NULL off. Default is off.';

COMMIT;
