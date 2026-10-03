-- migration: 0182_barcode_catalogue_photos
--
-- Issue #331, slice 2 of PRD #322 (decisions: docs/adr/0029-shared-barcode-catalogue.md
-- §5, §6). The shared photo: the first photo saved for a factory barcode is
-- copied into a shared bucket and stays. Builds on 0181 (gtin14 /
-- is_factory_gtin, the empty barcode_catalogue_photos table, and
-- barcode_suggestion, which already returns the photo's public URL once a row
-- exists). No app code depends on this.
--
-- What this adds:
--   1. The public-read bucket `barcode-catalogue-photos` (object path
--      '<gtin14>.png'), with NO storage.objects policies at all.
--   2. The photo block list: public.barcode_catalogue_photo_blocks.
--   3. public.barcode_catalogue_photo_candidates(...): the products whose photo
--      may be shared, oldest first. Service role only; read by the Edge
--      Function so it never needs its own copy of the factory-barcode rule.
--   4. public.barcode_catalogue_request_share(jsonb): POSTs a payload to the
--      `share-barcode-photo` Edge Function through pg_net. Used by the trigger,
--      the one-time backfill (supabase/scripts/backfill_barcode_catalogue_photos.sql)
--      and the removal runbook (ADR 0029 §6).
--   5. An AFTER INSERT OR UPDATE OF image_url, barcode trigger on
--      public.products that requests a share when a product with a photo and
--      a factory barcode has no shared photo yet.
--
-- Who writes: only the service role (the Edge Function). Clients can't write,
-- overwrite or delete in the bucket, and can't read or write the tables.
-- A shared photo is a COPY: the source shop's own photo
-- (product-images/<businessId>/<productId>.png) is never touched, and the
-- copy stays when the source changes or deletes its photo, product or account.
--
-- SECRETS (Vault): `project_url` already exists (0126). The hook secret must be
-- created once per project before shares fire:
--
--   select vault.create_secret('<random-long-string>', 'barcode_catalogue_hook_secret');
--
-- and the same value set as the Edge Function secret
-- BARCODE_CATALOGUE_HOOK_SECRET. Until both exist (and the function is
-- deployed with verify_jwt = false) the trigger does nothing — never a broken
-- product write.
--
-- DEPLOY ORDER: forgiving. This migration first is fine (the trigger is inert
-- until the secret exists). The only hard order: deploy `share-barcode-photo`
-- and set both secrets BEFORE running the backfill.

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Bucket (ADR 0029 §5). Same size and type limits as product-images (0144).
--
-- Public read comes from `public = true`: anyone can GET
-- /storage/v1/object/public/barcode-catalogue-photos/<gtin14>.png, which is
-- how barcode_suggestion's photo_url renders. No storage.objects policy names
-- this bucket, so authenticated and anon clients can't insert, update, delete
-- or list in it. Every existing storage.objects policy is scoped to its own
-- bucket_id (0144), so none of them reaches this one.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'barcode-catalogue-photos', 'barcode-catalogue-photos', true, 5242880,
  array['image/png','image/jpeg','image/jpg','image/webp','image/heic','image/heif']
)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Photo block list (ADR 0029 §6). A blocked sha256 is never shared again,
--    so the shop that sent it can't bring it back by saving again.
-- ---------------------------------------------------------------------------
create table if not exists public.barcode_catalogue_photo_blocks (
  sha256     text primary key check (sha256 ~ '^[0-9a-f]{64}$'),
  gtin14     text check (gtin14 ~ '^[0-9]{14}$'),
  blocked_at timestamptz not null default now()
);

alter table public.barcode_catalogue_photo_blocks enable row level security;
revoke all on table public.barcode_catalogue_photo_blocks from anon, authenticated;

comment on table public.barcode_catalogue_photo_blocks is
  'ADR 0029 §6: photo hashes (lower-case hex sha256 of the bytes) that are '
  'never shared. gtin14 is a note of where it was seen. RLS on, no policies: '
  'service role only.';

-- ---------------------------------------------------------------------------
-- 3. Candidates for the shared photo. Exactly one of the two arguments:
--      p_product_id → that product, if it qualifies (the trigger path);
--      p_gtin14     → every qualifying product for the GTIN, oldest
--                     created_at first (the backfill / runbook path).
--    Qualifies = not deleted, has an image_url, factory barcode. The WHERE
--    repeats the 0181 partial-index predicate so the GTIN branch uses it.
-- ---------------------------------------------------------------------------
create or replace function public.barcode_catalogue_photo_candidates(
  p_product_id uuid default null,
  p_gtin14     text default null
)
returns table (gtin14 text, product_id uuid, business_id uuid, image_url text)
language plpgsql
stable
set search_path = public, pg_temp
as $function$
begin
  if p_product_id is not null then
    return query
      select public.gtin14(p.barcode), p.id, p.business_id, p.image_url
        from public.products p
       where p.id = p_product_id
         and public.is_factory_gtin(p.barcode)
         and not p.is_deleted
         and nullif(btrim(p.image_url), '') is not null;
  elsif p_gtin14 is not null then
    return query
      select public.gtin14(p.barcode), p.id, p.business_id, p.image_url
        from public.products p
       where public.is_factory_gtin(p.barcode)
         and not p.is_deleted
         and public.gtin14(p.barcode) = p_gtin14
         and nullif(btrim(p.image_url), '') is not null
       order by p.created_at, p.id;
  end if;
