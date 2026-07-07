-- 0145_forbid_hard_delete_soft_tables.sql
--
-- Accountability guard: rows in soft-delete tables must NEVER be hard-deleted by
-- a client. A permanent DELETE breaks FK-referenced history (order_items, COGS,
-- FIFO cost_batches) and — because `products` is soft-delete / append-only in the
-- sync contract (no downward hard-delete reconcile) — leaves a stale, still-
-- sellable row on every device that already pulled it.
--
-- Enforcement = REVOKE DELETE on every table carrying an `is_deleted` column,
-- from the two client roles (`authenticated`, `anon`). The console + phone app
-- both connect as `authenticated`; the POS app only ever soft-deletes
-- (is_deleted = true) and the console deletes via the SECURITY DEFINER
-- `console_soft_delete_*` RPCs.
--
-- Why this does NOT break anything:
--   * SECURITY DEFINER functions run as the function OWNER, not the caller — so
--     `delete_business` (which fans out `DELETE FROM businesses` via ON DELETE
--     CASCADE onto products/etc.) and `console_soft_delete_product` keep working.
--   * The app never client-hard-deletes any of these tables: its `enqueueDelete`
--     tables (role_permissions, user_permission_overrides, store_role_permissions,
--     user_stores, notifications, saved_carts) are a DISJOINT set, untouched here.
--   * service_role is intentionally left alone (backend/admin path).
--
-- Idempotent: REVOKE of an absent privilege is a no-op, so this is safe to
-- re-run / double-apply.

do $$
declare
  t text;
  soft_delete_tables text[] := array[
    'products','categories','customers','suppliers','manufacturers','stores',
    'price_lists','drivers','expenses','expense_categories','expense_budgets',
    'roles','invite_codes','customer_wallets','crate_size_groups','store_settings'
  ];
begin
  foreach t in array soft_delete_tables loop
    execute format('revoke delete on public.%I from authenticated, anon', t);
  end loop;
end $$;
