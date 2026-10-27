# Apply plan: 0224 subscription tiers

Status: NOT APPLIED. Needs owner confirmation. Issue:
https://github.com/okworemmanuelc/reebaplus-web/issues/90 (slice A).

Migration: `supabase/migrations/0224_subscription_tiers.sql`. Replaces the
`local|international` plan CHECK with `free|basic|premium`, adds
`businesses.billing_cycle`, adds `business_plan_limits()` / `business_effective_plan()`,
seeds new sign-ups as `premium` + trial, and adds three BEFORE triggers
(`stores`, `invite_codes`, `user_businesses`) that raise `plan_limit_stores` /
`plan_limit_staff` / `plan_limit_warehouse` (SQLSTATE P0001).

## Before applying
1. Migration list tops at 0223; no other 0224 in flight.
2. NOT yet executed against any database (no local Postgres in the authoring
   environment). Run it first on reebaplus-dev, then run the integration checks:
   - free business: second `stores` insert -> `plan_limit_stores`; `kind='van'` -> `plan_limit_warehouse`
   - basic: 6th active `user_businesses` / invite -> `plan_limit_staff`
   - premium trial: all succeed; expired trial: effective plan `free`
   - re-upsert of an existing over-limit row succeeds (never blocked)
3. Console repo: `console_set_subscription` and the console plan editor must accept
   `free|basic|premium` + `billing_cycle` BEFORE or together with this apply, or
   console writes of `local|international` will hit the new CHECK and fail.
4. Capture current live defs of `set_business_trial_end` and
   `enforce_subscription_immutable` and confirm they equal 0131 / 0101
   (the rollback restores those).

## Apply (atomic: file has its own BEGIN/COMMIT)
`supabase db query --linked -f supabase/migrations/0224_subscription_tiers.sql`
then record: `insert into supabase_migrations.schema_migrations(version, name) values ('0224','subscription_tiers');`

## Behaviour on rollout (14 trial businesses + 1 `local`)
* Trial rows -> `premium` (effective plan stays premium until `trial_ends_at`).
* The `local` business -> `basic`. If it is over Basic limits it keeps working;
  only NEW stores/staff are refused.
* No data is deleted. Selling is never blocked.

## Client compatibility
Old app builds do not know the new plan names; they only read
`subscription_status`/`trial_ends_at` for the lock gate, so they keep working.
Old builds adding a store/invite over the limit get a raw P0001 sync error
(`plan_limit_*`) until updated.

## Not done in this slice
* Server-side pausing of over-limit staff (`user_businesses.status='suspended'`):
  done client-side only (see PR). A scheduled job could suspend extras on downgrade.
* Extra stores read-only: client-side only; no RLS-level read-only enforcement.
* Google Play Billing / RTDN writes to `plan` + `billing_cycle` (separate slice).

## Verify: `verify_post_apply.sql`.  Rollback: `rollback_pre_apply.sql`.
