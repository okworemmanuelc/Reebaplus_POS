-- 0218_shopper_notifications.sql
--
-- #434 (Online ordering 13/28, PRD #421): tell the Shopper when the shop
-- answers or moves their Online Order. Server half only. Order updates are
-- transactional, so they go out without marketing consent (#477). Status is
-- always visible in My Orders; the push / email is an alert only.
--
-- EVENTS (online_orders.status values from 0205/0208; "changed" is not a
-- status — the app shows "Changed" when an accepted order has a line with
-- accepted_qty < requested_qty, see shopper_models.dart):
--   accepted   new -> accepted, every line has accepted_qty = requested_qty
--   changed    new -> accepted with a lowered/removed line, OR an accepted
--              order's accepted_qty lowered afterwards
--   declined   new -> declined
--   cancelled  accepted -> cancelled_by_shop (the shop's cancel ONLY;
--              cancelled_by_customer — the Shopper's own cancel — and expired
--              never notify)
--   sent_out   accepted -> fulfilled
--
-- WHY A SECOND TRIGGER ON THE LINES. A shop phone's accept pushes the header
-- (online_orders, parent FK priority) BEFORE the lines' accepted_qty. When the
-- header flips to `accepted` the lines are usually still NULL, so the header
-- trigger cannot yet tell accepted from changed. Rule: the accepted/changed
-- notice fires from whichever write COMPLETES "status = accepted AND no line
-- has accepted_qty NULL" — the header trigger if the lines landed first, else
-- the statement-level lines trigger (one notice per order per statement, via
-- transition tables, so a batched lines upsert never sends twice).
--
-- ROUTING (per Shopper auth user = online_orders.shopper_account_id):
--   * Android push when that login has a live Android FCM token
--     (devices.auth_user_id, 0200; platform 'android', 0129; token +
--     permission, 0159) -> `send-push`, type 'shopper_online_order',
--     keyed by auth_user_id, no business (send-push's Shopper route).
--   * otherwise (web-link / iPhone Shoppers) email to auth.users.email ->
--     `send-email`, template order_<event>.
--   Both reuse the Vault secrets project_url + push_hook_secret and the
--   x-push-hook-secret header (0159/0215). No new secret.
--
-- NEVER BLOCKS A WRITE: every body runs inside BEGIN ... EXCEPTION WHEN OTHERS
-- THEN NULL, pg_net is async, and an unconfigured project (no Vault secrets)
-- is a silent no-op. Re-push upserts with an unchanged status / qty never
-- re-send (WHEN clause / transition-table diff).
--
-- No table, column or status change; no Drift change. DEPLOY: this migration,
-- then `send-push` and the new `send-email` (both --no-verify-jwt). Before
-- the functions are redeployed, the old send-push already routes shopper_*
-- records (just without the Android-only filter and data keys) and send-email
-- calls 404 harmlessly. Does not depend on 0193; never together with it.

BEGIN;

-- ── 1. accepted vs changed, once every line is decided ───────────────────────
-- NULL while any line still has accepted_qty NULL (the lines have not landed).
CREATE OR REPLACE FUNCTION public._shopper_order_accept_event(p_order_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.online_order_lines l
                  WHERE l.online_order_id = p_order_id
                    AND l.accepted_qty IS NULL) THEN NULL
    WHEN EXISTS (SELECT 1 FROM public.online_order_lines l
                  WHERE l.online_order_id = p_order_id
                    AND l.accepted_qty < l.requested_qty) THEN 'changed'
    ELSE 'accepted'
  END;
$function$;

-- ── 2. Is this login reachable by Android push? ──────────────────────────────
CREATE OR REPLACE FUNCTION public._shopper_has_android_push(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.devices d
     WHERE d.auth_user_id = p_auth_user_id
       AND d.fcm_token IS NOT NULL
       AND d.platform = 'android'
       AND d.push_permission_granted IS NOT FALSE
  );
$function$;

-- ── 3. Send one notice (push or email) ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public._notify_shopper_order(
  p_order_id uuid,
  p_event    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_base_url text;
  v_secret   text;
  v_shopper  uuid;
  v_ref      text;
  v_name     text;
  v_biz      text;
  v_phone    text;
  v_reason   text;
  v_email    text;
  v_title    text;
  v_message  text;
BEGIN
  IF p_event NOT IN ('accepted', 'changed', 'declined', 'cancelled', 'sent_out') THEN
    RETURN;
  END IF;
  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets WHERE name = 'project_url';
    SELECT decrypted_secret INTO v_secret
      FROM vault.decrypted_secrets WHERE name = 'push_hook_secret';
    IF v_base_url IS NULL OR v_secret IS NULL THEN
      RETURN;
    END IF;

    SELECT o.shopper_account_id, o.reference, o.shopper_name, b.name,
           coalesce(nullif(btrim(s.phone), ''), nullif(btrim(b.phone), '')),
           CASE p_event WHEN 'declined' THEN o.decline_reason
                        WHEN 'cancelled' THEN o.cancel_reason END
      INTO v_shopper, v_ref, v_name, v_biz, v_phone, v_reason
      FROM public.online_orders o
      JOIN public.businesses b ON b.id = o.business_id
      JOIN public.stores s ON s.id = o.store_id
     WHERE o.id = p_order_id;
    -- No Shopper login (account deleted, #438 unlinked it): nobody to tell.
    IF v_shopper IS NULL THEN
      RETURN;
    END IF;

    IF public._shopper_has_android_push(v_shopper) THEN
      v_title := CASE p_event
        WHEN 'accepted'  THEN 'Order accepted'
        WHEN 'changed'   THEN 'Order changed'
        WHEN 'declined'  THEN 'Order declined'
        WHEN 'cancelled' THEN 'Order cancelled'
        WHEN 'sent_out'  THEN 'Order sent out'
      END;
      v_message := v_biz || CASE p_event
        WHEN 'accepted'  THEN ' accepted your order ' || v_ref || '.'
        WHEN 'changed'   THEN ' changed your order ' || v_ref || '. See what is coming in My Orders.'
        WHEN 'declined'  THEN ' declined your order ' || v_ref || '.'
        WHEN 'cancelled' THEN ' cancelled your order ' || v_ref || '.'
        WHEN 'sent_out'  THEN ' sent out your order ' || v_ref || '.'
      END || coalesce(' Reason: ' || nullif(btrim(v_reason), ''), '');

      PERFORM net.http_post(
        url     := v_base_url || '/functions/v1/send-push',
        headers := jsonb_build_object(
          'content-type',       'application/json',
          'x-push-hook-secret', v_secret
        ),
        body    := jsonb_build_object('record', jsonb_build_object(
          'id',           p_order_id,
          'type',         'shopper_online_order',
          'severity',     'info',
          'title',        v_title,
          'message',      v_message,
          'auth_user_id', v_shopper,
          'data',         jsonb_build_object(
            'online_order_id', p_order_id,
            'event',           p_event
          )
        ))
      );
    ELSE
      SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_shopper;
      IF nullif(btrim(v_email), '') IS NULL THEN
        RETURN;
      END IF;
      PERFORM net.http_post(
        url     := v_base_url || '/functions/v1/send-email',
        headers := jsonb_build_object(
          'content-type',       'application/json',
          'x-push-hook-secret', v_secret
        ),
        body    := jsonb_build_object(
          'template', 'order_' || p_event,
          'to',       v_email,
          'data',     jsonb_build_object(
            'reference',     v_ref,
            'shopper_name',  v_name,
            'business_name', v_biz,
            'store_phone',   v_phone,
            'reason',        v_reason
          )
        )
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public._shopper_order_accept_event(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._shopper_has_android_push(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._notify_shopper_order(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._shopper_order_accept_event(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._shopper_has_android_push(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._notify_shopper_order(uuid, text) TO service_role;

-- ── 4. Header trigger: status changes ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_shopper_on_online_order_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event text;
BEGIN
  BEGIN
    v_event := CASE NEW.status
      -- NULL while the lines are still pending: the lines trigger sends it.
      WHEN 'accepted'          THEN public._shopper_order_accept_event(NEW.id)
      WHEN 'declined'          THEN 'declined'
      WHEN 'cancelled_by_shop' THEN 'cancelled'
      WHEN 'fulfilled'         THEN 'sent_out'
      -- cancelled_by_customer (the Shopper's own cancel) and expired: silent.
    END;
    IF v_event IS NOT NULL THEN
      PERFORM public._notify_shopper_order(NEW.id, v_event);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_shopper_online_order ON public.online_orders;
CREATE TRIGGER trg_notify_shopper_online_order
  AFTER UPDATE ON public.online_orders
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status
        AND NEW.status IN ('accepted', 'declined', 'cancelled_by_shop', 'fulfilled'))
  EXECUTE FUNCTION public.notify_shopper_on_online_order_update();

REVOKE EXECUTE ON FUNCTION public.notify_shopper_on_online_order_update()
  FROM PUBLIC, anon, authenticated;

-- ── 5. Lines trigger: accept completed after the header, or a later lower ────
-- Statement level with transition tables: one notice per order per statement,
-- however many lines the batched upsert touched.
CREATE OR REPLACE FUNCTION public.notify_shopper_on_online_order_lines_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  r       record;
  v_event text;
BEGIN
  BEGIN
    FOR r IN
      SELECT n.online_order_id,
             bool_or(o.accepted_qty IS NULL AND n.accepted_qty IS NOT NULL) AS decided,
             bool_or(o.accepted_qty IS NOT NULL
                     AND n.accepted_qty < o.accepted_qty)                   AS lowered
        FROM new_rows n
        JOIN old_rows o ON o.id = n.id
       GROUP BY n.online_order_id
    LOOP
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM public.online_orders oo
         WHERE oo.id = r.online_order_id AND oo.status = 'accepted');
      IF r.decided THEN
        v_event := public._shopper_order_accept_event(r.online_order_id);
      ELSIF r.lowered THEN
        v_event := 'changed';
      ELSE
        v_event := NULL;
      END IF;
      IF v_event IS NOT NULL THEN
        PERFORM public._notify_shopper_order(r.online_order_id, v_event);
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_shopper_online_order_lines ON public.online_order_lines;
CREATE TRIGGER trg_notify_shopper_online_order_lines
  AFTER UPDATE ON public.online_order_lines
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.notify_shopper_on_online_order_lines_update();

REVOKE EXECUTE ON FUNCTION public.notify_shopper_on_online_order_lines_update()
  FROM PUBLIC, anon, authenticated;

COMMIT;
