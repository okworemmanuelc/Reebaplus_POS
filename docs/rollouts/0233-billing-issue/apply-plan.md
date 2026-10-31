# Apply plan: 0233 failed-renewal billing issue (grace / hold)

Status: NOT APPLIED. Issue #591 (PRD #584 slice 7).
Migration: `supabase/migrations/0233_business_billing_issue.sql`.
Depends on 0224 + 0225 + 0231 + 0232 + **0234** (all must be on prod first).

## Numbering warning
The number 0233 was reserved, but 0234 already re-issues `apply_play_purchase`.
0233 MUST run **after** 0234. If 0234 is ever (re-)run after 0233, re-run 0233,
or `billing_issue` stops being written. `supabase db push` will see 0233 as
"before the last remote migration"; apply it by hand as below (no db push).

## What it does
* `businesses.billing_issue text NULL CHECK IN ('grace','hold')`.
  Cloud-authoritative / app-read-only: the 0224 UPDATE guard resets it and the
  0231 INSERT guard nulls it for authenticated/anon; not on the app push whitelist.
* `apply_play_purchase` (same signature, same grants) writes it:
  IN_GRACE_PERIOD -> `grace` (plan kept); ON_HOLD that downgrades -> `hold`;
  ACTIVE / CANCELED / EXPIRED / PAUSED -> NULL; a lapse kept by a manual grant or
  another entitled purchase -> NULL; PENDING -> unchanged. The Play stamp is now
  written before the businesses UPDATE.
* Manual admin activation (service_role sets `active` with a plan / end date
  that is not the Play stamp) clears it, inside `enforce_subscription_immutable`.
* `trg_send_push_billing_grace`: on a change INTO `grace` only, one pg_net POST
  to `send-push` (type `billing_issue`, `user_ids` = the owner's users.id).
  Staff phones get nothing. Never blocks the update.

## Deploy order
1. Run `verify_post_apply.sql` on reebaplus-dev (dev lacks 0224+: apply them
   in one aborted transaction, as done for this PR).
2. `supabase db query --linked -f supabase/migrations/0233_business_billing_issue.sql`
3. Record: `insert into supabase_migrations.schema_migrations(version, name) values ('0233','business_billing_issue');`
4. `supabase db query --linked -f docs/rollouts/0233-billing-issue/verify_post_apply.sql`
   (BEGIN … ROLLBACK, keeps nothing; passing = no error).
5. `supabase functions deploy send-push --no-verify-jwt`
   (until then the `billing_issue` push is skipped as not_routable: harmless).
6. `supabase functions deploy play-billing-verify --no-verify-jwt`
   (response gains `billing_issue`; no behaviour change needed for the column).
7. Ship the app (Drift v96) any time after step 2; older apps ignore the column.

Owner, in Play Console: 7-day grace period, then account hold.

## Rollback
`rollback.sql` restores the 0234 / 0224 / 0231 bodies, drops the trigger,
helpers and column, and deletes the schema_migrations row. Tested on dev.

## POS parity
New businesses column: the supervisor opens a `pos-parity` issue in reebaplus-web
(the console's manual activation already clears it via the guard).
