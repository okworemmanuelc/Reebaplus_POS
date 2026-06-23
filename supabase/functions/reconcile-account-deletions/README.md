# reconcile-account-deletions

Finishes account deletion by removing the CEO's `auth.users` login through the
Auth Admin API — the one step `delete_business` (an in-DB SECURITY DEFINER)
cannot do on managed Supabase. See `index.ts` header and migration `0125`.

## What it does

Scans `public.account_deletion_events` for rows still pending login removal
(`auth_user_deleted = false AND acknowledged_at IS NULL`) and, for each:

1. **Safety guard (defense-in-depth)** — the system invariant is
   one-email-one-business, so after a cascade the identity is normally orphaned
   and this guard never trips. But if the `owner_auth_user_id` still owns a
   business (`businesses.owner_id`) or still has any `public.users` row — i.e.
   the invariant has been violated (this happened in the incident that
   motivated the function: one email, two live businesses) — it does **not**
   delete the shared login, since another live business still depends on it. It
   marks the event `acknowledged_at` with a "login retained" note instead.
2. Otherwise (fully orphaned identity) it calls
   `service.auth.admin.deleteUser(uid)` and stamps `auth_user_deleted = true`.
   A genuine failure leaves the row pending with the reason on
   `auth_delete_error` for the next run to retry.

It is idempotent and safe to run repeatedly; it also heals historical rows that
predate this function.

## Required secrets

| Env var                        | Purpose                                                  |
| ------------------------------ | -------------------------------------------------------- |
| `SUPABASE_URL`                 | provided by the platform                                 |
| `SUPABASE_SERVICE_ROLE_KEY`    | provided by the platform; grants Admin-API delete access |
| `ACCOUNT_DELETION_HOOK_SECRET` | **set this** — shared secret gating every invocation     |

Set the gate secret:

```bash
supabase secrets set ACCOUNT_DELETION_HOOK_SECRET="$(openssl rand -hex 32)"
```

## Deploy

```bash
supabase functions deploy reconcile-account-deletions
```

## Wiring (pick one or both)

### A. Scheduled batch (recommended baseline)

Run every 15 minutes via `pg_cron` + `pg_net`. Store the URL/secret in Vault so
they aren't inlined:

```sql
-- one-time: stash the endpoint + secret in Vault
select vault.create_secret('https://<project-ref>.functions.supabase.co/reconcile-account-deletions', 'reconcile_deletions_url');
select vault.create_secret('<the ACCOUNT_DELETION_HOOK_SECRET value>', 'reconcile_deletions_secret');

select cron.schedule(
  'reconcile-account-deletions',
  '*/15 * * * *',
  $$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'reconcile_deletions_url'),
    headers := jsonb_build_object(
                 'content-type', 'application/json',
                 'x-admin-hook-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'reconcile_deletions_secret')
               ),
    body    := '{}'::jsonb
  );
  $$
);
```

### B. Near-real-time per-row (optional, layer on top of A)

`AFTER INSERT` trigger on `account_deletion_events` that posts the new row id.
The function processes just that id (`{ "record": { "id": "<uuid>" } }`). Keep
schedule A as the backstop for transient Admin-API failures.

## Manual run / verification

```bash
curl -s -X POST 'https://<project-ref>.functions.supabase.co/reconcile-account-deletions' \
  -H 'content-type: application/json' \
  -H "x-admin-hook-secret: $ACCOUNT_DELETION_HOOK_SECRET" \
  -d '{}' | jq
```

Response:

```json
{ "ok": true, "mode": "batch",
  "summary": { "processed": 3, "deleted": 1, "skipped_in_use": 2, "skipped_no_auth_id": 0, "failed": 0 },
  "results": [ ... ] }
```
