-- Drop the last_notification_sent_at column from public.users.
-- The "Waiting for Assignment" feature and its 48h escalation notification
-- system have been removed. This column is no longer written or read.
-- Mirrors the Drift v49 onUpgrade step in app_database.dart.
ALTER TABLE public.users DROP COLUMN IF EXISTS last_notification_sent_at;
