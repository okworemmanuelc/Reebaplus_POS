-- 0159_push_notifications
--
-- DEPLOY: This migration is ALREADY physically applied on prod (project
-- ewwyofbvfjyqqirrcaou) under ledger version 20260713151317 — devices.fcm_token
-- and the rest already exist. It was renumbered 0153 -> 0159 to clear the money-
-- integrity collision (0153-0158 are the money migrations that now own those
-- numbers on main). At merge time do NOT expect a fresh apply: every statement
-- below is idempotent (a safe no-op re-run), or run
-- `supabase migration repair --status applied 0159` to record it against the
-- ledger without re-executing.
--
-- Reebaplus — OS push notifications for CONSOLE BROADCASTS via Firebase Cloud
-- Messaging (FCM). See docs/adr/0018-push-notifications-fcm.md + the CONTEXT.md
-- Notifications glossary.
--
-- What this migration adds (server half of the pipeline):
--   1. FCM Device Token storage on the cloud-only `devices` registry (0129).
--   2. A token-uniqueness trigger so a token maps to exactly ONE devices row
--      (the most recent login) — the mechanism that keeps a broadcast to one
--      business from ever reaching a phone that now serves a different tenant
--      (architecture.md invariant #5).
--   3. A `push_sent_at` observability column on `notifications` (cloud-only).
--   4. An AFTER INSERT trigger on `notifications`, filtered to
--      `type = 'console_broadcast'`, that fans the new row out through pg_net to
--      the `send-push` Edge Function — mirroring the `send-invite-email`
--      trigger→pg_net→function pattern (0126).
--
-- Design notes:
--   * AFTER INSERT ONLY. The sync engine re-pushes rows as upserts, which fire
--     UPDATE (never INSERT), so a re-push can never re-send a push. (The app
--     also never INSERTs a console_broadcast cloud-side — it only marks them
--     read, an UPDATE — so this fires solely for console-authored rows.)
--   * Fire-and-forget over pg_net: a push failure never aborts the insert and
--     never blocks sync. The Notification row of record still arrives via the
--     normal realtime-pull path, so a lost push loses nothing (ADR 0018:
--     "push is an alert only — it never writes Drift").
--   * Push is broadcasts-ONLY for now (allowlist-extensible later). Other
--     notification types (sale_rejected, new_order, low_stock, staff.*) do not
--     push.
--
-- SECRETS (Vault): the Edge Function base URL and a shared hook secret are read
-- from Vault, never hard-coded. `project_url` already exists (created for 0126).
-- The push hook secret must be created once per project before pushes fire:
--
--   select vault.create_secret('<random-long-string>', 'push_hook_secret');
--
-- The same '<random-long-string>' is set as the Edge Function secret
-- PUSH_HOOK_SECRET (supabase secrets set PUSH_HOOK_SECRET=...), and the FCM
-- service-account JSON as FCM_SERVICE_ACCOUNT. Until BOTH the Vault secret and
-- the Edge Function exist the trigger degrades to "no push" — never a broken
-- insert (see the null-secret guard below).
--
-- DEPLOY ORDER (as with 0126/0129): this migration + the `send-push` Edge
-- Function + the Vault/secret setup ship BEFORE or WITH the app build that
-- registers tokens. An unconfigured pipeline is inert, never a broken
-- insert/login/sync.

-- pg_net for outbound HTTP from Postgres (already enabled by 0126; idempotent).
create extension if not exists pg_net with schema extensions;

-- -----------------------------------------------------------------------------
-- 1. FCM Device Token columns on the cloud-only `devices` registry (0129).
--    Written by the same DIRECT authenticated upsert that already maintains
--    device presence (never through Drift / the outbox). Nullable: a token is
--    unknown until the OS permission is granted and FCM issues one.
-- -----------------------------------------------------------------------------
alter table public.devices
  add column if not exists fcm_token              text,
  add column if not exists push_permission_granted boolean,
  add column if not exists fcm_token_updated_at    timestamptz;

-- Token resolution for the fan-out: SELECT fcm_token WHERE business_id = ?
-- AND fcm_token IS NOT NULL. Partial index keeps it to live tokens only.
create index if not exists idx_devices_business_fcm_token
  on public.devices (business_id)
  where fcm_token is not null;

-- -----------------------------------------------------------------------------
-- 2. Token uniqueness (architecture.md invariant #5).
--    A given FCM token addresses exactly ONE devices row — the most recent
--    login. Whenever a non-null token is written to a row, null it on every
--    OTHER row that currently holds it. SECURITY DEFINER because the losing row
--    may belong to a DIFFERENT business (a phone that changed hands), which the
--    caller's RLS would forbid it from touching. The self-recursive UPDATE only
--    ever writes fcm_token = NULL, so the nested trigger invocation short-
--    circuits on the `is not null` guard — no infinite recursion.
-- -----------------------------------------------------------------------------
create or replace function public._devices_enforce_token_uniqueness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  if new.fcm_token is not null then
    update public.devices
      set fcm_token           = null,
          fcm_token_updated_at = now()
      where fcm_token = new.fcm_token
        and id <> new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_devices_token_uniqueness on public.devices;
create trigger enforce_devices_token_uniqueness
  before insert or update on public.devices
  for each row
  execute function public._devices_enforce_token_uniqueness();

-- TRIGGER function, never a client RPC. A trigger fires it regardless of EXECUTE
-- grants, so revoke the default PUBLIC EXECUTE to keep a SECURITY DEFINER
-- function off the PostgREST /rpc/ surface (the security advisor flags it). Idempotent.
revoke execute on function public._devices_enforce_token_uniqueness()
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Observability + double-send guard on notifications. Cloud-only /
--    app-read-only: absent from the Drift schema, so a client re-push upsert
--    (partial row) never overwrites it.
-- -----------------------------------------------------------------------------
alter table public.notifications
  add column if not exists push_sent_at timestamptz;

-- -----------------------------------------------------------------------------
-- 4. AFTER INSERT trigger: POST a console_broadcast row to the send-push Edge
--    Function via pg_net. Mirrors public.send_invite_email_on_insert (0126).
-- -----------------------------------------------------------------------------
create or replace function public.send_push_on_broadcast_insert()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text;
  v_secret   text;
begin
  -- Belt-and-suspenders: the trigger WHEN clause already filters to
  -- console_broadcast, but guard here too in case the trigger is ever widened.
  if new.type is distinct from 'console_broadcast' then
    return new;
  end if;

  select decrypted_secret into v_base_url
    from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'push_hook_secret';

  -- Unconfigured project → do nothing rather than error the insert. The
  -- broadcast still syncs and appears in the bell on the next pull.
  if v_base_url is null or v_secret is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_base_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'content-type',       'application/json',
      'x-push-hook-secret', v_secret
    ),
    body    := jsonb_build_object('record', to_jsonb(new))
  );

  return new;
end;
$$;

drop trigger if exists trg_send_push_broadcast on public.notifications;
create trigger trg_send_push_broadcast
  after insert on public.notifications
  for each row
  when (new.type = 'console_broadcast')
  execute function public.send_push_on_broadcast_insert();

-- TRIGGER function, never a client RPC — revoke the default PUBLIC EXECUTE to
-- keep this SECURITY DEFINER function off the PostgREST /rpc/ surface (advisor).
revoke execute on function public.send_push_on_broadcast_insert()
  from public, anon, authenticated;
