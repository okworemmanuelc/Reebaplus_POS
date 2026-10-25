-- 0200_shopper_push_tokens.sql
--
-- #476 (Online ordering 25/28) — push tokens for Shoppers: phones without a
-- business. Parent PRD #421; identity rules ADR 0030; boundary ADR 0031.
--
-- Why. `public.devices` (0129, FCM columns 0159) needs `business_id` and
-- routes pushes by business only. A Shopper has no business, and a business
-- phone that also shops has ONE FCM token serving both roles.
--
-- What.
--   1. `devices.auth_user_id` (plain uuid, no FK, like `last_user_id`: rows
--      outlive their writer for console analytics). `business_id` becomes
--      nullable; a CHECK keeps every row addressed (business or auth user).
--   2. Server-stamped identity. A BEFORE trigger sets `auth_user_id :=
--      auth.uid()` on every direct client write (role `authenticated`), so the
--      app never sends it and cannot forge it. Writes made by trusted definer
--      code (the token-uniqueness trigger nulling another row's token, the
--      Shopper RPCs below) or by service_role keep the value they set.
--   3. Shopper-only rows: `business_id IS NULL`, one row per
--      (device_id, auth_user_id) via a partial unique index. Written ONLY by
--      the two SECURITY DEFINER RPCs below (identity from auth.uid(), never a
--      parameter). No new RLS policy: the existing tenant policy
--      (`business_id IN current_user_business_ids()`) is false for a NULL
--      business, so Shoppers get no direct table access at all and staff can
--      never write or read a business-less row.
--   4. Routing. Staff pushes stay `WHERE business_id = ?` (unchanged — console
--      broadcasts are untouched). Shopper pushes resolve
--      `WHERE auth_user_id = ? AND fcm_token IS NOT NULL`, which finds the
--      Shopper-only row OR the business row of a phone that also shops. The
--      0159 trigger still keeps ONE row per token, so a token is never sent the
--      same push twice and a business phone keeps its single row.
--
-- The 0147/0198 broadcast trigger already on `devices` skips NULL-business
-- rows (`if v_biz is not null`), so Shopper rows emit no tenant sync signal.
--
-- Not synced, no Drift mirror, no outbox (cloud-only like 0129). No backfill:
-- existing business rows are stamped on their next presence/token write
-- (sign-in, app-open online, reconnect). Nothing sends Shopper pushes yet —
-- #434 adds the senders; this slice is the token store + recipient lookup.
--
-- DEPLOY: additive, idempotent, any time. Deploy BEFORE (or with) the app
-- build that calls the Shopper RPCs; old builds are unaffected (they never send
-- auth_user_id and keep upserting on (business_id, device_id)). Deploy the
-- updated `send-push` Edge Function with or after this migration.

begin;

-- ── 1. Columns + addressing check ────────────────────────────────────────────
alter table public.devices
  add column if not exists auth_user_id uuid;  -- auth.users.id, NO FK (survives)

alter table public.devices
  alter column business_id drop not null;

alter table public.devices
  drop constraint if exists devices_addressed_check;
alter table public.devices
  add constraint devices_addressed_check
  check (business_id is not null or auth_user_id is not null);

-- One Shopper-only row per (device, login). Business rows keep the original
-- UNIQUE (business_id, device_id) — NULLs are distinct there, so it never
-- collides with these.
create unique index if not exists devices_shopper_device_user_key
  on public.devices (device_id, auth_user_id)
  where business_id is null;

-- Shopper recipient lookup: live tokens by auth user (business rows included).
create index if not exists idx_devices_auth_user_fcm_token
  on public.devices (auth_user_id)
  where fcm_token is not null;

-- ── 2. Server-stamped auth_user_id on direct client writes ───────────────────
-- SECURITY INVOKER on purpose: `current_user` must be the caller's role. A
-- direct PostgREST write runs as `authenticated`; definer functions run as
-- their owner and service_role as itself, so those keep what they set.
create or replace function public._devices_stamp_auth_user_id()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' then
    new.auth_user_id := auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists stamp_devices_auth_user_id on public.devices;
create trigger stamp_devices_auth_user_id
  before insert or update on public.devices
  for each row execute function public._devices_stamp_auth_user_id();

-- Trigger function, never a client RPC.
revoke execute on function public._devices_stamp_auth_user_id()
  from public, anon, authenticated;

-- ── 3. Shopper-only registration RPCs ────────────────────────────────────────
-- Register (or refresh) this phone's FCM token for the signed-in login with no
-- business. Identity is auth.uid(); the caller only names its opaque device id
-- and its own token/metadata. If the token already sits on THIS login's
-- business row (a business phone that shops), do nothing: that row already
-- routes Shopper pushes, and a second row would steal the token from staff
-- pushes via the 0159 one-row-per-token trigger.
create or replace function public.register_shopper_push_token(
  p_device_id               text,
  p_fcm_token               text,
  p_push_permission_granted boolean,
  p_platform                text    default null,
  p_manufacturer            text    default null,
  p_model                   text    default null,
  p_device_name             text    default null,
  p_os_version              text    default null,
  p_app_version             text    default null,
  p_is_physical_device      boolean default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(btrim(p_device_id), '') = '' or length(p_device_id) > 200 then
    raise exception 'invalid device id' using errcode = '22023';
  end if;
  if coalesce(btrim(p_fcm_token), '') = '' or length(p_fcm_token) > 4096 then
    raise exception 'invalid push token' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.devices d
    where d.fcm_token = p_fcm_token
      and d.business_id is not null
      and d.auth_user_id = v_uid
  ) then
    return;
  end if;

  insert into public.devices as d (
    business_id, auth_user_id, device_id, fcm_token, push_permission_granted,
    fcm_token_updated_at, platform, manufacturer, model, device_name,
    os_version, app_version, is_physical_device
  ) values (
    null, v_uid, p_device_id, p_fcm_token, p_push_permission_granted,
    now(), p_platform, p_manufacturer, p_model, p_device_name,
    p_os_version, p_app_version, p_is_physical_device
  )
  on conflict (device_id, auth_user_id) where business_id is null
  do update set
    fcm_token               = excluded.fcm_token,
    push_permission_granted = excluded.push_permission_granted,
    fcm_token_updated_at    = excluded.fcm_token_updated_at,
    platform                = coalesce(excluded.platform, d.platform),
    manufacturer            = coalesce(excluded.manufacturer, d.manufacturer),
    model                   = coalesce(excluded.model, d.model),
    device_name             = coalesce(excluded.device_name, d.device_name),
    os_version              = coalesce(excluded.os_version, d.os_version),
    app_version             = coalesce(excluded.app_version, d.app_version),
    is_physical_device      = coalesce(excluded.is_physical_device,
                                       d.is_physical_device);
end;
$$;

-- Shopper sign-out: null this login's token on this phone's Shopper-only row.
-- Touches only the caller's own business-less row; a no-op when none exists.
create or replace function public.clear_shopper_push_token(p_device_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  update public.devices
     set fcm_token = null,
         fcm_token_updated_at = now()
   where business_id is null
     and auth_user_id = v_uid
     and device_id = p_device_id
     and fcm_token is not null;
end;
$$;

revoke execute on function public.register_shopper_push_token(
  text, text, boolean, text, text, text, text, text, text, boolean
) from public, anon;
grant execute on function public.register_shopper_push_token(
  text, text, boolean, text, text, text, text, text, text, boolean
) to authenticated, service_role;

revoke execute on function public.clear_shopper_push_token(text)
  from public, anon;
grant execute on function public.clear_shopper_push_token(text)
  to authenticated, service_role;

commit;
