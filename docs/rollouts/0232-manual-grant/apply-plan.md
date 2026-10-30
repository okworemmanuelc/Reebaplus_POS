# Apply plan: 0232 manual grants survive a Play lapse

Status: NOT APPLIED. Issue #592 (PRD #584 slice 8).
Migration: `supabase/migrations/0232_manual_grant_survives_play_lapse.sql`.
Depends on 0224 + 0225 (both on prod). No app or Edge Function change.

## What it does
* Re-issues `apply_play_purchase` with the **same signature** (no overload) and
  the same grants (service_role only).
* Adds cloud-only `play_applied_entitlements` (one row per business, the last
  plan + end date Play wrote). Not synced; RLS forced; service_role only.
* A Play lapse no longer downgrades a business on a **running manual grant**:
  `active`, plan basic/premium, end date NULL or in the future, and NOT what Play
  wrote (no stamp or purchase row with the same plan and an end date within 1 s).
* An entitled purchase still overwrites a manual grant, except a CANCELED one
  when the manual grant is at least as good on both plan and end date.
  The full rule is in the migration header.

## Apply (file has its own BEGIN/COMMIT)
1. Run `verify_post_apply.sql` on reebaplus-dev first (needs 0224 + 0225 there).
2. `supabase db query --linked -f supabase/migrations/0232_manual_grant_survives_play_lapse.sql`
3. Record: `insert into supabase_migrations.schema_migrations(version, name) values ('0232','manual_grant_survives_play_lapse');`
4. `supabase db query --linked -f docs/rollouts/0232-manual-grant/verify_post_apply.sql`:
   passing = no error (it runs in BEGIN … ROLLBACK and keeps nothing).

Re-running the migration is safe (idempotent).

## Rollback
`rollback.sql` restores the 0225 body, drops the stamp table and deletes the
schema_migrations row. Businesses values are not touched.

## POS parity
Status rule change: the supervisor opens a `pos-parity` issue in reebaplus-web.
The console needs no change (manual grants keep being written via service_role).
