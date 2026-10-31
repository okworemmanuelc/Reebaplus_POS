# Apply plan: 0231 no more free trials

Status: NOT APPLIED. Issue #587 (PRD #584 slice 3).
Migration: `supabase/migrations/0231_no_trials.sql`.
Depends on 0224 (on prod). Ship after the never-lock client (#586) is on
phones: an ended trial moved to `inactive` must read as Free, not a lock.

## What it does
* New businesses start `inactive` / `free` / `trial_ends_at` NULL
  (status default + `set_business_trial_end()` re-issued, same signature).
* Customer roles (`authenticated`/`anon`) can no longer insert subscription
  values; the operator (service_role / console) can still insert or update
  any status, including an explicit trial.
* Data: `trial` rows with `trial_ends_at <= now()` move to `inactive`/`free`.
  Running trials and NULL-date rows are untouched.

## Before applying
Count what moves:
`select count(*) from businesses where subscription_status='trial' and trial_ends_at <= now();`

## Apply (file has its own BEGIN/COMMIT)
1. Run `verify_post_apply.sql` on reebaplus-dev first (needs 0224 there).
2. `supabase db query --linked -f supabase/migrations/0231_no_trials.sql`
3. Record: `insert into supabase_migrations.schema_migrations(version, name) values ('0231','no_trials');`
4. `supabase db query --linked -f docs/rollouts/0231-no-trials/verify_post_apply.sql`:
   passing = no error (it runs in BEGIN … ROLLBACK and keeps nothing).

Re-running the migration is safe (idempotent).

## Rollback
`rollback.sql` restores the `'trial'` default and the 0224 trigger body and
deletes the schema_migrations row. Businesses moved to Free stay on Free.

## POS parity
Status rule change: the supervisor opens a `pos-parity` issue in reebaplus-web
(new sign-ups are Free; the console's default-trial-days setting no longer
applies to sign-ups, only to an explicit trial the operator sets).
