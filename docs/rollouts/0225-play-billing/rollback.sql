-- Rollback for 0225_play_billing.sql. Does not touch businesses values.
BEGIN;
DROP FUNCTION IF EXISTS public.apply_play_purchase(uuid, text, text, text, timestamptz);
DROP TABLE IF EXISTS public.play_subscription_purchases;
DELETE FROM supabase_migrations.schema_migrations WHERE version = '0225';
COMMIT;
