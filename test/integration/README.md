# Tier-2 integration tests

Hits real dev Supabase. Verifies the v2 domain RPCs end-to-end:
round-trip (response ↔ cloud row), idempotent replay, and atomicity
(tenant guard + validation).

Files live under `test/integration/rpcs/`. The harness skips itself
automatically when env vars are absent, so leaving these files in the
default `flutter test` run does no harm.

## One-time setup (≈10 minutes)

These tests need a dedicated test user + business on your **dev**
Supabase project. Don't point them at production.

1. **Create the auth user.** In Supabase Studio → Authentication → Users
   → Add user → email like `test+sync@example.com`. Copy the new user's
   id (the `auth.users.id`) — you'll use it as `auth.uid()` in the next
   step.

2. **Bootstrap business + profile + staff user.** In the SQL editor,
   signed in as `service_role`:

   ```sql
   -- one-time test fixture
   DO $$
   DECLARE
     v_auth_uid     uuid := '<paste auth.users.id from step 1>';
     v_business_id  uuid := gen_random_uuid();
     v_user_id      uuid := gen_random_uuid();
   BEGIN
     INSERT INTO public.businesses (id, owner_id, onboarding_complete, name)
       VALUES (v_business_id, v_auth_uid, true, 'Sync Tests');

     INSERT INTO public.profiles (id, business_id, name, role, role_tier)
       VALUES (v_auth_uid, v_business_id, 'Test User', 'ceo', 5);

     INSERT INTO public.users (id, business_id, auth_user_id, name, role, pin)
       VALUES (v_user_id, v_business_id, v_auth_uid, 'Test User', 'admin', '0000');

     RAISE NOTICE 'TEST_BUSINESS_ID=%', v_business_id;
     RAISE NOTICE 'TEST_USER_ID=%', v_user_id;
   END $$;
   ```

   Copy the two ids printed in the NOTICE messages.

3. **Sign in once and capture the refresh token.** Easiest path: a
   one-line dart script run with `dart run`, or just paste this snippet
   into a scratch test that prints the token:

   ```dart
   final c = SupabaseClient('<dev url>', '<dev anon key>');
   await c.auth.signInWithOtp(email: 'test+sync@example.com');
   // …complete the magic link in the inbox, then in a fresh session:
   final res = await c.auth.verifyOTP(
     email: 'test+sync@example.com',
     token: '<the OTP code>',
     type: OtpType.email,
   );
   print('TEST_USER_REFRESH_TOKEN=${res.session?.refreshToken}');
   ```

   Refresh tokens last ~30 days by default. When tests start failing on
   `setSession`, repeat this step and update the env var.

4. **Persist the env vars.** Put them in a `direnv` `.envrc` (or any
   shell-startup file) so `flutter test` sees them:

   ```sh
   export TEST_SUPABASE_URL='https://<your-project>.supabase.co'
   export TEST_SUPABASE_ANON_KEY='eyJ...'
   export TEST_SUPABASE_SERVICE_ROLE_KEY='eyJ...'
   export TEST_USER_REFRESH_TOKEN='<from step 3>'
   export TEST_BUSINESS_ID='<from step 2>'
   export TEST_USER_ID='<from step 2>'
   ```

   `.envrc` is gitignored — never commit secrets.

## Running

### Private Storage listing (#467)

`rpcs/private_storage_listing_test.dart` requires migration 0191 and the business
schema on the approved `reebaplus-dev` project. Set `TEST_SUPABASE_URL`,
`TEST_SUPABASE_ANON_KEY`, `TEST_SUPABASE_SERVICE_ROLE_KEY`, and
`TEST_STORAGE_ISOLATION_ALLOW_WRITES=1`. No existing user refresh token is needed.
The suite creates and removes its own users, business and image objects, checks
listing denial against populated buckets, and verifies owner replacements and
anonymous public image retrieval. It refuses fixture writes to any other URL.

```sh
flutter test test/integration/rpcs/private_storage_listing_test.dart
```


```sh
# Tier 1 only (no env vars needed) — runs in <5s, every PR:
flutter test test/sync/dispatch/

# Tier 2 — needs the env vars above; ~10–20s including network:
flutter test test/integration/

# Both tiers:
flutter test
```

The Tier-2 files are tagged `@Tags(['integration'])` so a CI workflow
can opt them out with `--exclude-tags integration` if needed.

## Known limitations

- **Manual refresh-token seeding.** Step 3 is interactive. Until
  Supabase exposes a way to mint a session from `auth.admin` in the
  Dart SDK, devs re-run it whenever the token expires. Tracked in the
  redesign plan §9.5.
- **Tests share one test business.** Each test creates rows scoped by
  unique uuids and cleans up in `tearDown`, so parallelism within a
  single run is safe. Two devs running the suite against the same
  business at the same time will see flaky cleanup races — coordinate
  or each dev seeds their own test business.
- **No nightly CI yet.** Tier 2 is dev-machine-only. A scheduled
  workflow against a dedicated test project is the obvious next step
  but isn't part of this slice.

## Adding tests for new RPCs (batches 3–10)

Per the redesign plan §9.8, every batch ships with:

- one tier-1 file under `test/sync/dispatch/<dao>_dispatch_test.dart`
- one tier-2 file under `test/integration/rpcs/<rpc>_test.dart`

Use the existing files as templates. For `pos_record_sale_v2` and
`pos_cancel_order` specifically, the tier-2 file MUST include a
mid-flight rollback test — `pos_record_sale_v2` exercises insufficient
stock partway through a multi-item sale; `pos_cancel_order` exercises a
partial-state cancel where some items have already been refunded.

## Nigeria area reference (#471)

`flutter test test/integration/nigerian_areas_test.dart` needs only
`TEST_SUPABASE_URL` and `TEST_SUPABASE_ANON_KEY`. Deploy `0189_nigerian_areas.sql`
on that test backend first. This test is read-only, needs no tenant fixture or
refresh token, and compares all 774 pairs through the public anonymous role
with explicit pagination. A missing table or partial seed is a failure when
configured; absent environment variables are a visible skip.
