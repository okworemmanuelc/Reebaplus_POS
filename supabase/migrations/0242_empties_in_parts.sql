-- 0242_empties_in_parts.sql  (#629, slice S4 of PRD #620)
--
-- Empties in parts (owner decision 3): selling half a crate issues half a
-- crate of empties, returns can be in parts, and a crate deposit is
-- proportional (half a crate = half the per-crate rate, rounded half up to the
-- whole kobo through public.line_total_kobo).
--
-- 0239 already made every crate ledger / balance / pool / order_crate_lines /
-- pending_crate_returns quantity a double with a quarter CHECK, and recreated
-- the crate RPCs with double quantity types. Checked against the production
-- definitions on 2026-11-01, these need NO change and are not re-issued here:
--   checkout_order (crate block reads SUM(oi.quantity) as a double; the deposit
--     per brand arrives in kobo from the client), pos_record_crate_return,
--     pos_approve_crate_return, pos_transfer_crates, pos_record_sale_v2,
--     pos_cancel_order (refunds the held deposit by its kobo amount).
-- What is left, and what this migration does:
--
--   A. three crate counts that were still integer become double precision
--      with a quarter-step CHECK (the existing >= 0 / <> 0 checks stay):
--        crate_shortfall_writeoffs.crate_count
--        supplier_crate_deposits.crate_count
--        supplier_crate_deposit_requests.crate_count
--   B. console_crate_balances stops casting the crate sums to bigint (0.5 would
--      round on the console) and values each balance with line_total_kobo.
--      Return type is jsonb either way: same signature, CREATE OR REPLACE.
--   C. console_crate_ledger_net returns double precision instead of bigint.
--      The return type changes, so it is DROPped and re-GRANTed exactly as on
--      production (authenticated, service_role; no PUBLIC / anon).
--
-- B and C are console functions that originate in reebaplus-web; the bodies
-- are the production definitions of 2026-11-01 with only the casts / valuation
-- changed. pos-parity: the console must read `balance` and the net as numbers
-- that can be 0.5 (formatQty-style display).
--
-- Old-client safety: whole values still reach every client as JSON integers
-- (to_json(5::float8) = 5, see 0239). No client can create a fractional
-- crate_count before the new app version, so this is safe ahead of the app.
--
-- No view, index, policy or generated column depends on the three columns
-- (checked via pg_depend on 2026-11-01). All three tables were empty on
-- production on 2026-11-01. The append-only ledger triggers are row triggers,
-- which a table rewrite does not fire.
--
-- LOCKING: each ALTER COLUMN TYPE rewrites its (empty / tiny) table under
-- ACCESS EXCLUSIVE.

BEGIN;

-- ===========================================================================
-- A. Crate counts carry quarters
-- ===========================================================================
ALTER TABLE public.crate_shortfall_writeoffs
  ALTER COLUMN crate_count TYPE double precision USING crate_count::double precision;
ALTER TABLE public.crate_shortfall_writeoffs
  ADD CONSTRAINT crate_shortfall_writeoffs_crate_count_quarter_step
  CHECK (public.qty_is_quarter(crate_count));

ALTER TABLE public.supplier_crate_deposits
  ALTER COLUMN crate_count DROP DEFAULT;
ALTER TABLE public.supplier_crate_deposits
  ALTER COLUMN crate_count TYPE double precision USING crate_count::double precision;
ALTER TABLE public.supplier_crate_deposits
  ALTER COLUMN crate_count SET DEFAULT 0;
ALTER TABLE public.supplier_crate_deposits
  ADD CONSTRAINT supplier_crate_deposits_crate_count_quarter_step
  CHECK (public.qty_is_quarter(crate_count));

ALTER TABLE public.supplier_crate_deposit_requests
  ALTER COLUMN crate_count DROP DEFAULT;
ALTER TABLE public.supplier_crate_deposit_requests
  ALTER COLUMN crate_count TYPE double precision USING crate_count::double precision;
ALTER TABLE public.supplier_crate_deposit_requests
  ALTER COLUMN crate_count SET DEFAULT 0;
ALTER TABLE public.supplier_crate_deposit_requests
  ADD CONSTRAINT supplier_crate_deposit_requests_crate_count_quarter_step
  CHECK (public.qty_is_quarter(crate_count));

-- ===========================================================================
-- B. console_crate_balances: balances keep their parts
-- ===========================================================================
-- Changed from production: `sum(...)::bigint` -> `sum(...)` (double precision)
-- and `t.balance * t.rate_kobo` -> `public.line_total_kobo(t.rate_kobo,
-- t.balance)`, so value_kobo stays a whole kobo for a half crate.
CREATE OR REPLACE FUNCTION public.console_crate_balances(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_res jsonb;
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;

  select jsonb_build_object(
    'customer_debt', coalesce((
      select jsonb_agg(jsonb_build_object(
        'customer_id', t.customer_id,
        'customer_name', t.customer_name,
        'manufacturer_id', t.manufacturer_id,
        'manufacturer_name', t.manufacturer_name,
        'balance', t.balance,
        'rate_kobo', t.rate_kobo,
        'value_kobo', public.line_total_kobo(t.rate_kobo, t.balance)
      ) order by t.manufacturer_name, t.customer_name)
      from (
        select cl.customer_id, c.name as customer_name, cl.manufacturer_id,
               m.name as manufacturer_name, m.deposit_amount_kobo as rate_kobo,
               sum(cl.quantity_delta) as balance
          from public.crate_ledger cl
          join public.manufacturers m on m.id = cl.manufacturer_id
          left join public.customers c on c.id = cl.customer_id
         where cl.business_id = p_business_id
           and cl.customer_id is not null
           and cl.manufacturer_id is not null
         group by cl.customer_id, c.name, cl.manufacturer_id, m.name, m.deposit_amount_kobo
        having sum(cl.quantity_delta) <> 0
      ) t
    ), '[]'::jsonb),
    'supplier_debt', coalesce((
      select jsonb_agg(jsonb_build_object(
        'supplier_id', t.supplier_id,
        'supplier_name', t.supplier_name,
        'manufacturer_id', t.manufacturer_id,
        'manufacturer_name', t.manufacturer_name,
        'balance', t.balance,
        'rate_kobo', t.rate_kobo,
        'value_kobo', public.line_total_kobo(t.rate_kobo, t.balance)
      ) order by t.manufacturer_name, t.supplier_name)
      from (
        select sl.supplier_id, s.name as supplier_name, sl.manufacturer_id,
               m.name as manufacturer_name, m.deposit_amount_kobo as rate_kobo,
               sum(sl.quantity_delta) as balance
          from public.supplier_crate_ledger sl
          join public.manufacturers m on m.id = sl.manufacturer_id
          left join public.suppliers s on s.id = sl.supplier_id
         where sl.business_id = p_business_id
         group by sl.supplier_id, s.name, sl.manufacturer_id, m.name, m.deposit_amount_kobo
        having sum(sl.quantity_delta) <> 0
      ) t
    ), '[]'::jsonb),
    'pool', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_id', t.store_id,
        'store_name', t.store_name,
        'manufacturer_id', t.manufacturer_id,
        'manufacturer_name', t.manufacturer_name,
        'balance', t.balance,
        'rate_kobo', t.rate_kobo,
        'value_kobo', public.line_total_kobo(t.rate_kobo, t.balance)
      ) order by t.manufacturer_name, t.store_name)
      from (
        select cl.store_id, st.name as store_name, cl.manufacturer_id,
               m.name as manufacturer_name, m.deposit_amount_kobo as rate_kobo,
               sum(cl.quantity_delta) as balance
          from public.crate_ledger cl
          join public.manufacturers m on m.id = cl.manufacturer_id
          left join public.stores st on st.id = cl.store_id
         where cl.business_id = p_business_id
           and cl.customer_id is null
           and cl.store_id is not null
           and cl.manufacturer_id is not null
           and cl.movement_type <> 'full_crate_damage'
         group by cl.store_id, st.name, cl.manufacturer_id, m.name, m.deposit_amount_kobo
        having sum(cl.quantity_delta) <> 0
      ) t
    ), '[]'::jsonb)
  ) into v_res;

  return v_res;
