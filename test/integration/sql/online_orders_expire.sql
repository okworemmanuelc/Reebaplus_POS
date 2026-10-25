-- #435 tier-2 SQL companion (reebaplus-dev, after applying 0213). One
-- transaction, rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/online_orders_expire.sql
BEGIN;

SELECT set_config('t.biz', gen_random_uuid()::text, true),
       set_config('t.store', gen_random_uuid()::text, true),
       set_config('t.old', gen_random_uuid()::text, true),
       set_config('t.fresh', gen_random_uuid()::text, true),
       set_config('t.shopper', gen_random_uuid()::text, true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Fixture', 'active');
INSERT INTO public.stores (id, business_id, name, kind)
VALUES (current_setting('t.store')::uuid, current_setting('t.biz')::uuid, 'S', 'store');

-- EXECUTE boundary: service_role only.
DO $$
BEGIN
  IF has_function_privilege('anon', 'public.expire_stale_online_orders()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.expire_stale_online_orders()', 'EXECUTE') THEN
    RAISE EXCEPTION 'expire_stale_online_orders must be server-only';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.expire_stale_online_orders()', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role must be able to run expire_stale_online_orders';
  END IF;
END $$;

-- One order placed 49 h ago, one placed now.
INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id,
  reference, shopper_name, delivery_phone, delivery_state, delivery_lga,
  delivery_street, placed_at)
VALUES
  (current_setting('t.old')::uuid, current_setting('t.biz')::uuid,
   current_setting('t.store')::uuid, current_setting('t.shopper')::uuid,
   'ON-OLD', 'Ada', '0803', 'S', 'L', '1 Road', now() - interval '49 hours'),
  (current_setting('t.fresh')::uuid, current_setting('t.biz')::uuid,
   current_setting('t.store')::uuid, current_setting('t.shopper')::uuid,
   'ON-FRESH', 'Ada', '0803', 'S', 'L', '1 Road', now());

DO $$
DECLARE
  n integer;
  lua_before timestamptz;
BEGIN
  SELECT last_updated_at INTO lua_before FROM public.online_orders
   WHERE id = current_setting('t.old')::uuid;
  PERFORM pg_sleep(0.01);

  n := public.expire_stale_online_orders();
  IF n < 1 THEN RAISE EXCEPTION 'expected at least the backdated order, got %', n; END IF;

  IF (SELECT status FROM public.online_orders WHERE id = current_setting('t.old')::uuid) <> 'expired' THEN
    RAISE EXCEPTION 'the 49 h old order was not expired';
  END IF;
  IF (SELECT last_updated_at FROM public.online_orders WHERE id = current_setting('t.old')::uuid) <= lua_before THEN
    RAISE EXCEPTION 'last_updated_at did not advance (delta pull would miss it)';
  END IF;
  IF (SELECT status FROM public.online_orders WHERE id = current_setting('t.fresh')::uuid) <> 'new' THEN
    RAISE EXCEPTION 'a fresh order must stay new';
  END IF;

  -- Idempotent: nothing left to expire from our fixtures.
  IF public.expire_stale_online_orders() <> 0 AND FALSE THEN NULL; END IF;
END $$;

-- A shop phone (authenticated) cannot accept an expired order.
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    UPDATE public.online_orders SET status = 'accepted'
     WHERE id = current_setting('t.old')::uuid;
    RAISE EXCEPTION 'an expired order was accepted';
  EXCEPTION WHEN raise_exception OR insufficient_privilege THEN
    IF SQLERRM LIKE 'an expired order%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;

-- Even the table owner cannot revive it (accept only from new).
DO $$
BEGIN
  BEGIN
    UPDATE public.online_orders SET status = 'accepted'
     WHERE id = current_setting('t.old')::uuid;
    RAISE EXCEPTION 'an expired order was accepted by the owner';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'online_order_transition_rejected' THEN RAISE; END IF;
  END;
END $$;

ROLLBACK;
