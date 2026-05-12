// resend-invite — regenerate the human_code for an unredeemed pending invite.
//
// Authenticated; caller must be in the same business as the invite and
// have role_tier ≥ 4. Calls the SECURITY DEFINER RPC regenerate_invite_code
// (0027) which atomically:
//   • Validates the invite is still pending (regen only works pre-redemption)
//   • Marks the old row status='revoked'
//   • Inserts a new row with a fresh 8-char human_code and 7-day TTL
//   • Sets regenerated_from = <old_id>, regenerated_at = now()
//   • Logs invite.regenerated to activity_logs
//
// The endpoint name "resend-invite" is preserved for client-side callers
// that still use this URL; the semantics are now "regenerate code" since
// there's no email/SMS resend in rev 3.

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { getCallerClient } from "../_shared/db.ts";
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

  // Use the caller client so the RPC's auth.uid() / business_id() resolve
  // to the inviter. SECURITY DEFINER bypasses RLS internally; identity
  // still flows through the JWT.
  const caller = getCallerClient(req);
  const { data: userResp } = await caller.auth.getUser();
  if (!userResp?.user) return errorResponse("unauthenticated");

  const { data, error } = await caller.rpc("regenerate_invite_code", {
    p_invite_id: body.invite_id,
  });
  if (error) {
    const msg = (error.message ?? "").toLowerCase();
    if (msg.includes("forbidden")) return errorResponse("forbidden");
    if (msg.includes("invite_not_found")) {
      return errorResponse("invalid_token");
    }
    if (msg.includes("invite_not_pending")) {
      return errorResponse("already_used");
    }
    if (msg.includes("unauthenticated")) {
      return errorResponse("unauthenticated");
    }
    const rpcErr = error as {
      message?: string;
      code?: string;
      details?: string;
      hint?: string;
    };
    console.warn(
      `[resend-invite] regenerate_invite_code RPC failed: ${rpcErr.message} (code=${rpcErr.code})`,
    );
    return errorResponse("internal", {
      rpc_error: rpcErr.message ?? "(no message)",
      rpc_code: rpcErr.code ?? null,
      rpc_details: rpcErr.details ?? null,
      rpc_hint: rpcErr.hint ?? null,
    });
  }

  // RPC returns the full new invite row as jsonb. Surface the bits the
  // client needs for the share screen.
  const row = data as Record<string, unknown> | null;
  if (!row) return errorResponse("internal");

  return okResponse({
    invite_id: row.id,
    human_code: row.human_code,
    expires_at: row.expires_at,
  });
});
