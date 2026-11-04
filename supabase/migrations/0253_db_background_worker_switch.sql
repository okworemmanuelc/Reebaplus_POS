-- 0253_db_background_worker_switch.sql
--
-- #687 (PRD #680 S6): cloud off switch for the phone's local database worker.
-- 'on' = the database runs on Drift's background worker (the default).
-- 'off' = phones go back to the screen's thread, at their next app open.
-- Same table, read and write rules as min_android_build (0240): readable before
-- sign-in, writable only by console admins. Changed by SQL or a console admin;
-- no console screen. Not synced to Drift: the phone reads the one key on launch
-- and resume and keeps its last answer in a small local file.

INSERT INTO public.app_config (key, value)
VALUES ('db_background_worker', 'on')
ON CONFLICT (key) DO NOTHING;
