-- 0144_product_images_bucket.sql
--
-- #78 / PRD #76 — Storage bucket for the optional synced product photo.
--
-- ProductImageService uploads a product's picked image here and writes the
-- resulting public URL onto products.image_url (0143), which converges
-- cross-device via the normal sync path. Reuses the BusinessLogoService
-- pattern (public bucket + local file cache), but business-scopes the object
-- path so writes are gated by RLS.
--
-- Path scheme: <businessId>/<productId>.png — the first folder segment is the
-- owning business, checked against current_user_business_ids(). Public read so
-- getPublicUrl renders on every device (and offline from the local cache);
-- writes restricted to authenticated members of that business.
--
-- Idempotent (ON CONFLICT / DROP POLICY IF EXISTS) so it is safe to re-run.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-images', 'product-images', true, 5242880,
  array['image/png','image/jpeg','image/jpg','image/webp','image/heic','image/heif']
)
on conflict (id) do nothing;

drop policy if exists "product_images_read" on storage.objects;
create policy "product_images_read" on storage.objects
  for select using (bucket_id = 'product-images');

drop policy if exists "product_images_insert" on storage.objects;
create policy "product_images_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'product-images'
    and ((storage.foldername(name))[1])::uuid in (select current_user_business_ids())
  );

drop policy if exists "product_images_update" on storage.objects;
create policy "product_images_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'product-images'
    and ((storage.foldername(name))[1])::uuid in (select current_user_business_ids())
  )
  with check (
    bucket_id = 'product-images'
    and ((storage.foldername(name))[1])::uuid in (select current_user_business_ids())
  );

drop policy if exists "product_images_delete" on storage.objects;
create policy "product_images_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'product-images'
    and ((storage.foldername(name))[1])::uuid in (select current_user_business_ids())
  );
