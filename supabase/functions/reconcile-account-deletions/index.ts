// reconcile-account-deletions
//
// Completes the half of account deletion that an in-DB SECURITY DEFINER cannot
// do on managed Supabase: removing the CEO's `auth.users` login.
//
// Background (§10.3): `delete_business` cascade-deletes the tenant correctly,
// then best-effort tries `DELETE FROM auth.users`. On managed Supabase a
// `postgres`-owned SECURITY DEFINER cannot reliably delete from `auth.users`
// (that belongs to the Auth Admin API), so it fails on every call. Migration
// 0125 stopped swallowing that and now records it on
// account_deletion_events.auth_delete_error with auth_user_deleted = false.
//
// This function is the durable fix. It scans account_deletion_events for rows
// where the login is still pending removal and finishes the job through the
// Auth Admin API (service-role `auth.admin.deleteUser`).
//
// SAFETY — defense-in-depth against an invariant violation:
//   The rule is one-email-one-business (architecture invariant #9;
//   users.auth_user_id is globally unique). In correct operation, once
//   delete_business cascades, the identity is fully orphaned and the login is
//   safe to remove. We do NOT assume that holds. This job is keyed off
//   account_deletion_events, and the very incident that motivated it was an
//   invariant VIOLATION — a single email owning two live businesses. If that
//   recurs and we processed the first business's deletion event blindly, we
//   would delete the shared login while the second business is still live,
//   locking its CEO out. So we only delete when the identity is provably
//   orphaned: no `businesses.owner_id = uid` AND no `users.auth_user_id = uid`.
//   If anything still references it we mark the event acknowledged (login
//   retained) rather than delete — the safe outcome, not a failure. In a
//   healthy system this guard never trips; it exists to fail safe if it does.
//
// Invocation — two supported shapes, both gated by a shared secret in the
// `x-admin-hook-secret` header (ACCOUNT_DELETION_HOOK_SECRET); there is no user
// JWT on this path:
//   1. Batch reconcile (no body, or `{}`): process up to BATCH_LIMIT pending
//      events. Wire this to pg_cron / a scheduled invoke (e.g. every 15 min).
//      It also heals historical rows left behind before this function existed.
//   2. Single row (`{ "record": { "id": "<event-uuid>" } }`): process exactly
//      one event. Wire this to an AFTER INSERT trigger on
//      account_deletion_events via pg_net for near-real-time removal.
//
// Idempotency: a row is "pending" only while auth_user_deleted = false AND
// acknowledged_at IS NULL. Success sets auth_user_deleted = true; a skip (still
// in use) sets acknowledged_at. Either way the row leaves the pending set, so
// re-invocation never double-acts. A genuine Admin-API failure leaves the row
// pending (with the reason on auth_delete_error) for the next run to retry.

import { handlePreflight, corsHeaders } from "../_shared/cors.ts";
import { getServiceClient } from "../_shared/db.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const BATCH_LIMIT = 50;

interface DeletionEvent {
  id: string;
  owner_auth_user_id: string | null;
  owner_email: string | null;
  auth_user_deleted: boolean;
  acknowledged_at: string | null;
}

interface SingleRowPayload {
  record?: { id?: string };
}

type Outcome = "deleted" | "skipped_in_use" | "skipped_no_auth_id" | "failed";

interface EventResult {
  id: string;
  outcome: Outcome;
  detail?: string;
}

function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders },
  });
}

/// Is this auth identity still referenced by any live business or user row?
/// Under one-email-one-business this is false after a cascade; if it is ever
/// true the invariant has been violated and we must NOT delete the shared login
/// (another live business still depends on it).
async function authIdentityStillInUse(
  service: SupabaseClient,
  authUid: string,
): Promise<boolean> {
  const { count: ownsCount, error: ownsErr } = await service
    .from("businesses")
    .select("id", { count: "exact", head: true })
    .eq("owner_id", authUid);
  if (ownsErr) throw new Error(`businesses lookup: ${ownsErr.message}`);
  if ((ownsCount ?? 0) > 0) return true;

  const { count: userCount, error: userErr } = await service
    .from("users")
    .select("id", { count: "exact", head: true })
    .eq("auth_user_id", authUid);
  if (userErr) throw new Error(`users lookup: ${userErr.message}`);
  return (userCount ?? 0) > 0;
}

