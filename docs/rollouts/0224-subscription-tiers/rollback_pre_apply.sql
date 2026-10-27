-- Rollback for 0224_subscription_tiers. Restores the pre-0224 shape.
-- Data note: the plan mapping is lossy. Trial rows go back to a null plan;
-- active premium -> 'international'; active basic/free -> 'local'.
-- billing_cycle values are dropped with the column.
BEGIN;

DROP TRIGGER IF EXISTS trg_stores_plan_limit ON public.stores;
DROP TRIGGER IF EXISTS trg_invite_codes_plan_limit ON public.invite_codes;
DROP TRIGGER IF EXISTS trg_user_businesses_plan_limit ON public.user_businesses;
DROP FUNCTION IF EXISTS public.enforce_plan_limit_stores();
DROP FUNCTION IF EXISTS public.enforce_plan_limit_invites();
DROP FUNCTION IF EXISTS public.enforce_plan_limit_staff();
DROP FUNCTION IF EXISTS public.business_effective_plan(uuid);
DROP FUNCTION IF EXISTS public.business_plan_limits(text);

-- 0101 guard (without billing_cycle)
CREATE OR REPLACE FUNCTION public.enforce_subscription_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    NEW.subscription_status  := OLD.subscription_status;
    NEW.subscription_plan    := OLD.subscription_plan;
    NEW.trial_ends_at        := OLD.trial_ends_at;
    NEW.current_period_end   := OLD.current_period_end;
  END IF;
  RETURN NEW;
END $$;

-- 0131 seeding trigger (no plan seeding)
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
  RETURN NEW;
END $$;

ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS businesses_subscription_plan_check;
UPDATE public.businesses SET subscription_plan = NULL WHERE subscription_status = 'trial';
UPDATE public.businesses SET subscription_plan = 'international' WHERE subscription_plan = 'premium';
UPDATE public.businesses SET subscription_plan = 'local' WHERE subscription_plan IN ('basic','free');
ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_subscription_plan_check
    CHECK (subscription_plan IN ('local','international'));

ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS businesses_billing_cycle_check;
ALTER TABLE public.businesses DROP COLUMN IF EXISTS billing_cycle;

COMMIT;
