-- #433 tier-2 SQL companion (reebaplus-dev, after applying 0215). WRITTEN, NOT
-- RUN by the agent. One transaction, rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/online_order_staff_push.sql
-- Asserts recipient selection of _online_order_push_recipients(biz, store):
--   IN : CEO; cashier assigned to the store (role grant); user with a
--        force-grant override; cashier re-granted by a store override
--   OUT: cashier assigned to ANOTHER store; stock keeper (no permission);
--        cashier with a force-revoke override; cashier revoked by a store
--        override; suspended member; soft-deleted user
-- plus: inserting an online order never fails (trigger swallows errors),
-- and the helper is server-only.
BEGIN;

SELECT set_config('t.biz', gen_random_uuid()::text, true),
       set_config('t.s1', gen_random_uuid()::text, true),
       set_config('t.s2', gen_random_uuid()::text, true),
       set_config('t.r_ceo', gen_random_uuid()::text, true),
       set_config('t.r_cash', gen_random_uuid()::text, true),
       set_config('t.r_sk', gen_random_uuid()::text, true),
       set_config('t.shopper', gen_random_uuid()::text, true);
SELECT set_config('t.u_ceo', gen_random_uuid()::text, true),
       set_config('t.u_cash1', gen_random_uuid()::text, true),
       set_config('t.u_cash2', gen_random_uuid()::text, true),
       set_config('t.u_sk', gen_random_uuid()::text, true),
       set_config('t.u_grant', gen_random_uuid()::text, true),
       set_config('t.u_revoke', gen_random_uuid()::text, true),
       set_config('t.u_susp', gen_random_uuid()::text, true),
       set_config('t.u_del', gen_random_uuid()::text, true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.shopper')::uuid, current_setting('t.shopper') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Fixture', 'active');
INSERT INTO public.stores (id, business_id, name, kind) VALUES
  (current_setting('t.s1')::uuid, current_setting('t.biz')::uuid, 'S1', 'store'),
  (current_setting('t.s2')::uuid, current_setting('t.biz')::uuid, 'S2', 'store');

INSERT INTO public.roles (id, business_id, name, slug) VALUES
  (current_setting('t.r_ceo')::uuid,  current_setting('t.biz')::uuid, 'CEO', 'ceo'),
  (current_setting('t.r_cash')::uuid, current_setting('t.biz')::uuid, 'Cashier', 'cashier'),
  (current_setting('t.r_sk')::uuid,   current_setting('t.biz')::uuid, 'Stock keeper', 'stock_keeper');
INSERT INTO public.role_permissions (business_id, role_id, permission_key)
VALUES (current_setting('t.biz')::uuid, current_setting('t.r_cash')::uuid, 'online_orders.answer');

-- users (no role / soft-delete columns; removal lives on user_businesses.status)
INSERT INTO public.users (id, business_id, name) VALUES
  (current_setting('t.u_ceo')::uuid,   current_setting('t.biz')::uuid, 'ceo'),
  (current_setting('t.u_cash1')::uuid, current_setting('t.biz')::uuid, 'cash1'),
  (current_setting('t.u_cash2')::uuid, current_setting('t.biz')::uuid, 'cash2'),
  (current_setting('t.u_sk')::uuid,    current_setting('t.biz')::uuid, 'sk'),
  (current_setting('t.u_grant')::uuid, current_setting('t.biz')::uuid, 'grant'),
  (current_setting('t.u_revoke')::uuid,current_setting('t.biz')::uuid, 'revoke'),
  (current_setting('t.u_susp')::uuid,  current_setting('t.biz')::uuid, 'susp'),
  (current_setting('t.u_del')::uuid,   current_setting('t.biz')::uuid, 'del');

INSERT INTO public.user_businesses (business_id, user_id, role_id, status) VALUES
  (current_setting('t.biz')::uuid, current_setting('t.u_ceo')::uuid,   current_setting('t.r_ceo')::uuid,  'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_cash1')::uuid, current_setting('t.r_cash')::uuid, 'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_cash2')::uuid, current_setting('t.r_cash')::uuid, 'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_sk')::uuid,    current_setting('t.r_sk')::uuid,   'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_grant')::uuid, current_setting('t.r_sk')::uuid,   'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_revoke')::uuid,current_setting('t.r_cash')::uuid, 'active'),
  (current_setting('t.biz')::uuid, current_setting('t.u_susp')::uuid,  current_setting('t.r_cash')::uuid, 'suspended'),
  (current_setting('t.biz')::uuid, current_setting('t.u_del')::uuid,   current_setting('t.r_cash')::uuid, 'removed');

