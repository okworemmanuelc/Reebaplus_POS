-- 0185_business_logos_bucket.sql
--
-- #343 — the `business-logos` Storage bucket was never created on the project
-- (it was a manual dashboard step that never happened), so BusinessLogoService
-- uploads have always failed. This creates it, with RLS mirroring
-- product-images (0144).
--
-- Path scheme: `<businessId>.<ext>` at the bucket root — `<businessId>.jpg`
-- from #340, `<businessId>.png` from older app versions still in shops. There
-- is no folder segment, so the business is the file name before the dot.
--
-- Size cap: 5 MB, same as product-images today. NOT 1 MB yet — older app
-- versions upload PNG; the 1 MB cap ships with #341 once the JPEG version is
-- on every phone.
--
-- Public read (public bucket, so getPublicUrl renders on every device);
-- writes/deletes restricted to authenticated members of that business. The
-- business id is compared as text so a malformed name never raises a uuid
-- cast error — it simply doesn't match.
--
-- Idempotent (ON CONFLICT / DROP POLICY IF EXISTS) so it is safe to re-run.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'business-logos', 'business-logos', true, 5242880,
  array['image/jpeg','image/png']
)
on conflict (id) do nothing;

drop policy if exists "business_logos_read" on storage.objects;
create policy "business_logos_read" on storage.objects
  for select using (bucket_id = 'business-logos');

drop policy if exists "business_logos_insert" on storage.objects;
create policy "business_logos_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'business-logos'
    and name ~ '^[^/]+\.(jpg|png)$'
    and split_part(name, '.', 1) in (select b::text from current_user_business_ids() b)
  );

drop policy if exists "business_logos_update" on storage.objects;
create policy "business_logos_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'business-logos'
    and name ~ '^[^/]+\.(jpg|png)$'
    and split_part(name, '.', 1) in (select b::text from current_user_business_ids() b)
  )
  with check (
    bucket_id = 'business-logos'
    and name ~ '^[^/]+\.(jpg|png)$'
    and split_part(name, '.', 1) in (select b::text from current_user_business_ids() b)
  );

drop policy if exists "business_logos_delete" on storage.objects;
create policy "business_logos_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'business-logos'
    and name ~ '^[^/]+\.(jpg|png)$'
    and split_part(name, '.', 1) in (select b::text from current_user_business_ids() b)
  );
