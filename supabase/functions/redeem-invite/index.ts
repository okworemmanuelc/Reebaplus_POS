// redeem-invite — finalise the invitee's join by 8-char human_code, with the
// rev 3 four-screen wizard fields collected client-side.
//
// Authenticated; the invitee just signed in via OTP. Resolves the human_code
// to an invite_id, then calls the SECURITY DEFINER RPC accept_invite (0026)
// which atomically:
//   • Validates email match against auth.uid()'s email
//   • Find-or-creates the public.users row
//   • Inserts the public.business_members row (with all wizard fields) and
//     verification_status='not_started', verification_due_at = now() + 14d
//   • Marks the invite accepted
//   • Fans out 'member.created' notifications to CEO + warehouse-matched
//     admins/managers (gated on xmax = 0 for replay-safety)
//
// Returns canonical {user, membership, invite} as ok-wrapped JSON. The
// Flutter client calls SupabaseSyncService.applyServerResponse to seed
// local Drift without a snapshot pull.
//
// Rev 3 simplifications vs rev 2:
//   • Token and 8-char `code` branches removed — only human_code remains.
//   • Wizard fields (staff_phone, next_of_kin_*, guarantor_*) are now
//     part of the request body and forwarded to accept_invite.

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { getCallerClient, getServiceClient } from "../_shared/db.ts";

interface RequestBody {
  human_code?: string;
  user_name?: string;
  staff_phone?: string;
  next_of_kin_name?: string;
  next_of_kin_phone?: string;
  next_of_kin_relation?: string;
  guarantor_name?: string | null;
  guarantor_phone?: string | null;
  guarantor_relation?: string | null;
}

function trimRequired(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length > 0 ? t : null;
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

  const humanCode = trimRequired(body.human_code)?.toUpperCase();
  const userName = trimRequired(body.user_name);
  const staffPhone = trimRequired(body.staff_phone);
  const nokName = trimRequired(body.next_of_kin_name);
  const nokPhone = trimRequired(body.next_of_kin_phone);
  const nokRelation = trimRequired(body.next_of_kin_relation);

  // Required wizard fields. Guarantor trio is optional.
  if (
    !humanCode ||
    !userName ||
    !staffPhone ||
    !nokName ||
    !nokPhone ||
    !nokRelation
  ) {
    return errorResponse("invalid_payload");
  }

  const caller = getCallerClient(req);
  const service = getServiceClient();

  const { data: userResp } = await caller.auth.getUser();
  if (!userResp?.user) return errorResponse("unauthenticated");

  // Resolve human_code → invite_id (service client, RLS-bypass).
  //
  // Widened to (pending, accepted) so a replay after a successful first
  // attempt still finds the row — needed when the client errored on the
  // local-Drift seed AFTER the server already accepted. Without this the
  // user gets "invalid_token" on retry and is permanently locked out of
  // their own invite until an admin regenerates it.
  //
  // ordered/limited because the partial unique index
  // uq_invites_pending_human_code only enforces uniqueness on pending;
  // an old accepted row in another business could theoretically share
  // the same human_code over the long run. Prefer the most recent —
  // and the accept_invite RPC's email-match guard rejects any
  // cross-business mismatch anyway.
  const { data: invRow, error: invErr } = await service
    .from("invites")
    .select("id, status, expires_at")
    .eq("human_code", humanCode)
    .in("status", ["pending", "accepted"])
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (invErr) return errorResponse("internal");
  if (!invRow) return errorResponse("invalid_token");
  // Expiry only matters for the first acceptance. An invite that already
  // flipped to 'accepted' is settled — replaying it shouldn't fail on
  // an expiry that's now in the past.
  if (
    invRow.status === "pending" &&
    new Date(invRow.expires_at).getTime() < Date.now()
  ) {
    return errorResponse("expired");
  }

  // Use the caller client so accept_invite sees auth.uid(). SECURITY
  // DEFINER bypasses RLS internally; identity flows through the JWT.
  const { data: rpcRes, error: rpcErr } = await caller.rpc("accept_invite", {
    p_invite_id: invRow.id,
    p_user_name: userName,
    p_staff_phone: staffPhone,
    p_next_of_kin_name: nokName,
    p_next_of_kin_phone: nokPhone,
    p_next_of_kin_relation: nokRelation,
    p_guarantor_name: trimRequired(body.guarantor_name),
    p_guarantor_phone: trimRequired(body.guarantor_phone),
    p_guarantor_relation: trimRequired(body.guarantor_relation),
  });

  if (rpcErr) {
    const msg = (rpcErr.message ?? "").toLowerCase();
    if (msg.includes("email_mismatch")) return errorResponse("email_mismatch");
    if (msg.includes("invite_expired")) return errorResponse("expired");
    if (msg.includes("invite_status_invalid")) {
      return errorResponse("already_used");
    }
    if (msg.includes("invite_not_found")) {
      return errorResponse("invalid_token");
    }
    if (msg.includes("unauthenticated")) {
      return errorResponse("unauthenticated");
    }
    console.warn(`[redeem-invite] accept_invite RPC failed: ${rpcErr.message}`);
    return errorResponse("internal");
  }

  // RPC returns {user, membership, invite}. Spread into the okResponse
  // envelope so the client's _interpret sees ok:true and the canonical
  // rows together.
  return okResponse(rpcRes as Record<string, unknown>);
});
