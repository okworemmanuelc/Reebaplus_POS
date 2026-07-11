-- 0150_products_barcode.sql
--
-- #113 (ADR 0017, unwritten — implemented from the issue ACs) — optional
-- product barcode, the foundation for barcode scanning (#118).
--
-- Adds public.products.barcode: an optional, human-typed (later scanned) code
-- that identifies a product. The client column already exists (Drift schema
-- v18); this lands the cloud half so the value converges cross-device through
-- the normal outbox -> upsert -> pull path. `products` is a pass-through push
-- table (no push-column whitelist in sync_registry.dart), so the column rides
-- sync as soon as it exists on both sides — no RPC or whitelist change needed.
--
-- NULLABLE and additive: barcode-less products stay NULL, existing rows are
-- untouched.
--
-- NO UNIQUE constraint (deliberate): uniqueness is enforced softly in the app
-- (the Add/Edit form warns on a collision but still allows the save). A DB
-- UNIQUE would reject a colliding offline write on push and permanently jam the
-- outbox — the exact failure mode this issue is required to avoid.
--
-- Deploy-ordering: this must land on the cloud BEFORE any client pushes a
-- product upsert carrying a non-null barcode, or the upsert would reference an
-- unknown column and jam the outbox. No shipped client sets barcode yet, so
-- deploying this alongside the feature PR is safe.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS barcode text;
