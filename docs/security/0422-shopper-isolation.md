# Shopper isolation groundwork — #422

Status: implementation prepared; owner approved the architecture rules in chat
on 2026-10-23. Live verification and the tombstone decision remain outstanding. Parent #421 is still held for all later slices.

## Evidence (read-only catalogue audit, 2026-10-23)

The connected Supabase migration history ends at 0186. There are 69 public
tables with a `business_id` column. All public tables have RLS enabled, but
RLS being enabled is not sufficient proof of isolation.

- `current_user_business_ids()` reads `profiles.business_id`, rather than
  independently checking `user_businesses`. `business_id()` uses the same
  profile pointer. The PRD's assumption that lack of membership alone denies
  all tenant access therefore needs qualification.
- `profiles_self_insert` and `profiles_self_update` check only
  `id = auth.uid()`. A membership-less login can otherwise supply another
  business's ID in its own profile and become authorized by the pointer-based
  policies. Migration 0188 binds direct profile writes to a legitimate existing
  `users` link or an owned business; trusted onboarding/invite definer RPCs
  retain their existing atomic bootstrap path.
- `_checkout_draw_fifo`, `_checkout_insert_lines`,
  `_checkout_mint_order_number`, `_customer_wallet_balance` and
  `seed_default_roles_for_business` are definer functions granted to
  `authenticated` without an entry membership guard. They expose tenant
  aggregates or mutation paths outside the guarded entry RPCs. Migration 0188
  revokes direct client execution while preserving owner/service execution.
  Searches of mobile `lib/` and web `web-pos/src/` found no direct client calls;
  nested SQL calls remain valid under the entry RPC's definer owner.
- The web schema baseline also defines `is_other_business_owner(email,
  exclude_business_id)`, an arbitrary email ownership probe callable by
  authenticated users. No current mobile/web application caller was found.
  Migration 0188 conditionally makes it server-only when installed; mobile-only
  schema installs do not contain that function. No web application code changes.

No customer rows, emails, stock quantities or money values were retrieved by
the audit. No remote schema or production data was changed.

## Deliberate exceptions and unresolved blockers

1. **Deletion tombstones conflict with literal zero-tenant-row access.** Migration
   0114 intentionally grants every authenticated login SELECT on
   `deleted_businesses`, including business ID, name and deletion time. A former
   member has already lost membership when their offline phone needs that row
   to trigger a wipe. Silently switching the policy to active-member-only would
   break that safety mechanism. Owner decision needed: explicitly sanction the
   minimal deletion projection, or design an authenticated former-device lookup
   before withdrawing enumeration. This branch preserves the existing contract
   and excludes that table explicitly from the live-tenant zero-row assertion;
   it does not claim the PRD's literal zero-row criterion is met.
2. **#467 remains separate:** product-image and business-logo Storage listing
   policies expose object names. Keep public image display working while denying
   enumeration to non-members. This issue must land before Shopper launch.
3. **#468 remains separate:** audit and revoke unintended signed-out definer
   grants without breaking intentional invite/onboarding previews. The live
   catalogue still shows those grants. Do not blanket-revoke all public RPCs:
   browsing and some existing pre-auth flows intentionally need public access.
4. **Owner sign-off recorded (2026-10-23):** ADRs 0030 and 0031 and invariants
   #9 and #1/#4/#5/#8 now record the approved identity and Shopper boundary. This
   approval does not resolve the tombstone question or waive live verification.

## Verification

- `supabase/audits/0422_shopper_boundary.sql` is a read-only, repeatable inventory
  of tenant tables/policies and client-executable definer functions, including
  RPCs installed by the separate web repo. Review entity-ID-only functions as
  well as those with `p_business_id`.
- `test/integration/rpcs/shopper_isolation_test.dart` creates a real throwaway
  login and signs in with a password exclusively for testing (product sign-in
  remains email OTP). It proves the login has no linked business, discovers
  tenant tables from the service-role OpenAPI schema, checks signed-out and
  Shopper reads, attempts profile forgery, probes internal helpers, tests direct
  INSERT/UPDATE/DELETE denial, and exercises discovered business-ID RPCs. It
  treats malformed requests and missing endpoints as failures, not proof of
  authorization. Own-business profile insertion is a positive compatibility
  control. Fixtures use only new UUIDs and are removed in teardown.
- Live tests require a dedicated test backend and an explicit write opt-in.
  The existing shared dev/production backend was inspected read-only; migration
  deployment and fixture-writing live tests were not performed there.
- After applying 0188 in that test backend, run the new suite and existing
  `complete_onboarding_test.dart`, invite/onboarding flows, checkout and web
  golden-scenario tests. A parser check alone does not verify policy semantics.
- Recheck migration numbering before deployment: the web checkout handoff
  already uses 0187, so this branch allocates 0188. No 0187 placeholder is added.

## Completion

Local verification: `flutter analyze --no-pub` clean; full `flutter test
--no-pub --reporter expanded` finished with **5225 passed, 299 skipped, no
failures**. The six new live tests are skipped without dedicated credentials.
The migration and audit SQL pass a PostgreSQL parser check. No remote policy
semantics, onboarding compatibility or ACL change is claimed live-verified.

Do not close #422 or enable Shopper access until #467/#468 are resolved,
the tombstone decision is recorded, and live isolation
tests pass against the migrated schema. Screens, Shopper tables and storefront
RPCs remain owned by later slices.
