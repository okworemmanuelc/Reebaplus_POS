-- 0146_restamp_soft_deleted_rows.sql
--
-- One-time cleanup for the "deleted product still sellable" symptom (#88). Rows
-- correctly soft-deleted on the console (is_deleted = true) can still show on a
-- logged-in device that never received the update: Supabase realtime does not
-- replay events missed while the socket was down, and before #88's catch-up
-- pull a device only re-pulled on login / manual refresh.
--
-- Bumping last_updated_at = now() on every already-soft-deleted row forces the
-- next incremental pull (pos_pull_snapshot: WHERE last_updated_at > p_since) to
-- re-deliver it, so each device applies is_deleted = true and drops it from the
-- POS grid / lists.
--
-- POSITIVE sync only — it never deletes a local row, so there is zero wipe-race
-- risk. (This is deliberately NOT the rejected "delete local rows absent from a
-- full cloud snapshot" reconcile, which could wrongly delete valid rows on an
-- incomplete snapshot.) Pairs with #87 (REVOKE client hard-delete) and #88
-- (reconnect + app-resume catch-up pull).
--
-- Scoped to the user-visible catalog / entity tables, all of which ride
-- pos_pull_snapshot down. Guarded by to_regclass so it is safe on any schema
-- subset. Idempotent (re-running simply re-stamps the same rows).

do $$
declare
  t text;
  restamp_tables text[] := array[
    'products','categories','customers','suppliers','manufacturers','stores',
    'price_lists','drivers','expenses','expense_categories','expense_budgets'
  ];
begin
  foreach t in array restamp_tables loop
    if to_regclass('public.' || t) is not null then
      execute format(
        'update public.%I set last_updated_at = now() where is_deleted = true', t
      );
    end if;
  end loop;
end $$;
