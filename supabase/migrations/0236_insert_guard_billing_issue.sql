-- 0236_insert_guard_billing_issue.sql
--
-- #591 (PRD #584). The INSERT guard (set_business_trial_end) from 0231, plus
-- forcing businesses.billing_issue (0235) to NULL for customer roles.
--
-- DEPLOY GATE: ships TOGETHER WITH 0231 (no trials), i.e. only after phones run
-- the #586 never-lock release. Applying it alone would also start the 0231
-- "new businesses start on Free" behaviour, which old clients render as LOCKED.
-- DEPENDS ON 0231 + 0235. Idempotent.

BEGIN;

CREATE OR REPLACE FUNCTION public.set_business_trial_end()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_days integer;
BEGIN
  -- Customer roles never choose their own subscription (no self-granted trial
  -- or paid plan via a raw PostgREST insert).
  IF current_user IN ('authenticated', 'anon') THEN
    NEW.subscription_status := 'inactive';
    NEW.subscription_plan   := 'free';
    NEW.billing_cycle       := NULL;
    NEW.trial_ends_at       := NULL;
    NEW.current_period_end  := NULL;
    NEW.billing_issue       := NULL;
    RETURN NEW;
  END IF;

  -- Explicit trial from the console / operator: keep the old stamping.
  IF NEW.subscription_status = 'trial' THEN
    IF NEW.trial_ends_at IS NULL THEN
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
    IF NEW.subscription_plan IS NULL THEN
      NEW.subscription_plan := 'premium';
    END IF;
  ELSIF NEW.subscription_status = 'inactive' AND NEW.subscription_plan IS NULL THEN
    NEW.subscription_plan := 'free';
  END IF;
  RETURN NEW;
END $$;

COMMIT;
