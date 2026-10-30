# Apply plan: 0234 plan switching without double billing

Status: NOT APPLIED. Issue #589 (PRD #584 slice 5).
Migration: `supabase/migrations/0234_play_plan_switching.sql`.
Depends on 0224 + 0225 + 0232. Ships with an app change and a
`play-billing-verify` Edge Function change.

## What it does
* Adds `linked_purchase_token`, `replaced_by_token`, `replaced_at` to
  `play_subscription_purchases` (+ a partial index on the linked token).
* Re-issues `apply_play_purchase` with the **same signature** (no overload) and
  the same grants. The only change from 0232: on a lapse, a **replaced** row
  no longer counts as "another entitled purchase". 0232's manual-grant rule and
  `play_applied_entitlements` stamp are unchanged.
* The Edge Function (same PR) marks the old token replaced when a new purchase
  carries `linkedPurchaseToken`, never applies a replaced token again, holds an
  early non-revoke EXPIRED (old token lapsing before the new one is verified),
  binds an unknown RTDN token through a known linked token, and treats the
  owned line item of a deferred switch as the current plan until renewal.

## Order (columns must exist before the new function writes them)
1. Run `verify_post_apply.sql` against reebaplus-dev with 0224/0225/0232/0234
   applied inside one aborted transaction (dev lacks 0224+).
2. `supabase db query --linked -f supabase/migrations/0234_play_plan_switching.sql`
3. Record: `insert into supabase_migrations.schema_migrations(version, name) values ('0234','play_plan_switching');`
4. `supabase db query --linked -f docs/rollouts/0234-plan-switching/verify_post_apply.sql`:
   passing = no error (BEGIN … ROLLBACK, keeps nothing).
5. Redeploy the function: `supabase functions deploy play-billing-verify --no-verify-jwt`
   (`--no-verify-jwt` is required: Pub/Sub pushes carry no Supabase JWT).
6. Ship the app build (plan switching uses Play replacement).

Re-running the migration is safe (idempotent).

## Rollback
`rollback.sql` restores the 0232 body and deletes the schema_migrations row. It
keeps the columns (the new function writes them); drop them with the commented
statements only after redeploying the pre-#589 function.

## POS parity
`play_subscription_purchases` gains columns and the lapse rule changes: the
supervisor opens a `pos-parity` issue in reebaplus-web. The console needs no
change unless it shows Play purchase rows (then hide replaced ones).
