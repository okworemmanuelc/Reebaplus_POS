-- 0224_subscription_tiers.sql
--
-- Reebaplus - subscription tiers (reebaplus-web#90, slice A).
--
-- Replaces the legacy 'local' | 'international' plans with the volume-free
-- Free / Basic / Premium model: plans differ ONLY by stores + staff accounts.
--
--   Plan     stores       staff (incl. owner)   warehouse (van-sales source)
--   free     1            1                     no
--   basic    1            5                     no
--   premium  unlimited    unlimited             yes
--
-- Trial = 30 days (console-configurable, 0131) of PREMIUM. When the trial ends
-- unpaid the business is effectively 'free'. NOTHING is ever deleted or blocked
-- from selling: limits are enforced only when ADDING a store, INVITING staff or
-- ACTIVATING staff. Existing over-limit data stays (the client pauses extra
-- staff / makes extra stores read-only; see docs/rollouts/0224-subscription-tiers).
--
-- Storage (unchanged shape): businesses.subscription_status ('trial'|'active'|
-- 'inactive'), subscription_plan (now free|basic|premium, nullable),
-- trial_ends_at, current_period_end. New: billing_cycle ('monthly'|'yearly').
--
-- Enforcement is by BEFORE INSERT/UPDATE triggers (not RPCs) because stores,
-- invite_codes and user_businesses are written both by the offline-first sync
-- push (direct upserts) and by redeem_invite_code; a trigger covers every path.
-- Each trigger skips rows that already exist (an upsert of an existing row must
-- never be blocked by a later downgrade). Errors: SQLSTATE P0001 with message
-- 'plan_limit_stores' | 'plan_limit_staff' | 'plan_limit_warehouse'.
--
-- ASSUMPTION (flag for review): there is no separate 'warehouse' store kind;
-- stores.kind is 'store' | 'van'. Vans are loaded from a warehouse (van-sales
-- spec), so creating a van is the "warehouse" feature gated by
-- plan_limit_warehouse. Vans do not count toward max_stores.

BEGIN;

-- 1. Columns / constraints -----------------------------------------------------
ALTER TABLE public.businesses
  DROP CONSTRAINT IF EXISTS businesses_subscription_plan_check;

UPDATE public.businesses SET subscription_plan = 'basic'   WHERE subscription_plan = 'local';
UPDATE public.businesses SET subscription_plan = 'premium' WHERE subscription_plan = 'international';
UPDATE public.businesses SET subscription_plan = 'premium'
 WHERE subscription_status = 'trial' AND subscription_plan IS NULL;

ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_subscription_plan_check
    CHECK (subscription_plan IN ('free','basic','premium'));

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS billing_cycle text;

ALTER TABLE public.businesses
  DROP CONSTRAINT IF EXISTS businesses_billing_cycle_check;
ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_billing_cycle_check
    CHECK (billing_cycle IN ('monthly','yearly'));

-- 2. Operator-only guard now also covers billing_cycle (0101) ------------------
CREATE OR REPLACE FUNCTION public.enforce_subscription_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    NEW.subscription_status  := OLD.subscription_status;
    NEW.subscription_plan    := OLD.subscription_plan;
    NEW.billing_cycle        := OLD.billing_cycle;
    NEW.trial_ends_at        := OLD.trial_ends_at;
    NEW.current_period_end   := OLD.current_period_end;
  END IF;
  RETURN NEW;
END $$;

-- 3. New sign-ups: plan 'premium' + trial (body of 0131 plus the plan) ---------
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

-- 4. Plan limits + effective plan ----------------------------------------------
-- null = unlimited. Staff count includes the owner. Unknown plan => free.
CREATE OR REPLACE FUNCTION public.business_plan_limits(p_plan text)
RETURNS TABLE (max_stores int, max_staff int, warehouse_allowed boolean)
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT t.max_stores, t.max_staff, t.warehouse_allowed
    FROM (VALUES
      ('free'::text,    1,          1,          false),
      ('basic'::text,   1,          5,          false),
      ('premium'::text, NULL::int,  NULL::int,  true)
    ) AS t(plan, max_stores, max_staff, warehouse_allowed)
   WHERE t.plan = CASE WHEN p_plan IN ('free','basic','premium') THEN p_plan ELSE 'free' END
$$;

CREATE OR REPLACE FUNCTION public.business_effective_plan(p_business_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (SELECT CASE
              WHEN b.subscription_status = 'trial'
                   AND (b.trial_ends_at IS NULL OR b.trial_ends_at > now())
                THEN 'premium'
              WHEN b.subscription_status = 'active'
                   AND (b.current_period_end IS NULL OR b.current_period_end > now())
                THEN COALESCE(b.subscription_plan, 'free')
              ELSE 'free'
            END
       FROM public.businesses b
      WHERE b.id = p_business_id),
    'free')
$$;

REVOKE ALL ON FUNCTION public.business_effective_plan(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.business_effective_plan(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.business_plan_limits(text) TO authenticated, anon;

-- 5. Enforcement triggers --------------------------------------------------------
-- 5a. stores: extra 'store' beyond max_stores, or any 'van' without warehouse.
CREATE OR REPLACE FUNCTION public.enforce_plan_limit_stores()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim record;
  v_count int;
BEGIN
  IF NEW.is_deleted THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.stores s WHERE s.id = NEW.id) THEN
    RETURN NEW;  -- upsert of an existing row: never block
  END IF;
  SELECT * INTO v_lim
    FROM public.business_plan_limits(public.business_effective_plan(NEW.business_id));
  IF NEW.kind = 'van' THEN
    IF NOT v_lim.warehouse_allowed THEN
      RAISE EXCEPTION 'plan_limit_warehouse' USING ERRCODE = 'P0001',
        HINT = 'Warehouse and van sales need the Premium plan.';
    END IF;
  ELSIF v_lim.max_stores IS NOT NULL THEN
    SELECT count(*) INTO v_count FROM public.stores s
     WHERE s.business_id = NEW.business_id AND s.kind = 'store' AND NOT s.is_deleted;
    IF v_count >= v_lim.max_stores THEN
      RAISE EXCEPTION 'plan_limit_stores' USING ERRCODE = 'P0001',
        HINT = 'Your plan allows ' || v_lim.max_stores || ' store(s). Upgrade to Premium for more.';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_stores_plan_limit ON public.stores;
CREATE TRIGGER trg_stores_plan_limit
  BEFORE INSERT ON public.stores
  FOR EACH ROW EXECUTE FUNCTION public.enforce_plan_limit_stores();

-- 5b. invite_codes: pending invites + active staff must stay within max_staff.
CREATE OR REPLACE FUNCTION public.enforce_plan_limit_invites()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim record;
  v_count int;
BEGIN
  IF NEW.is_deleted OR NEW.revoked_at IS NOT NULL OR NEW.used_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM public.invite_codes i WHERE i.id = NEW.id) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_lim
    FROM public.business_plan_limits(public.business_effective_plan(NEW.business_id));
  IF v_lim.max_staff IS NOT NULL THEN
    SELECT (SELECT count(*) FROM public.user_businesses ub
             WHERE ub.business_id = NEW.business_id AND ub.status = 'active')
         + (SELECT count(*) FROM public.invite_codes i
             WHERE i.business_id = NEW.business_id AND NOT i.is_deleted
               AND i.used_at IS NULL AND i.revoked_at IS NULL
               AND i.expires_at > now())
      INTO v_count;
    IF v_count >= v_lim.max_staff THEN
      RAISE EXCEPTION 'plan_limit_staff' USING ERRCODE = 'P0001',
        HINT = 'Your plan allows ' || v_lim.max_staff || ' staff account(s). Upgrade for more.';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_invite_codes_plan_limit ON public.invite_codes;
CREATE TRIGGER trg_invite_codes_plan_limit
  BEFORE INSERT ON public.invite_codes
  FOR EACH ROW EXECUTE FUNCTION public.enforce_plan_limit_invites();

-- 5c. user_businesses: redeeming an invite (or re-activating a suspended member)
--     must not push active staff past max_staff. The owner's own row at
--     onboarding passes (new sign-ups are on a Premium trial).
CREATE OR REPLACE FUNCTION public.enforce_plan_limit_staff()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim record;
  v_count int;
BEGIN
  IF NEW.status <> 'active' THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    IF EXISTS (SELECT 1 FROM public.user_businesses ub
                WHERE ub.id = NEW.id
                   OR (ub.user_id = NEW.user_id AND ub.business_id = NEW.business_id)) THEN
      RETURN NEW;
    END IF;
  ELSIF OLD.status = 'active' THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_lim
    FROM public.business_plan_limits(public.business_effective_plan(NEW.business_id));
  IF v_lim.max_staff IS NOT NULL THEN
    SELECT count(*) INTO v_count FROM public.user_businesses ub
     WHERE ub.business_id = NEW.business_id AND ub.status = 'active';
    IF v_count >= v_lim.max_staff THEN
      RAISE EXCEPTION 'plan_limit_staff' USING ERRCODE = 'P0001',
        HINT = 'Your plan allows ' || v_lim.max_staff || ' staff account(s). Upgrade for more.';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_user_businesses_plan_limit ON public.user_businesses;
CREATE TRIGGER trg_user_businesses_plan_limit
  BEFORE INSERT OR UPDATE OF status ON public.user_businesses
  FOR EACH ROW EXECUTE FUNCTION public.enforce_plan_limit_staff();

COMMIT;
