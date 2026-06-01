-- 0064_replica_identity_full_hard_delete_tables.sql
--
-- Live realtime DELETE propagation for the three hard-delete tables.
--
-- Problem
-- -------
-- Supabase Realtime authorizes every change against the row's RLS SELECT
-- policy before broadcasting it. For a DELETE, the only columns available in
-- the old record are those in the table's REPLICA IDENTITY. These three tables
-- carry RLS policies that filter by `business_id`:
--
--   role_permissions  -> role_permissions_tenant_rw (USING business_id IN ...)
--   saved_carts       -> business-scoped tenant policy
--   notifications     -> business-scoped tenant policy
--
-- but their replica identity is the Postgres DEFAULT = primary key (`id`) only.
-- So `business_id` is absent from a delete's old record, the RLS check runs
-- against a NULL business_id, fails, and Realtime DROPS the DELETE event before
-- it reaches subscribed clients. Net effect on a multi-device business: a
-- revoked role permission (or a removed saved cart / dismissed notification)
-- never disappears on the *other* devices live — it only clears when that
-- device next does a full snapshot reconcile (app restart / re-login).
--
-- These are the only three tables the client hard-deletes (the `enqueueDelete`
-- call sites) and the only ones the sync service applies realtime DELETEs /
-- snapshot-reconcile hard-deletes for. Soft-delete tables are unaffected: they
-- sync as UPDATEs (is_deleted=true), and an UPDATE's *new* record always
-- carries every column regardless of replica identity.
--
-- Fix
-- ---
-- REPLICA IDENTITY FULL makes the old record carry every column, so Realtime
-- can authorize the DELETE against the real `business_id` and deliver it live.
-- Cost is a little extra WAL volume on UPDATE/DELETE — negligible for these
-- small, low-write tables. Idempotent: re-running is a no-op.

ALTER TABLE public.role_permissions REPLICA IDENTITY FULL;
ALTER TABLE public.saved_carts      REPLICA IDENTITY FULL;
ALTER TABLE public.notifications    REPLICA IDENTITY FULL;
