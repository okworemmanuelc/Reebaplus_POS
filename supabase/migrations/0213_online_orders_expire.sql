-- 0213_online_orders_expire.sql
--
-- #435 (Online ordering 14/28, PRD #421): an Online Order still `new` after 48
-- hours moves to `expired` (system only). The Shopper sees "The shop didn't
-- respond"; the shop's Online tab stops counting it as New. 0212 is reserved.
--
-- No guard change: _online_orders_guard (0208) already allows new -> expired
-- for non-client writers only (AND NOT v_client), and a shop phone can only
-- move new -> accepted, so an expired order can never be accepted.
--
-- Reaches shop phones like any server write: last_updated_at is advanced here
-- (and by bump_online_orders_last_updated_at), so the delta pull picks it up,
-- and zz_broadcast_sync_signal (already on online_orders) fires the live nudge.
--
-- Scheduling: pg_cron, hourly, only where the extension exists (production has
-- it; the dev database may not). No grant to anon / authenticated.

BEGIN;

CREATE OR REPLACE FUNCTION public.expire_stale_online_orders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.online_orders
     SET status = 'expired',
         last_updated_at = now()
   WHERE status = 'new'
     AND placed_at < now() - interval '48 hours';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.expire_stale_online_orders() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_stale_online_orders() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_stale_online_orders() TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire-stale-online-orders') THEN
      PERFORM cron.unschedule('expire-stale-online-orders');
    END IF;
    PERFORM cron.schedule(
      'expire-stale-online-orders', '7 * * * *',
      'SELECT public.expire_stale_online_orders()');
  END IF;
END $$;

COMMIT;
