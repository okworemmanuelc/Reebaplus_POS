-- 0208_online_order_answer.sql
--
-- #427 (Online ordering 6/28, PRD #421, ADRs 0030/0031): the shop sees and
-- answers Online Orders. Cloud twin of Drift schemaVersion 93
-- (app_database.dart, `from < 93`). 0207 is reserved for another slice.
--
-- WHAT THIS ADDS
--   1. customers.shopper_account_id (uuid, nullable): the Shopper login a
--      shop Customer is linked to. Set ONLY by a deliberate staff choice on the
--      first accepted order (ADR 0030: never a phone-number match). At most one
--      live Customer per Shopper per business (partial unique index; a
--      soft-deleted Customer frees the link). Plain uuid, no FK: #438 nulls it
--      when the Shopper deletes their account.
--   2. Permissions (category 'Online store'):
--        online_orders.view    see the Online tab + order detail
--        online_orders.answer  accept / decline (the app also requires the
--                              order's store to be one the user works in)
--      CEO, Manager and Cashier by default: the seed function is re-issued
--      VERBATIM from 0195 with the two keys added for Manager and Cashier, and
--      existing CEO / Manager / Cashier roles get a one-off backfill. The keys
--      reach the catalogue BEFORE any grant syncs (role_permissions FK).
--   3. _online_orders_guard re-issued VERBATIM from 0205 plus one check: a
--      client (shop phone) may move an order out of `new` (accept / decline)
--      only while holding online_orders.answer. The status machine itself is
--      unchanged — accept / decline still succeed ONLY from `new`, so an answer
--      that races a customer cancel is refused with P0001
--      'online_order_transition_rejected'. The app treats that refusal as
--      benign: it drops the stale answer and re-reads the order from the
--      cloud (never a Sync Issues orphan) and shows "Cancelled by the customer
--      before you accepted".
--
-- No new synced table, no pos_pull_snapshot change (0205 already carries
-- online_orders / online_order_lines; customers is already in the snapshot).
--
-- DEPLOY: AFTER 0205, and BEFORE the app build carrying Drift 93 — that build
-- pushes customers.shopper_account_id on every customer upsert, which the
-- cloud rejects (PGRST204) until this column exists. Never together with 0193.

BEGIN;

-- =========================================================================
-- 1. customers.shopper_account_id — one live Customer per Shopper per business
-- =========================================================================
ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS shopper_account_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS customers_business_shopper_account
  ON public.customers (business_id, shopper_account_id)
  WHERE shopper_account_id IS NOT NULL AND NOT is_deleted;

COMMENT ON COLUMN public.customers.shopper_account_id IS
  '#427: the Shopper (auth user) this Customer is linked to. Set only by a '
  'staff choice on the first accepted Online Order, never by phone match.';

-- =========================================================================
-- 2. Permissions — catalogue first, then the seed, then the one-off backfill
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('online_orders.view',   'See online orders',                 'Online store'),
  ('online_orders.answer', 'Accept or decline online orders',   'Online store')
ON CONFLICT (key) DO NOTHING;

-- Verbatim latest seed (0195), with online_orders.view / .answer added for
-- Manager and Cashier (the CEO already gets every catalogue key).
CREATE OR REPLACE FUNCTION public.seed_default_roles_for_business(
  p_business_id uuid
)
RETURNS TABLE (
  ceo_role_id          uuid,
  manager_role_id      uuid,
  cashier_role_id      uuid,
  stock_keeper_role_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ceo  uuid;
  v_mgr  uuid;
  v_cash uuid;
  v_sk   uuid;
  v_drv  uuid;
BEGIN
  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'CEO',          'ceo',          true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_ceo;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Manager',      'manager',      true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_mgr;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Cashier',      'cashier',      true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_cash;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Stock keeper', 'stock_keeper', true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_sk;

  -- #140 — the fifth system role. Last in tier order (CEO → Manager → Cashier
  -- → Stock keeper → Driver), which is how every role list is sorted.
  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Driver',       'driver',       true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_drv;

  -- CEO: all keys (includes the new van.manage / van.sell via the SELECT).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: explicit list + van.manage (#140 — a manager sets up vans, loads
  -- them and records remittances; they never sell from one).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_mgr, 'sales.make'),
    (p_business_id, v_mgr, 'sales.cancel'),
    (p_business_id, v_mgr, 'sales.confirm'),
    (p_business_id, v_mgr, 'sales.discount.give'),
    (p_business_id, v_mgr, 'products.add'),
    (p_business_id, v_mgr, 'products.edit_price'),
    (p_business_id, v_mgr, 'products.manage_listing'),
    (p_business_id, v_mgr, 'online_orders.view'),
    (p_business_id, v_mgr, 'online_orders.answer'),
    (p_business_id, v_mgr, 'products.edit_buying_price'),
    (p_business_id, v_mgr, 'products.delete'),
    (p_business_id, v_mgr, 'stock.add'),
    (p_business_id, v_mgr, 'stock.view'),
    (p_business_id, v_mgr, 'stock.adjust'),
    (p_business_id, v_mgr, 'expenses.create'),
    (p_business_id, v_mgr, 'reports.see_sales'),
    (p_business_id, v_mgr, 'reports.see_cost_prices'),
    (p_business_id, v_mgr, 'reports.see_expenses'),
    (p_business_id, v_mgr, 'customers.add'),
    (p_business_id, v_mgr, 'customers.update'),
    (p_business_id, v_mgr, 'customers.delete'),
    (p_business_id, v_mgr, 'customers.wallet.update'),
    (p_business_id, v_mgr, 'customers.set_debt_limit'),
    (p_business_id, v_mgr, 'customers.wallet.totals.view'),
    (p_business_id, v_mgr, 'customers.wallet.withdraw'),
    (p_business_id, v_mgr, 'stores.request_transfer'),
    (p_business_id, v_mgr, 'stores.dispatch_transfer'),
    (p_business_id, v_mgr, 'stores.receive_transfer'),
    (p_business_id, v_mgr, 'staff.invite'),
    (p_business_id, v_mgr, 'staff.suspend'),
    (p_business_id, v_mgr, 'staff.change_role'),
    (p_business_id, v_mgr, 'van.manage'),
    (p_business_id, v_mgr, 'funds.open_day'),
    (p_business_id, v_mgr, 'funds.close_day'),
    (p_business_id, v_mgr, 'funds.view')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: + online_orders.view / .answer (#427).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_cash, 'sales.make'),
    (p_business_id, v_cash, 'sales.confirm'),
    (p_business_id, v_cash, 'stock.view'),
    (p_business_id, v_cash, 'reports.see_sales'),
    (p_business_id, v_cash, 'customers.add'),
    (p_business_id, v_cash, 'customers.update'),
    (p_business_id, v_cash, 'customers.wallet.update'),
    (p_business_id, v_cash, 'online_orders.view'),
    (p_business_id, v_cash, 'online_orders.answer')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Stock keeper: unchanged.
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_sk, 'stock.add'),
    (p_business_id, v_sk, 'stock.view'),
    (p_business_id, v_sk, 'stock.adjust')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Driver: `van.sell` only. Deliberately NOT `sales.make` — a driver sells
  -- through the van terminal (#142), not the store POS — and deliberately NOT
  -- `van.manage`, which is what makes "a driver records their own remittance"
  -- impossible by construction (spec §9.5, edge case 21).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_drv, 'van.sell')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  INSERT INTO public.role_settings (business_id, role_id, setting_key, setting_value)
  VALUES
    (p_business_id, v_ceo,  'max_discount_percent',        '100'),
    (p_business_id, v_ceo,  'max_expense_approval_kobo',   NULL),
    (p_business_id, v_mgr,  'max_discount_percent',        '10'),
    (p_business_id, v_mgr,  'max_expense_approval_kobo',   '0'),
    (p_business_id, v_cash, 'max_discount_percent',        '0'),
    (p_business_id, v_cash, 'max_expense_approval_kobo',   '0'),
    (p_business_id, v_sk,   'max_discount_percent',        '0'),
    (p_business_id, v_sk,   'max_expense_approval_kobo',   '0'),
    (p_business_id, v_drv,  'max_discount_percent',        '0'),
    (p_business_id, v_drv,  'max_expense_approval_kobo',   '0')
  ON CONFLICT (role_id, setting_key) DO NOTHING;

  RETURN QUERY SELECT v_ceo, v_mgr, v_cash, v_sk;
END;
$function$;

-- Existing businesses receive the new defaults once. Do not rewrite this
-- migration to re-grant an intentionally revoked permission on later releases.
INSERT INTO public.role_permissions (business_id, role_id, permission_key)
SELECT r.business_id, r.id, k.key
  FROM public.roles r
 CROSS JOIN (VALUES ('online_orders.view'), ('online_orders.answer')) AS k(key)
 WHERE r.slug IN ('ceo', 'manager', 'cashier')
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- =========================================================================
-- 3. The status guard — verbatim from 0205 plus the answer permission check
-- =========================================================================
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
    -- #427: a shop phone answers (accept / decline) only with the permission.
    -- Checked before the status machine so a revoked answer is a plain 42501,
    -- not mistaken for the benign customer-cancelled-first race.
    IF v_client AND OLD.status = 'new'
       AND NEW.status IN ('accepted', 'declined')
       AND NOT public.caller_has_permission(NEW.business_id, 'online_orders.answer')
    THEN
      RAISE EXCEPTION 'online_orders.answer permission required'
        USING ERRCODE = '42501';
    END IF;
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

REVOKE ALL ON FUNCTION public._online_orders_guard() FROM PUBLIC, anon, authenticated;

COMMIT;
