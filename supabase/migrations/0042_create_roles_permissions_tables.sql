-- 0042_create_roles_permissions_tables.sql
--
-- Reebaplus master plan §2.4 — data-driven roles, permissions, and
-- membership. Creates seven new tables: one global static-config
-- (permissions) and six tenant-scoped synced (roles, role_permissions,
-- role_settings, user_businesses, invite_codes, user_stores).
--
-- This migration is SCHEMA ONLY. The next migration (0043) seeds the
-- permissions table and backfills default roles + permissions + a CEO
-- membership for every pre-existing business. Migration 0044 updates
-- the `complete_onboarding` RPC to seed the same rows on every new
-- business creation.
--
-- The matching Drift v13 migration creates the same tables locally
-- and seeds the same permission keys (the only static config). Tenant
-- rows arrive on local devices via the next sync pull.
--
-- Structure (matters for FK + RLS ordering):
--   1. Bump trigger function (used by §6).
--   2. CREATE TABLE for all 7 tables. FK order respected: permissions
--      first (no FKs), then roles (FK to businesses), then everything
--      else (FK to roles among others). Indexes follow each table.
--   3. ENABLE RLS on all tables.
--   4. CREATE POLICY for all. Done as a SECOND PASS after every table
--      exists — policies on `roles` / `role_permissions` / etc. reference
--      `user_businesses` in their USING clauses, and Postgres validates
--      table references at CREATE POLICY time.
--   5. Realtime publication.
--   6. last_updated_at bump triggers.

BEGIN;

-- =========================================================================
-- 1. Bump trigger function. Mirrors the auto-bump used on other synced
--    tables; matches the SQLite trigger emitted by the Drift loop in
--    `_postCreateStatements`.
-- =========================================================================

CREATE OR REPLACE FUNCTION public._bump_last_updated_at() RETURNS trigger AS $$
BEGIN
  IF NEW.last_updated_at IS NOT DISTINCT FROM OLD.last_updated_at THEN
    NEW.last_updated_at := now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- 2. CREATE TABLE — all seven, in FK-respecting order. Indexes inline
--    with each table.
-- =========================================================================

-- 2a. permissions — global static config.
CREATE TABLE public.permissions (
  key             text PRIMARY KEY,
  description     text NOT NULL,
  category        text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_updated_at timestamptz NOT NULL DEFAULT now()
);

-- 2b. roles — per-business. Four system defaults seeded later.
CREATE TABLE public.roles (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name               text NOT NULL,
  slug               text NOT NULL,
  is_system_default  boolean NOT NULL DEFAULT false,
  is_deleted         boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, name),
  UNIQUE (business_id, slug)
);
CREATE INDEX idx_roles_business_lua ON public.roles (business_id, last_updated_at);
CREATE INDEX idx_roles_business_deleted ON public.roles (business_id, is_deleted);

-- 2c. role_permissions — presence = grant; absence = not granted.
CREATE TABLE public.role_permissions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  role_id            uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  permission_key     text NOT NULL REFERENCES public.permissions(key) ON DELETE RESTRICT,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (role_id, permission_key)
);
CREATE INDEX idx_role_permissions_business_lua ON public.role_permissions (business_id, last_updated_at);
CREATE INDEX idx_role_permissions_role ON public.role_permissions (role_id);

-- 2d. role_settings — per-role tunable values.
CREATE TABLE public.role_settings (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  role_id            uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  setting_key        text NOT NULL,
  setting_value      text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (role_id, setting_key)
);
CREATE INDEX idx_role_settings_business_lua ON public.role_settings (business_id, last_updated_at);
CREATE INDEX idx_role_settings_role ON public.role_settings (role_id);

-- 2e. user_businesses — replaces dropped business_members.
CREATE TABLE public.user_businesses (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  user_id            uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role_id            uuid NOT NULL REFERENCES public.roles(id) ON DELETE RESTRICT,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended')),
  last_login_at      timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, business_id)
);
CREATE INDEX idx_user_businesses_business_lua ON public.user_businesses (business_id, last_updated_at);
CREATE INDEX idx_user_businesses_user ON public.user_businesses (user_id);

-- 2f. invite_codes — replaces dropped invites. Soft-deletable for
--     revoke (per CLAUDE.md hard rule #9).
CREATE TABLE public.invite_codes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  role_id               uuid NOT NULL REFERENCES public.roles(id) ON DELETE RESTRICT,
  code                  text NOT NULL CHECK (length(code) = 8),
  email                 text NOT NULL,
  warehouse_id          uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  generated_by_user_id  uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  expires_at            timestamptz NOT NULL,
  used_by_user_id       uuid REFERENCES public.users(id) ON DELETE SET NULL,
  used_at               timestamptz,
  revoked_at            timestamptz,
  is_deleted            boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  last_updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_invite_codes_business_lua ON public.invite_codes (business_id, last_updated_at);
CREATE INDEX idx_invite_codes_business_deleted ON public.invite_codes (business_id, is_deleted);
-- At most one active code per code value at a time. Used / revoked /
-- deleted codes drop out so the value can in principle be reused; the
-- 8-char alphanumeric keyspace makes accidental collisions vanishingly
-- unlikely.
CREATE UNIQUE INDEX uq_invite_codes_active ON public.invite_codes (code)
  WHERE used_at IS NULL AND revoked_at IS NULL AND is_deleted = false;

-- 2g. user_stores — many-to-many. Replaces users.warehouse_id.
CREATE TABLE public.user_stores (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  user_id            uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  warehouse_id       uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  created_at         timestamptz NOT NULL DEFAULT now(),
  last_updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, warehouse_id)
);
CREATE INDEX idx_user_stores_business_lua ON public.user_stores (business_id, last_updated_at);
CREATE INDEX idx_user_stores_user ON public.user_stores (user_id);

