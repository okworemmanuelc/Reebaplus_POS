-- 0258_van_return_empties_only.sql
--
-- #790 (owner, 2026-11-11): empty crates can come back from a van ALONE.
--
-- public.van_return_events.quantity was CHECK (quantity > 0), so a return row
-- always had to carry goods. It may now carry no goods as long as it carries
-- empties: quantity > 0, OR quantity = 0 with shells_back > 0. A row with
-- neither is still refused. A WIDENING: every existing row passes.
--
-- An empties-only row has credit_kobo = 0 and cost_kobo = 0, moves no stock and
-- posts no driver-ledger entry; only the empties reach the warehouse's crate
-- pool (the same leg a mixed return already writes).
--
-- Mirrors Drift schemaVersion 111. DEPLOY ORDER: land this BEFORE any v111
-- client pushes. An OLDER app cannot store an empties-only row it pulls (its
-- local CHECK still wants quantity > 0), so raise the minimum build when v111
-- ships.
-- POS PARITY: any console view of van returns must cope with quantity = 0.

BEGIN;

ALTER TABLE public.van_return_events
  DROP CONSTRAINT IF EXISTS van_return_events_quantity_check;

ALTER TABLE public.van_return_events
  ADD CONSTRAINT van_return_events_quantity_check
  CHECK (quantity > 0 OR (quantity = 0 AND shells_back > 0));

COMMIT;
