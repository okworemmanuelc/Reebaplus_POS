-- 0104_store_crate_balances.sql
-- Per-store empty-crate balance table (master plan §16.8.1 Phase 2).
-- Adds crate_ledger.store_id column (nullable) so movements can be attributed
-- to a specific store. Creates the store_crate_balances cache table (analogous
-- to manufacturer_crate_balances) and wires it into RLS, realtime, and
-- pos_pull_snapshot.

BEGIN;

-- ─── 1. crate_ledger: add nullable store_id column ──────────────────────────
ALTER TABLE public.crate_ledger
  ADD COLUMN IF NOT EXISTS store_id UUID REFERENCES public.stores(id) ON DELETE SET NULL;

-- ─── 2. store_crate_balances ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.store_crate_balances (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  store_id          UUID        NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  manufacturer_id   UUID        NOT NULL REFERENCES public.manufacturers(id) ON DELETE CASCADE,
  balance           INTEGER     NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (business_id, store_id, manufacturer_id)
);

-- Index for tenant sync pull.
CREATE INDEX IF NOT EXISTS idx_store_crate_balances_business_updated
  ON public.store_crate_balances (business_id, last_updated_at);

-- Bump trigger so realtime and incremental pulls pick up changes.
CREATE OR REPLACE FUNCTION public.set_store_crate_balances_last_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.last_updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_store_crate_balances_updated ON public.store_crate_balances;
CREATE TRIGGER trg_store_crate_balances_updated
  BEFORE UPDATE ON public.store_crate_balances
  FOR EACH ROW EXECUTE FUNCTION public.set_store_crate_balances_last_updated_at();

-- ─── 3. RLS ──────────────────────────────────────────────────────────────────
ALTER TABLE public.store_crate_balances ENABLE ROW LEVEL SECURITY;

-- Use current_user_business_ids() (profiles-based, not inline subquery) to
-- avoid the auth_user_id drift issue (see memory: New synced-table RLS pattern).
CREATE POLICY "tenant_isolation" ON public.store_crate_balances
  USING (business_id IN (SELECT public.current_user_business_ids()));

-- ─── 4. Realtime ──────────────────────────────────────────────────────────────
-- No REPLICA IDENTITY FULL — this is a cache table (upsert-only, never
-- tombstoned), same as manufacturer_crate_balances.
ALTER PUBLICATION supabase_realtime ADD TABLE public.store_crate_balances;

-- ─── 5. Backfill — fold existing manufacturer.empty_crate_stock into the
--        primary store (oldest non-deleted store per business) ─────────────────
-- This mirrors the local v44 onUpgrade backfill so the cloud snapshot matches.
INSERT INTO public.store_crate_balances
  (id, business_id, store_id, manufacturer_id, balance, last_updated_at)
SELECT
  gen_random_uuid(),
  m.business_id,
  primary_store.id AS store_id,
  m.id             AS manufacturer_id,
  m.empty_crate_stock,
  NOW()
FROM public.manufacturers m
CROSS JOIN LATERAL (
  SELECT id
  FROM   public.stores
  WHERE  business_id = m.business_id
    AND  (is_deleted IS NULL OR is_deleted = FALSE)
  ORDER  BY created_at ASC
  LIMIT  1
) AS primary_store
WHERE m.empty_crate_stock > 0
  AND m.is_deleted IS NOT TRUE
ON CONFLICT (business_id, store_id, manufacturer_id) DO NOTHING;

COMMIT;
