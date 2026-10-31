-- 0235_business_billing_issue.sql
--
-- #591 (PRD #584 slice 7). Failed Play renewal: grace period + account hold.
-- DEPENDS ON 0224 + 0225 + 0232 + 0234 (NOT on the gated 0231). Re-issues
-- apply_play_purchase() with the SAME signature (no overload / PGRST203) and
-- keeps 0232's manual-grant rule and 0234's replaced-token rule intact.
-- Idempotent: safe to run twice.
--
-- WHAT THIS ADDS
--   1. businesses.billing_issue text NULL, CHECK IN ('grace','hold').
--      Cloud-authoritative, app-read-only (like subscription_*):
--        * the 0224 UPDATE guard (enforce_subscription_immutable) resets it
--          for authenticated / anon;
--        * the INSERT guard nulls it for authenticated / anon from 0236
--          (deployed together with the gated 0231);
--        * the app never pushes it (not in the businesses push whitelist).
--   2. apply_play_purchase() writes it from the Play state:
--        IN_GRACE_PERIOD (entitled, keeps the plan)          -> 'grace'
--        ON_HOLD that downgrades the business to Free        -> 'hold'
--        ACTIVE / CANCELED / EXPIRED / PAUSED / revoked      -> NULL
--        a lapse kept by a running manual grant or by another
--        entitled purchase (the shop keeps a paid plan)      -> NULL
--        PENDING, and tokens the Edge Function holds or that
--        were replaced (#589, never applied)                 -> unchanged
--      The Play stamp (play_applied_entitlements, 0232) is now written BEFORE
--      the businesses UPDATE so the guard below can tell Play from an admin.
--   3. Manual admin activation clears it: in enforce_subscription_immutable,
--      for any non-customer role, when the row moves to / stays 'active' with a
--      changed status, plan or end date, the writer did not set billing_issue
--      itself, and the new plan + end date are NOT the Play stamp (same 1 s
--      tolerance as 0232) -> billing_issue := NULL. Same edge as 0232: an admin
--      re-saving exactly the values Play wrote is treated as Play.
--   4. One push to the owner on ENTERING grace: AFTER UPDATE OF billing_issue
--      trigger, only when it changes to 'grace' from anything else (one push
--      per grace episode; repeated IN_GRACE_PERIOD RTDNs do not re-send).
--      Same pg_net -> send-push path and Vault secrets as 0215, as a targeted
--      staff push (type 'billing_issue', user_ids = [the owner's users.id]),
--      so staff phones get nothing. Never blocks the update.
--
-- DEPLOY ORDER: this migration, then redeploy send-push AND play-billing-verify
-- (both `--no-verify-jwt`). Until send-push is redeployed it skips the unknown
-- 'billing_issue' type (not_routable), so applying the migration first is safe.

BEGIN;

-- 1. Column ---------------------------------------------------------------------
ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS billing_issue text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'businesses_billing_issue_check'
       AND conrelid = 'public.businesses'::regclass
  ) THEN
    ALTER TABLE public.businesses
      ADD CONSTRAINT businesses_billing_issue_check
      CHECK (billing_issue IN ('grace', 'hold'));
  END IF;
END $$;

-- 2. Play-stamp lookup for the guard (SECURITY DEFINER: the guard runs as the
--    writer's role, which may not read the cloud-only stamp table) -----------
CREATE OR REPLACE FUNCTION public._business_values_play_stamped(
  p_business_id uuid,
  p_plan        text,
  p_period_end  timestamptz
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.play_applied_entitlements e
     WHERE e.business_id = p_business_id
       AND e.plan IS NOT DISTINCT FROM p_plan
       AND ((e.period_end IS NULL AND p_period_end IS NULL)
            OR abs(extract(epoch FROM (e.period_end - p_period_end))) < 1)
  );
$$;

REVOKE ALL ON FUNCTION public._business_values_play_stamped(uuid, text, timestamptz)
  FROM public, anon, authenticated;

-- 3. UPDATE guard (0224 body + billing_issue + manual-activation clear) -------
CREATE OR REPLACE FUNCTION public.enforce_subscription_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    NEW.subscription_status  := OLD.subscription_status;
    NEW.subscription_plan    := OLD.subscription_plan;
    NEW.billing_cycle        := OLD.billing_cycle;
    NEW.trial_ends_at        := OLD.trial_ends_at;
    NEW.current_period_end   := OLD.current_period_end;
    NEW.billing_issue        := OLD.billing_issue;
    RETURN NEW;
  END IF;

  -- #591: an admin activating the shop by hand ends the Play billing issue.
  IF OLD.billing_issue IS NOT NULL
     AND NEW.billing_issue IS NOT DISTINCT FROM OLD.billing_issue
     AND NEW.subscription_status = 'active'
     AND (NEW.subscription_status, NEW.subscription_plan, NEW.current_period_end)
         IS DISTINCT FROM
         (OLD.subscription_status, OLD.subscription_plan, OLD.current_period_end)
     AND NOT public._business_values_play_stamped(
           NEW.id, NEW.subscription_plan, NEW.current_period_end)
  THEN
    NEW.billing_issue := NULL;
  END IF;
  RETURN NEW;
END $$;

-- 4. (moved) The INSERT-guard change for billing_issue lives in 0236, which
--    ships with the gated 0231 (no trials). Until then a customer-role insert
--    could set billing_issue on its own new row: harmless (it only shows that
--    owner a payment banner) and the next Play apply overwrites it.

-- 5. apply_play_purchase (0234 body + billing_issue) --------------------------
CREATE OR REPLACE FUNCTION public.apply_play_purchase(
  p_business_id  uuid,
  p_product_id   text,
  p_base_plan_id text,
  p_state        text,
  p_expiry_time  timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_plan         text;
  v_cycle        text;
  v_entitled     boolean;
  v_other        boolean;
  v_status       text;
  v_cur_plan     text;
  v_cur_end      timestamptz;
  v_play_written boolean;
  v_manual       boolean;
  v_found        boolean;
  v_issue        text;
BEGIN
  v_plan := CASE p_product_id
    WHEN 'reebaplus_basic'   THEN 'basic'
    WHEN 'reebaplus_premium' THEN 'premium'
    ELSE NULL END;
  IF v_plan IS NULL THEN
    RAISE EXCEPTION 'unknown_product %', p_product_id;
  END IF;
  IF p_base_plan_id NOT IN ('monthly', 'yearly') THEN
    RAISE EXCEPTION 'unknown_base_plan %', p_base_plan_id;
  END IF;
  v_cycle := p_base_plan_id;

  v_entitled := p_state IN ('ACTIVE', 'IN_GRACE_PERIOD')
    OR (p_state = 'CANCELED' AND p_expiry_time IS NOT NULL AND p_expiry_time > now());

  -- Lock the business so an app verify and an RTDN cannot interleave.
  SELECT b.subscription_status, b.subscription_plan, b.current_period_end
    INTO v_status, v_cur_plan, v_cur_end
    FROM public.businesses b
   WHERE b.id = p_business_id
   FOR UPDATE;
  v_found := FOUND;

  v_play_written :=
    EXISTS (
      SELECT 1 FROM public.play_applied_entitlements e
       WHERE e.business_id = p_business_id
         AND e.plan IS NOT DISTINCT FROM v_cur_plan
         AND ((e.period_end IS NULL AND v_cur_end IS NULL)
              OR abs(extract(epoch FROM (e.period_end - v_cur_end))) < 1)
    )
    OR EXISTS (
      SELECT 1 FROM public.play_subscription_purchases p
       WHERE p.business_id = p_business_id
         AND p.expiry_time IS NOT NULL
         AND v_cur_end IS NOT NULL
         AND abs(extract(epoch FROM (p.expiry_time - v_cur_end))) < 1
         AND (CASE p.product_id
                WHEN 'reebaplus_basic'   THEN 'basic'
                WHEN 'reebaplus_premium' THEN 'premium'
              END) IS NOT DISTINCT FROM v_cur_plan
    );

  v_manual := COALESCE(
    v_status = 'active'
    AND v_cur_plan IN ('basic', 'premium')
    AND (v_cur_end IS NULL OR v_cur_end > now())
    AND NOT v_play_written,
    false);

  IF v_entitled THEN
    -- A cancelled (winding-down) purchase never replaces a manual grant that
    -- is at least as good on plan AND end date. Not a payment problem.
    IF v_manual AND p_state = 'CANCELED'
       AND (v_cur_end IS NULL OR v_cur_end >= p_expiry_time)
       AND (v_cur_plan = 'premium' OR v_plan = 'basic') THEN
      UPDATE public.businesses SET billing_issue = NULL
       WHERE id = p_business_id AND billing_issue IS NOT NULL;
      RETURN jsonb_build_object('ok', true, 'entitled', true, 'unchanged', true,
                                'kept_manual_grant', true);
    END IF;

    v_issue := CASE WHEN p_state = 'IN_GRACE_PERIOD' THEN 'grace' END;

    -- #591: stamp FIRST, so the guard sees these values as Play-written.
    IF v_found THEN
      INSERT INTO public.play_applied_entitlements AS e
             (business_id, plan, billing_cycle, period_end, applied_at)
      VALUES (p_business_id, v_plan, v_cycle, p_expiry_time, now())
      ON CONFLICT (business_id) DO UPDATE
         SET plan          = EXCLUDED.plan,
             billing_cycle = EXCLUDED.billing_cycle,
             period_end    = EXCLUDED.period_end,
             applied_at    = EXCLUDED.applied_at;
    END IF;

    UPDATE public.businesses
       SET subscription_plan   = v_plan,
           billing_cycle       = v_cycle,
           subscription_status = 'active',
           current_period_end  = p_expiry_time,
           billing_issue       = v_issue
     WHERE id = p_business_id;

    RETURN jsonb_build_object('ok', true, 'entitled', true, 'plan', v_plan,
                              'billing_cycle', v_cycle, 'billing_issue', v_issue);
  END IF;

  -- PENDING never changes entitlement.
  IF p_state = 'PENDING' THEN
    RETURN jsonb_build_object('ok', true, 'entitled', false, 'unchanged', true);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.play_subscription_purchases p
     WHERE p.business_id = p_business_id
       AND p.expiry_time > now()
       AND p.state IN ('ACTIVE', 'IN_GRACE_PERIOD', 'CANCELED')
       AND p.replaced_by_token IS NULL   -- #589: a replaced token entitles nothing
       AND NOT (p.product_id = p_product_id AND p.base_plan_id = p_base_plan_id
                AND p.state = p_state AND p.expiry_time IS NOT DISTINCT FROM p_expiry_time)
  ) INTO v_other;

  -- The shop keeps a paid plan in the next two cases: nothing for the owner
  -- to fix, so no billing issue.
  IF v_other THEN
    UPDATE public.businesses SET billing_issue = NULL
     WHERE id = p_business_id AND billing_issue IS NOT NULL;
    RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', false);
  END IF;

  IF v_manual THEN
    UPDATE public.businesses SET billing_issue = NULL
     WHERE id = p_business_id AND billing_issue IS NOT NULL;
    RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', false,
                              'kept_manual_grant', true);
  END IF;

  v_issue := CASE WHEN p_state = 'ON_HOLD' THEN 'hold' END;

  UPDATE public.businesses
     SET subscription_plan   = 'free',
         billing_cycle       = NULL,
         subscription_status = 'inactive',
         current_period_end  = p_expiry_time,
         billing_issue       = v_issue
   WHERE id = p_business_id;
  RETURN jsonb_build_object('ok', true, 'entitled', false, 'downgraded', true,
                            'billing_issue', v_issue);
END $$;

REVOKE ALL ON FUNCTION public.apply_play_purchase(uuid, text, text, text, timestamptz)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_play_purchase(uuid, text, text, text, timestamptz)
  TO service_role;

-- 6. One owner push on entering grace ------------------------------------------
CREATE OR REPLACE FUNCTION public.send_push_on_billing_grace()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_base_url text;
  v_secret   text;
  v_owner    uuid;
BEGIN
  -- A push problem must never fail or slow the billing update.
  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets WHERE name = 'project_url';
    SELECT decrypted_secret INTO v_secret
      FROM vault.decrypted_secrets WHERE name = 'push_hook_secret';
    IF v_base_url IS NULL OR v_secret IS NULL OR NEW.owner_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- The owner's users.id (devices.last_user_id). Owner only: staff never
    -- get a billing push.
    SELECT u.id INTO v_owner
      FROM public.users u
     WHERE u.business_id = NEW.id
       AND u.auth_user_id = NEW.owner_id
     LIMIT 1;
    IF v_owner IS NULL THEN
      RETURN NEW;
    END IF;

    PERFORM net.http_post(
      url     := v_base_url || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'content-type',       'application/json',
        'x-push-hook-secret', v_secret
      ),
      body    := jsonb_build_object('record', jsonb_build_object(
        'id',          gen_random_uuid(),
        'type',        'billing_issue',
        'severity',    'warning',
        'title',       'Payment didn''t go through',
        'message',     'Your Reebaplus payment didn''t go through. Update it in '
                         || 'Google Play to keep your plan.',
        'business_id', NEW.id,
        'user_ids',    to_jsonb(ARRAY[v_owner]),
        'data',        jsonb_build_object(
          'type',          'billing_issue',
          'billing_issue', 'grace'
        )
      ))
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_send_push_billing_grace ON public.businesses;
CREATE TRIGGER trg_send_push_billing_grace
  AFTER UPDATE OF billing_issue ON public.businesses
  FOR EACH ROW
  WHEN (NEW.billing_issue = 'grace' AND OLD.billing_issue IS DISTINCT FROM 'grace')
  EXECUTE FUNCTION public.send_push_on_billing_grace();

-- TRIGGER function, never a client RPC (keeps it off the /rpc/ surface).
REVOKE EXECUTE ON FUNCTION public.send_push_on_billing_grace()
  FROM PUBLIC, anon, authenticated;

COMMIT;
