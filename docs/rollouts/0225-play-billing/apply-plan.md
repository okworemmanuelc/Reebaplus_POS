# Apply plan: 0225 Google Play Billing

Status: LIVE on prod. 0224 and 0225 are applied and the `play-billing-verify`
Edge Function is deployed; 0232/0234 deployed 2026-10-31.
Issue: https://github.com/okworemmanuelc/reebaplus-web/issues/90 (slice B).

Migration: `supabase/migrations/0225_play_billing.sql`
Edge Function: `supabase/functions/play-billing-verify`
**Depends on 0224** (`businesses.subscription_plan` in free|basic|premium and
`businesses.billing_cycle`). Do not apply 0225 before 0224 is live; the
`apply_play_purchase()` function writes those values.

## 1. Owner setup (nothing below can be done by an agent)

### Play Console
1. App: package name = the Android `applicationId` (set as `PLAY_PACKAGE_NAME`).
   The app must have an uploaded build in at least an internal-testing track
   before subscriptions can be created.
2. Payments profile + merchant account set up (Monetize > Setup).
3. Create two subscriptions (Monetize with Play > Products > Subscriptions):
   * Product ID `reebaplus_basic`
   * Product ID `reebaplus_premium`
4. On each, create two **base plans** (auto-renewing), IDs exactly:
   * `monthly` (billing period 1 month)
   * `yearly` (billing period 1 year)
   Activate them. **Do not add a free-trial offer** (the 30-day Premium trial
   lives in our DB, no card).
5. Prices (set NGN for Nigeria, USD elsewhere via "Edit prices"; Google
   converts the rest):

   | Product | monthly | yearly |
   |---|---|---|
   | reebaplus_basic | NGN 1,500 / USD 2 | NGN 15,000 / USD 20 |
   | reebaplus_premium | NGN 6,500 / USD 5 | NGN 65,000 / USD 50 |
6. Add license-tester Gmail accounts (Setup > License testing) to test with
   test cards without being charged.

### Service account + API access
1. Google Cloud project linked to the Play Console (Setup > API access).
2. Create a service account in that project, create a JSON key.
3. In Play Console > Users and permissions, invite the service account email
   and grant, for this app: *View financial data* and *Manage orders and
   subscriptions*. (Permissions can take up to ~24h to propagate.)
4. Enable the "Google Play Android Developer API" in the Cloud project.

### Real-time developer notifications (Pub/Sub)
1. In the same Cloud project, create a Pub/Sub topic, e.g. `play-rtdn`.
2. Grant `google-play-developer-notifications@system.gserviceaccount.com` the
   **Pub/Sub Publisher** role on that topic.
3. Create a **push** subscription on the topic with endpoint:
   `https://<PROJECT_REF>.supabase.co/functions/v1/play-billing-verify?secret=<PLAY_RTDN_SECRET>`
   (ack deadline 30s; default retry policy is fine).
4. Play Console > Monetize > Monetization setup > Real-time developer
   notifications: enter the full topic name
   (`projects/<cloud-project>/topics/play-rtdn`), choose "Subscriptions only",
   and use "Send test notification" (the function acks it with 200/ignored).

### Edge Function secrets
```
supabase secrets set --project-ref <ref> \
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(cat service-account.json)" \
  PLAY_PACKAGE_NAME=<applicationId> \
  PLAY_RTDN_SECRET=<long random string, same as in the push URL>
```
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are provided
by the platform.

## 2. Apply (in this order, after 0224)
1. Confirm 0224 is applied and the migration list tops at 0224.
2. Apply the migration (own BEGIN/COMMIT):
   `supabase db query --linked -f supabase/migrations/0225_play_billing.sql`
   then record: `insert into supabase_migrations.schema_migrations(version, name) values ('0225','play_billing');`
3. Verify: `verify_post_apply.sql` (all checks read-only).
4. Deploy the function (JWT verification MUST be off: Pub/Sub sends no Supabase
   JWT; the app path validates the user JWT itself, the RTDN path the secret):
   `supabase functions deploy play-billing-verify --no-verify-jwt --project-ref <ref>`
5. Ship the app build (needs the Play Billing library; `in_app_purchase` adds
   the `com.android.vending.BILLING` permission automatically). Test via an
   internal-testing track with a license tester.

## 3. Behaviour summary
* App purchase: app calls the function with the user JWT; function checks
  `businesses.owner_id = caller`, gets the purchase from
  `purchases.subscriptionsv2.get`, rejects a token bound to another business
  or whose obfuscated account id is not this business, acknowledges (required
  within 3 days or Google refunds), upserts `play_subscription_purchases`, and
  calls `apply_play_purchase`.
* RTDN: function re-fetches the purchase (Google is authoritative), updates
  the row and the business. Unknown tokens are acked and ignored (the app's
  verify call is the only way a token gets bound to a business).
* Entitled states: ACTIVE, IN_GRACE_PERIOD, CANCELED until expiry. EXPIRED /
  ON_HOLD / PAUSED / revoked set `free` + status `inactive` unless another
  entitled purchase exists for the business.

## Rollback
`rollback.sql`: drops the function and table. Then
`supabase functions delete play-billing-verify`, delete the
schema_migrations row, and clear the RTDN topic in Play Console. Businesses
already moved to a paid plan keep their `businesses` values (adjust from the
console if needed).
