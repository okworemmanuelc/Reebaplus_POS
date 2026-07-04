-- 0131_configurable_trial_length.sql
--
-- Reebaplus — make the new-sign-up free-trial length operator-configurable
-- (admin console PRD #37 / issue #42). Until now set_business_trial_end()
-- (migration 0101) hard-coded a 30-day trial. The admin console now owns a single
-- setting, public.console_settings.default_trial_days, written from its System
-- Settings tab via a gated RPC. This amends the POS-owned seeding trigger to READ
-- that value instead of the constant 30.
--
-- CROSS-REPO BOUNDARY: the console_settings table and the console_get_trial_days()
-- getter are created by the CONSOLE repo's supabase/console_access.sql (§13),
-- applied to this same shared Supabase project. This migration only changes the
-- trigger's body — it does NOT create that table (the console owns it).
--
-- WHY call console_get_trial_days() rather than SELECT the table directly: this
-- trigger runs as the signing-up user (role anon/authenticated), and console_settings
-- has admin-only RLS — a direct read would return no rows and silently fall back to
-- 30 always. console_get_trial_days() is SECURITY DEFINER (bypasses that RLS) and is
-- granted to anon+authenticated, so the trigger reads the real configured value.
--
-- FUTURE SIGN-UPS ONLY: the trigger fires BEFORE INSERT, so existing businesses'
-- trial_ends_at is untouched (unchanged from 0101). Per-business trial dates stay
-- editable from the console's subscription manager.
--
-- DEFENSIVE: if the console function is not yet deployed (e.g. this migration runs
-- ahead of console_access.sql §13), the inner block falls back to 30 rather than
-- failing the INSERT; a NULL or out-of-range value also folds to 30.

CREATE OR REPLACE FUNCTION public.set_business_trial_end()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_days integer;
BEGIN
  IF NEW.subscription_status = 'trial' AND NEW.trial_ends_at IS NULL THEN
    BEGIN
      v_days := public.console_get_trial_days();
    EXCEPTION WHEN undefined_function THEN
      v_days := 30;  -- console setting not deployed yet; keep the historical default
    END;
    IF v_days IS NULL OR v_days < 1 OR v_days > 365 THEN
      v_days := 30;
    END IF;
    NEW.trial_ends_at := now() + make_interval(days => v_days);
  END IF;
  RETURN NEW;
END $$;

-- The trg_businesses_set_trial_end trigger (0101) still points at this function;
-- CREATE OR REPLACE swaps the body in place, so no trigger change is needed.
