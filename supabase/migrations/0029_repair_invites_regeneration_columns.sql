-- =============================================================================
-- 0029_repair_invites_regeneration_columns.sql — Re-apply 0025's invites
--   regeneration tracking columns; they're missing from the active cloud DB.
--
-- Symptom (caught while testing the new Task #17 regenerate action on the
-- staff list): the regenerate_invite_code RPC (0027) raised
--
--     ERROR 42703: column "regenerated_from" of relation "invites" does not
--     exist
--
-- when called on a pending invite. The Edge Function surfaced this as the
-- generic `internal` error after the diagnostic patch landed.
--
-- 0025 is in the migrations directory and the deployment log claims it
-- applied, but `information_schema.columns` says regenerated_from /
-- regenerated_at are missing. Most likely cause: 0025 was applied against
-- a staging snapshot whose migration history was later stamped onto the
-- active cloud DB without the DDL itself running there. Re-applying just
-- the column + index half of 0025 is harmless on a DB where it did land
-- (IF NOT EXISTS) and corrective everywhere it didn't.
--
-- The "revoke rev-2 6-char codes" cleanup half of 0025 is intentionally
-- skipped — that cleanup has either already happened or is moot now, and
-- re-running it on the same DB twice is a no-op (the WHERE clause filters
-- pending+6-char which excludes anything we already revoked).
--
-- Apply after 0028.
-- =============================================================================

ALTER TABLE public.invites
  ADD COLUMN IF NOT EXISTS regenerated_from uuid REFERENCES public.invites(id),
  ADD COLUMN IF NOT EXISTS regenerated_at   timestamptz;

CREATE INDEX IF NOT EXISTS idx_invites_regenerated_from
  ON public.invites (regenerated_from)
  WHERE regenerated_from IS NOT NULL;

-- =============================================================================
-- Verification:
--
--   -- A. Columns landed.
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='invites'
--     AND column_name IN ('regenerated_from','regenerated_at');
--   -- expect 2 rows
--
--   -- B. Index landed.
--   SELECT indexname FROM pg_indexes
--   WHERE schemaname='public' AND tablename='invites'
--     AND indexname='idx_invites_regenerated_from';
--   -- expect 1 row
--
--   -- C. Regenerate works end-to-end. From the app: create a pending
--   --    invite, then tap Regenerate. Expect the new row in:
--   --      SELECT id, status, regenerated_from, regenerated_at
--   --      FROM public.invites
--   --      WHERE business_id = '<biz>' ORDER BY created_at DESC LIMIT 5;
-- =============================================================================
