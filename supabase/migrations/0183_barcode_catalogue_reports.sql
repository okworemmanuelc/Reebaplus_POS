-- migration: 0183_barcode_catalogue_reports
--
-- Issue #335, slice 4 of PRD #322 (decisions: docs/adr/0029-shared-barcode-catalogue.md §6).
-- Shops report a wrong name, a wrong unit, or a bad or private photo in the
-- shared barcode catalogue from product details. Reports are private to
-- Reebaplus: a developer reads them with the service role and applies a block
-- by hand (runbook in ADR 0029 §6).
--
-- What this adds:
--   1. public.barcode_catalogue_reports: RLS on, NO policies, no grants to
--      anon/authenticated. Not synced, not in Drift.
--   2. A partial unique index: one OPEN report per business per GTIN-14.
--   3. public.report_barcode_catalogue_entry(...): the only write path. A
--      definer RPC that takes the business from the caller's memberships and
--      the reporter from the caller's own users row, never from the client.
--      A repeat report (same business, same GTIN, still open) updates that
--      row's reasons, note and shown values instead of inserting (the first
--      reporter is kept). Returns void,
--      so a shop can never read any report back.
--
-- Deletes: a deleted business (or user) leaves its reports; business_id and
-- reported_by are set to null.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.barcode_catalogue_reports (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gtin14          text NOT NULL CHECK (gtin14 ~ '^[0-9]{14}$'),
  reasons         text[] NOT NULL CHECK (
                    cardinality(reasons) > 0
                    AND array_position(reasons, NULL) IS NULL
                    AND reasons <@ ARRAY['wrong_name', 'wrong_unit', 'bad_photo']::text[]
                  ),
  note            text CHECK (note IS NULL OR char_length(note) <= 500),
  shown_name      text,
  shown_unit      text,
  shown_photo_url text,
  business_id     uuid REFERENCES public.businesses(id) ON DELETE SET NULL,
  reported_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
  status          text NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open', 'resolved', 'dismissed')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz
);

ALTER TABLE public.barcode_catalogue_reports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.barcode_catalogue_reports FROM anon, authenticated;

COMMENT ON TABLE public.barcode_catalogue_reports IS
  'ADR 0029 §6: shop reports about a shared barcode catalogue entry. Written '
  'only by report_barcode_catalogue_entry. RLS on, no policies: service role '
  'only. Never synced, never read by a client.';

-- ---------------------------------------------------------------------------
-- 2. One open report per business per GTIN
-- ---------------------------------------------------------------------------

-- The RPC's ON CONFLICT targets this index, so two reports sent at the same
-- moment still end as one row. A row whose business was deleted has a NULL
-- business_id and never conflicts.
CREATE UNIQUE INDEX IF NOT EXISTS barcode_catalogue_reports_one_open
  ON public.barcode_catalogue_reports (business_id, gtin14)
  WHERE status = 'open';

-- The runbook reads open reports, oldest first.
CREATE INDEX IF NOT EXISTS barcode_catalogue_reports_status_created
  ON public.barcode_catalogue_reports (status, created_at);

-- FK indexes so the ON DELETE SET NULL cascades don't scan the table.
CREATE INDEX IF NOT EXISTS barcode_catalogue_reports_business_id
  ON public.barcode_catalogue_reports (business_id);
CREATE INDEX IF NOT EXISTS barcode_catalogue_reports_reported_by
  ON public.barcode_catalogue_reports (reported_by);

-- ---------------------------------------------------------------------------
-- 3. Report RPC
-- ---------------------------------------------------------------------------

-- Raises:
--   42501 when the caller is not signed in, is not a member of p_business_id,
--         or has no active users row in it;
--   22023 when p_barcode is not a factory GTIN, p_reasons is empty or holds an
--         unknown/NULL reason, or the note is longer than 500 characters.
-- The shown_* values are what the sheet displayed; they are trimmed and
-- capped (name/unit 200, URL 1000 characters) so a client can't store a
-- novel. A blank note is stored as NULL.
CREATE OR REPLACE FUNCTION public.report_barcode_catalogue_entry(
  p_business_id     uuid,
  p_barcode         text,
  p_reasons         text[],
  p_note            text,
  p_shown_name      text,
  p_shown_unit      text,
  p_shown_photo_url text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_code    text := btrim(coalesce(p_barcode, ''));
  v_user_id uuid;
  v_reasons text[];
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.current_user_business_ids() b(id)
        WHERE b.id = p_business_id)
  THEN
    RAISE EXCEPTION 'not a member of this business' USING ERRCODE = '42501';
  END IF;

  SELECT u.id INTO v_user_id
    FROM public.users u
   WHERE u.auth_user_id = v_uid
     AND u.business_id = p_business_id
     AND NOT u.is_deleted;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'no staff record in this business' USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_factory_gtin(v_code) THEN
    RAISE EXCEPTION 'not a factory barcode' USING ERRCODE = '22023';
  END IF;

  IF p_reasons IS NULL
     OR cardinality(p_reasons) = 0
     OR array_position(p_reasons, NULL) IS NOT NULL
     OR NOT (p_reasons <@ ARRAY['wrong_name', 'wrong_unit', 'bad_photo']::text[])
  THEN
    RAISE EXCEPTION 'invalid reasons' USING ERRCODE = '22023';
  END IF;
  v_reasons := ARRAY(SELECT DISTINCT r FROM unnest(p_reasons) AS t(r) ORDER BY r);

  IF char_length(v_note) > 500 THEN
    RAISE EXCEPTION 'note is longer than 500 characters' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.barcode_catalogue_reports AS r (
    gtin14, reasons, note, shown_name, shown_unit, shown_photo_url,
    business_id, reported_by
  )
  VALUES (
    public.gtin14(v_code),
    v_reasons,
    v_note,
    left(nullif(btrim(coalesce(p_shown_name, '')), ''), 200),
    left(nullif(btrim(coalesce(p_shown_unit, '')), ''), 200),
    left(nullif(btrim(coalesce(p_shown_photo_url, '')), ''), 1000),
    p_business_id,
    v_user_id
  )
  ON CONFLICT (business_id, gtin14) WHERE status = 'open'
  DO UPDATE SET
    reasons         = EXCLUDED.reasons,
    note            = EXCLUDED.note,
    shown_name      = EXCLUDED.shown_name,
    shown_unit      = EXCLUDED.shown_unit,
    shown_photo_url = EXCLUDED.shown_photo_url;
END;
$function$;

COMMENT ON FUNCTION public.report_barcode_catalogue_entry(uuid, text, text[], text, text, text, text) IS
  'ADR 0029 §6: a shop reports a problem with a shared barcode catalogue '
  'entry. Business and reporter come from the caller; one open report per '
  'business per GTIN (a repeat updates it). Returns nothing.';

REVOKE ALL ON FUNCTION public.report_barcode_catalogue_entry(uuid, text, text[], text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_barcode_catalogue_entry(uuid, text, text[], text, text, text, text)
  TO authenticated, service_role;
