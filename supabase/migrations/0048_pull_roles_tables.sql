-- =============================================================================
-- 0048_pull_roles_tables.sql — Reebaplus POS pivot (roles in the PULL path).
--
-- The 5 role/membership tenant tables (roles, role_permissions, role_settings,
-- user_businesses, user_stores) were added cloud-side in 0042 and are seeded
-- per business by complete_onboarding (0044). They already PUSH from the
-- client (they're in `_syncedTenantTables`), but pos_pull_snapshot never
-- listed them, so a fresh device's first pull never received them — the local
-- role tables stayed empty until a write happened to round-trip.
--
-- This migration adds the 5 tables to pos_pull_snapshot's v_tenant_tables
-- array. The generic FOREACH ... WHERE t.business_id = $1 loop already handles
-- any tenant table with a business_id + last_updated_at column, so no other
-- change is needed. (`permissions` is global static config, identical on every
-- device and seeded by migration on both sides — intentionally NOT pulled.
-- `invite_codes` is deferred to the Staff Sign Up step.)
--
-- Sole change vs the 0047 body: 5 entries appended to v_tenant_tables.
--
-- DEPLOY ORDERING — READ BEFORE RUNNING:
--   Deploy AFTER 0047 (this re-creates pos_pull_snapshot from the 0047 body,
--   which already carries the 0045/0046 renames — store_id, shipments,
--   crate_size_groups). 0047 + 0048 deploy together, right after the client
--   carrying the §5 onboarding work ships. There is no client/cloud contract
--   risk in the other direction: a client that pulls these tables before 0048
--   deploys simply gets empty slices (the old snapshot omits them), exactly
--   the pre-0048 behaviour.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- pos_pull_snapshot — body from 0047 §4. Sole change: 5 role/membership
-- tables appended to v_tenant_tables.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pos_pull_snapshot(
  p_business_id uuid,
  p_since       timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_caller_business uuid;
  v_result          jsonb := '{}'::jsonb;
  v_table           text;
  v_rows            jsonb;
  v_query           text;
  v_tenant_tables   text[] := ARRAY[
    'profiles','users','stores','manufacturers','crate_size_groups',
    'categories','products','inventory','customers','suppliers',
    'orders','order_items','shipments','purchase_items',
    'expenses','expense_categories',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'notifications','stock_transactions',
    'customer_wallets','wallet_transactions',
    'saved_carts','pending_crate_returns',
    'manufacturer_crate_balances','crate_ledger',
    'price_lists','payment_transactions','sessions','settings',
    -- 0048: roles + membership (master plan §2.4). permissions is global
    -- (seeded by migration on both sides); invite_codes deferred to Staff
    -- Sign Up.
    'roles','role_permissions','role_settings','user_businesses','user_stores'
  ];
BEGIN
  v_caller_business := public.business_id();
  IF v_caller_business IS NULL THEN
    RAISE EXCEPTION 'no_business_for_caller'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_caller_business <> p_business_id THEN
    RAISE EXCEPTION 'tenant_mismatch'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
    INTO v_rows
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND (p_since IS NULL OR b.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('businesses', v_rows);

  FOREACH v_table IN ARRAY v_tenant_tables LOOP
    v_query := format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)
         FROM public.%I t
         WHERE t.business_id = $1
           AND ($2::timestamptz IS NULL OR t.last_updated_at > $2)',
      v_table
    );
    EXECUTE v_query INTO v_rows USING p_business_id, p_since;
    v_result := v_result || jsonb_build_object(v_table, v_rows);
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
    INTO v_rows
    FROM public.system_config s
    WHERE (p_since IS NULL OR s.last_updated_at > p_since);
  v_result := v_result || jsonb_build_object('system_config', v_rows);

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz) FROM public;
GRANT EXECUTE ON FUNCTION public.pos_pull_snapshot(uuid, timestamptz)
  TO authenticated;

COMMIT;
