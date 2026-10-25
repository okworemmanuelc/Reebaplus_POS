-- 0205_online_orders.sql
--
-- #426 (Online ordering 5/28, PRD #421, ADRs 0030/0031): Shoppers place
-- orders. One cart across shops; Place order creates ONE Online Order per
-- shop, each placed independently. Cloud twin of Drift schemaVersion 92
-- (app_database.dart, `from < 92`).
--
-- WHAT THIS ADDS
--   1. Shopper tables, keyed by auth user, cloud-only (never synced to shops):
--        shopper_profiles   name (one row per login)
--        shopper_phones     saved phones (one default)
--        shopper_addresses  saved delivery addresses (one default)
--      RLS on with NO policies and no table grants: only the definer RPCs
--      below read or write them, always for auth.uid().
--   2. Business-scoped, synced to shop phones:
--        online_orders       one Shopper request to one store
--        online_order_lines  its lines (price / tier / name snapshots)
--      RLS for shop members via current_user_business_ids(). A Shopper has no
--      membership, so the tenant policy gives them nothing; their only read
--      path is shopper_my_orders() (own rows, public fields only).
--   3. The status-transition guard (BEFORE INSERT/UPDATE triggers):
--        new      → accepted                (shop)
--        new      → declined                (shop, reason required)
--        new      → cancelled_by_customer   (Shopper, via shopper_cancel_order)
--        new      → expired                 (system job, 48 h — later slice)
--        accepted → cancelled_by_shop       (shop, reason required)
--        accepted → fulfilled               (shop Checkout, linked order set)
--      Anything else raises P0001 'online_order_transition_rejected' (the shop
--      app treats it as a benign rejection reconciled by the next pull, #427).
--      Placement snapshots (who, where, prices, quantities asked) are
--      immutable; a shop may only lower accepted quantities.
--      Direct client INSERTs of NEW rows are refused (orders are created only
--      by the place-order RPC); an upsert of an EXISTING row is allowed so the
--      shop outbox (#427) can push status changes as full-row upserts.
--   4. Shopper RPCs (SECURITY DEFINER, search_path '', authenticated only):
--        shopper_get_profile()                     profile + saved contacts
--        shopper_save_profile(name, phone, address) first-time / edit details
--        shopper_save_phone / shopper_save_address  add another (optionally default)
--        shopper_remove_phone / shopper_remove_address
--        shopper_place_orders(orders, phone, address, note)
--        shopper_cancel_order(order_id)             only while `new`
--        shopper_my_orders(limit, before)           own orders, newest first
--   5. Live sync: zz_broadcast_sync_signal on both order tables (0198 guard),
--      realtime publication, and pos_pull_snapshot re-issued VERBATIM from
--      0203 plus the two tables after their parents.
--
-- PLACE ORDER (one store at a time, each in its own sub-transaction):
--   * identity from auth.uid(); a shopper_profiles row is required;
--   * idempotent on the client-generated order id (a retry returns the
--     already-placed order, never a duplicate);
--   * spam protection: at most 20 Online Orders per hour per Shopper
--     ("You've placed a lot of orders — please wait a little");
--   * the store must pass every storefront hide rule (_storefront_stores:
--     online, a store not a van, business visible, synced within 7 days) and
--     deliver to the chosen address (_storefront_reach);
--   * an owner cannot order from their own business (staff may);
--   * every product: this business, Show online, available, not deleted,
--     not prescription-only; quantity obeys order_quantity_allowed() (0201)
--     and is at most the store's real stock — the refusal never reveals the
--     count ("The store can't supply that many");
--   * the price is re-read from the product row (Retailer price; the linked
--     Customer tier arrives with #429) — client prices are never trusted;
--   * NO stock decrement: stock moves only at Send to till (#431).
--   A store that fails is reported back (code + product id); the others are
--   still placed.
--
-- DEPLOY: before the app build that calls these RPCs / carries Drift 92.
-- Never together with 0193. If #474's 0204 also re-issues pos_pull_snapshot,
-- re-base section 6 on 0204 before deploying (keep both tables lists).

BEGIN;

-- =========================================================================
-- 1. Shopper tables (cloud-only, RPC-only)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.shopper_profiles (
  auth_user_id    uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name            text        NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 100),
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.shopper_phones (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  phone           text        NOT NULL CHECK (btrim(phone) <> '' AND char_length(phone) <= 30),
  is_default      boolean     NOT NULL DEFAULT false,
  is_deleted      boolean     NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS shopper_phones_one_default
  ON public.shopper_phones (auth_user_id) WHERE is_default AND NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_shopper_phones_user
  ON public.shopper_phones (auth_user_id) WHERE NOT is_deleted;

CREATE TABLE IF NOT EXISTS public.shopper_addresses (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  country         text        NOT NULL DEFAULT 'Nigeria' CHECK (btrim(country) <> ''),
  state           text        NOT NULL CHECK (btrim(state) <> ''),
  lga             text        NOT NULL CHECK (btrim(lga) <> ''),
  street          text        NOT NULL CHECK (btrim(street) <> '' AND char_length(street) <= 200),
  is_default      boolean     NOT NULL DEFAULT false,
  is_deleted      boolean     NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS shopper_addresses_one_default
  ON public.shopper_addresses (auth_user_id) WHERE is_default AND NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_shopper_addresses_user
  ON public.shopper_addresses (auth_user_id) WHERE NOT is_deleted;

DROP TRIGGER IF EXISTS bump_shopper_profiles_last_updated_at ON public.shopper_profiles;
CREATE TRIGGER bump_shopper_profiles_last_updated_at
  BEFORE UPDATE ON public.shopper_profiles
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();
DROP TRIGGER IF EXISTS bump_shopper_phones_last_updated_at ON public.shopper_phones;
CREATE TRIGGER bump_shopper_phones_last_updated_at
  BEFORE UPDATE ON public.shopper_phones
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();
DROP TRIGGER IF EXISTS bump_shopper_addresses_last_updated_at ON public.shopper_addresses;
CREATE TRIGGER bump_shopper_addresses_last_updated_at
  BEFORE UPDATE ON public.shopper_addresses
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

ALTER TABLE public.shopper_profiles  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopper_phones    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shopper_addresses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.shopper_profiles, public.shopper_phones, public.shopper_addresses
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.shopper_profiles, public.shopper_phones, public.shopper_addresses
  TO service_role;

COMMENT ON TABLE public.shopper_profiles IS
  '#426: Shopper name per login. Cloud-only; read/written only by shopper_* RPCs.';
COMMENT ON TABLE public.shopper_phones IS
  '#426: Shopper saved phones (one default). Cloud-only; shopper_* RPCs only.';
COMMENT ON TABLE public.shopper_addresses IS
  '#426: Shopper saved delivery addresses (one default). Cloud-only; RPCs only.';

-- =========================================================================
-- 2. online_orders + online_order_lines (business-scoped, synced)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.online_orders (
  id                   uuid        PRIMARY KEY,
  business_id          uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id             uuid        NOT NULL REFERENCES public.stores(id)     ON DELETE CASCADE,
  -- The Shopper's auth user. Plain uuid, no FK: the shop keeps its record
  -- after the Shopper deletes their account (#438 nulls it).
  shopper_account_id   uuid,
  -- The shop's Customer record, null until linked on first accept (#429).
  customer_id          uuid        REFERENCES public.customers(id) ON DELETE SET NULL,
  status               text        NOT NULL DEFAULT 'new' CHECK (status IN (
                         'new', 'accepted', 'declined', 'cancelled_by_customer',
                         'cancelled_by_shop', 'fulfilled', 'expired')),
  reference            text        NOT NULL CHECK (btrim(reference) <> ''),
  currency             text        NOT NULL DEFAULT 'NGN',
  estimated_total_kobo bigint      NOT NULL DEFAULT 0 CHECK (estimated_total_kobo >= 0),
  shopper_name         text        NOT NULL,
  delivery_phone       text        NOT NULL,
  delivery_country     text        NOT NULL DEFAULT 'Nigeria',
  delivery_state       text        NOT NULL,
  delivery_lga         text        NOT NULL,
  delivery_street      text        NOT NULL,
  note                 text        CHECK (note IS NULL OR char_length(note) <= 500),
  decline_reason       text        CHECK (decline_reason IS NULL OR char_length(decline_reason) <= 300),
  cancel_reason        text        CHECK (cancel_reason IS NULL OR char_length(cancel_reason) <= 300),
  -- The Order created by Checkout after Send to till (#431).
  linked_order_id      uuid        REFERENCES public.orders(id) ON DELETE SET NULL,
  placed_at            timestamptz NOT NULL DEFAULT now(),
  responded_at         timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  last_updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS online_orders_business_reference
  ON public.online_orders (business_id, reference);
CREATE INDEX IF NOT EXISTS idx_online_orders_business_lua
  ON public.online_orders (business_id, last_updated_at);
CREATE INDEX IF NOT EXISTS idx_online_orders_store_status
  ON public.online_orders (store_id, status);
CREATE INDEX IF NOT EXISTS idx_online_orders_shopper_placed
  ON public.online_orders (shopper_account_id, placed_at DESC);

CREATE TABLE IF NOT EXISTS public.online_order_lines (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      uuid        NOT NULL REFERENCES public.businesses(id)    ON DELETE CASCADE,
  online_order_id  uuid        NOT NULL REFERENCES public.online_orders(id) ON DELETE CASCADE,
  product_id       uuid        NOT NULL REFERENCES public.products(id)      ON DELETE CASCADE,
  product_name     text        NOT NULL,
  unit             text,
  unit_price_kobo  bigint      NOT NULL CHECK (unit_price_kobo >= 0),
  price_tier       text        NOT NULL DEFAULT 'retailer',
  requested_qty    integer     NOT NULL CHECK (requested_qty >= 1),
  -- Null until the shop accepts; may only be lowered (0 = line removed).
  accepted_qty     integer     CHECK (accepted_qty IS NULL OR accepted_qty >= 0),
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT online_order_lines_accepted_le_requested
    CHECK (accepted_qty IS NULL OR accepted_qty <= requested_qty)
);
CREATE UNIQUE INDEX IF NOT EXISTS online_order_lines_order_product
  ON public.online_order_lines (online_order_id, product_id);
CREATE INDEX IF NOT EXISTS idx_online_order_lines_business_lua
  ON public.online_order_lines (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_online_orders_last_updated_at ON public.online_orders;
CREATE TRIGGER bump_online_orders_last_updated_at
  BEFORE UPDATE ON public.online_orders
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();
DROP TRIGGER IF EXISTS bump_online_order_lines_last_updated_at ON public.online_order_lines;
CREATE TRIGGER bump_online_order_lines_last_updated_at
  BEFORE UPDATE ON public.online_order_lines
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

COMMENT ON TABLE public.online_orders IS
  '#426: a Shopper''s request to one store. Not a Sale: no stock, revenue, '
  'money or crate effect. Created only by shopper_place_orders.';
COMMENT ON TABLE public.online_order_lines IS
  '#426: Online Order lines with price/tier/name snapshots at placement.';

-- =========================================================================
-- 3. Guards — status machine, immutable snapshots, RPC-only creation
-- =========================================================================
-- SECURITY INVOKER on purpose: current_user is the caller's role. A direct
-- PostgREST write runs as `authenticated`; definer RPCs run as their owner,
-- and service_role / the system job as themselves.
CREATE OR REPLACE FUNCTION public._online_orders_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_client boolean := current_user IN ('authenticated', 'anon');
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- A client may upsert an EXISTING order (the ON CONFLICT update then runs
    -- this guard as UPDATE); creating one is the place-order RPC's job.
    IF v_client AND NOT EXISTS (
      SELECT 1 FROM public.online_orders o WHERE o.id = NEW.id
    ) THEN
      RAISE EXCEPTION 'online orders are created only by shopper_place_orders'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  -- Placement snapshots are fixed for clients (shop phones). Trusted definer
  -- code (the place-order RPC's total, #438's account unlink) may write them.
  IF v_client AND (
     NEW.business_id        IS DISTINCT FROM OLD.business_id
     OR NEW.store_id           IS DISTINCT FROM OLD.store_id
     OR NEW.shopper_account_id IS DISTINCT FROM OLD.shopper_account_id
     OR NEW.reference          IS DISTINCT FROM OLD.reference
     OR NEW.currency           IS DISTINCT FROM OLD.currency
     OR NEW.shopper_name       IS DISTINCT FROM OLD.shopper_name
     OR NEW.delivery_phone     IS DISTINCT FROM OLD.delivery_phone
     OR NEW.delivery_country   IS DISTINCT FROM OLD.delivery_country
     OR NEW.delivery_state     IS DISTINCT FROM OLD.delivery_state
     OR NEW.delivery_lga       IS DISTINCT FROM OLD.delivery_lga
     OR NEW.delivery_street    IS DISTINCT FROM OLD.delivery_street
     OR NEW.note               IS DISTINCT FROM OLD.note
     OR NEW.placed_at          IS DISTINCT FROM OLD.placed_at
     OR NEW.created_at         IS DISTINCT FROM OLD.created_at
     OR NEW.estimated_total_kobo > OLD.estimated_total_kobo) THEN
    RAISE EXCEPTION 'online order placement details cannot change'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
      (OLD.status = 'new' AND NEW.status = 'accepted')
      OR (OLD.status = 'new' AND NEW.status = 'declined'
          AND nullif(btrim(NEW.decline_reason), '') IS NOT NULL)
      OR (OLD.status = 'new' AND NEW.status = 'cancelled_by_customer'
          AND NOT v_client)
      OR (OLD.status = 'new' AND NEW.status = 'expired' AND NOT v_client)
      OR (OLD.status = 'accepted' AND NEW.status = 'cancelled_by_shop'
          AND nullif(btrim(NEW.cancel_reason), '') IS NOT NULL)
      OR (OLD.status = 'accepted' AND NEW.status = 'fulfilled'
          AND NEW.linked_order_id IS NOT NULL)
    ) THEN
      RAISE EXCEPTION 'online_order_transition_rejected'
        USING ERRCODE = 'P0001',
              DETAIL = format('%s -> %s', OLD.status, NEW.status);
    END IF;
    IF NEW.status IN ('accepted', 'declined') AND NEW.responded_at IS NULL THEN
      NEW.responded_at := now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._online_order_lines_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_client boolean := current_user IN ('authenticated', 'anon');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF v_client AND NOT EXISTS (
      SELECT 1 FROM public.online_order_lines l WHERE l.id = NEW.id
    ) THEN
      -- A shop may lower or remove lines, never add them.
      RAISE EXCEPTION 'online order lines are created only by shopper_place_orders'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF v_client AND (
     NEW.business_id     IS DISTINCT FROM OLD.business_id
     OR NEW.online_order_id IS DISTINCT FROM OLD.online_order_id
     OR NEW.product_id      IS DISTINCT FROM OLD.product_id
     OR NEW.product_name    IS DISTINCT FROM OLD.product_name
     OR NEW.unit            IS DISTINCT FROM OLD.unit
     OR NEW.unit_price_kobo IS DISTINCT FROM OLD.unit_price_kobo
     OR NEW.price_tier      IS DISTINCT FROM OLD.price_tier
     OR NEW.requested_qty   IS DISTINCT FROM OLD.requested_qty
     OR NEW.created_at      IS DISTINCT FROM OLD.created_at) THEN
    RAISE EXCEPTION 'online order line snapshots cannot change'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.accepted_qty IS DISTINCT FROM OLD.accepted_qty AND NOT EXISTS (
    SELECT 1 FROM public.online_orders o
     WHERE o.id = NEW.online_order_id AND o.status IN ('new', 'accepted')
  ) THEN
    RAISE EXCEPTION 'online_order_transition_rejected'
      USING ERRCODE = 'P0001', DETAIL = 'line change on a closed order';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._online_orders_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._online_order_lines_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS online_orders_guard ON public.online_orders;
CREATE TRIGGER online_orders_guard
  BEFORE INSERT OR UPDATE ON public.online_orders
  FOR EACH ROW EXECUTE FUNCTION public._online_orders_guard();
DROP TRIGGER IF EXISTS online_order_lines_guard ON public.online_order_lines;
CREATE TRIGGER online_order_lines_guard
  BEFORE INSERT OR UPDATE ON public.online_order_lines
  FOR EACH ROW EXECUTE FUNCTION public._online_order_lines_guard();

-- =========================================================================
-- 4. RLS, realtime, live signal
-- =========================================================================
ALTER TABLE public.online_orders      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.online_order_lines ENABLE ROW LEVEL SECURITY;

-- Shop members: read, and update (the guard limits what changes). INSERT is
-- allowed by policy only so a full-row outbox upsert of an EXISTING row
-- works; the guard refuses brand-new rows. No DELETE policy.
DROP POLICY IF EXISTS online_orders_tenant_select ON public.online_orders;
CREATE POLICY online_orders_tenant_select ON public.online_orders
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()));
DROP POLICY IF EXISTS online_orders_tenant_insert ON public.online_orders;
CREATE POLICY online_orders_tenant_insert ON public.online_orders
  FOR INSERT TO authenticated
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));
DROP POLICY IF EXISTS online_orders_tenant_update ON public.online_orders;
CREATE POLICY online_orders_tenant_update ON public.online_orders
  FOR UPDATE TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

DROP POLICY IF EXISTS online_order_lines_tenant_select ON public.online_order_lines;
CREATE POLICY online_order_lines_tenant_select ON public.online_order_lines
  FOR SELECT TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()));
DROP POLICY IF EXISTS online_order_lines_tenant_insert ON public.online_order_lines;
CREATE POLICY online_order_lines_tenant_insert ON public.online_order_lines
  FOR INSERT TO authenticated
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));
DROP POLICY IF EXISTS online_order_lines_tenant_update ON public.online_order_lines;
CREATE POLICY online_order_lines_tenant_update ON public.online_order_lines
  FOR UPDATE TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

REVOKE ALL ON public.online_orders, public.online_order_lines FROM anon;
REVOKE DELETE, TRUNCATE ON public.online_orders, public.online_order_lines
  FROM authenticated;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['online_orders', 'online_order_lines'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;

-- Live-sync signal: a new Online Order pings the shop's phones at once (#470).
DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.online_orders;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.online_orders
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();
DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.online_order_lines;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.online_order_lines
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- =========================================================================
-- 5. Shopper RPCs
-- =========================================================================

-- Internal: the caller's auth user, or 42501 when signed out.
CREATE OR REPLACE FUNCTION public._shopper_uid()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'sign in to continue' USING ERRCODE = '42501';
  END IF;
  RETURN v_uid;
END;
$$;
REVOKE ALL ON FUNCTION public._shopper_uid() FROM PUBLIC, anon, authenticated;

-- Profile + saved contacts. NULL when the Shopper has not given details yet.
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
BEGIN
  SELECT p.name INTO v_name FROM public.shopper_profiles p
   WHERE p.auth_user_id = v_uid;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'name', v_name,
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

-- Internal: save (or re-use) one phone for p_uid; returns its id.
CREATE OR REPLACE FUNCTION public._shopper_put_phone(
  p_uid uuid, p_phone text, p_make_default boolean)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_phone text := btrim(coalesce(p_phone, ''));
  v_id uuid;
BEGIN
  IF v_phone = '' OR char_length(v_phone) > 30 THEN
    RAISE EXCEPTION 'invalid_phone' USING ERRCODE = '22023';
  END IF;
  SELECT ph.id INTO v_id FROM public.shopper_phones ph
   WHERE ph.auth_user_id = p_uid AND NOT ph.is_deleted AND ph.phone = v_phone
   LIMIT 1;
  IF p_make_default THEN
    UPDATE public.shopper_phones SET is_default = false
     WHERE auth_user_id = p_uid AND is_default AND id IS DISTINCT FROM v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.shopper_phones (auth_user_id, phone, is_default)
    VALUES (p_uid, v_phone, coalesce(p_make_default, false))
    RETURNING id INTO v_id;
  ELSIF p_make_default THEN
    UPDATE public.shopper_phones SET is_default = true WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$$;

-- Internal: save (or re-use) one address for p_uid; returns its id.
CREATE OR REPLACE FUNCTION public._shopper_put_address(
  p_uid uuid, p_country text, p_state text, p_lga text, p_street text,
  p_make_default boolean)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_country text := coalesce(nullif(btrim(p_country), ''), 'Nigeria');
  v_state   text := btrim(coalesce(p_state, ''));
  v_lga     text := btrim(coalesce(p_lga, ''));
  v_street  text := btrim(coalesce(p_street, ''));
  v_id uuid;
BEGIN
  IF v_state = '' OR v_lga = '' OR v_street = '' OR char_length(v_street) > 200
     OR char_length(v_state) > 100 OR char_length(v_lga) > 100
     OR char_length(v_country) > 100 THEN
    RAISE EXCEPTION 'invalid_address' USING ERRCODE = '22023';
  END IF;
  SELECT a.id INTO v_id FROM public.shopper_addresses a
   WHERE a.auth_user_id = p_uid AND NOT a.is_deleted
     AND a.country = v_country AND a.state = v_state AND a.lga = v_lga
     AND a.street = v_street
   LIMIT 1;
  IF p_make_default THEN
    UPDATE public.shopper_addresses SET is_default = false
     WHERE auth_user_id = p_uid AND is_default AND id IS DISTINCT FROM v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.shopper_addresses
      (auth_user_id, country, state, lga, street, is_default)
    VALUES (p_uid, v_country, v_state, v_lga, v_street,
            coalesce(p_make_default, false))
    RETURNING id INTO v_id;
  ELSIF p_make_default THEN
    UPDATE public.shopper_addresses SET is_default = true WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._shopper_put_phone(uuid, text, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._shopper_put_address(uuid, text, text, text, text, boolean)
  FROM PUBLIC, anon, authenticated;

-- First-time details or an edit: name + default phone + default address.
CREATE OR REPLACE FUNCTION public.shopper_save_profile(
  p_name    text,
  p_phone   text,
  p_country text,
  p_state   text,
  p_lga     text,
  p_street  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := public._shopper_uid();
  v_name text := btrim(coalesce(p_name, ''));
BEGIN
  IF v_name = '' OR char_length(v_name) > 100 THEN
    RAISE EXCEPTION 'invalid_name' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.shopper_profiles (auth_user_id, name)
  VALUES (v_uid, v_name)
  ON CONFLICT (auth_user_id) DO UPDATE SET name = EXCLUDED.name;
  PERFORM public._shopper_put_phone(v_uid, p_phone, true);
  PERFORM public._shopper_put_address(v_uid, p_country, p_state, p_lga, p_street, true);
  RETURN public.shopper_get_profile();
END;
$$;

CREATE OR REPLACE FUNCTION public.shopper_save_phone(
  p_phone text, p_make_default boolean DEFAULT false)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
BEGIN
  IF (SELECT count(*) FROM public.shopper_phones
       WHERE auth_user_id = v_uid AND NOT is_deleted) >= 10 THEN
    RAISE EXCEPTION 'too_many_saved_phones' USING ERRCODE = '22023';
  END IF;
  RETURN public._shopper_put_phone(v_uid, p_phone, p_make_default);
END;
$$;

CREATE OR REPLACE FUNCTION public.shopper_save_address(
  p_country text, p_state text, p_lga text, p_street text,
  p_make_default boolean DEFAULT false)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
BEGIN
  IF (SELECT count(*) FROM public.shopper_addresses
       WHERE auth_user_id = v_uid AND NOT is_deleted) >= 10 THEN
    RAISE EXCEPTION 'too_many_saved_addresses' USING ERRCODE = '22023';
  END IF;
  RETURN public._shopper_put_address(
    v_uid, p_country, p_state, p_lga, p_street, p_make_default);
END;
$$;

-- Removing the default leaves no default (the app asks for one at checkout).
CREATE OR REPLACE FUNCTION public.shopper_remove_phone(p_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.shopper_phones SET is_deleted = true, is_default = false
   WHERE id = p_id AND auth_user_id = public._shopper_uid();
$$;

CREATE OR REPLACE FUNCTION public.shopper_remove_address(p_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.shopper_addresses SET is_deleted = true, is_default = false
   WHERE id = p_id AND auth_user_id = public._shopper_uid();
$$;

-- Place one Online Order per store. p_orders:
--   [{"id": uuid (client-generated), "store_id": uuid,
--     "lines": [{"product_id": uuid, "quantity": int}, ...]}, ...]
-- p_address: {"country","state","lga","street"}. Returns one result per
-- store, in input order:
--   {"id","store_id","ok":true,"reference","status","total_kobo","currency"}
--   {"id","store_id","ok":false,"code", "product_id"?}
-- codes: rate_limited | store_unavailable | out_of_area | own_business |
--        product_unavailable | quantity_rule | not_enough_stock | invalid
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

-- Cancel an own order, only while it is `new`. Returns the new status.
-- An order the shop already answered raises P0001 'order_not_cancellable'.
CREATE OR REPLACE FUNCTION public.shopper_cancel_order(p_order_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := public._shopper_uid();
  v_status text;
BEGIN
  SELECT o.status INTO v_status FROM public.online_orders o
   WHERE o.id = p_order_id AND o.shopper_account_id = v_uid
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_status = 'cancelled_by_customer' THEN
    RETURN v_status;
  END IF;
  IF v_status <> 'new' THEN
    RAISE EXCEPTION 'order_not_cancellable' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.online_orders SET status = 'cancelled_by_customer'
   WHERE id = p_order_id;
  RETURN 'cancelled_by_customer';
END;
$$;

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

-- Grants: signed-in only (a Shopper is any authenticated login).
DO $$
DECLARE
  fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.shopper_get_profile()',
    'public.shopper_save_profile(text, text, text, text, text, text)',
    'public.shopper_save_phone(text, boolean)',
    'public.shopper_save_address(text, text, text, text, boolean)',
    'public.shopper_remove_phone(uuid)',
    'public.shopper_remove_address(uuid)',
    'public.shopper_place_orders(jsonb, text, jsonb, text)',
    'public.shopper_cancel_order(uuid)',
    'public.shopper_my_orders(integer, timestamptz)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END LOOP;
END $$;

COMMENT ON FUNCTION public.shopper_place_orders(jsonb, text, jsonb, text) IS
  '#426: one Online Order per store, each placed independently; server '
  're-prices and re-checks every rule. No stock movement.';
COMMENT ON FUNCTION public.shopper_my_orders(integer, timestamptz) IS
  '#426: the caller''s own Online Orders (public fields only).';

-- =========================================================================
-- 6. pos_pull_snapshot — add online_orders + online_order_lines
--    Body copied verbatim from 0203 (latest definition); the only change is
--    the two list entries marked "0205 (#426)", after their parents
--    (businesses, stores, customers, products, orders).
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
    'categories','products','inventory',
    'cost_batches',
    'customers','suppliers',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    'supplier_crate_deposit_requests','supplier_crate_deposits',
    'orders','order_items',
    'order_crate_lines',
    -- 0205 (#426): Online Orders + lines; parents stores, customers,
    -- products and orders are all listed above.
    'online_orders','online_order_lines',
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

COMMIT;