-- Store assignments: everyone except cash2 works at S1; cash2 works at S2 only.
INSERT INTO public.user_stores (business_id, user_id, store_id)
SELECT current_setting('t.biz')::uuid, x::uuid, current_setting('t.s1')::uuid
  FROM unnest(ARRAY[current_setting('t.u_cash1'), current_setting('t.u_sk'),
       current_setting('t.u_grant'), current_setting('t.u_revoke'),
       current_setting('t.u_susp'), current_setting('t.u_del')]) AS x;
INSERT INTO public.user_stores (business_id, user_id, store_id)
VALUES (current_setting('t.biz')::uuid, current_setting('t.u_cash2')::uuid, current_setting('t.s2')::uuid);

-- Overrides: force-grant the stock keeper-role user; force-revoke a cashier.
INSERT INTO public.user_permission_overrides (business_id, user_id, permission_key, is_granted) VALUES
  (current_setting('t.biz')::uuid, current_setting('t.u_grant')::uuid,  'online_orders.answer', true),
  (current_setting('t.biz')::uuid, current_setting('t.u_revoke')::uuid, 'online_orders.answer', false);

DO $$
DECLARE r uuid[];
BEGIN
  r := public._online_order_push_recipients(
         current_setting('t.biz')::uuid, current_setting('t.s1')::uuid);
  IF NOT current_setting('t.u_ceo')::uuid   = ANY(r) THEN RAISE EXCEPTION 'CEO must be alerted'; END IF;
  IF NOT current_setting('t.u_cash1')::uuid = ANY(r) THEN RAISE EXCEPTION 'assigned cashier must be alerted'; END IF;
  IF NOT current_setting('t.u_grant')::uuid = ANY(r) THEN RAISE EXCEPTION 'force-granted user must be alerted'; END IF;
  IF current_setting('t.u_cash2')::uuid  = ANY(r) THEN RAISE EXCEPTION 'other-store cashier must NOT be alerted'; END IF;
  IF current_setting('t.u_sk')::uuid     = ANY(r) THEN RAISE EXCEPTION 'stock keeper without permission must NOT be alerted'; END IF;
  IF current_setting('t.u_revoke')::uuid = ANY(r) THEN RAISE EXCEPTION 'force-revoked cashier must NOT be alerted'; END IF;
  IF current_setting('t.u_susp')::uuid   = ANY(r) THEN RAISE EXCEPTION 'suspended member must NOT be alerted'; END IF;
  IF current_setting('t.u_del')::uuid    = ANY(r) THEN RAISE EXCEPTION 'removed member must NOT be alerted'; END IF;

  -- Store S2: only cash2 (assigned there, role grant) + the CEO.
  r := public._online_order_push_recipients(
         current_setting('t.biz')::uuid, current_setting('t.s2')::uuid);
  IF NOT (current_setting('t.u_cash2')::uuid = ANY(r) AND current_setting('t.u_ceo')::uuid = ANY(r)) THEN
    RAISE EXCEPTION 'S2 must alert cash2 and the CEO';
  END IF;
  IF current_setting('t.u_cash1')::uuid = ANY(r) THEN RAISE EXCEPTION 'S1 cashier must not be alerted for S2'; END IF;
END $$;

-- Store-layer override: revoke cashiers at S1 -> cash1 drops out, cash2 (S2) unaffected.
INSERT INTO public.store_role_permissions (business_id, store_id, role_id, permission_key, is_granted)
VALUES (current_setting('t.biz')::uuid, current_setting('t.s1')::uuid,
        current_setting('t.r_cash')::uuid, 'online_orders.answer', false);
DO $$
DECLARE r uuid[];
BEGIN
  r := public._online_order_push_recipients(
         current_setting('t.biz')::uuid, current_setting('t.s1')::uuid);
  IF current_setting('t.u_cash1')::uuid = ANY(r) THEN RAISE EXCEPTION 'store revoke must drop cash1'; END IF;
  IF NOT current_setting('t.u_grant')::uuid = ANY(r) THEN RAISE EXCEPTION 'user override beats store layer'; END IF;
END $$;

-- The helper is server-only.
DO $$
BEGIN
  IF has_function_privilege('anon', 'public._online_order_push_recipients(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._online_order_push_recipients(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'recipient helper must be server-only';
  END IF;
END $$;

-- Placement is never blocked, even if the push path errors (Vault unset here
-- or pg_net failing is swallowed by the trigger).
INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id,
  reference, shopper_name, delivery_phone, delivery_state, delivery_lga, delivery_street)
VALUES (gen_random_uuid(), current_setting('t.biz')::uuid, current_setting('t.s1')::uuid,
  current_setting('t.shopper')::uuid, 'ON-PUSH', 'Ada Obi', '0803', 'S', 'L', '1 Road');

ROLLBACK;
