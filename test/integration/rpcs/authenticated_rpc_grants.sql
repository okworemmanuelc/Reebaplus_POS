-- Dedicated-dev Tier2: real authenticated onboarding, member Quick Sale and
-- denial of another-email admin probing. All auth/business/money fixtures roll back.
BEGIN;
SELECT set_config('test.auth_id', gen_random_uuid()::text, true);
SELECT set_config('test.business_id', gen_random_uuid()::text, true);
SELECT set_config('test.user_id', gen_random_uuid()::text, true);
SELECT set_config('test.order_id', gen_random_uuid()::text, true);
SELECT set_config('test.store_id', gen_random_uuid()::text, true);
INSERT INTO auth.users(id, email)
VALUES (current_setting('test.auth_id')::uuid,
        current_setting('test.auth_id') || '@example.invalid');
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', current_setting('test.auth_id'), 'role', 'authenticated',
  'email', current_setting('test.auth_id') || '@example.invalid')::text, true);
SET LOCAL ROLE authenticated;

-- This identity has no console_admins membership and cannot probe another email.
DO $$
BEGIN
  BEGIN
    PERFORM public.is_console_admin_email('other-person@example.invalid');
    RAISE EXCEPTION 'Signed-in non-admin unexpectedly learned admin-email status';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;

SELECT public.complete_onboarding(
  p_business_id => current_setting('test.business_id')::uuid,
  p_store_id => NULL,
  p_owner_name => 'RPC grant fixture',
  p_business_name => 'RPC grant fixture',
  p_business_type => 'Beverage distributor',
  p_business_phone => '',
  p_business_email => current_setting('test.auth_id') || '@example.invalid',
  p_location => NULL,
  p_settings => '{"currency":"NGN","timezone":"Africa/Lagos"}'::jsonb,
  p_user_id => current_setting('test.user_id')::uuid,
  p_tracks_empty_crates => false
);

DO $$
DECLARE result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.businesses
                 WHERE id = current_setting('test.business_id')::uuid) THEN
    RAISE EXCEPTION 'Authenticated onboarding did not create its business';
  END IF;
  INSERT INTO public.stores(id, business_id, name)
  VALUES (current_setting('test.store_id')::uuid,
          current_setting('test.business_id')::uuid, 'Fixture store');
  result := public.pos_record_sale_v2(
    p_business_id => current_setting('test.business_id')::uuid,
    p_actor_id => current_setting('test.user_id')::uuid,
    p_order_id => current_setting('test.order_id')::uuid,
    p_order_number => 'ACL-468-' || current_setting('test.order_id'),
    p_store_id => current_setting('test.store_id')::uuid,
    p_payment_type => 'cash',
    p_items => '[{"product_id":null,"quantity":1,"unit_price_kobo":100}]'::jsonb,
    p_amount_paid_kobo => 100,
    p_payment_method => 'cash'
  );
  IF (result->'order'->>'id')::uuid <> current_setting('test.order_id')::uuid
     OR NOT EXISTS (SELECT 1 FROM public.orders
          WHERE id = current_setting('test.order_id')::uuid
            AND total_amount_kobo = 100) THEN
    RAISE EXCEPTION 'Authenticated member sale failed to persist expected order';
  END IF;
END;
$$;
ROLLBACK;
