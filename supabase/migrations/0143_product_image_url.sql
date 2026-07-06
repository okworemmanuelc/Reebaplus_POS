-- 0143_product_image_url.sql
--
-- #78 / PRD #76 — optional synced product photo.
--
-- Adds products.image_url: the public URL of a product's photo in the
-- `product-images` Storage bucket. The client uploads the picked image, then
-- writes this URL onto the product row, which converges cross-device through
-- the normal outbox → upsert → pull path (products is a pass-through push
-- table, so no RPC or whitelist change is needed — the column rides sync as
-- soon as it exists on both sides).
--
-- Nullable and additive: photo-less products stay NULL, existing rows are
-- untouched. The existing local `image_path` column is unchanged (it keeps
-- serving offline render on the device that added the image).
--
-- Deploy-ordering: this must land on the cloud BEFORE any client on Drift
-- schema v59 pushes a product upsert carrying image_url, or the upsert would
-- reference an unknown column and jam the outbox.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS image_url text;
