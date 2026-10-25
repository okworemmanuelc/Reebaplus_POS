-- 0215_online_order_staff_push.sql
--
-- #433 (Online ordering 12/28, PRD #421): a new Online Order sends an FCM push
-- to the staff who can answer it. Server half only; the app tap routing ships
-- with the client (invariant #13: the push is an alert, the order reaches Drift
-- by pull, and the tap tolerates it not being local yet).
--
-- WHAT THIS ADDS
--   1. public._online_order_push_recipients(business, store): the users.id list
--      to alert. A user is a recipient when ALL hold:
--        * active member of the business (user_businesses.status = 'active'),
--          not soft-deleted;
--        * works at the store: a user_stores row for it, OR is the CEO, OR is a
--          Manager whose role has manager_view_all_stores = 'true' (mirrors the
--          app's canViewAllStoresProvider);
--        * holds online_orders.answer, resolved exactly like the app and
--          caller_has_permission (0135) but for an arbitrary user and with the
--          store layer for THIS store: CEO all-on; else role grant, then
--          store_role_permissions (this store + role), then
--          user_permission_overrides (most specific wins).
--   2. AFTER INSERT trigger on online_orders -> pg_net -> the `send-push` Edge
--      Function (same Vault secrets and x-push-hook-secret as 0159). Payload
--      record: type 'online_order', title 'New online order', message with the
--      reference + the shopper's first name, user_ids, data {type,
--      online_order_id, store_id}.
--
-- NEVER BLOCKS THE INSERT: the whole body runs inside BEGIN ... EXCEPTION WHEN
-- OTHERS THEN NULL, pg_net is async/fire-and-forget, and an unconfigured
-- project (no Vault secrets) is a silent no-op. AFTER INSERT only, so the sync
-- engine's upserts (UPDATE) can never re-send.
--
-- DEPLOY ORDER: this migration, then deploy the `send-push` Edge Function
-- (`supabase functions deploy send-push --no-verify-jwt`). Until the function
-- is redeployed it skips unknown record types (`not_routable`), so applying the
-- migration first is harmless. No Drift change. Does not depend on 0193.

BEGIN;

CREATE OR REPLACE FUNCTION public._online_order_push_recipients(
  p_business_id uuid,
  p_store_id    uuid
)
RETURNS uuid[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE(array_agg(u.id), ARRAY[]::uuid[])
    FROM public.users u
    JOIN public.user_businesses ub
      ON ub.user_id = u.id
     AND ub.business_id = p_business_id
     AND ub.status = 'active'
    JOIN public.roles r ON r.id = ub.role_id
   WHERE u.business_id = p_business_id
     AND NOT u.is_deleted
     -- Works at this store.
     AND (
       r.slug = 'ceo'
       OR EXISTS (
         SELECT 1 FROM public.user_stores us
          WHERE us.user_id = u.id AND us.store_id = p_store_id
       )
       OR (r.slug = 'manager' AND EXISTS (
         SELECT 1 FROM public.role_settings rs
          WHERE rs.role_id = r.id
            AND rs.setting_key = 'manager_view_all_stores'
            AND rs.setting_value = 'true'
       ))
     )
     -- Holds online_orders.answer (CEO all-on; else role -> store -> user).
     AND (
       r.slug = 'ceo'
       OR COALESCE(
         (SELECT o.is_granted FROM public.user_permission_overrides o
           WHERE o.user_id = u.id AND o.business_id = p_business_id
             AND o.permission_key = 'online_orders.answer' LIMIT 1),
         (SELECT s.is_granted FROM public.store_role_permissions s
           WHERE s.store_id = p_store_id AND s.role_id = r.id
             AND s.permission_key = 'online_orders.answer' LIMIT 1),
         EXISTS (
           SELECT 1 FROM public.role_permissions rp
            WHERE rp.role_id = r.id AND rp.business_id = p_business_id
              AND rp.permission_key = 'online_orders.answer'
         )
       )
     );
$function$;

REVOKE ALL ON FUNCTION public._online_order_push_recipients(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._online_order_push_recipients(uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.send_push_on_online_order_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_base_url text;
  v_secret   text;
  v_users    uuid[];
BEGIN
  -- A push problem must never fail or slow order placement.
  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets WHERE name = 'project_url';
    SELECT decrypted_secret INTO v_secret
      FROM vault.decrypted_secrets WHERE name = 'push_hook_secret';
    IF v_base_url IS NULL OR v_secret IS NULL THEN
      RETURN NEW;
    END IF;

    v_users := public._online_order_push_recipients(NEW.business_id, NEW.store_id);
    IF v_users IS NULL OR cardinality(v_users) = 0 THEN
      RETURN NEW;
    END IF;

    PERFORM net.http_post(
      url     := v_base_url || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'content-type',       'application/json',
        'x-push-hook-secret', v_secret
      ),
      body    := jsonb_build_object('record', jsonb_build_object(
        'id',          NEW.id,
        'type',        'online_order',
        'severity',    'info',
        'title',       'New online order',
        'message',     'Order ' || NEW.reference || ' from '
                         || COALESCE(NULLIF(split_part(btrim(NEW.shopper_name), ' ', 1), ''), 'a customer'),
        'business_id', NEW.business_id,
        'user_ids',    to_jsonb(v_users),
        'data',        jsonb_build_object(
          'type',            'online_order',
          'online_order_id', NEW.id,
          'store_id',        NEW.store_id
        )
      ))
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_send_push_online_order ON public.online_orders;
CREATE TRIGGER trg_send_push_online_order
  AFTER INSERT ON public.online_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.send_push_on_online_order_insert();

-- TRIGGER function, never a client RPC (keeps it off the /rpc/ surface).
REVOKE EXECUTE ON FUNCTION public.send_push_on_online_order_insert()
  FROM PUBLIC, anon, authenticated;

COMMIT;
