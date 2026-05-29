-- =============================================================================
-- 0053_pull_invite_codes.sql — Reebaplus POS (invite_codes in the PULL path).
--
-- invite_codes was added cloud-side in 0042 and already PUSHes from the client
-- (it's in `_syncedTenantTables`), but pos_pull_snapshot never listed it
-- (0048 deliberately deferred it — the only then-known consumer was Staff Sign
-- Up redemption, which uses the lookup_invite_code SECURITY-DEFINER RPC and
-- doesn't need local rows). The Staff Management → Invites tab (§9.3, CEO +
-- Manager) reads `invite_codes` locally, so a code created on one device never
-- reached the tab on any other device. This completes the round-trip.
--
-- This migration adds 'invite_codes' to pos_pull_snapshot's v_tenant_tables
-- array. invite_codes carries business_id + last_updated_at, so the generic
-- FOREACH ... WHERE t.business_id = $1 loop already handles it — no other
-- change is needed. RLS (invite_codes_tenant_rw, 0050/0051 profiles-based)
-- already lets a tenant's CEO/Manager SELECT their codes, and the snapshot is
-- SECURITY DEFINER with its own tenant guard, so no policy change is required.
--
-- Sole change vs the 0048 body: 1 entry ('invite_codes') appended to
-- v_tenant_tables.
--
-- DEPLOY ORDERING — READ BEFORE RUNNING:
--   Deploy AFTER 0048 (this re-creates pos_pull_snapshot from the 0048 body,
--   which already carries the 5 role/membership tables) and BEFORE/WITH the
--   client change that adds 'invite_codes' to _pullOrder. A client that pulls
--   invite_codes before 0053 deploys simply gets an empty slice (the old
--   snapshot omits the key) — exactly the pre-0053 behaviour, no 42703.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- pos_pull_snapshot — body from 0048. Sole change: 'invite_codes' appended to
-- v_tenant_tables.
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
    -- (seeded by migration on both sides).
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    -- 0053: invite_codes — so the Staff Management Invites tab (§9.3) shows
    -- codes created on any device in the business, not just the creator's.
    'invite_codes'
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
