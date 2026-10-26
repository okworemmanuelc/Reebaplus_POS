-- #434 tier-2 SQL companion (reebaplus-dev, after applying 0218). WRITTEN, NOT
-- RUN by the agent. One transaction, rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/shopper_notifications.sql
-- Asserts:
--   * _shopper_order_accept_event: NULL while any line is undecided, 'changed'
--     when a line is lowered/removed, else 'accepted'
--   * _shopper_has_android_push: only a live Android token with permission
--     not denied (iPhone, null token, denied permission -> email instead)
--   * both triggers exist; status changes and batched line updates never fail
--     (Vault unset here / pg_net errors are swallowed)
--   * every 0218 function is server-only
BEGIN;

SELECT set_config('t.biz', gen_random_uuid()::text, true),
       set_config('t.store', gen_random_uuid()::text, true),
       set_config('t.prod', gen_random_uuid()::text, true),
       set_config('t.shopper', gen_random_uuid()::text, true),
       set_config('t.ios', gen_random_uuid()::text, true),
       set_config('t.o1', gen_random_uuid()::text, true),
       set_config('t.o2', gen_random_uuid()::text, true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid'),
  (current_setting('t.ios')::uuid, current_setting('t.ios') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Fixture', 'active');
INSERT INTO public.stores (id, business_id, name, kind)
VALUES (current_setting('t.store')::uuid, current_setting('t.biz')::uuid, 'S1', 'store');
INSERT INTO public.products (id, business_id, name, retailer_price_kobo,
                             buying_price_kobo, show_online, is_available,
                             min_order_qty, order_step, max_order_qty)
VALUES (current_setting('t.prod')::uuid, current_setting('t.biz')::uuid,
        'Lager', 450000, 300000, true, true, 1, 1, NULL);

-- Two open orders, two lines each (accepted_qty NULL = undecided).
INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id,
  reference, shopper_name, delivery_phone, delivery_state, delivery_lga, delivery_street)
VALUES
  (current_setting('t.o1')::uuid, current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.shopper')::uuid, 'ON-N1', 'Ada Obi', '0803', 'S', 'L', '1 Road'),
  (current_setting('t.o2')::uuid, current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.ios')::uuid, 'ON-N2', 'Bo Eze', '0803', 'S', 'L', '1 Road');
INSERT INTO public.online_order_lines (business_id, online_order_id, product_id,
  product_name, unit_price_kobo, requested_qty)
SELECT current_setting('t.biz')::uuid, o::uuid, current_setting('t.prod')::uuid,
       'Lager', 450000, q
  FROM unnest(ARRAY[current_setting('t.o1'), current_setting('t.o2')]) AS o,
       unnest(ARRAY[2, 3]) AS q;

-- Triggers are installed.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notify_shopper_online_order'
                   AND tgrelid = 'public.online_orders'::regclass)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notify_shopper_online_order_lines'
                   AND tgrelid = 'public.online_order_lines'::regclass) THEN
    RAISE EXCEPTION '0218 triggers missing';
  END IF;
END $$;

-- Header lands first (the shop phone's push order): accepted, lines undecided.
UPDATE public.online_orders SET status = 'accepted'
 WHERE id IN (current_setting('t.o1')::uuid, current_setting('t.o2')::uuid);
DO $$
BEGIN
  IF public._shopper_order_accept_event(current_setting('t.o1')::uuid) IS NOT NULL THEN
    RAISE EXCEPTION 'undecided lines must defer the notice to the lines trigger';
  END IF;
END $$;

-- Lines land in one batched statement: o1 untouched (accepted), o2 lowered.
UPDATE public.online_order_lines SET accepted_qty = requested_qty
 WHERE online_order_id = current_setting('t.o1')::uuid;
UPDATE public.online_order_lines
   SET accepted_qty = CASE WHEN requested_qty = 3 THEN 1 ELSE requested_qty END
 WHERE online_order_id = current_setting('t.o2')::uuid;
DO $$
BEGIN
  IF public._shopper_order_accept_event(current_setting('t.o1')::uuid) IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'all lines as asked must read accepted';
  END IF;
  IF public._shopper_order_accept_event(current_setting('t.o2')::uuid) IS DISTINCT FROM 'changed' THEN
    RAISE EXCEPTION 'a lowered line must read changed';
  END IF;
END $$;

-- A later lower on an accepted order, and a no-op re-push, never fail.
UPDATE public.online_order_lines SET accepted_qty = 1
 WHERE online_order_id = current_setting('t.o1')::uuid AND requested_qty = 2;
UPDATE public.online_order_lines SET accepted_qty = accepted_qty
 WHERE online_order_id = current_setting('t.o1')::uuid;

-- The shop cancel transition never fails.
UPDATE public.online_orders SET status = 'cancelled_by_shop', cancel_reason = 'Closed'
 WHERE id = current_setting('t.o1')::uuid;

-- Android reachability.
INSERT INTO public.devices (business_id, auth_user_id, device_id, platform,
                            fcm_token, push_permission_granted) VALUES
  (NULL, current_setting('t.shopper')::uuid, 'dev-android', 'android', 'tok-a-' || current_setting('t.shopper'), true),
  (NULL, current_setting('t.ios')::uuid,     'dev-ios',     'ios',     'tok-i-' || current_setting('t.ios'), true);
DO $$
BEGIN
  IF NOT public._shopper_has_android_push(current_setting('t.shopper')::uuid) THEN
    RAISE EXCEPTION 'android shopper must be push-reachable';
  END IF;
  IF public._shopper_has_android_push(current_setting('t.ios')::uuid) THEN
    RAISE EXCEPTION 'iPhone shopper must get email, not push';
  END IF;
END $$;
UPDATE public.devices SET push_permission_granted = false
 WHERE auth_user_id = current_setting('t.shopper')::uuid;
DO $$
BEGIN
  IF public._shopper_has_android_push(current_setting('t.shopper')::uuid) THEN
    RAISE EXCEPTION 'denied permission must fall back to email';
  END IF;
END $$;
UPDATE public.devices SET push_permission_granted = true, fcm_token = NULL
 WHERE auth_user_id = current_setting('t.shopper')::uuid;
DO $$
BEGIN
  IF public._shopper_has_android_push(current_setting('t.shopper')::uuid) THEN
    RAISE EXCEPTION 'a cleared token (sign-out) must fall back to email';
  END IF;
END $$;

-- Every 0218 function is server-only.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public._shopper_order_accept_event(uuid)',
    'public._shopper_has_android_push(uuid)',
    'public._notify_shopper_order(uuid,text)',
    'public.notify_shopper_on_online_order_update()',
    'public.notify_shopper_on_online_order_lines_update()'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE')
       OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% must be server-only', f;
    END IF;
  END LOOP;
END $$;

ROLLBACK;
