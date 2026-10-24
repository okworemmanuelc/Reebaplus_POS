-- #467: Public image URLs remain readable, but Storage metadata/listing is
-- private to the object's business. SELECT is retained for member upserts.
-- Logos use a root filename, unlike products' business-id folder.
begin;

drop policy if exists "product_images_read" on storage.objects;
create policy "product_images_read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] in (
      select b::text from public.current_user_business_ids() b
    )
  );

drop policy if exists "business_logos_read" on storage.objects;
create policy "business_logos_read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'business-logos'
    and name ~ '^[^/]+\.(jpg|png)$'
    and split_part(name, '.', 1) in (
      select b::text from public.current_user_business_ids() b
    )
  );

-- Deliberately no bucket/public flag, upload, update or delete policy change.
commit;
