-- migration: 0181_barcode_catalogue_lookup
--
-- Issue #330, slice 1 of PRD #322 (decisions: docs/adr/0029-shared-barcode-catalogue.md).
-- The cloud side of shared name and unit suggestions. No app code depends on
-- this yet (#332 adds the client), so it is safe to deploy ahead of any build.
--
-- What this adds:
--   1. The factory-barcode rule (ADR 0029 §2): public.gtin14(text) and
--      public.is_factory_gtin(text), both IMMUTABLE. The same rule lives in
--      Dart (lib/core/utils/factory_barcode.dart). Shared vectors in
--      test/fixtures/gtin_vectors.json keep the two in lockstep; change both
--      together, never one.
--   2. public.barcode_catalogue_normalise_name(text): the one name
--      normalisation (collapse whitespace, trim, lower-case) used by the vote
--      AND by the name block list, so the removal runbook can't drift from it.
--   3. The kill switch (§7): public.platform_settings, seeded with
--      barcode_catalogue.suggestions_enabled = true.
--   4. The name block list (§6): public.barcode_catalogue_name_blocks.
--   5. The shared photo table (§5), created EMPTY so the lookup can join it.
--      #331 fills it. object_path is relative to the
--      `barcode-catalogue-photos` bucket (e.g. '<gtin14>.png').
--   6. The lookup RPC (§3, §4): public.barcode_suggestion(p_barcode).
--   7. An expression index on products(gtin14(barcode)) for the lookup.
--
-- Tenancy (architecture.md invariant #5, named exception): barcode_suggestion
-- is the ONLY way across the tenant boundary. It returns one aggregate row of
-- (name, unit, photo_url) with no business id, product id or vote count. RLS
-- on public.products is unchanged; no client can SELECT another business's
-- rows. The three new tables have RLS on and NO policies (service role only).
--
-- Index safety: gtin14 / is_factory_gtin run inside an index expression on
-- public.products, so they run on every product insert/update. They must
-- never raise for any text input (a raise would jam every outbox that pushes
-- that product). Both check the shape with a regex before touching a digit.

-- ---------------------------------------------------------------------------
-- 1. Factory-barcode rule
-- ---------------------------------------------------------------------------

-- The code left-padded to 14 digits when it is ASCII digits of length 8, 12,
-- 13 or 14, else NULL. Says nothing about the check digit or restricted
-- prefixes; use is_factory_gtin for that.
CREATE OR REPLACE FUNCTION public.gtin14(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT CASE
    WHEN p_code ~ '^[0-9]+$' AND length(p_code) IN (8, 12, 13, 14)
      THEN lpad(p_code, 14, '0')
  END;
$function$;

COMMENT ON FUNCTION public.gtin14(text) IS
  'ADR 0029 §2: the code left-padded to 14 digits when it is 8/12/13/14 ASCII '
  'digits, else NULL. Mirrors FactoryBarcode.padToGtin14 (Dart).';

-- True when p_code is a real factory GTIN (ADR 0029 §2):
--   * ASCII digits only, length 8/12/13/14, valid GS1 mod-10 check digit;
--   * not all zeros;
--   * not GS1 restricted circulation: GTIN-13 prefixes 02, 04, 2; UPC-A
--     number systems 2, 4; GTIN-8 starting 0 or 2; a GTIN-14 is judged on
--     its inner GTIN-13 (the 13 digits after the indicator).
-- Strict: no trimming. NULL in, false out.
CREATE OR REPLACE FUNCTION public.is_factory_gtin(p_code text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
DECLARE
  v_len   int;
  v_sum   int := 0;
  v_digit int;
  v_inner text;
BEGIN
  IF p_code IS NULL OR p_code !~ '^[0-9]+$' THEN
    RETURN false;
  END IF;

  v_len := length(p_code);
  IF v_len NOT IN (8, 12, 13, 14) THEN
    RETURN false;
  END IF;

  IF p_code !~ '[1-9]' THEN
    RETURN false;  -- all zeros
  END IF;

  -- GS1 mod-10: from the right, the check digit has weight 1, then the
  -- weights alternate 3, 1, 3, ... The weighted sum must be a multiple of 10.
  FOR i IN 0 .. v_len - 1 LOOP
    v_digit := ascii(substr(p_code, v_len - i, 1)) - 48;
    v_sum := v_sum + CASE WHEN i % 2 = 1 THEN v_digit * 3 ELSE v_digit END;
  END LOOP;
  IF v_sum % 10 <> 0 THEN
    RETURN false;
  END IF;

  IF v_len = 8 THEN
    RETURN left(p_code, 1) NOT IN ('0', '2');
  END IF;

  IF v_len = 12 THEN
    RETURN left(p_code, 1) NOT IN ('2', '4');
  END IF;

  v_inner := CASE WHEN v_len = 14 THEN substr(p_code, 2) ELSE p_code END;
  RETURN NOT (left(v_inner, 2) IN ('02', '04') OR left(v_inner, 1) = '2');
END;
$function$;

COMMENT ON FUNCTION public.is_factory_gtin(text) IS
  'ADR 0029 §2: true for a real factory GTIN (8/12/13/14 digits, valid check '
  'digit, not all zeros, not restricted circulation). Mirrors '
  'FactoryBarcode.isFactoryGtin (Dart); shared vectors in '
  'test/fixtures/gtin_vectors.json.';

-- ---------------------------------------------------------------------------
-- 2. Name normalisation (vote grouping + block list key)
-- ---------------------------------------------------------------------------

-- Collapse runs of whitespace to one space, trim, lower-case. NULL for a
-- NULL or blank name.
CREATE OR REPLACE FUNCTION public.barcode_catalogue_normalise_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT nullif(lower(btrim(regexp_replace(p_name, '\s+', ' ', 'g'))), '');
$function$;

COMMENT ON FUNCTION public.barcode_catalogue_normalise_name(text) IS
  'ADR 0029 §3/§6: the one name normalisation used by barcode_suggestion and '
  'by barcode_catalogue_name_blocks.normalised_name.';

-- ---------------------------------------------------------------------------
-- 3. Kill switch (§7)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.platform_settings (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_settings FROM anon, authenticated;

COMMENT ON TABLE public.platform_settings IS
  'Reebaplus-only platform switches. RLS on, no policies: service role only. '
  'Never synced, never read by a client.';

INSERT INTO public.platform_settings (key, value)
VALUES ('barcode_catalogue.suggestions_enabled', 'true'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Name block list (§6)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.barcode_catalogue_name_blocks (
  gtin14          text NOT NULL CHECK (gtin14 ~ '^[0-9]{14}$'),
  normalised_name text NOT NULL
    CHECK (normalised_name = public.barcode_catalogue_normalise_name(normalised_name)),
  blocked_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (gtin14, normalised_name)
);

ALTER TABLE public.barcode_catalogue_name_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.barcode_catalogue_name_blocks FROM anon, authenticated;

COMMENT ON TABLE public.barcode_catalogue_name_blocks IS
  'ADR 0029 §6: names removed from the shared catalogue, per GTIN-14. '
  'Insert with gtin14(code) and barcode_catalogue_normalise_name(name). '
  'RLS on, no policies: service role only.';

-- ---------------------------------------------------------------------------
-- 5. Shared photos (§5): empty here, filled by #331
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.barcode_catalogue_photos (
  gtin14      text PRIMARY KEY CHECK (gtin14 ~ '^[0-9]{14}$'),
  object_path text NOT NULL,
  sha256      text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.barcode_catalogue_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.barcode_catalogue_photos FROM anon, authenticated;

COMMENT ON TABLE public.barcode_catalogue_photos IS
  'ADR 0029 §5: the first photo per GTIN-14. object_path is relative to the '
  'barcode-catalogue-photos bucket. RLS on, no policies: service role only.';

-- ---------------------------------------------------------------------------
-- 6. Lookup index
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_products_factory_gtin14
  ON public.products (public.gtin14(barcode))
  WHERE public.is_factory_gtin(barcode) AND NOT is_deleted;

-- ---------------------------------------------------------------------------
-- 7. Lookup RPC (§3, §4)
-- ---------------------------------------------------------------------------

-- Zero rows, or one row of (name, unit, photo_url).
--
-- Zero rows when: the kill switch is off (or missing), the code is not a
-- factory GTIN, or nothing (no voting name, no voting unit, no photo) exists
-- for it.
--
-- Vote, over non-deleted products whose gtin14(barcode) matches:
--   * one vote per business: its most recently updated matching product;
--   * names are grouped by barcode_catalogue_normalise_name; blocked names
--     for this GTIN are dropped (that business does not fall back to an
--     older product);
--   * most votes wins, a tie goes to max(last_updated_at) in the group;
--   * the name returned is the most common spelling in the winning group
--     (whitespace collapsed and trimmed, case kept), tie: the most recent;
--   * the unit is a separate vote over the same per-business products under
--     the same rules; a product with no unit does not vote.
-- photo_url is the public URL of the barcode_catalogue_photos row for the
-- GTIN, built from the Vault secret `project_url` (NULL if either is absent).
CREATE OR REPLACE FUNCTION public.barcode_suggestion(p_barcode text)
RETURNS TABLE (name text, unit text, photo_url text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
#variable_conflict use_column
DECLARE
  v_code       text := btrim(coalesce(p_barcode, ''));
  v_gtin14     text;
  v_name       text;
  v_unit       text;
  v_photo_path text;
  v_base_url   text;
  v_photo_url  text;
BEGIN
  IF NOT public.is_factory_gtin(v_code) THEN
    RETURN;
  END IF;

  IF NOT coalesce(
    (SELECT ps.value = 'true'::jsonb
       FROM public.platform_settings ps
      WHERE ps.key = 'barcode_catalogue.suggestions_enabled'),
    false
  ) THEN
    RETURN;
  END IF;

  v_gtin14 := public.gtin14(v_code);

  WITH voters AS (
    -- One row per business: its most recently updated matching product.
    -- The WHERE repeats the partial-index predicate so the index is used.
    SELECT DISTINCT ON (p.business_id)
           p.name            AS raw_name,
           p.unit            AS raw_unit,
           p.last_updated_at AS updated_at
      FROM public.products p
     WHERE public.is_factory_gtin(p.barcode)
       AND NOT p.is_deleted
       AND public.gtin14(p.barcode) = v_gtin14
     ORDER BY p.business_id, p.last_updated_at DESC, p.id DESC
  ),
  name_votes AS (
    SELECT public.barcode_catalogue_normalise_name(v.raw_name)   AS norm,
           btrim(regexp_replace(v.raw_name, '\s+', ' ', 'g'))   AS spelling,
           v.updated_at
      FROM voters v
  ),
  allowed_names AS (
    SELECT nv.norm, nv.spelling, nv.updated_at
      FROM name_votes nv
     WHERE nv.norm IS NOT NULL
       AND NOT EXISTS (
             SELECT 1
               FROM public.barcode_catalogue_name_blocks b
              WHERE b.gtin14 = v_gtin14
                AND b.normalised_name = nv.norm)
  ),
  name_winner AS (
    SELECT an.norm
      FROM allowed_names an
     GROUP BY an.norm
     ORDER BY count(*) DESC, max(an.updated_at) DESC, an.norm
     LIMIT 1
  ),
  unit_votes AS (
    SELECT public.barcode_catalogue_normalise_name(v.raw_unit)   AS norm,
           btrim(regexp_replace(v.raw_unit, '\s+', ' ', 'g'))   AS spelling,
           v.updated_at
      FROM voters v
     WHERE public.barcode_catalogue_normalise_name(v.raw_unit) IS NOT NULL
  ),
  unit_winner AS (
    SELECT uv.norm
      FROM unit_votes uv
     GROUP BY uv.norm
     ORDER BY count(*) DESC, max(uv.updated_at) DESC, uv.norm
     LIMIT 1
  )
  SELECT
    (SELECT an.spelling
       FROM allowed_names an
       JOIN name_winner nw ON nw.norm = an.norm
      GROUP BY an.spelling
      ORDER BY count(*) DESC, max(an.updated_at) DESC, an.spelling
      LIMIT 1),
    (SELECT uv.spelling
       FROM unit_votes uv
       JOIN unit_winner uw ON uw.norm = uv.norm
      GROUP BY uv.spelling
      ORDER BY count(*) DESC, max(uv.updated_at) DESC, uv.spelling
      LIMIT 1)
    INTO v_name, v_unit;

  SELECT ph.object_path INTO v_photo_path
    FROM public.barcode_catalogue_photos ph
   WHERE ph.gtin14 = v_gtin14;

  IF v_photo_path IS NOT NULL THEN
    SELECT ds.decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets ds
     WHERE ds.name = 'project_url';
    IF v_base_url IS NOT NULL THEN
      v_photo_url := rtrim(v_base_url, '/')
        || '/storage/v1/object/public/barcode-catalogue-photos/'
        || v_photo_path;
    END IF;
  END IF;

  IF v_name IS NULL AND v_unit IS NULL AND v_photo_url IS NULL THEN
    RETURN;
  END IF;

  name := v_name;
  unit := v_unit;
  photo_url := v_photo_url;
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.barcode_suggestion(text) IS
  'ADR 0029 §3/§4: consensus (name, unit, photo_url) for a factory barcode, '
  'computed live across businesses. Never returns business identity or vote '
  'counts. The only sanctioned cross-tenant read (invariant #5 exception).';

REVOKE ALL ON FUNCTION public.barcode_suggestion(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.barcode_suggestion(text) TO authenticated, service_role;
