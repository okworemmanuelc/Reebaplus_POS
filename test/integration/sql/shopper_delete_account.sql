-- #438 tier-2 SQL companion (reebaplus-dev only, after 0221 + 0229). WRITTEN, NOT RUN
-- by the agent. One transaction, rolled back.
--   psql "$DEV_DB_URL" -v ON_ERROR_STOP=1 -f test/integration/sql/shopper_delete_account.sql
-- Asserts shopper_delete_account():
--   * a Shopper's New order -> cancelled_by_customer; an answered order keeps
--     its status; both keep their snapshots, shopper_account_id -> NULL;
--   * the shop's linked Customer survives with shopper_account_id NULL;
--   * shopper_* rows and the Shopper-only devices row are gone;
--   * a pure Shopper gets a 'shopper' account_deletion_events row;
--   * a business member who also shops keeps users + user_businesses + login
--     (no deletion event), only their shopper data goes;
--   * 0229: the account_deleted email address is captured before the erase
--     (event owner_email is the login email) and the pg_net send, with Vault
--     unset here, is swallowed so the RPC still succeeds; the email helper is
--     service_role only;
--   * another Shopper is untouched; signed out cannot call it.
BEGIN;

SELECT set_config('t.biz', gen_random_uuid()::text, true),
       set_config('t.store', gen_random_uuid()::text, true),
       set_config('t.role', gen_random_uuid()::text, true),
       set_config('t.s', gen_random_uuid()::text, true),       -- pure Shopper
       set_config('t.m', gen_random_uuid()::text, true),       -- member who shops
       set_config('t.o', gen_random_uuid()::text, true),       -- other Shopper
       set_config('t.mu', gen_random_uuid()::text, true),      -- member users.id
       set_config('t.cust', gen_random_uuid()::text, true),
       set_config('t.o_new', gen_random_uuid()::text, true),
       set_config('t.o_acc', gen_random_uuid()::text, true),
       set_config('t.o_other', gen_random_uuid()::text, true),
       set_config('t.tok', 'da' || substr(md5(random()::text), 1, 8), true);

INSERT INTO auth.users (id, email) VALUES
  (current_setting('t.s')::uuid, current_setting('t.s') || '@example.invalid'),
  (current_setting('t.m')::uuid, current_setting('t.m') || '@example.invalid'),
  (current_setting('t.o')::uuid, current_setting('t.o') || '@example.invalid');
INSERT INTO public.businesses (id, name, subscription_status)
VALUES (current_setting('t.biz')::uuid, 'Delete ' || current_setting('t.tok'), 'active');
INSERT INTO public.stores (id, business_id, name, kind, country, state, lga)
VALUES (current_setting('t.store')::uuid, current_setting('t.biz')::uuid, 'DA store',
        'store', 'Nigeria', 'State', 'Lga');
INSERT INTO public.roles (id, business_id, name, slug)
VALUES (current_setting('t.role')::uuid, current_setting('t.biz')::uuid, 'Cashier', 'cashier');

-- The member: users row (auth-linked) + active membership.
INSERT INTO public.users (id, business_id, name, auth_user_id)
VALUES (current_setting('t.mu')::uuid, current_setting('t.biz')::uuid, 'member',
        current_setting('t.m')::uuid);
INSERT INTO public.user_businesses (business_id, user_id, role_id, status)
VALUES (current_setting('t.biz')::uuid, current_setting('t.mu')::uuid,
        current_setting('t.role')::uuid, 'active');

INSERT INTO public.shopper_profiles (auth_user_id, name) VALUES
  (current_setting('t.s')::uuid, 'Sade'),
  (current_setting('t.m')::uuid, 'Musa'),
  (current_setting('t.o')::uuid, 'Obi');
INSERT INTO public.shopper_phones (auth_user_id, phone, is_default) VALUES
  (current_setting('t.s')::uuid, '0801', true),
  (current_setting('t.m')::uuid, '0802', true),
  (current_setting('t.o')::uuid, '0803', true);
