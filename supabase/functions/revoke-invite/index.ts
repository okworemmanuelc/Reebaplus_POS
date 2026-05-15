// revoke-invite — cancel an unredeemed (pending or expired) invite.
//
// Authenticated; caller must be in the same business as the invite and have
// role_tier ≥ 4. Idempotent on already-revoked rows. Refuses to flip
// accepted invites (returns `already_used`).
//
// Writes the invites UPDATE and the activity_logs entry via the service
// client. RLS on activity_logs blocks direct caller-JWT inserts; the
// service-role write here is the same pattern send-invite uses for its
// privileged side-effects. The two writes are not transactional — failure
// of the activity-log insert is logged but does not roll back the revoke
// (activity_logs is observability, not source of truth).

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { getCallerClient, getServiceClient } from "../_shared/db.ts";
import { loadCaller } from "../_shared/auth.ts";
import { isUuid } from "../_shared/validation.ts";

interface RequestBody {
  invite_id?: string;
}

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") return errorResponse("invalid_payload");

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_payload");
  }

  if (!isUuid(body.invite_id)) return errorResponse("invalid_payload");

  const service = getServiceClient();
  const caller = getCallerClient(req);
  const ctx = await loadCaller(caller, service);
  if (!ctx) return errorResponse("unauthenticated");
  if (ctx.roleTier < 5) return errorResponse("forbidden");

  const { data: invite, error: fetchErr } = await service
    .from("invites")
    .select("id, business_id, status, invitee_name")
    .eq("id", body.invite_id!)
    .maybeSingle();
  if (fetchErr) {
    console.warn(`[revoke-invite] fetch failed: ${fetchErr.message}`);
    return errorResponse("internal");
  }
  if (!invite) return errorResponse("invalid_token");
  if (invite.business_id !== ctx.businessId) {
    return errorResponse("forbidden");
  }

  // Idempotent on already-revoked rows: stale UI replays return success
  // without writing a duplicate activity-log entry.
  if (invite.status === "revoked") {
    return okResponse({ invite_id: invite.id, status: "revoked" });
  }
  // Refuse to flip a redeemed invite — accepted is terminal.
  if (invite.status === "accepted") {
    return errorResponse("already_used");
  }
  // pending and expired both fall through. Revoking an expired invite is
  // a no-op for the recipient but removes the row from the staff-list
  // pending bucket, which is the desired admin outcome.

  const nowIso = new Date().toISOString();
  const { data: updatedRow, error: updErr } = await service
    .from("invites")
    .update({ status: "revoked", last_updated_at: nowIso })
    .eq("id", invite.id)
    .select("*")
    .single();
  if (updErr) {
    console.warn(`[revoke-invite] update failed: ${updErr.message}`);
    return errorResponse("internal");
  }

  const inviteeLabel = invite.invitee_name && invite.invitee_name !== "Unknown"
    ? invite.invitee_name
    : "staff member";
  const { error: logErr } = await service
    .from("activity_logs")
    .insert({
      business_id: ctx.businessId,
      user_id: ctx.callerUserId,
      action: "invite.revoked",
      description: `${ctx.callerName || "An admin"} revoked invite for ${inviteeLabel}`,
    });
  if (logErr) {
    console.warn(
      `[revoke-invite] activity log insert failed: ${logErr.message}`,
    );
  }

  return okResponse({
    invite_id: invite.id,
    status: "revoked",
    invite: updatedRow,
  });
});
