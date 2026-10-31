-- Rollback for 0231_no_trials.sql.
-- Restores the 'trial' column default and the 0224 body of
-- set_business_trial_end() (same signature), so new sign-ups get a Premium
-- trial again. Does NOT move any business back to trial: the ended-trial ->
-- Free data change is one-way (those trials had already ended).
BEGIN;

ALTER TABLE public.businesses
  ALTER COLUMN subscription_status SET DEFAULT 'trial';

CREATE OR REPLACE FUNCTION public.set_business_trial_end()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_days integer;
BEGIN
  IF NEW.subscription_status = 'trial' AND NEW.trial_ends_at IS NULL THEN
    BEGIN
      v_days := public.console_get_trial_days();
    EXCEPTION WHEN undefined_function THEN
      v_days := 30;
    END;
    IF v_days IS NULL OR v_days < 1 OR v_days > 365 THEN
      v_days := 30;
    END IF;
    NEW.trial_ends_at := now() + make_interval(days => v_days);
  END IF;
  IF NEW.subscription_status = 'trial' AND NEW.subscription_plan IS NULL THEN
    NEW.subscription_plan := 'premium';
  END IF;
  RETURN NEW;
END $$;

DELETE FROM supabase_migrations.schema_migrations WHERE version = '0231';

COMMIT;
