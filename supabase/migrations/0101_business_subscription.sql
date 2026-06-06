-- 0101_business_subscription.sql
--
-- Reebaplus — app subscription / access gating (master plan §32). The operator
-- manages each business's subscription from the separate web admin console; the
-- POS app only READS this state and locks itself when a business's trial has
-- expired or its status is 'inactive'. There is no in-app payment.
--
-- State lives as four new columns on public.businesses (it already syncs to the
-- device via the dedicated businesses realtime channel + pull, so no new sync
-- plumbing is needed). The columns are CLOUD-AUTHORITATIVE / APP-READ-ONLY:
--   1. the app's push column-whitelist (_pushableColumns['businesses']) omits
--      them, so the device can never push them; and
--   2. the BEFORE UPDATE guard below resets them for the `authenticated`/`anon`
--      roles, so a customer JWT cannot self-activate via a raw PostgREST call.
--
-- CONSOLE REQUIREMENT: the admin console must write these columns with the
-- service_role key (which it already needs — it manages ALL businesses, beyond
-- any single business's RLS scope). service_role and the migration role bypass
-- the guard; an ordinary `authenticated` user is reset to the prior values.
--
-- businesses already SELECTs to its own business (businesses_select, 0002/0062)
-- and already has the trg_businesses_bump_lua BEFORE UPDATE trigger (0001), so a
-- console UPDATE bumps last_updated_at and the device's LWW guard accepts it.

-- 1. Columns -----------------------------------------------------------------
ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS subscription_status text NOT NULL DEFAULT 'trial'
    CHECK (subscription_status IN ('trial','active','inactive')),
  ADD COLUMN IF NOT EXISTS subscription_plan text
    CHECK (subscription_plan IN ('local','international')),
  ADD COLUMN IF NOT EXISTS trial_ends_at timestamptz,
  ADD COLUMN IF NOT EXISTS current_period_end timestamptz;

-- 2. Backfill: every existing business gets a fresh 30-day trial on rollout so
--    no current user is locked out on launch day (master plan §32 "Rollout").
--    Runs as the migration role, so the guard in step 4 does not reset it.
UPDATE public.businesses
   SET subscription_status = 'trial',
       trial_ends_at = now() + interval '30 days'
 WHERE trial_ends_at IS NULL;

-- 3. Auto-trial for new sign-ups. Onboarding (complete_onboarding) inserts the
--    business row without subscription fields; this stamps a 30-day trial so the
--    app side needs no change. Only fills when left at the 'trial' default with
--    no end date — an explicit insert (e.g. a console-created Active row) is kept.
CREATE OR REPLACE FUNCTION public.set_business_trial_end()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.subscription_status = 'trial' AND NEW.trial_ends_at IS NULL THEN
    NEW.trial_ends_at := now() + interval '30 days';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_businesses_set_trial_end
  BEFORE INSERT ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.set_business_trial_end();

-- 4. Immutability guard: the subscription columns are operator-only. For the
--    customer-facing roles (`authenticated` JWTs, `anon`) any change is silently
--    reset to OLD, so a legitimate app UPDATE of name/type/phone still succeeds
--    while subscription_* stays whatever the console last set. service_role and
--    the migration/admin roles pass through. Mirrors enforce_append_only's
--    OLD/NEW shape (0001) but resets instead of raising.
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

CREATE TRIGGER trg_businesses_enforce_subscription
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.enforce_subscription_immutable();
