-- migration: 0184_barcode_catalogue_report_fix
--
-- Issue #335 follow-up to 0183. 0183's report_barcode_catalogue_entry
-- filtered the caller's staff row on users.is_deleted, a column that exists
-- in Drift but NOT on public.users in the cloud (cloud users rows are
-- hard-deleted). Every call failed with 42703. No app build calls the RPC
-- yet, so nothing was lost.
--
-- Same signature, so CREATE OR REPLACE replaces it in place (no overload).
-- Grants are re-asserted for clarity; they survive a replace anyway.

-- Raises:
--   42501 when the caller is not signed in, is not a member of p_business_id,
--         or has no users row in it;
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
     AND u.business_id = p_business_id;
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
