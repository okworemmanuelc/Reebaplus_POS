-- migration: 0124_drop_legacy_complete_onboarding_overload
-- 0123 added p_tracks_empty_crates to complete_onboarding via CREATE OR REPLACE.
-- Because the new parameter changes the signature, Postgres created a SECOND
-- overload (11 args) alongside the original 10-arg function instead of replacing
-- it. With both present, an older client that calls complete_onboarding with the
-- original 10 named args matches BOTH candidates (the 11-arg one defaults the new
-- param), so PostgREST raises PGRST203 "could not choose the best candidate
-- function" — defeating the DEFAULT-true backward-compat intent.
--
-- Drop the legacy 10-arg overload. The 11-arg version (p_tracks_empty_crates
-- boolean DEFAULT true) fully covers older callers, who now resolve to it and
-- get the default.

DROP FUNCTION IF EXISTS public.complete_onboarding(
  uuid,   -- p_business_id
  uuid,   -- p_store_id
  text,   -- p_owner_name
  text,   -- p_business_name
  text,   -- p_business_type
  text,   -- p_business_phone
  text,   -- p_business_email
  jsonb,  -- p_location
  jsonb,  -- p_settings
  uuid    -- p_user_id
);
