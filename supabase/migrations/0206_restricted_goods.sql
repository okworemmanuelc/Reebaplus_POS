-- 0206_restricted_goods.sql
--
-- #479 (Online ordering 28/28, PRD #421, ADR 0031): restricted goods.
-- Cloud only — no Drift change, no tenant table, nothing in the outbox.
--
-- WHAT THIS ADDS
--   1. A public marketplace category a pharmacy can map its prescription-only
--      medicines to: 'prescription-medicines' (Health, restricted
--      'prescription'). Prescription items are NEVER listed online: 0202's
--      _storefront_cards (feed, search, store page — and the Sponsored slots
--      #461 adds there) and 0204's storefront_product_photos already drop a
--      product whose category or parent category is 'prescription'; this
--      migration only gives shops a category that carries the flag. The
--      bundled Dart catalogue (lib/core/data/marketplace_categories.dart)
--      mirrors the row; a parity test compares every field.
--   2. shopper_age_confirmations — one row per login that confirmed
--      "I am 18 or older" (owner decision 2026-10-22). Cloud-only, RPC-only:
--      RLS on with NO policies and no table grants. Deleted with the login
--      (ON DELETE CASCADE). A signed-out Shopper's confirmation lives on the
--      phone and is copied here at sign-in / Place order.
--   3. product_online_restriction(product) — THE classification rule, server
--      only: 'prescription' when the product's category or its parent is
--      prescription-only, else 'age_18' when either is 18+, else NULL.
--   4. shopper_age_confirmation_missing(uid, product ids) — server-only rule
--      the place-order RPC (#426, shopper_place_orders) calls per store:
--      true when any product is 18+ and that login never confirmed.
--      #426 maps it to the store result code 'age_confirmation_required'.
--   5. Shopper RPCs (SECURITY DEFINER, search_path '', authenticated only):
--        shopper_confirm_age()       record the confirmation; returns its time
--        shopper_age_confirmed_at()  the time, or NULL when never confirmed
--
-- DEPLOY: after 0190 (marketplace_categories) and 0202 (storefront). It does
-- not depend on 0205 (#426) and may deploy before or after it. Never together
-- with 0193. Legal review of online alcohol / medicine sales is an owner
-- action before launch — these flags are not legal clearance.

BEGIN;

-- =========================================================================
-- 1. Prescription-only medicines category
-- =========================================================================
INSERT INTO public.marketplace_categories (slug, name, parent_slug, sort, restricted)
VALUES ('prescription-medicines', 'Prescription medicines', 'health', 46, 'prescription')
ON CONFLICT (slug) DO NOTHING;

-- =========================================================================
-- 2. 18+ confirmations (cloud-only, RPC-only)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.shopper_age_confirmations (
  auth_user_id uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  confirmed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.shopper_age_confirmations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.shopper_age_confirmations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.shopper_age_confirmations TO service_role;

COMMENT ON TABLE public.shopper_age_confirmations IS
  '#479: logins that confirmed they are 18 or older. RPC-only (no policies).';

-- =========================================================================
-- 3. The classification rule (server-only)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.product_online_restriction(p_product_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE
           WHEN mc.restricted = 'prescription'
             OR parent.restricted = 'prescription' THEN 'prescription'
           WHEN mc.restricted = 'age_18'
             OR parent.restricted = 'age_18' THEN 'age_18'
         END
  FROM public.products p
  LEFT JOIN public.categories c
    ON c.id = p.category_id AND c.business_id = p.business_id
   AND NOT c.is_deleted
  LEFT JOIN public.marketplace_categories mc
    ON mc.slug = c.marketplace_category
  LEFT JOIN public.marketplace_categories parent
    ON parent.slug = mc.parent_slug
  WHERE p.id = p_product_id;
$$;
REVOKE ALL ON FUNCTION public.product_online_restriction(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.product_online_restriction(uuid) TO service_role;

COMMENT ON FUNCTION public.product_online_restriction(uuid) IS
  '#479: prescription | age_18 | NULL from the product''s marketplace category '
  '(or its parent). Server-only.';

-- =========================================================================
-- 4. The placement rule (server-only; #426 calls it per store)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.shopper_age_confirmation_missing(
  p_uid         uuid,
  p_product_ids uuid[]
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT EXISTS (
           SELECT 1 FROM unnest(coalesce(p_product_ids, ARRAY[]::uuid[])) AS x(id)
            WHERE public.product_online_restriction(x.id) = 'age_18')
     AND NOT EXISTS (
           SELECT 1 FROM public.shopper_age_confirmations a
            WHERE a.auth_user_id = p_uid);
$$;
REVOKE ALL ON FUNCTION public.shopper_age_confirmation_missing(uuid, uuid[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopper_age_confirmation_missing(uuid, uuid[])
  TO service_role;

COMMENT ON FUNCTION public.shopper_age_confirmation_missing(uuid, uuid[]) IS
  '#479: true when any product is 18+ and the login never confirmed its age. '
  'shopper_place_orders (#426) refuses that store with age_confirmation_required.';

-- =========================================================================
-- 5. Shopper RPCs (authenticated only)
-- =========================================================================
-- Record "I am 18 or older" for the caller. Idempotent: the first time wins.
CREATE OR REPLACE FUNCTION public.shopper_confirm_age()
RETURNS timestamptz
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_at  timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'sign in to continue' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.shopper_age_confirmations (auth_user_id)
  VALUES (v_uid)
  ON CONFLICT (auth_user_id) DO NOTHING;
  SELECT a.confirmed_at INTO v_at
    FROM public.shopper_age_confirmations a WHERE a.auth_user_id = v_uid;
  RETURN v_at;
END;
$$;
REVOKE ALL ON FUNCTION public.shopper_confirm_age() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopper_confirm_age() TO authenticated, service_role;

-- When the caller confirmed, or NULL.
CREATE OR REPLACE FUNCTION public.shopper_age_confirmed_at()
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'sign in to continue' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT a.confirmed_at FROM public.shopper_age_confirmations a
           WHERE a.auth_user_id = v_uid);
END;
$$;
REVOKE ALL ON FUNCTION public.shopper_age_confirmed_at() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopper_age_confirmed_at() TO authenticated, service_role;

COMMENT ON FUNCTION public.shopper_confirm_age() IS
  '#479: the caller confirms they are 18 or older (idempotent).';
COMMENT ON FUNCTION public.shopper_age_confirmed_at() IS
  '#479: when the caller confirmed they are 18 or older, or NULL.';

COMMIT;
