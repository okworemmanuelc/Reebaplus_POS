-- 0199_store_online_ordering.sql
--
-- #423 (PRD #421, user stories 55-59, 93, 103): a store can go online.
-- Cloud twin of Drift schemaVersion 89 (app_database.dart, `from < 89`).
--
-- WHAT THIS ADDS
--   1. stores: country / state / lga (the store's own area — Nigeria from the
--      bundled lists that match ng_areas (0189), free text elsewhere), phone
--      (public store phone; falls back to the business phone in the app),
--      online_note (<= 280 chars, shown to shoppers) and
--      online_ordering_enabled (default OFF).
--      `state` and `country` already exist on prod as unused, all-NULL legacy
--      columns; ADD COLUMN IF NOT EXISTS keeps them.
--   2. store_delivery_areas: the synced per-store delivery list. lga NULL =
--      the whole state. Soft-deleted (is_deleted), never hard-deleted, so it
--      needs no client hard-delete reconcile. The client mints a deterministic
--      id per (store, country, state, lga) so re-adding an area revives the
--      same row and two devices adding the same area converge on one row.
--   3. Permission `stores.online_ordering` (category 'Online store'), CEO by
--      default. The seed function already gives the CEO every catalogue key,
--      so only existing CEO roles need the one-off backfill below.
--
-- THE SWITCH BACKSTOP. A CHECK refuses online_ordering_enabled = true for a
-- van or for a store without state + LGA. The app refuses first (the switch
-- is disabled with a prompt), so this only stops a hand-written/RPC write.
-- "At least one delivery area" is enforced by the app write path (a CHECK
-- cannot see another table).
--
-- Switching off hides the store immediately for storefront reads (#425 must
-- require online_ordering_enabled); online orders already placed are separate
-- rows (#426+) and stay workable.
--
-- RLS: current_user_business_ids(), never an inline user_businesses subquery.
-- Live sync: zz_broadcast_sync_signal attached here (0198 guard checks it).
--
-- DEPLOY ORDERING: deploy BEFORE the schema-89 app. An older cloud would
-- reject pushes of the new store columns / table and jam the outbox until
-- this lands. The reverse order is safe (old apps never write these).

BEGIN;

-- =========================================================================
-- 1. stores — area, public phone, online note, the switch
-- =========================================================================
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS country text;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS state text;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS lga text;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS online_note text;
ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS online_ordering_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.stores DROP CONSTRAINT IF EXISTS stores_online_note_length;
ALTER TABLE public.stores ADD CONSTRAINT stores_online_note_length
  CHECK (online_note IS NULL OR char_length(online_note) <= 280);

ALTER TABLE public.stores DROP CONSTRAINT IF EXISTS stores_online_requires_area;
ALTER TABLE public.stores ADD CONSTRAINT stores_online_requires_area
  CHECK (
    NOT online_ordering_enabled
    OR (
      kind = 'store'
      AND nullif(btrim(state), '') IS NOT NULL
      AND nullif(btrim(lga), '') IS NOT NULL
    )
  );

COMMENT ON COLUMN public.stores.online_ordering_enabled IS
  '#423: store listed to shoppers. Requires kind=store + state + LGA. '
  'Storefront reads must also require the business not deleted/inactive.';
COMMENT ON COLUMN public.stores.lga IS
  '#423: local government area; Nigeria values match public.ng_areas.';

-- Storefront search by area (#425) filters online stores by state/LGA.
CREATE INDEX IF NOT EXISTS idx_stores_online_area
  ON public.stores (state, lga)
  WHERE online_ordering_enabled AND NOT is_deleted;

-- =========================================================================
-- 2. store_delivery_areas — synced per-store delivery list
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.store_delivery_areas (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id        UUID        NOT NULL REFERENCES public.stores(id)     ON DELETE CASCADE,
  country         TEXT        NOT NULL DEFAULT 'Nigeria',
  state           TEXT        NOT NULL CHECK (btrim(state) <> ''),
  -- NULL = the whole state (covers all its LGAs).
  lga             TEXT        CHECK (lga IS NULL OR btrim(lga) <> ''),
  is_deleted      BOOLEAN     NOT NULL DEFAULT false,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_store_delivery_areas_store
  ON public.store_delivery_areas (store_id) WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_store_delivery_areas_area
  ON public.store_delivery_areas (state, lga) WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_store_delivery_areas_business_lua
  ON public.store_delivery_areas (business_id, last_updated_at);

DROP TRIGGER IF EXISTS bump_store_delivery_areas_last_updated_at
  ON public.store_delivery_areas;
CREATE TRIGGER bump_store_delivery_areas_last_updated_at
  BEFORE UPDATE ON public.store_delivery_areas
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

COMMENT ON TABLE public.store_delivery_areas IS
  '#423: states/LGAs a store delivers to (lga NULL = whole state). Synced, '
  'soft-deleted. Deterministic client ids per (store, country, state, lga).';

ALTER TABLE public.store_delivery_areas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "store_delivery_areas_tenant_rw" ON public.store_delivery_areas;
CREATE POLICY "store_delivery_areas_tenant_rw"
  ON public.store_delivery_areas
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));

ALTER TABLE public.store_delivery_areas REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'store_delivery_areas'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.store_delivery_areas;
  END IF;
END $$;

-- Live-sync signal (0147 does not cover tables created after it; #470).
DROP TRIGGER IF EXISTS zz_broadcast_sync_signal ON public.store_delivery_areas;
CREATE TRIGGER zz_broadcast_sync_signal
  AFTER INSERT OR UPDATE OR DELETE ON public.store_delivery_areas
  FOR EACH ROW EXECUTE FUNCTION public.zz_broadcast_sync_signal();

-- =========================================================================
-- 3. Permission — catalogue first, then the one-off CEO backfill
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('stores.online_ordering', 'Switch a store''s online ordering on/off', 'Online store')
ON CONFLICT (key) DO NOTHING;

-- New businesses: seed_default_roles_for_business (0195) grants the CEO every
-- catalogue key. Existing businesses get the default once; do not rewrite this
-- to re-grant an intentionally revoked permission later.
INSERT INTO public.role_permissions (business_id, role_id, permission_key)
SELECT business_id, id, 'stores.online_ordering'
  FROM public.roles WHERE slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- =========================================================================
-- 4. pos_pull_snapshot — add store_delivery_areas (after stores)
--    Carries forward the 0172 list verbatim. The incremental fast-link pull
--    reads only the tables this RPC returns.
-- =========================================================================
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
    'profiles','users','stores',
    -- 0199 (#423): per-store delivery areas; parent stores is just above.
    'store_delivery_areas',
    'manufacturers','crate_size_groups',
    'categories','products','inventory',
    'cost_batches',
    'customers','suppliers',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    'supplier_crate_deposit_requests','supplier_crate_deposits',
    'orders','order_items',
    'order_crate_lines',
    'shipments','purchase_items',
    'expenses','expense_categories',
    'expense_budgets',
    'customer_crate_balances','delivery_receipts','drivers',
    'stock_transfers','stock_adjustments','activity_logs',
    'error_logs',
    'notifications','stock_transactions',
    'stock_adjustment_requests',
    'quick_sale_requests',
    'customer_wallets','wallet_transactions',
    'saved_carts',
    'pending_crate_returns','crate_ledger','manufacturer_crate_balances',
    'store_crate_balances',
    'supplier_crate_balances',
    'price_lists','payment_transactions','sessions','settings',
    'roles','role_permissions','role_settings','user_businesses','user_stores',
    'invite_codes',
    'stock_counts',
    'daily_closings',
    'van_trips','van_trip_lots','van_return_events','driver_ledger_entries',
    'user_permission_overrides',
    'store_role_permissions'
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

COMMIT;
