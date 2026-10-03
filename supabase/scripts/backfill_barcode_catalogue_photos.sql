-- One-time photo backfill for the shared barcode catalogue (#331, ADR 0029 §5).
--
-- Run ONCE per project, as postgres (SQL editor or `supabase db query --linked`),
-- AFTER all of:
--   * migration 0182 is applied;
--   * the `share-barcode-photo` Edge Function is deployed (verify_jwt = false);
--   * the hook secret exists in BOTH places, with the same value:
--       Vault:            select vault.create_secret('<value>', 'barcode_catalogue_hook_secret');
--       Edge secret:      supabase secrets set BARCODE_CATALOGUE_HOOK_SECRET=<value>
--
-- It asks the function to share a photo, in {gtin14} mode, for every factory
-- GTIN that has at least one photo and no shared photo yet. The function walks
-- each GTIN's products oldest first and skips blocked hashes. Safe to re-run:
-- GTINs that already have a shared photo are left out (and the function skips
-- them anyway).
--
-- requests_queued = NULL count means Vault isn't configured: nothing was sent.

with gtins as (
  select distinct public.gtin14(p.barcode) as gtin14
    from public.products p
   where public.is_factory_gtin(p.barcode)
     and not p.is_deleted
     and nullif(btrim(p.image_url), '') is not null
     and not exists (
           select 1
             from public.barcode_catalogue_photos ph
            where ph.gtin14 = public.gtin14(p.barcode))
),
requests as (
  select g.gtin14,
         public.barcode_catalogue_request_share(jsonb_build_object('gtin14', g.gtin14)) as request_id
    from gtins g
)
select count(*)          as gtins_with_photo,
       count(request_id) as requests_queued
  from requests;

-- Afterwards (pg_net keeps responses for about 6 hours):
--
--   select count(*) as shared_photos from public.barcode_catalogue_photos;
--
--   select status_code, content::jsonb ->> 'status' as outcome, count(*)
--     from net._http_response
--    where created > now() - interval '1 hour'
--    group by 1, 2;
