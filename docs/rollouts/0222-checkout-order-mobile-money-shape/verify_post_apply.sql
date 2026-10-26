-- Post-apply verification for 0222 (read-only). Run after applying.

-- 1. Exactly ONE checkout_order, the 9-arg shape (a second row = overload => PGRST203).
select oid::regprocedure, proacl::text from pg_proc where proname = 'checkout_order';
-- expect 1 row: ...(..., p_customer_id uuid, p_crate_deposit_by_manufacturer jsonb);
-- acl has authenticated + service_role + postgres, NOT anon, NOT PUBLIC (no '=X/postgres').

-- 2. The new parameter exists with a default.
select pg_get_function_arguments('public.checkout_order'::regproc);

-- 3. Migration recorded.
select version from supabase_migrations.schema_migrations where version = '0222';

-- 4. After the first real web sale post-apply (replace :order_id):
-- header: real payment_type, deposit column, amount_paid = tender
select payment_type, total_amount_kobo, net_amount_kobo, amount_paid_kobo, crate_deposit_paid_kobo
  from orders where id = :'order_id';
-- rows: sale / crate_deposit / wallet_topup, all with store_id, summing to amount_paid_kobo
select type, method, amount_kobo, store_id from payment_transactions where order_id = :'order_id';
select sum(amount_kobo) as rows_sum from payment_transactions where order_id = :'order_id';
-- invariant for ALL post-apply web orders (expect 0 rows):
select o.id from orders o
 where o.order_number like 'WEB-%' and o.created_at > now() - interval '1 day'
   and o.amount_paid_kobo <> coalesce((select sum(amount_kobo) from payment_transactions p where p.order_id = o.id and p.type in ('sale','crate_deposit','wallet_topup')), 0);
