# Apply plan: 0235 failed-renewal billing issue (grace / hold)

Status: NOT APPLIED. Issue #591 (PRD #584 slice 7).
Migration: `supabase/migrations/0235_business_billing_issue.sql`.
Depends on 0224 + 0225 + 0232 + **0234** (all on prod since 2026-10-31). Does NOT
depend on the gated 0231.

## Gated companion: 0236
`0236_insert_guard_billing_issue.sql` adds `billing_issue := NULL` to the
INSERT guard. It re-issues the 0231 body, so it ships **with 0231** (after phones
run the #586 never-lock release), never alone.

## What it does
* `businesses.billing_issue text NULL CHECK IN ('grace','hold')`.
  Cloud-authoritative / app-read-only: the 0224 UPDATE guard resets it and (from
  0236) the INSERT guard nulls it for authenticated/anon; not on the app push whitelist.
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
2. From a temp worktree with the gated files removed (0193, 0231, 0236):
   `supabase db push --include-all` (applies 0235 only).
3. (nothing to record by hand: db push records 0235)
4. `supabase db query --linked -f docs/rollouts/0235-billing-issue/verify_post_apply.sql`
   (BEGIN … ROLLBACK, keeps nothing; passing = no error).
5. `supabase functions deploy send-push --no-verify-jwt`
   (until then the `billing_issue` push is skipped as not_routable: harmless).
6. `supabase functions deploy play-billing-verify --no-verify-jwt`
   (response gains `billing_issue`; no behaviour change needed for the column).
7. Ship the app (Drift v96) any time after step 2; older apps ignore the column.

Owner, in Play Console: 7-day grace period, then account hold.

## Rollback
`rollback.sql` restores the 0234 / 0224 bodies (INSERT guard untouched), drops the trigger,
helpers and column, and deletes the schema_migrations row. Tested on dev.

## POS parity
New businesses column: the supervisor opens a `pos-parity` issue in reebaplus-web
(the console's manual activation already clears it via the guard).