end;
$function$;

-- ===========================================================================
-- C. console_crate_ledger_net: bigint -> double precision
-- ===========================================================================
DROP FUNCTION IF EXISTS public.console_crate_ledger_net(uuid, uuid, uuid, uuid, text, timestamp with time zone, timestamp with time zone);

CREATE OR REPLACE FUNCTION public.console_crate_ledger_net(p_business_id uuid, p_customer_id uuid DEFAULT NULL::uuid, p_manufacturer_id uuid DEFAULT NULL::uuid, p_store_id uuid DEFAULT NULL::uuid, p_movement_type text DEFAULT NULL::text, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS double precision
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_console_admin() then
    raise exception 'not authorized';
  end if;
  return coalesce((
    select sum(cl.quantity_delta)
      from public.crate_ledger cl
     where cl.business_id = p_business_id
       and (p_customer_id     is null or cl.customer_id     = p_customer_id)
       and (p_manufacturer_id is null or cl.manufacturer_id = p_manufacturer_id)
       and (p_store_id        is null or cl.store_id        = p_store_id)
       and (p_movement_type   is null or cl.movement_type   = p_movement_type)
       and (p_from            is null or cl.created_at     >= p_from)
       and (p_to              is null or cl.created_at      < p_to)
  ), 0);
end;
$function$;

-- Grants exactly as on production (2026-11-01):
-- {postgres=X, service_role=X, authenticated=X}.
REVOKE ALL ON FUNCTION public.console_crate_ledger_net(uuid, uuid, uuid, uuid, text, timestamp with time zone, timestamp with time zone) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.console_crate_ledger_net(uuid, uuid, uuid, uuid, text, timestamp with time zone, timestamp with time zone) TO authenticated, service_role;

COMMIT;
