-- 0129_devices.sql
--
-- Reebaplus — device registry for the operator CONSOLE's analytics. This is
-- NOT an in-app feature: there is no device screen. It lets the console see the
-- phone make/model + last-seen of every device that has ever logged into a
-- business.
--
-- Cloud-ONLY table: no local Drift mirror, and it is deliberately absent from
-- `_syncedTenantTables` / `pos_pull_snapshot` / the realtime publication / the
-- offline sync queue. The app writes it with a DIRECT authenticated
-- `supabase.upsert` — exactly like AuthService._registerCloudSession does for
-- `sessions` — upserted on sign-in, app-open-when-online, and connectivity
-- recovery. One row per (business_id, device_id).
--
-- Retention: rows SURVIVE business deletion (device churn analytics). Both
-- `business_id` and `last_user_id` are plain uuids with NO foreign key, so the
-- `delete_business` cascade (0112, DELETE FROM businesses) does not remove them.
--
-- DEPLOY ORDER: push this BEFORE an app build that upserts `devices` reaches a
-- device, or the upsert 42P01s (relation does not exist) cloud-side. Even then
-- the app swallows the error (fire-and-forget) — an un-deployed table only
-- means "no analytics yet", never a broken login or sync.

-- -----------------------------------------------------------------------------
-- 1. Table.
-- -----------------------------------------------------------------------------
CREATE TABLE public.devices (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL,   -- plain uuid, NO FK (survives business delete)
  device_id          text NOT NULL,   -- opaque per-device UUID (getOrCreateDeviceId)
  platform           text,            -- 'android' | 'ios'
  manufacturer       text,            -- e.g. 'samsung' | 'Apple'
  model              text,            -- e.g. 'SM-A146U' | 'iPhone16,1'
  device_name        text,            -- marketing/user label (imperfect on iOS)
  os_version         text,            -- e.g. 'Android 14 (SDK 34)' | 'iOS 17.4'
  app_version        text,            -- '<version>+<build>'
  is_physical_device boolean,         -- false = emulator/simulator (filter it out)
  last_user_id       uuid,            -- users.id, plain uuid, NO FK (survives)
  last_user_email    text,            -- denormalized for the console (no join)
  last_user_name     text,            -- denormalized for the console (no join)
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, device_id)
);

CREATE INDEX idx_devices_business_last_seen
  ON public.devices (business_id, last_seen_at DESC);

-- -----------------------------------------------------------------------------
-- 2. Server-authoritative last_seen_at.
--    Stamp it on every INSERT and UPDATE so a device with a wrong clock can't
--    skew the analytics and the client never has to send a timestamp. On the
--    upsert's ON CONFLICT DO UPDATE this trigger still fires (BEFORE UPDATE), so
--    last_seen_at advances on every presence write. first_seen_at is never in
--    the client payload and this trigger never touches it, so it keeps its
--    insert-time DEFAULT for the life of the row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._devices_stamp_last_seen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  NEW.last_seen_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER stamp_devices_last_seen
  BEFORE INSERT OR UPDATE ON public.devices
  FOR EACH ROW EXECUTE FUNCTION public._devices_stamp_last_seen();

-- -----------------------------------------------------------------------------
-- 3. Row Level Security — profiles-based tenant scoping via
--    current_user_business_ids() (NOT an inline user_businesses subquery; that
--    hit auth_user_id-drift 42501 push failures — see 0050/0088/0108). The app
--    only ever writes its OWN business's row; the console reads across every
--    tenant via service_role, which bypasses RLS.
-- -----------------------------------------------------------------------------
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "devices_tenant_rw" ON public.devices
  FOR ALL TO authenticated
  USING (business_id IN (SELECT public.current_user_business_ids()))
  WITH CHECK (business_id IN (SELECT public.current_user_business_ids()));
