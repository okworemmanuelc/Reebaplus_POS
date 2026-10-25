-- #473: online listing content on products — the shop's own description,
-- brand and order limits. A listing is the product plus these columns; there
-- is no separate listing record (owner decision 2026-10-22, PRD #421).
--
-- CLOUD FIRST: deploy before any app build that writes these columns.
-- products has no push whitelist, so an older cloud rejects the unknown
-- columns and jams the outbox.
--
-- Mirrors Drift v90 (lib/core/database/app_database.dart, Products). Every
-- CHECK here has a twin column CHECK there. Never copied into the shared
-- barcode catalogue (it reads only name, unit and photo).
begin;

alter table public.products
  add column if not exists online_description text,
  add column if not exists brand text,
  add column if not exists min_order_qty integer not null default 1,
  add column if not exists order_step integer not null default 1,
  add column if not exists max_order_qty integer;

alter table public.products
  drop constraint if exists products_online_description_length,
  add constraint products_online_description_length
    check (online_description is null or char_length(online_description) <= 2000),
  drop constraint if exists products_brand_length,
  add constraint products_brand_length
    check (brand is null or char_length(brand) <= 60),
  drop constraint if exists products_min_order_qty_positive,
  add constraint products_min_order_qty_positive check (min_order_qty >= 1),
  drop constraint if exists products_order_step_positive,
  add constraint products_order_step_positive check (order_step >= 1),
  drop constraint if exists products_max_order_qty_range,
  add constraint products_max_order_qty_range
    check (max_order_qty is null or max_order_qty >= min_order_qty);

comment on column public.products.online_description is
  '#473: Online store description (<= 2000 chars). Shop-owned; never shared.';
comment on column public.products.brand is
  '#473: Brand shown online (<= 60 chars). Prefilled from the manufacturer in drink shops.';
comment on column public.products.min_order_qty is
  '#473: Smallest online order quantity (>= 1).';
comment on column public.products.order_step is
  '#473: Online orders must be a multiple of this (12 = whole crates only).';
comment on column public.products.max_order_qty is
  '#473: Largest online order quantity; null = no limit.';

-- The one cloud rule for "may a shopper order this many?" — the place-order
-- RPC (#426) calls it per line. Twin of OrderQuantityRule.allows (Dart).
create or replace function public.order_quantity_allowed(
  p_quantity integer,
  p_min integer,
  p_step integer,
  p_max integer
)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_quantity is not null
     and p_quantity >= 1
     and p_quantity >= coalesce(p_min, 1)
     and p_quantity % greatest(coalesce(p_step, 1), 1) = 0
     and (p_max is null or p_quantity <= p_max);
$$;

comment on function public.order_quantity_allowed(integer, integer, integer, integer) is
  '#473: true when an online order quantity obeys a product''s min, step and max.';

-- A pure helper with no table access; RPCs call it as their owner. Signed-out
-- callers gain nothing from it, so keep the #468 posture (no anon/PUBLIC).
revoke execute on function public.order_quantity_allowed(integer, integer, integer, integer)
  from public, anon;
grant execute on function public.order_quantity_allowed(integer, integer, integer, integer)
  to authenticated, service_role;

commit;
