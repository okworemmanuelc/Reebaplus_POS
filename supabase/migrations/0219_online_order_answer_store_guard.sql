-- 0219_online_order_answer_store_guard.sql
--
-- #528 (follow-up to #427 / PR #526, PRD #421): the cloud now enforces the
-- store-assigned rule for answering an Online Order. Until now only the app
-- checked it; 0208's guard checked online_orders.answer but not that the
-- caller works at the order's store. 0217 / 0218 are reserved by open PRs.
--
-- WHAT THIS ADDS
--   1. public._caller_works_at_order_store(business, store) — SECURITY DEFINER
--      helper (the guard itself must stay SECURITY INVOKER: it tells a shop
--      phone apart from trusted server code by current_user). The caller is
--      resolved exactly like caller_has_permission (0135): users.auth_user_id
--      = auth.uid(), then the active user_businesses row (latest login) and its
--      role. The store rule is EXACTLY _online_order_push_recipients' (0215):
--      the CEO; or a user_stores row for the store; or a Manager whose role has
--      role_settings manager_view_all_stores = 'true'. Removed / suspended
--      members (user_businesses.status <> 'active') never pass. users has no
--      soft-delete column.
--   2. _online_orders_guard re-issued VERBATIM from 0208 plus one check, next
--      to the permission check and with the same error style: a shop phone
--      may move an order out of `new` (accept / decline) only at a store it
--      works at -> 42501 'online_orders.answer store assignment required'.
--      Placed before the status machine, so it is never mistaken for the
--      benign customer-cancelled-first race (P0001).
--
-- Same guard signature and grants. No table, column, status or money change;
-- no Drift change. The web console answers through the same guard, so the
-- same store rule now applies there (pos-parity issue filed).
--
-- DEPLOY: any time after 0208 and 0215. Independent of 0193.

BEGIN;

-- =========================================================================
-- 1. Does the caller work at this store? (0215's store rule, 0135's caller)
-- =========================================================================
CREATE OR REPLACE FUNCTION public._caller_works_at_order_store(
  p_business_id uuid,
  p_store_id    uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid;
  v_role_id uuid;
  v_slug    text;
BEGIN
  SELECT id INTO v_user_id
    FROM public.users
   WHERE auth_user_id = auth.uid()
   LIMIT 1;
  IF v_user_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT ub.role_id, r.slug
    INTO v_role_id, v_slug
    FROM public.user_businesses ub
    JOIN public.roles r ON r.id = ub.role_id
   WHERE ub.user_id = v_user_id
     AND ub.business_id = p_business_id
     AND ub.status = 'active'
   ORDER BY ub.last_login_at DESC NULLS LAST
   LIMIT 1;
  IF v_role_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN (
    v_slug = 'ceo'
    OR EXISTS (
      SELECT 1 FROM public.user_stores us
       WHERE us.user_id = v_user_id AND us.store_id = p_store_id
    )
    OR (v_slug = 'manager' AND EXISTS (
      SELECT 1 FROM public.role_settings rs
       WHERE rs.role_id = v_role_id
         AND rs.setting_key = 'manager_view_all_stores'
         AND rs.setting_value = 'true'
    ))
  );
END;
$function$;

-- The guard runs as the shop phone's role (authenticated), so that role calls
-- the helper; it answers only for the caller's own auth.uid().
REVOKE ALL ON FUNCTION public._caller_works_at_order_store(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._caller_works_at_order_store(uuid, uuid)
  TO authenticated, service_role;

-- =========================================================================
-- 2. The status guard — verbatim from 0208 plus the store assignment check
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
    -- #528: ... and only at a store the caller works at (0215's store rule).
    IF v_client AND OLD.status = 'new'
       AND NEW.status IN ('accepted', 'declined')
       AND NOT public._caller_works_at_order_store(NEW.business_id, NEW.store_id)
    THEN
      RAISE EXCEPTION 'online_orders.answer store assignment required'
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
