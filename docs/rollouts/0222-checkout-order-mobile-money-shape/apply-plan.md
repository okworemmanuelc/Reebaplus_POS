# Apply plan: 0222 checkout_order mobile money shape

Status: NOT APPLIED. Needs owner confirmation. Issues:
https://github.com/okworemmanuelc/reebaplus-web/issues/72 and
https://github.com/okworemmanuelc/reebaplus-web/issues/80

Migration: `supabase/migrations/0222_checkout_order_mobile_money_shape.sql`
(DROPs the 8-arg `checkout_order`, creates the 9-arg one with
`p_crate_deposit_by_manufacturer jsonb DEFAULT '{}'`, re-grants).

## Before applying
1. Golden suite green: `flutter test test/golden` (Dart arm) and the rpc arm
   (`flutter test test/integration/rpcs/checkout_order_golden_test.dart --tags integration`)
   against reebaplus-dev with 0222 applied there first. The rpc arm has NOT been run
   yet (no dev credentials in the authoring environment; the TEST_* values on that
   machine point at production, which must not be used).
2. Confirm live `checkout_order` still equals `rollback_pre_apply.sql` (re-capture:
   `select pg_get_functiondef('public.checkout_order'::regproc)`); migration list tops at 0221.

## Apply (one step, atomic: the file has its own BEGIN/COMMIT)
`supabase db query --linked -f supabase/migrations/0222_checkout_order_mobile_money_shape.sql`
then record: `insert into supabase_migrations.schema_migrations(version, name) values ('0222','checkout_order_mobile_money_shape');`

## Compatibility
* Old-shape callers (current web client, which omits the new key unless a deposit is
  collected) keep working through the default.
* The new web client (reebaplus-web PR) sends `p_crate_deposit_by_manufacturer` only when
  a deposit is collected. Until this is applied, a deposit checkout fails PGRST202, so
  the web UI gates deposit collection behind a capability flag (see that PR).
* Orders written before apply are not migrated.

## Verify: `verify_post_apply.sql`.  Rollback: `rollback_pre_apply.sql` (function swap only).