end;
$function$;

comment on function public.barcode_catalogue_photo_candidates(uuid, text) is
  'ADR 0029 §5: products whose photo may become the shared photo (not '
  'deleted, has image_url, factory barcode), oldest first. Read by the '
  'share-barcode-photo Edge Function. Service role only.';

revoke all on function public.barcode_catalogue_photo_candidates(uuid, text)
  from public, anon, authenticated;
grant execute on function public.barcode_catalogue_photo_candidates(uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Request a share: POST p_body to share-barcode-photo via pg_net. Returns
--    the pg_net request id (look it up in net._http_response), or NULL when
--    the project isn't configured. p_body is {"record": {...}} or
--    {"gtin14": "<14 digits>"}. Mirrors send_push_on_broadcast_insert (0159).
--
--    Runbook / backfill use (as postgres or service role):
--      select public.barcode_catalogue_request_share(
--        jsonb_build_object('gtin14', public.gtin14('<barcode>')));
-- ---------------------------------------------------------------------------
create or replace function public.barcode_catalogue_request_share(p_body jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $function$
declare
  v_base_url text;
  v_secret   text;
begin
  select decrypted_secret into v_base_url
    from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'barcode_catalogue_hook_secret';

  if v_base_url is null or v_secret is null then
    return null;
  end if;

  -- Download + hash + upload can outlast pg_net's 5 s default.
  return net.http_post(
    url                  := rtrim(v_base_url, '/') || '/functions/v1/share-barcode-photo',
    headers              := jsonb_build_object(
      'content-type',                    'application/json',
      'x-barcode-catalogue-hook-secret', v_secret
    ),
    body                 := p_body,
    timeout_milliseconds := 30000
  );
end;
$function$;

comment on function public.barcode_catalogue_request_share(jsonb) is
  'ADR 0029 §5/§6: POST {record} or {gtin14} to the share-barcode-photo Edge '
  'Function via pg_net. NULL when project_url or '
  'barcode_catalogue_hook_secret is missing from Vault. Service role only.';

revoke all on function public.barcode_catalogue_request_share(jsonb)
  from public, anon, authenticated;
grant execute on function public.barcode_catalogue_request_share(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------
-- 5. Trigger on public.products.
--
-- Fires on INSERT, and on UPDATE when image_url or barcode is in the SET list
-- (a sync upsert sets every column, so a re-push fires it too; the "already
-- shared" check below makes that a cheap no-op once a GTIN has its photo).
-- It must never raise: products is the hottest synced table, and a raise here
-- would reject the push and jam every outbox carrying the product. So the
-- request is fire-and-forget (pg_net sends after commit) and any error is
-- downgraded to a warning.
-- ---------------------------------------------------------------------------
create or replace function public.share_barcode_photo_on_product_write()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $function$
begin
  -- The WHEN clause already checks these two; guard here too in case the
  -- trigger is ever widened.
  if new.image_url is null or not public.is_factory_gtin(new.barcode) then
    return new;
  end if;

  if new.is_deleted then
    return new;
  end if;

  if exists (
    select 1
      from public.barcode_catalogue_photos ph
     where ph.gtin14 = public.gtin14(new.barcode)
  ) then
    return new;
  end if;

  begin
    perform public.barcode_catalogue_request_share(
      jsonb_build_object('record', jsonb_build_object(
        'id',          new.id,
        'business_id', new.business_id,
        'barcode',     new.barcode,
        'image_url',   new.image_url
      ))
    );
  exception when others then
    raise warning 'share-barcode-photo request failed for product %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$function$;

drop trigger if exists trg_share_barcode_photo on public.products;
create trigger trg_share_barcode_photo
  after insert or update of image_url, barcode on public.products
  for each row
  when (new.image_url is not null and public.is_factory_gtin(new.barcode))
  execute function public.share_barcode_photo_on_product_write();

-- TRIGGER function, never a client RPC — revoke the default PUBLIC EXECUTE to
-- keep this SECURITY DEFINER function off the PostgREST /rpc/ surface (advisor).
revoke execute on function public.share_barcode_photo_on_product_write()
  from public, anon, authenticated;
