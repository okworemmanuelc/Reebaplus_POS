-- tool/wipe_cloud.sql
--
-- Full cloud wipe. Run AFTER migration 0041_remove_staff_management.sql
-- has deployed (this script assumes business_members and invites tables
-- are already gone — it won't try to truncate them).
--
-- What this does:
--   1. TRUNCATEs every tenant table (CASCADE handles FKs).
--   2. Resets sync cursors / system config.
--   3. Drops every row from auth.users — every previously-issued JWT is
--      now invalid; the next app launch will go through email + OTP.
--
-- What this does NOT do:
--   * Drop schema. The schema is intact (per migration 0041).
--   * Touch auth.identities / auth.sessions explicitly — auth.users
--     CASCADE-deletes them.
--   * Reset migration history (`supabase_migrations.schema_migrations`).
--     Leave that intact so migrations track their applied state.
--
-- HOW TO RUN:
--   psql "$SUPABASE_DB_URL" -f tool/wipe_cloud.sql
-- or paste into the Supabase SQL editor.
--
-- REQUIRES: privilege to TRUNCATE all tables and DELETE from auth.users.
-- The service-role connection has this; the anon key does not.
--
-- IRREVERSIBLE. After running, every account must re-sign up from scratch.

BEGIN;

-- ─── 1. Truncate all tenant tables ────────────────────────────────────────
-- One TRUNCATE with CASCADE handles all FKs in a single statement and is
-- much faster than per-table DELETEs. Tables that don't exist (e.g.
-- because 0041 already dropped them) must be skipped, so we wrap in a
-- single dynamic block.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    -- POS / inventory / orders
    'public.purchase_items',
    'public.purchases',
    'public.order_items',
    'public.orders',
    'public.stock_transactions',
    'public.stock_adjustments',
    'public.stock_transfers',
    'public.inventory',
    'public.price_lists',
    'public.products',
    'public.categories',
    'public.suppliers',
    'public.manufacturers',
    'public.crate_groups',
    'public.crate_ledger',
    'public.customer_crate_balances',
    'public.manufacturer_crate_balances',
    'public.pending_crate_returns',
    'public.saved_carts',
    -- Customers / wallets
    'public.wallet_transactions',
    'public.customer_wallets',
    'public.customers',
    -- Deliveries / drivers
    'public.delivery_receipts',
    'public.drivers',
    -- Payments / expenses
    'public.payment_transactions',
    'public.expenses',
    'public.expense_categories',
    -- Activity / notifications / settings
    'public.activity_logs',
    'public.notifications',
    'public.settings',
    -- Warehouses
    'public.warehouses',
    -- Identity (must come after everything that FKs to it)
    'public.sessions',
    'public.users',
    'public.profiles',
    'public.businesses',
    -- Sync queue (cloud-side, if any)
    'public.sync_queue'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF to_regclass(t) IS NOT NULL THEN
      EXECUTE format('TRUNCATE TABLE %s CASCADE', t);
      RAISE NOTICE 'truncated %', t;
    ELSE
      RAISE NOTICE 'skipped (does not exist): %', t;
    END IF;
  END LOOP;
END $$;

-- ─── 2. Drop every Supabase Auth user ─────────────────────────────────────
-- This also cascades through auth.identities, auth.sessions,
-- auth.refresh_tokens, auth.mfa_factors, etc. Every previously-issued
-- access token / refresh token becomes invalid immediately.
DELETE FROM auth.users;

-- ─── 3. Verification ──────────────────────────────────────────────────────
DO $$
DECLARE
  n_users          int;
  n_profiles       int;
  n_businesses     int;
  n_auth_users     int;
  n_business_mems  int;
  n_invites        int;
BEGIN
  SELECT count(*) INTO n_users        FROM public.users;
  SELECT count(*) INTO n_profiles     FROM public.profiles;
  SELECT count(*) INTO n_businesses   FROM public.businesses;
  SELECT count(*) INTO n_auth_users   FROM auth.users;
  SELECT count(*) INTO n_business_mems FROM (
    SELECT 1 WHERE to_regclass('public.business_members') IS NOT NULL
  ) s;
  SELECT count(*) INTO n_invites      FROM (
    SELECT 1 WHERE to_regclass('public.invites') IS NOT NULL
  ) s;

  RAISE NOTICE 'post-wipe counts: users=% profiles=% businesses=% auth.users=%',
    n_users, n_profiles, n_businesses, n_auth_users;
  RAISE NOTICE 'staff tables still present: business_members=% invites=%',
    n_business_mems, n_invites;
END $$;

COMMIT;

-- After this commits:
--   * The Flutter emulator must be wiped too:
--       adb shell pm clear com.reebaplus.reebaplus_pos
--   * First app launch will start at EmailEntryScreen.
