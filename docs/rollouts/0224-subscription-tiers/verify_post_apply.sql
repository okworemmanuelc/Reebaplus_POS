-- Post-apply verification for 0224 (read-only).
select subscription_status, subscription_plan, billing_cycle, count(*) from businesses group by 1,2,3;
-- expect no 'local'/'international'; every 'trial' row has plan 'premium'.

select pg_get_constraintdef(oid) from pg_constraint
 where conrelid = 'public.businesses'::regclass and conname in ('businesses_subscription_plan_check','businesses_billing_cycle_check');

select * from public.business_plan_limits('free');     -- 1,1,f
select * from public.business_plan_limits('basic');    -- 1,5,f
select * from public.business_plan_limits('premium');  -- null,null,t

select b.id, b.subscription_status, public.business_effective_plan(b.id) from businesses b limit 20;

select tgname from pg_trigger where tgname in
 ('trg_stores_plan_limit','trg_invite_codes_plan_limit','trg_user_businesses_plan_limit');  -- 3 rows

select version from supabase_migrations.schema_migrations where version = '0224';
