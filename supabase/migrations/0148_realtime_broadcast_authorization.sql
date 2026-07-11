-- 0148_realtime_broadcast_authorization.sql
--
-- Workstream B (#101), slice B2 — per-tenant authorization for the Broadcast
-- signal (0147). Realtime Authorization gates private-channel joins with RLS
-- policies on `realtime.messages`: when a client joins a private channel,
-- Realtime runs a policy check (a SELECT against realtime.messages, rolled back)
-- using the caller's Auth JWT and the channel topic (exposed via
-- `realtime.topic()`), then caches the result for the connection.
--
-- 0147 emits to topic `store_<business_id>`. This policy authorizes a caller to
-- JOIN/RECEIVE on that topic ONLY when `<business_id>` is one of the caller's own
-- businesses (`public.current_user_business_ids()` = the profiles-based tenant
-- set used by every other table's RLS). A caller therefore cannot subscribe to
-- another tenant's `store_<id>` topic — no cross-tenant signal leak (invariant
-- #5's spirit, at the signal layer).
--
-- SELECT only (receive). There is deliberately NO INSERT (send) policy:
--   * The 0147 trigger emits via `realtime.send`, invoked from a SECURITY
--     DEFINER trigger that runs as its owner and bypasses this RLS — it needs no
--     client-facing send grant.
--   * Clients only ever RECEIVE the signal; without an INSERT policy a
--     malicious client cannot spoof a broadcast onto a tenant topic.
--
-- `extension = 'broadcast'` scopes the policy to Broadcast messages only (not
-- Presence, which this app does not use).
--
-- Idempotent (drop-if-exists first). Reversible: drop the policy.
--
-- OPERATIONAL NOTE (not enforceable from SQL): full private-channel enforcement
-- also requires "Allow public access" to be OFF in the project's Realtime
-- settings (Dashboard → Realtime → Settings). With it ON, a client could still
-- join a *non-private* channel of the same name unauthenticated. The mobile/web
-- clients always join with `private: true`, so this RLS gate applies to them
-- regardless; the dashboard toggle is a belt-and-suspenders hardening step for
-- the human/ops to confirm.

drop policy if exists "tenant receives own store broadcast signal"
  on realtime.messages;

create policy "tenant receives own store broadcast signal"
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and (select realtime.topic()) in (
    select 'store_' || t.bid::text
    from public.current_user_business_ids() as t(bid)
  )
);