INSERT INTO public.shopper_addresses (auth_user_id, state, lga, street, is_default) VALUES
  (current_setting('t.s')::uuid, 'S', 'L', 'S street', true),
  (current_setting('t.m')::uuid, 'S', 'L', 'M street', true),
  (current_setting('t.o')::uuid, 'S', 'L', 'O street', true);
INSERT INTO public.shopper_age_confirmations (auth_user_id) VALUES
  (current_setting('t.s')::uuid), (current_setting('t.o')::uuid);
INSERT INTO public.devices (device_id, auth_user_id, business_id) VALUES
  ('dev-s-' || current_setting('t.tok'), current_setting('t.s')::uuid, NULL),
  ('dev-o-' || current_setting('t.tok'), current_setting('t.o')::uuid, NULL);

-- The shop's Customer linked to the Shopper.
INSERT INTO public.customers (id, business_id, name, shopper_account_id)
VALUES (current_setting('t.cust')::uuid, current_setting('t.biz')::uuid, 'Sade (shop)',
        current_setting('t.s')::uuid);

INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id, status,
  reference, shopper_name, delivery_phone, delivery_state, delivery_lga, delivery_street) VALUES
  (current_setting('t.o_new')::uuid, current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.s')::uuid, 'new', 'DA-N-' || current_setting('t.tok'), 'Sade', '0801', 'S', 'L', 'S street'),
  (current_setting('t.o_other')::uuid, current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.o')::uuid, 'new', 'DA-O-' || current_setting('t.tok'), 'Obi', '0803', 'S', 'L', 'O street');
INSERT INTO public.online_orders (id, business_id, store_id, shopper_account_id, status,
  reference, shopper_name, delivery_phone, delivery_state, delivery_lga, delivery_street) VALUES
  (current_setting('t.o_acc')::uuid, current_setting('t.biz')::uuid, current_setting('t.store')::uuid,
   current_setting('t.s')::uuid, 'new', 'DA-A-' || current_setting('t.tok'), 'Sade', '0801', 'S', 'L', 'S street');
UPDATE public.online_orders SET status = 'accepted' WHERE id = current_setting('t.o_acc')::uuid;

-- 1. EXECUTE boundaries.
DO $$
BEGIN
  IF has_function_privilege('anon', 'public.shopper_delete_account()', 'EXECUTE') THEN
    RAISE EXCEPTION 'shopper_delete_account must not be callable signed out';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.shopper_delete_account()', 'EXECUTE') THEN
    RAISE EXCEPTION 'shopper_delete_account must be callable signed in';
  END IF;
END;
$$;

-- 2. The pure Shopper deletes their account.
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('t.s'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb := public.shopper_delete_account();
BEGIN
  IF (r->>'login_kept')::boolean THEN
    RAISE EXCEPTION 'a pure Shopper''s login must not be kept: %', r;
  END IF;
  IF (r->>'cancelled_orders')::int <> 1 OR (r->>'unlinked_customers')::int <> 1 THEN
    RAISE EXCEPTION 'unexpected counts: %', r;
  END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_s uuid := current_setting('t.s')::uuid;
  o record;
BEGIN
  SELECT * INTO o FROM public.online_orders WHERE id = current_setting('t.o_new')::uuid;
  IF o.status <> 'cancelled_by_customer' THEN
    RAISE EXCEPTION 'New order must be cancelled_by_customer, got %', o.status;
  END IF;
  IF o.shopper_account_id IS NOT NULL OR o.shopper_name <> 'Sade'
     OR o.delivery_street <> 'S street' THEN
    RAISE EXCEPTION 'order must be unlinked with its snapshots kept';
  END IF;
  SELECT * INTO o FROM public.online_orders WHERE id = current_setting('t.o_acc')::uuid;
  IF o.status <> 'accepted' OR o.shopper_account_id IS NOT NULL THEN
    RAISE EXCEPTION 'answered order must keep its status and be unlinked';
  END IF;
  IF (SELECT shopper_account_id FROM public.customers
       WHERE id = current_setting('t.cust')::uuid AND NOT is_deleted) IS NOT NULL
     OR NOT EXISTS (SELECT 1 FROM public.customers WHERE id = current_setting('t.cust')::uuid) THEN
    RAISE EXCEPTION 'customer must survive, unlinked';
  END IF;
  IF EXISTS (SELECT 1 FROM public.shopper_profiles WHERE auth_user_id = v_s)
     OR EXISTS (SELECT 1 FROM public.shopper_phones WHERE auth_user_id = v_s)
     OR EXISTS (SELECT 1 FROM public.shopper_addresses WHERE auth_user_id = v_s)
     OR EXISTS (SELECT 1 FROM public.shopper_age_confirmations WHERE auth_user_id = v_s)
     OR EXISTS (SELECT 1 FROM public.devices WHERE auth_user_id = v_s AND business_id IS NULL) THEN
    RAISE EXCEPTION 'shopper_* rows must be erased';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.account_deletion_events
                  WHERE owner_auth_user_id = v_s AND kind = 'shopper'
                    AND business_id IS NULL) THEN
    RAISE EXCEPTION 'a shopper deletion event must be recorded for the reconcile job';
  END IF;
  -- 0229: the email address was read before the erase.
  IF (SELECT owner_email FROM public.account_deletion_events
       WHERE owner_auth_user_id = v_s) IS DISTINCT FROM v_s::text || '@example.invalid' THEN
    RAISE EXCEPTION 'the Shopper email must be captured before deletion';
  END IF;
  IF has_function_privilege('authenticated',
       'public._notify_shopper_account_deleted(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the email helper must not be callable by clients';
  END IF;
  -- Either the in-DB delete worked or the event is pending for the job.
  IF EXISTS (SELECT 1 FROM auth.users WHERE id = v_s)
     AND (SELECT auth_user_deleted FROM public.account_deletion_events
           WHERE owner_auth_user_id = v_s) THEN
    RAISE EXCEPTION 'event says deleted but the login still exists';
  END IF;
  -- The other Shopper is untouched.
  IF NOT EXISTS (SELECT 1 FROM public.shopper_profiles WHERE auth_user_id = current_setting('t.o')::uuid)
     OR NOT EXISTS (SELECT 1 FROM public.devices WHERE auth_user_id = current_setting('t.o')::uuid)
     OR (SELECT status FROM public.online_orders WHERE id = current_setting('t.o_other')::uuid) <> 'new' THEN
    RAISE EXCEPTION 'another Shopper was touched';
  END IF;
END;
$$;

-- 3. The business member who also shops.
SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('t.m'), 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb := public.shopper_delete_account();
BEGIN
  IF NOT (r->>'login_kept')::boolean OR (r->>'auth_user_deleted')::boolean THEN
    RAISE EXCEPTION 'a business member must keep their login: %', r;
  END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE v_m uuid := current_setting('t.m')::uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_m) THEN
    RAISE EXCEPTION 'member login must survive';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users u
                   JOIN public.user_businesses ub ON ub.user_id = u.id
                  WHERE u.auth_user_id = v_m AND ub.status = 'active'
                    AND ub.business_id = current_setting('t.biz')::uuid) THEN
    RAISE EXCEPTION 'member must keep their business membership';
  END IF;
  IF EXISTS (SELECT 1 FROM public.account_deletion_events WHERE owner_auth_user_id = v_m) THEN
    RAISE EXCEPTION 'no deletion event for a member';
  END IF;
  IF EXISTS (SELECT 1 FROM public.shopper_profiles WHERE auth_user_id = v_m)
     OR EXISTS (SELECT 1 FROM public.shopper_phones WHERE auth_user_id = v_m)
     OR EXISTS (SELECT 1 FROM public.shopper_addresses WHERE auth_user_id = v_m) THEN
    RAISE EXCEPTION 'member''s shopper data must be erased';
  END IF;
END;
$$;

ROLLBACK;