async function processEvent(
  service: SupabaseClient,
  ev: DeletionEvent,
): Promise<EventResult> {
  // Nothing to do if the row was already resolved.
  if (ev.auth_user_deleted || ev.acknowledged_at) {
    return { id: ev.id, outcome: "skipped_in_use", detail: "already_resolved" };
  }

  const authUid = ev.owner_auth_user_id;
  if (!authUid) {
    // No identity to act on — acknowledge so it leaves the pending set.
    await service
      .from("account_deletion_events")
      .update({
        acknowledged_at: new Date().toISOString(),
        auth_delete_error: "skipped: no owner_auth_user_id recorded",
      })
      .eq("id", ev.id);
    return { id: ev.id, outcome: "skipped_no_auth_id" };
  }

  // SAFETY GUARD: never delete a login that's still in use elsewhere.
  let inUse: boolean;
  try {
    inUse = await authIdentityStillInUse(service, authUid);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await service
      .from("account_deletion_events")
      .update({ auth_delete_error: `reconcile lookup failed: ${msg}` })
      .eq("id", ev.id);
    return { id: ev.id, outcome: "failed", detail: msg };
  }

  if (inUse) {
    await service
      .from("account_deletion_events")
      .update({
        acknowledged_at: new Date().toISOString(),
        auth_delete_error:
          "skipped: auth identity still owns other businesses (login retained)",
      })
      .eq("id", ev.id);
    return { id: ev.id, outcome: "skipped_in_use" };
  }

  // Fully orphaned — remove the login via the Auth Admin API.
  const { error: delErr } = await service.auth.admin.deleteUser(authUid);
  if (delErr) {
    // Treat "user not found" as success — the login is already gone.
    const notFound = (delErr.status === 404) ||
      /not.?found/i.test(delErr.message ?? "");
    if (!notFound) {
      await service
        .from("account_deletion_events")
        .update({ auth_delete_error: `admin.deleteUser: ${delErr.message}` })
        .eq("id", ev.id);
      return { id: ev.id, outcome: "failed", detail: delErr.message };
    }
  }

  await service
    .from("account_deletion_events")
    .update({
      auth_user_deleted: true,
      acknowledged_at: new Date().toISOString(),
      auth_delete_error: null,
    })
    .eq("id", ev.id);
  return { id: ev.id, outcome: "deleted" };
}

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);
  }

  // Shared-secret gate — no user JWT on this back-office path.
  const expectedSecret = Deno.env.get("ACCOUNT_DELETION_HOOK_SECRET");
  const providedSecret = req.headers.get("x-admin-hook-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return jsonResponse({ ok: false, error: "unauthenticated" }, 401);
  }

  // Optional single-row payload; absent/invalid body => batch mode.
  let singleId: string | null = null;
  try {
    const raw = await req.text();
    if (raw.trim().length > 0) {
      const payload = JSON.parse(raw) as SingleRowPayload;
      if (payload?.record?.id && typeof payload.record.id === "string") {
        singleId = payload.record.id;
      }
    }
  } catch (_e) {
    // Malformed body — fall through to batch mode.
  }

  const service = getServiceClient();
  const selectCols =
    "id, owner_auth_user_id, owner_email, auth_user_deleted, acknowledged_at";

  let events: DeletionEvent[] = [];
  if (singleId) {
    const { data, error } = await service
      .from("account_deletion_events")
      .select(selectCols)
      .eq("id", singleId)
      .maybeSingle();
    if (error) {
      return jsonResponse({ ok: false, error: error.message }, 500);
    }
    if (data) events = [data as DeletionEvent];
  } else {
    const { data, error } = await service
      .from("account_deletion_events")
      .select(selectCols)
      .eq("auth_user_deleted", false)
      .is("acknowledged_at", null)
      .order("deleted_at", { ascending: true })
      .limit(BATCH_LIMIT);
    if (error) {
      return jsonResponse({ ok: false, error: error.message }, 500);
    }
    events = (data ?? []) as DeletionEvent[];
  }

  const results: EventResult[] = [];
  for (const ev of events) {
    try {
      results.push(await processEvent(service, ev));
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("processEvent crashed", ev.id, msg);
      results.push({ id: ev.id, outcome: "failed", detail: msg });
    }
  }

  const summary = {
    processed: results.length,
    deleted: results.filter((r) => r.outcome === "deleted").length,
    skipped_in_use: results.filter((r) => r.outcome === "skipped_in_use").length,
    skipped_no_auth_id:
      results.filter((r) => r.outcome === "skipped_no_auth_id").length,
    failed: results.filter((r) => r.outcome === "failed").length,
  };

  return jsonResponse({ ok: true, mode: singleId ? "single" : "batch", summary, results }, 200);
});
