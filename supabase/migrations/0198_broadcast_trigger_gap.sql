-- 0198_broadcast_trigger_gap.sql
--
-- #470 — Live sync signal missing on tables created after migration 0147.
--
-- Why. 0147 attached `zz_broadcast_sync_signal` with a ONE-TIME loop over the
-- tables that existed when it ran. Nothing re-runs that loop, so every
-- business-scoped table created later has no live "refresh now" signal: a write
-- on one phone only reaches the business's other phones on the 30 s periodic
-- pull / reconnect / resume. Tables affected (read from migrations 0148–0197):
--   daily_closings (0157); van_trips, van_trip_lots, driver_ledger_entries
--   (0162); van_return_events (0165); supplier_crate_deposit_requests,
--   supplier_crate_deposits (0172); crate_shortfall_writeoffs (0175);
--   barcode_catalogue_reports (0183, nullable business_id).
--
-- What.
--   1. Re-run 0147's attach rule — every `public` base table (relkind='r') with
--      a live `business_id` column, plus `businesses` — attaching the SAME
--      trigger (same name, same function, AFTER INSERT OR UPDATE OR DELETE,
--      FOR EACH ROW) ONLY where it is missing. Existing triggers are untouched
--      (no drop/recreate). The rule is not widened.
--   2. A read-only catalogue helper `public.broadcast_trigger_missing_tables`
--      that the tier-2 guard test
--      (test/integration/rpcs/broadcast_trigger_coverage_test.dart) calls with
--      the service-role key, so the NEXT new tenant table cannot silently miss
--      the trigger. EXECUTE is granted to service_role only.
--
-- Deploy any time; additive. Idempotent (safe to re-run). The trigger
-- function itself is unchanged (still owned by 0147).

begin;

-- ── 1. Attach the trigger where 0147's rule says it belongs but it is missing ─
do $$
declare
  r record;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and (
        c.relname = 'businesses'
        or exists (
          select 1
          from pg_attribute a
          where a.attrelid = c.oid
            and a.attname = 'business_id'
            and not a.attisdropped
        )
      )
      and not exists (
        select 1
        from pg_trigger t
        where t.tgrelid = c.oid
          and t.tgname = 'zz_broadcast_sync_signal'
          and not t.tgisinternal
      )
  loop
    execute format(
      'create trigger zz_broadcast_sync_signal '
      'after insert or update or delete on public.%I '
      'for each row execute function public.zz_broadcast_sync_signal()',
      r.relname
    );
  end loop;
end $$;

-- ── 2. Guard helper for the tier-2 coverage test ────────────────────────────
-- p_tables NULL  → every table matching 0147's rule that lacks the trigger.
-- p_tables given → every listed name that has no `zz_broadcast_sync_signal`
--                  trigger on public.<name> (a missing table is reported too).
create or replace function public.broadcast_trigger_missing_tables(
  p_tables text[] default null
)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select c.relname::text
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where p_tables is null
    and n.nspname = 'public'
    and c.relkind = 'r'
    and (
      c.relname = 'businesses'
      or exists (
        select 1
        from pg_catalog.pg_attribute a
        where a.attrelid = c.oid
          and a.attname = 'business_id'
          and not a.attisdropped
      )
    )
    and not exists (
      select 1
      from pg_catalog.pg_trigger t
      where t.tgrelid = c.oid
        and t.tgname = 'zz_broadcast_sync_signal'
        and not t.tgisinternal
    )
  union all
  select l.name
  from pg_catalog.unnest(p_tables) as l(name)
  where p_tables is not null
    and not exists (
      select 1
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      join pg_catalog.pg_trigger t on t.tgrelid = c.oid
      where n.nspname = 'public'
        and c.relname = l.name
        and t.tgname = 'zz_broadcast_sync_signal'
        and not t.tgisinternal
    )
  order by 1;
$$;

comment on function public.broadcast_trigger_missing_tables(text[]) is
  '#470: read-only catalogue check used by the tier-2 broadcast trigger '
  'coverage test. Returns tables lacking zz_broadcast_sync_signal. '
  'service_role only.';

revoke execute on function public.broadcast_trigger_missing_tables(text[])
  from public, anon, authenticated;
grant execute on function public.broadcast_trigger_missing_tables(text[])
  to service_role;

commit;
