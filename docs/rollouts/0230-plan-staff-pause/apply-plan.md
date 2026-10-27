# Apply plan: 0230 enforce_plan_staff_pause

Status: NOT APPLIED. Needs owner confirmation. Issue:
https://github.com/okworemmanuelc/reebaplus-web/issues/90 (follow-up to 0224).

Migration: `supabase/migrations/0230_enforce_plan_staff_pause.sql`. Adds
`public.enforce_plan_staff_pause(p_business_id uuid) returns uuid[]` (SECURITY
DEFINER, execute only for `service_role`). Not scheduled, not called by the app.

## Number
The brief said 0229, but `0229_shopper_account_deleted_email.sql` is already on
origin/main (and 0225 is the Play Billing PR), so this is **0230**. Re-check
`ls supabase/migrations` and rename before applying if anything else landed.

## Behaviour
* Active members > effective plan `max_staff` -> extras set to `suspended`
  (`last_updated_at = now()` so devices pull it).
* Kept: owner (role slug `ceo`) first, then longest-serving
  (`created_at`, `id`) - same order as the app's `pausedStaffIds()`.
* The owner is never suspended (multiple owners are all kept, even over cap).
* `removed` / already `suspended` rows untouched. Unlimited plan -> returns `{}`.
* Returns the suspended `user_id`s (ordered), so they can be re-activated.
* Interaction with `trg_user_businesses_plan_limit` (0224): suspending passes the
  trigger (it only checks rows becoming `active`). RE-ACTIVATION IS LIMIT-CHECKED:
  `update ... set status='active'` raises `plan_limit_staff` while
  active >= max_staff. Re-activate after the upgrade lands (effective plan raised),
  or only up to the cap.

## Before applying
1. Confirm the number is still free; other pending migrations: 0225 (billing).
2. Run on reebaplus-dev first; run `verify_post_apply.sql` (rollback block).
3. Decide the caller (cron / billing webhook / console). Out of scope here.

## Apply (atomic: file has its own BEGIN/COMMIT)
`supabase db query --linked -f supabase/migrations/0230_enforce_plan_staff_pause.sql`
then record: `insert into supabase_migrations.schema_migrations(version, name) values ('0230','enforce_plan_staff_pause');`

## Not done
Nothing calls the function yet; no data changes on apply. Rollback: `rollback_pre_apply.sql`.
