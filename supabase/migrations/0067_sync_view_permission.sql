-- 0067_sync_view_permission.sql
--
-- Reebaplus — Sync Issues access (CEO Settings). Adds the `sync.view`
-- permission to the cloud catalogue so it stays in sync with the local Drift
-- catalogue (schema v26). `sync.view` gates the Sync Issues troubleshooting
-- screen + its sidebar item / sync badge / banner.
--
-- The CEO always has Sync Issues access via an in-code role check, so this
-- migration does NOT need to grant the CEO anything; other roles get it through
-- the per-role toggle in CEO Settings → Sync Issues access, which writes a
-- normal (synced) role_permissions grant.
--
-- REQUIRED, not optional. `role_permissions.permission_key` has a FK
-- (REFERENCES public.permissions(key) ON DELETE RESTRICT). Granting `sync.view`
-- to a non-CEO role enqueues a role_permissions upsert; if this key is absent
-- from the cloud catalogue the cloud rejects that upsert on the FK, so the grant
-- never reaches other devices — the toggle "works" locally but does not sync in
-- real time. Pushing this row is what makes the cross-device grant land.
--
-- Additive + idempotent (key is the PK). Safe to push any time.

INSERT INTO public.permissions (key, description, category)
VALUES ('sync.view', 'View sync issues', 'System')
ON CONFLICT (key) DO NOTHING;
