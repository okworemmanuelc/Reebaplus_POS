-- 0223_backfill_business_timezone_from_currency.sql
--
-- #63 (reebaplus-web): CEO sign-up hardcoded settings.timezone = 'Africa/Lagos'
-- for every business, so non-Nigerian businesses cut business days, daily
-- closings and reports on Lagos time. The app now derives the timezone from the
-- chosen country (lib/core/data/timezones.dart); this repairs existing rows.
--
-- The business country is not stored on its own column, so the repair keys off
-- settings.default_currency, and ONLY for currencies used by a single timezone.
-- Ambiguous currencies (NGN, XOF, XAF, EUR, USD, CAD) are left untouched, and
-- only rows still holding the old 'Africa/Lagos' default are changed, so any
-- timezone a user chose deliberately is never overwritten. Idempotent.
--
-- settings.last_updated_at is advanced explicitly below
-- so shop phones pull the corrected value.
--
-- DEPLOY: additive data fix; no schema change. Review the dry-run SELECT below
-- before applying. NOT applied to any database by the PR that adds it.
--
--   SELECT s.business_id, c.value AS currency
--   FROM public.settings s
--   JOIN public.settings c ON c.business_id = s.business_id
--                         AND c.key = 'default_currency'
--   WHERE s.key = 'timezone' AND s.value = 'Africa/Lagos' AND c.value <> 'NGN';

WITH currency_zone(currency, tz) AS (
  VALUES
    ('AFN', 'Asia/Kabul'),
    ('AED', 'Asia/Dubai'),
    ('CNY', 'Asia/Shanghai'),
    ('EGP', 'Africa/Cairo'),
    ('GBP', 'Europe/London'),
    ('GHS', 'Africa/Accra'),
    ('INR', 'Asia/Kolkata'),
    ('KES', 'Africa/Nairobi'),
    ('LRD', 'Africa/Monrovia'),
    ('MAD', 'Africa/Casablanca'),
    ('RWF', 'Africa/Kigali'),
    ('SLL', 'Africa/Freetown'),
    ('TZS', 'Africa/Dar_es_Salaam'),
    ('UGX', 'Africa/Kampala'),
    ('ZAR', 'Africa/Johannesburg'),
    ('ZMW', 'Africa/Lusaka'),
    ('ZWL', 'Africa/Harare')
)
UPDATE public.settings s
   SET value = z.tz,
       last_updated_at = now()
  FROM public.settings c
  JOIN currency_zone z ON z.currency = upper(trim(c.value))
 WHERE s.key = 'timezone'
   AND s.value = 'Africa/Lagos'
   AND c.business_id = s.business_id
   AND c.key = 'default_currency';
