-- Post-apply verification for 0230. Read-only checks, then a self-rolling-back
-- round trip (the DO block RAISEs at the end so nothing persists).
select proname, prosecdef from pg_proc where proname = 'enforce_plan_staff_pause';   -- 1 row, t

select has_function_privilege('authenticated','public.enforce_plan_staff_pause(uuid)','execute');  -- f
select has_function_privilege('service_role','public.enforce_plan_staff_pause(uuid)','execute');   -- t

select version from supabase_migrations.schema_migrations where version = '0230';

-- Round trip on a real FREE/expired business that has >1 active member.
-- Expect: NOTICE lists suspended ids, the owner is absent, then the exception
-- rolls everything back.
do $$
declare v_biz uuid; v_ids uuid[]; v_owner_active int;
begin
  select ub.business_id into v_biz
    from public.user_businesses ub
    join public.businesses b on b.id = ub.business_id
   where ub.status = 'active' and public.business_effective_plan(b.id) = 'free'
   group by ub.business_id having count(*) > 1 limit 1;
  if v_biz is null then raise notice 'no over-limit free business to test'; return; end if;
  v_ids := public.enforce_plan_staff_pause(v_biz);
  select count(*) into v_owner_active from public.user_businesses ub
    join public.roles r on r.id = ub.role_id
   where ub.business_id = v_biz and r.slug = 'ceo' and ub.status = 'active';
  raise notice 'suspended % ; owners still active: %', v_ids, v_owner_active;
  raise exception 'rollback verify';
end $$;