-- =========================================================================
-- 3. ENABLE RLS on all seven tables. Until policies land in step 4,
--    every non-superuser read/write is denied. The migration runs as
--    the database owner (postgres) which bypasses RLS, so the seed in
--    0043 still works even during this window.
-- =========================================================================

ALTER TABLE public.permissions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_settings    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_businesses  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_codes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_stores      ENABLE ROW LEVEL SECURITY;

-- =========================================================================
-- 4. CREATE POLICY — SECOND PASS, after every table exists. Policies
--    on roles / role_permissions / role_settings / invite_codes /
--    user_stores all reference user_businesses in their USING /
--    WITH CHECK clauses; that table now exists, so the policies parse.
-- =========================================================================

-- 4a. permissions — read-only catalog; every authenticated user can read.
CREATE POLICY "permissions_read" ON public.permissions
  FOR SELECT TO authenticated USING (true);

-- 4b. user_businesses — bootstrap-safe self-or-member visibility. A
--     user can ALWAYS see their own membership row even if they're not
--     yet recognised as a member (chicken-and-egg on first login).
CREATE POLICY "user_businesses_self_or_member" ON public.user_businesses
  FOR ALL TO authenticated
  USING (
    user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    OR business_id IN (
      SELECT ub.business_id FROM public.user_businesses ub
       WHERE ub.user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
         AND ub.status = 'active'
    )
  )
  WITH CHECK (
    user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
    OR business_id IN (
      SELECT ub.business_id FROM public.user_businesses ub
       WHERE ub.user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
         AND ub.status = 'active'
    )
  );

-- 4c-4g. Standard "tenant member" policy for the remaining five tables.
CREATE POLICY "roles_tenant_rw" ON public.roles
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

CREATE POLICY "role_permissions_tenant_rw" ON public.role_permissions
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

CREATE POLICY "role_settings_tenant_rw" ON public.role_settings
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

CREATE POLICY "invite_codes_tenant_rw" ON public.invite_codes
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

CREATE POLICY "user_stores_tenant_rw" ON public.user_stores
  FOR ALL TO authenticated
  USING (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ))
  WITH CHECK (business_id IN (
    SELECT business_id FROM public.user_businesses
     WHERE user_id IN (SELECT id FROM public.users WHERE auth_user_id = auth.uid())
       AND status = 'active'
  ));

-- =========================================================================
-- 5. Realtime publication. The six synced tenant tables need to be in
--    the realtime publication so DELETE / INSERT events flow to
--    subscribed clients. `permissions` is NOT included — it's static
--    config seeded by migration.
-- =========================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE
  public.roles,
  public.role_permissions,
  public.role_settings,
  public.user_businesses,
  public.invite_codes,
  public.user_stores;

-- =========================================================================
-- 6. last_updated_at bump triggers — wired to the function defined in §1.
-- =========================================================================

CREATE TRIGGER bump_roles_last_updated_at
  BEFORE UPDATE ON public.roles
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

CREATE TRIGGER bump_role_permissions_last_updated_at
  BEFORE UPDATE ON public.role_permissions
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

CREATE TRIGGER bump_role_settings_last_updated_at
  BEFORE UPDATE ON public.role_settings
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

CREATE TRIGGER bump_user_businesses_last_updated_at
  BEFORE UPDATE ON public.user_businesses
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

CREATE TRIGGER bump_invite_codes_last_updated_at
  BEFORE UPDATE ON public.invite_codes
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

CREATE TRIGGER bump_user_stores_last_updated_at
  BEFORE UPDATE ON public.user_stores
  FOR EACH ROW EXECUTE FUNCTION public._bump_last_updated_at();

COMMIT;

-- =============================================================================
-- Verification queries (run by hand after deploy):
--
--   SELECT to_regclass('public.permissions');       -- expect 'permissions'
--   SELECT to_regclass('public.roles');             -- expect 'roles'
--   SELECT to_regclass('public.role_permissions');  -- expect 'role_permissions'
--   SELECT to_regclass('public.role_settings');     -- expect 'role_settings'
--   SELECT to_regclass('public.user_businesses');   -- expect 'user_businesses'
--   SELECT to_regclass('public.invite_codes');      -- expect 'invite_codes'
--   SELECT to_regclass('public.user_stores');       -- expect 'user_stores'
--
--   SELECT COUNT(*) FROM public.permissions;        -- expect 0 (seeded by 0043)
--
--   -- All seven tables RLS-enabled:
--   SELECT relname, relrowsecurity FROM pg_class
--    WHERE relname IN ('permissions','roles','role_permissions','role_settings',
--                      'user_businesses','invite_codes','user_stores');
--   -- expect relrowsecurity = true for every row.
-- =============================================================================
