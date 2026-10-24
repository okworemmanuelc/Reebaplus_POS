-- 0197_businesses_sells_one_price.sql
--
-- #493 — "We sell at one price" (owner decision: option A).
--
-- Cloud twin of Drift schemaVersion 86
-- (lib/core/database/app_database.dart, the `from < 86` upgrade step).
--
-- WHAT THIS CHANGES
--
--   businesses gains ONE column, sells_one_price boolean NOT NULL DEFAULT
--   false. Every existing shop is OFF, so nothing changes for anyone until the
--   owner turns it on (CEO Settings -> Business Info). At CEO sign-up the app
--   suggests ON for a Restaurant only and writes it with a follow-up update of
--   the new business row (complete_onboarding is NOT changed — no new param, so
--   no overload risk).
--
-- THE TILL RULE (money). When true the app hides every wholesale price box and
-- the till always charges the Retail price (order_items.price_tier =
-- 'retailer'), whatever the customer's own tier. Saved
-- products.wholesaler_price_kobo values are never overwritten, so turning the
-- setting off brings them all back. No cloud RPC picks a price by tier (the
-- client sends line prices), so no function changes here. The web console must
-- follow the same rule (reebaplus-web#142).
--
-- RLS is untouched: the businesses policies cover every column. The column is
-- on the app's businesses push whitelist (sync_registry.dart pushColumns).
--
-- DEPLOY ORDERING: deploy this BEFORE shipping a v86 client. A v86 client
-- pushes sells_one_price on every businesses upsert; against a table without
-- it the push is rejected and jams that device's outbox until this lands. The
-- reverse is safe: an older client never writes the column, and the pull
-- defaults a missing value to false.

BEGIN;

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS sells_one_price boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.businesses.sells_one_price IS
  '#493: "We sell at one price". When true the till always charges the retail '
  'price and wholesale boxes are hidden; saved wholesale prices are kept. '
  'Owner setting, default false.';

COMMIT;
