-- 0126_invite_email_trigger
--
-- Auto-send the branded Reebaplus invite email when an invite_codes row lands
-- in Postgres. Pairs with the `send-invite-email` Edge Function.
--
-- Design (see CONTEXT/architecture.md, server-logic row):
--   * The invite is created on-device in Drift and syncs through the outbox.
--     Firing the email server-side — when the row INSERTs into the cloud —
--     means an invite created OFFLINE still emails once it syncs, and the
--     client stays thin. The device's instant Copy / SMS / WhatsApp share
--     covers the offline window.
--   * AFTER INSERT only. The sync engine re-pushes rows via upsert; a conflict
--     fires UPDATE, never INSERT, so a re-push can never re-send the email.
--   * The email send is fire-and-forget over pg_net. If Resend is down the
--     invite code is still valid and shareable — no invite is lost to an email
--     failure.
--
-- SECRETS: the Edge Function base URL and the shared hook secret are read from
-- Vault, never hard-coded here (keeps secrets out of the repo). They must be
-- created once per project before invites will email:
--
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<random-long-string>',             'invite_email_hook_secret');
--
-- The same '<random-long-string>' must be set as the Edge Function secret
-- INVITE_EMAIL_HOOK_SECRET (supabase secrets set INVITE_EMAIL_HOOK_SECRET=...).

-- 1. pg_net for outbound HTTP from Postgres (first use in this project).
create extension if not exists pg_net with schema extensions;

-- 2. Observability + double-send guard. Cloud-only / app-read-only: the column
--    is absent from the Drift schema, so the client never reads or writes it,
--    and a client re-push upsert (partial row) never overwrites it.
alter table public.invite_codes
  add column if not exists invite_email_sent_at timestamptz;

-- 3. Trigger function: POST the new row to the Edge Function via pg_net.
create or replace function public.send_invite_email_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text;
  v_secret   text;
begin
  -- Nothing to email without an address; skip soft-deleted rows defensively.
  if new.email is null or new.is_deleted is true then
    return new;
  end if;

  select decrypted_secret into v_base_url
    from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'invite_email_hook_secret';

  -- If the project isn't configured for invite email yet, do nothing rather
  -- than error the insert. The invite still syncs and is shareable on-device.
  if v_base_url is null or v_secret is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_base_url || '/functions/v1/send-invite-email',
    headers := jsonb_build_object(
      'content-type',        'application/json',
      'x-invite-hook-secret', v_secret
    ),
    body    := jsonb_build_object('record', to_jsonb(new))
  );

  return new;
end;
$$;

drop trigger if exists trg_send_invite_email on public.invite_codes;
create trigger trg_send_invite_email
  after insert on public.invite_codes
  for each row
  execute function public.send_invite_email_on_insert();
