-- 0186_photo_bucket_limits.sql
--
-- #341 — the #340 backstop: lower the product-images upload cap from 5 MB to
-- 1 MB. The app (from #340) uploads JPEG q80 ≤800px, typically < 300 KB;
-- pending PNG uploads queued before #340 are re-encoded to JPEG before upload.
-- Shipped before a rollout wait because the photo feature is not yet used in
-- shops (the bucket held 0 objects). MIME list unchanged. business-logos gets
-- its 1 MB cap at creation (0185).

update storage.buckets
   set file_size_limit = 1048576
 where id = 'product-images';
