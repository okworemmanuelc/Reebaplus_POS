-- 0171_crate_money_arrangement.sql
--
-- #211 / PRD #203, ADR 0023 rule 3 — Crate deposit outflow 2/8:
-- a brand says whether its crate money moves at all, and when.
--
-- Cloud twin of Drift schemaVersion 78
-- (lib/core/database/app_database.dart, the `from < 78` upgrade step).
--
-- ONE column: `manufacturers.crate_money_arrangement`, TEXT NOT NULL
-- DEFAULT 'none'.
--
--   'none'           — swap only. Crates go out, empties come back, no money
--                      ever changes hands. THE DEFAULT.
--   'per_delivery'   — a deposit is placed with the supplier on each receipt
--                      and returned on each hand-back.
--   'standing_float' — a lump sum placed once, moved only on a real top-up or
--                      a real payout.
--
-- WHY THE DEFAULT IS THE WHOLE POINT. Every existing manufacturer row, on every
-- live tenant, lands on 'none' the moment this runs — and NOTHING is backfilled.
-- That is the release gate for all eight slices of PRD #203: with every brand on
-- 'none', the later slices have nothing to act on, so they can ship to
-- production without moving a single tenant's figures. Do NOT add a backfill
-- that infers an arrangement from deposit_amount_kobo or from historic
-- supplier_crate_ledger rows — inferring one would silently opt a live tenant
-- into money movements they never asked for, and ADR 0023 ("Rejected
-- alternatives") rules out restating history on the authority of ADR 0021.
--
-- WHAT THIS MIGRATION DOES NOT DO:
--   * No money moves. No ledger row, no payment_transactions row, no balance
--     recomputation. Slices 3-8 of PRD #203 do that work, each behind this flag.
--   * No new rate column. The per-crate rate stays
--     `manufacturers.deposit_amount_kobo` — the single canonical rate (ADR 0023
--     rule 2). `crate_size_groups.deposit_amount_kobo` is a DEAD column with
--     zero readers and must not be revived as a per-size rate.
--   * No `*_kobo` column at all, so the bigint rule (0130) has nothing to bite
--     on here; `deposit_amount_kobo` was already widened to bigint by 0130.
--
-- RLS: none to add. `manufacturers` is an existing tenant table — it was
-- ENABLE/FORCE'd and given its tenant_select / tenant_insert / tenant_update /
-- tenant_delete policies by 0002_rls.sql, and Postgres RLS is row-level, so a
-- new COLUMN on an existing table inherits those policies unchanged. The
-- "clone the newest policy, use current_user_business_ids(), never an inline
-- user_businesses subquery" rule governs NEW tables; this migration creates
-- none, and rewriting `manufacturers`' long-standing policies would be an
-- unrelated (and risky) change riding on a feature slice.
--
-- No pos_pull_snapshot change is needed: `manufacturers` is already in the
-- v_tenant_tables array and the RPC ships whole rows (`to_jsonb(t)`), so the
-- new column rides down to devices automatically. On the push side the client's
-- `manufacturers` sync entry DOES carry an explicit column whitelist (#159
-- demoted `empty_crate_stock`), so the new column is added to that whitelist in
-- lib/core/database/sync_registry.dart, with a pull-side default of 'none' as
-- the deploy-order fuse for a v78 device that pulls before this lands.
--
-- DEPLOY ORDERING: this is a pure additive column with a default, so either
-- order is safe. A v78 client pushing before this lands sends a column the
-- cloud does not have (the push is rejected and retried, not corrupted); a
-- pre-v78 client pulling after this lands simply ignores an extra key. The
-- registry default covers the reverse. Deploying this FIRST is still preferred.

BEGIN;

-- =========================================================================
-- 1. manufacturers.crate_money_arrangement
--    TEXT NOT NULL DEFAULT 'none' — every existing row becomes "swap only".
--    The CHECK is added separately (and guarded) because ADD COLUMN IF NOT
--    EXISTS is not re-runnable together with a named constraint. Same shape as
--    0161's stores.kind.
-- =========================================================================
ALTER TABLE public.manufacturers
  ADD COLUMN IF NOT EXISTS crate_money_arrangement text NOT NULL DEFAULT 'none';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.manufacturers'::regclass
       AND conname  = 'manufacturers_crate_money_arrangement_check'
  ) THEN
    ALTER TABLE public.manufacturers
      ADD CONSTRAINT manufacturers_crate_money_arrangement_check
      CHECK (crate_money_arrangement IN ('none','per_delivery','standing_float'));
  END IF;
END
$$;

COMMENT ON COLUMN public.manufacturers.crate_money_arrangement IS
  '#211 crate deposit outflow (ADR 0023 rule 3): whether crate money moves for '
  'this brand, and when. ''none'' = swap only, no money ever changes hands (the '
  'default every existing row carries — the release gate for PRD #203); '
  '''per_delivery'' = a deposit placed on each receipt and returned on each '
  'hand-back; ''standing_float'' = a lump sum moved only on a real top-up or '
  'payout. Valued at manufacturers.deposit_amount_kobo, the single canonical '
  'per-crate rate — NEVER crate_size_groups.deposit_amount_kobo, which is dead.';

COMMIT;

-- =============================================================================
-- Verification (run by hand after deploy):
--
--   -- 1. Column shape.
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_name = 'manufacturers'
--      AND column_name = 'crate_money_arrangement';
--   -- expect: crate_money_arrangement | text | NO | 'none'::text
--
--   -- 2. CHECK constraint present.
--   SELECT conname FROM pg_constraint
--    WHERE conrelid = 'public.manufacturers'::regclass
--      AND conname = 'manufacturers_crate_money_arrangement_check';
--   -- expect: 1 row
--
--   -- 3. THE RELEASE GATE — every existing brand on every tenant reads 'none'.
--   SELECT crate_money_arrangement, COUNT(*)
--     FROM public.manufacturers
--    GROUP BY crate_money_arrangement;
--   -- expect: exactly one group, none | <every existing row>. Any other group
--   -- means something backfilled, which must be reverted before slice 3 ships.
--
--   -- 4. No tenant was opted in by accident.
--   SELECT COUNT(*) FROM public.manufacturers
--    WHERE crate_money_arrangement <> 'none';
--   -- expect: 0
-- =============================================================================
