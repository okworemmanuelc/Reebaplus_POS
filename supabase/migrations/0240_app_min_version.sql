-- 0240_app_min_version.sql
--
-- #626 (PRD #620 decisions 5 + 12): "must-update" switch. One server-held
-- minimum Android build number; a phone whose build is below it shows the
-- full-screen "Update Required" page. 0 (the seed) blocks nobody.
--
-- A NEW tiny key/value table is used rather than public.console_settings:
-- that table is owned by the console repo (see 0131) and has admin-only RLS,
-- so the phone (even before sign-in) could not read it.
--
-- READ:  anon + authenticated may SELECT (the check runs before sign-in).
-- WRITE: console admins only (is_console_admin()) and service_role. No client
--        INSERT/UPDATE/DELETE for anyone else.
-- Not synced to Drift: the phone fetches the one key on launch/resume.

CREATE TABLE IF NOT EXISTS public.app_config (
  key        text PRIMARY KEY,
  value      text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS app_config_read ON public.app_config;
CREATE POLICY app_config_read ON public.app_config
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS app_config_console_write ON public.app_config;
CREATE POLICY app_config_console_write ON public.app_config
  FOR ALL TO authenticated
  USING (public.is_console_admin())
  WITH CHECK (public.is_console_admin());

REVOKE ALL ON public.app_config FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.app_config TO anon, authenticated;
-- RLS (app_config_console_write) limits these to console admins.
GRANT INSERT, UPDATE, DELETE ON public.app_config TO authenticated;
GRANT ALL ON public.app_config TO service_role;

-- Nothing is blocked until the owner raises this.
INSERT INTO public.app_config (key, value)
VALUES ('min_android_build', '0')
ON CONFLICT (key) DO NOTHING;
