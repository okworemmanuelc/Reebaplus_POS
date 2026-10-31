-- 0231_no_trials.sql
--
-- Reebaplus - no more free trials (#587, PRD #584 slice 3).
--
-- Every NEW business starts on the Free plan:
--   subscription_status = 'inactive', subscription_plan = 'free',
--   trial_ends_at = NULL.
-- 'inactive' + 'free' simply means Free (1 store, 1 staff incl. the owner).
-- The app never locks any more (#586), so this is not a lock-out.
--
-- What stamped a trial before, and what changes here:
--   1. Column default businesses.subscription_status = 'trial' (0101).
--      -> default 'inactive'. subscription_plan gets NO column default: a
--      default is applied before BEFORE triggers run, so it would hide an
--      operator 'trial' insert's NULL plan from the trigger below. The
--      trigger fills 'free' instead.
--   2. BEFORE INSERT trigger trg_businesses_set_trial_end ->
--      set_business_trial_end() (0101, 0131, 0224) stamped trial_ends_at and
--      plan 'premium' on a 'trial' row. complete_onboarding (0178, SECURITY
--      DEFINER) inserts the business without subscription columns, so it got
--      the trial from (1) + (2). Same signature re-issued (no overload):
--        * customer roles (authenticated / anon) can no longer insert any
--          subscription value: the row is forced to inactive/free/NULLs (the
--          0101/0224 guard only covered UPDATE).
--        * an explicit 'trial' insert by service_role (the admin console) or
--          the migration role is still honoured and still gets its end date
--          (console_get_trial_days()) and plan 'premium', so the console can
--          set any status.
--        * otherwise a NULL plan on an 'inactive' row becomes 'free'.
--   No other RPC writes subscription columns on insert (grep of migrations).
--
-- Data: ended trials (status 'trial', trial_ends_at <= now()) move to
-- inactive/free. Running trials (trial_ends_at > now()) and grace rows
-- (trial_ends_at NULL) are left alone and finish naturally. trial_ends_at is
-- kept as history. Runs as the migration owner, so the 0224 UPDATE guard
-- (enforce_subscription_immutable, resets only for authenticated/anon) does
-- not block it. trg_businesses_bump_lua bumps last_updated_at, so devices pull
-- the change.
--
-- Idempotent: SET DEFAULT, CREATE OR REPLACE and the guarded UPDATE can all be
-- re-run safely.
--
-- Rollback: docs/rollouts/0231-no-trials/rollback.sql restores the 0224
-- trigger body and the 'trial' default. It does NOT move businesses back to
-- trial (the data change is one-way by design).

BEGIN;

-- 1. Column defaults ------------------------------------------------------------
ALTER TABLE public.businesses
  ALTER COLUMN subscription_status SET DEFAULT 'inactive';

-- 2. Insert trigger: new businesses start on Free --------------------------------
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

-- trg_businesses_set_trial_end (0101) still points at this function; make sure
-- it exists (idempotent) in case an environment lost it.
DROP TRIGGER IF EXISTS trg_businesses_set_trial_end ON public.businesses;
CREATE TRIGGER trg_businesses_set_trial_end
  BEFORE INSERT ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.set_business_trial_end();

-- 3. Data: ended trials move to Free -------------------------------------------
UPDATE public.businesses
   SET subscription_status = 'inactive',
       subscription_plan   = 'free'
 WHERE subscription_status = 'trial'
   AND trial_ends_at <= now();

COMMIT;
