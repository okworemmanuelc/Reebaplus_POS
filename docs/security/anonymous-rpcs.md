# Signed-out RPC grants (#468)

Read-only production catalogue audit2026-10-23 confirmed the nine functions in
the issue.0194 removes signed-out execution from five and explicitly preserves
authenticated onboarding, sales and console access. Trigger function execution
is server-only. No function signature, tenant table, money calculation or RLS
policy changes.
The unused email-probe helper is service-role-only, including for signed-in users.
The 2026-10-24 caller search covered POS lib/, supabase/functions/, every web
source file and console_access.sql; remaining occurrences are definitions/grants
and documentation, not calls. A read-only production pg_proc.prosrc and
pg_policies search found zero dependent function bodies or policies.

Remaining anonymous functions, left unchanged by this migration:

| Function | Reason |
| --- | --- |
| accept_invite_preview(text) | Dropped in 0220 (#506) |
| accept_invite_preview_by_code(text) | Dropped in 0220 (#506) |
| lookup_invite_code(text) | Mobile staff signup validates a code before OTP |
| console_get_trial_days() | Scalar trial-duration bootstrap setting |
| storefront_feed / storefront_search / storefront_store / storefront_store_products | #425 (0202): signed-out Browse. Public listing fields only; every hide rule server-side; helpers `_storefront_*` are server-only |
| storefront_product_photos(uuid, uuid) | #474 (0204): one listed product's public photo URLs in order (cover first); same hide rules via `_storefront_stores`; a gallery photo only once its Storage object exists |

The legacy first two previews have a pre-existing defect: their functions refer
to `public.invites` and `public.warehouses`, both absent in the live catalogue and
the committed development snapshot. A baseline call returns42P01. Their ACLs are
preserved, but their functionality is not claimed tested or repaired by0194.
Current mobile signup uses lookup_invite_code and redeem_invite_code instead.
Owner review moved the cleanup follow-up forward:
[POS bug #506](https://github.com/okworemmanuelc/Reebaplus_POS/issues/506) tracks
confirming there are no callers and then dropping both exact legacy signatures.
Only migration0194's comments changed for that follow-up; its body is unchanged.

## Console rollout dependency

The current web AdminLogin calls is_console_admin_email before requesting OTP.
Deploy companion web branch fix/468-console-login-without-email-probe first,
then apply0194. It requests OTP with shouldCreateUser:false and checks active
console_admins membership only after OTP verification. Non-admin authenticated
identities are still signed out and refused. See web parity issue136:
https://github.com/okworemmanuelc/reebaplus-web/issues/136.

Production migration remains owner-deployed. Development has no real console
users; its rollout can be tested independently.

## Development verification

The development schema snapshot omits ACLs. Before testing, existing definer
functions received the effective anon/authenticated/service_role permissions
captured from read-only production catalogue metadata. PUBLIC execute was
materialized as explicit grants to those roles; no function bodies or tenant
records were copied.0188 was reapplied on top so its new restrictions remain.
New0192/0193 deletion behavior was left in place.

Fresh comparison on2026-10-24, immediately before0194: all nine function
signatures and all27 effective EXECUTE checks (anon, authenticated, service_role)
matched production. Each of the nine was executable by all three roles before
0194. The valid prior restoration file is dev-function-role-baseline.sql;
the obsolete live-function-acl-baseline.sql was never executed. No further
baseline correction was required for this red-to-green run.

Run test/integration/rpcs/anonymous_rpc_grants_test.dart with TEST_SUPABASE_URL
exactly https://yngwzuinxhxhzdfagcbg.supabase.co and its anon key. No authenticated
session, service key or business fixtures are required. The four HTTP denial checks
failed on the baseline as expected. Trigger-returning functions are never exposed
in PostgREST's RPC schema cache, so the SQL companion anonymous_rpc_grants.sql
checks its execution boundary under SET LOCAL ROLE anon in a rollback transaction.
That baseline failed0A000 because it reached the trigger-function body; after the
fix it must fail at the permission boundary before entering the body.
Mobile invitation lookup and scalar trial
duration remain callable. The SQL audit lists all remaining anonymous definers;
production's pre-migration list has nine entries, expected post-migration four.

Companion web validation: three React login tests, production build and ESLint
on both changed files pass. POS analyzer reports zero issues.

After integrating main c019ea4f, the completed full Flutter suite passed
5384 tests with299 skipped and zero failures (7m54s). Six dedicated development
HTTP checks and both rollback SQL probes were rerun successfully on that
integrated branch. The earlier interrupted suite is not counted as a pass.

After0194 on development: six HTTP tests pass, including permission denials for
all four regular RPC targets and successful invite lookup/trial-duration calls.
The trigger rollback SQL passes as well. A second rollback SQL test creates a
fresh auth identity, successfully calls complete_onboarding, creates its store,
and records a100-kobo member Quick Sale through pos_record_sale_v2. It also proves
a signed-in non-admin cannot call is_console_admin_email for another email.
All auth, business and order fixtures roll back. The dev reference permissions
catalogue was seeded from14 committed permission INSERT statements first;
no live tenant rows were copied.

Production is untouched. Merge/deploy the web login fix and manually check it
before owner approval of production0194. Numbers0188–0193 belong to unmerged
branches; if0194 reaches production first, subsequent migration deployment must
include those earlier versions deliberately (`supabase db push --include-all`)
only after reviewing every migration's release gate. In particular0193 must wait
for adoption of the updated business deletion client. Apply0194 individually at
its approved production step; never let a generic push deploy0193 implicitly.
Do not renumber other branches' migration files.
