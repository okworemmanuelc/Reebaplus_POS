-- 0147_broadcast_sync_signal.sql
--
-- Workstream B (#101), slice B1 — the writer-agnostic live-sync SIGNAL.
--
-- What / why. A change made on one till must reach the others near-instantly.
-- `postgres_changes` was the original live path; it is unreliable (see the
-- 2026-07 realtime investigation) and, per architecture.md, Realtime is a
-- *signal that triggers a pull, "not the transport for the data itself"*. This
-- migration adds that signal via Supabase **Broadcast**: one generic AFTER
-- trigger that, on any tenant-row write, emits a MINIMAL message
-- `{table, id, op}` — NO row data — to the tenant topic `store_<business_id>`.
-- Every client subscribed to that topic reacts identically: schedule a debounced
-- catch-up pull (mobile) / refetch (web). The payload never carries the change,
-- so the trigger is deliberately writer-agnostic (it fires the same whether the
-- write came from the mobile outbox push, the web `checkout_order` RPC, or the
-- console) and stays "one trigger for all tables".
--
-- Design guarantees:
--   * WRITE-SAFE. The whole body is wrapped in EXCEPTION WHEN OTHERS THEN NULL,
--     so a signalling failure can NEVER abort — or even slow to an error — the
--     underlying business write. (`realtime.send` also self-swallows, but we do
--     not rely on that.)
--   * FIRES LAST. Named `zz_broadcast_sync_signal` so it sorts after any other
--     row trigger (Postgres fires per-row triggers in trigger-name order) — the
--     signal is the final side effect of a successful row change.
--   * MINIMAL PAYLOAD. `{table, id, op}` only. The client pulls authoritative
--     rows through the normal cursor-paginated path; the message is a nudge.
--   * NO-OP UPDATES SKIPPED. An UPDATE that changes nothing (e.g. an idempotent
--     lost-ack re-upsert of an identical row) emits no signal.
--   * SECURITY DEFINER + `SET search_path = ''`. The trigger runs as its owner
--     (migration role), so the `realtime.send` INSERT into `realtime.messages`
--     bypasses that table's RLS (which currently has 0 policies — per-tenant
--     read authorization is slice B2). Everything is schema-qualified.
--   * GENERIC over row shape. Reads `business_id` / `id` via `to_jsonb(...)` so
--     the one function works for every table, including natural-key tables with
--     no `id` column (the payload id is then null — the client ignores it).
--
-- Echo/loop safety (PRD risk #5): a client's reaction to a signal is a PULL,
-- which writes only to its LOCAL Drift store and never back to the cloud — so a
-- pull can never re-fire this cloud trigger. A device receiving the echo of its
-- own push simply runs one extra (debounced, idempotent) pull. No loop exists.
--
-- Attach set: every `public` base table (relkind='r') carrying a `business_id`
-- column, plus `businesses` itself (its `id` IS the tenant key). This is a
-- superset of the app's synced tenant tables — attaching to a not-app-synced
-- table (e.g. `devices`, `console_audit`) only costs a harmless, debounced,
-- redundant pull, never a correctness issue — and it keeps "add a synced table =
-- one registry entry": a new tenant table auto-inherits the signal with no
-- migration. The attach loop is idempotent (drop-if-exists first).
--
-- Reversible: `DROP FUNCTION public.zz_broadcast_sync_signal() CASCADE;` removes
-- the function and every attached trigger, restoring the pre-B state.

-- ── The one generic trigger function ────────────────────────────────────────
create or replace function public.zz_broadcast_sync_signal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_biz text;
  v_id  text;
begin
  -- Skip no-op updates: nothing changed, so there is nothing to converge.
  if tg_op = 'UPDATE'
     and to_jsonb(old) is not distinct from to_jsonb(new) then
    return null;
  end if;

  -- Resolve the tenant topic key. `businesses` has no `business_id` column —
  -- its own `id` is the tenant key; every other attached table has business_id.
  if tg_table_name = 'businesses' then
    v_biz := coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id');
  else
    v_biz := coalesce(
      to_jsonb(new) ->> 'business_id',
      to_jsonb(old) ->> 'business_id'
    );
  end if;

  v_id := coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id');

  if v_biz is not null then
    perform realtime.send(
      jsonb_build_object('table', tg_table_name, 'id', v_id, 'op', tg_op),
      'sync',
      'store_' || v_biz,
      true  -- private topic: reception is RLS-gated on realtime.messages (B2)
    );
  end if;

  return null;  -- AFTER trigger: the return value is ignored
exception
  when others then
    -- A signalling failure must never abort or error the underlying write.
    return null;
end;
$$;

comment on function public.zz_broadcast_sync_signal() is
  'Workstream B (#101/B1): emits a minimal {table,id,op} Broadcast signal to '
  'topic store_<business_id> on every tenant-row write. Write-safe, fires last, '
  'no row data. Clients react by scheduling a pull. Per-tenant read auth = B2.';

-- This is a TRIGGER function, never a client RPC. A trigger fires it regardless
-- of EXECUTE grants, so revoke the default PUBLIC EXECUTE to keep it off the
-- PostgREST `/rpc/` surface (a SECURITY DEFINER function callable by anon is a
-- needless exposure — the security advisor flags it). Idempotent.
revoke execute on function public.zz_broadcast_sync_signal()
  from public, anon, authenticated;

-- ── Attach to every business-scoped base table (+ businesses) ────────────────
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
  loop
    execute format(
      'drop trigger if exists zz_broadcast_sync_signal on public.%I',
      r.relname
    );
    execute format(
      'create trigger zz_broadcast_sync_signal '
      'after insert or update or delete on public.%I '
      'for each row execute function public.zz_broadcast_sync_signal()',
      r.relname
    );
  end loop;
end $$;
