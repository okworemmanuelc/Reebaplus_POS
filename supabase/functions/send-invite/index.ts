// send-invite — issue a fresh invitation for {email, role, warehouse_id}.
//
// Authenticated; caller must have role_tier ≥ 4. Runs the full pre-check
// ladder (defense in depth — check-invite-email is a UX shortcut, not a
// security gate), generates an 8-character human_code, inserts the
// invites row via service_role, and returns the code to the admin's
// client. The admin shares it via WhatsApp / SMS / Email / paper from
// the modal success screen.

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { getCallerClient, getServiceClient } from "../_shared/db.ts";
import { loadCaller } from "../_shared/auth.ts";
import { issueInvite } from "../_shared/issue.ts";

interface RequestBody {
  email?: string;
  role?: string;
  warehouse_id?: string | null;
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

  const service = getServiceClient();
  const caller = getCallerClient(req);
  const ctx = await loadCaller(caller, service);
  if (!ctx) return errorResponse("unauthenticated");
  if (ctx.roleTier < 5) return errorResponse("forbidden");

  const result = await issueInvite(service, ctx, {
    email: body.email ?? "",
    role: body.role ?? "",
    warehouseId: body.warehouse_id ?? null,
  });

  if (!result.ok) {
    return errorResponse(result.error, result.details);
  }

  return okResponse({
    invite_id: result.inviteId,
    human_code: result.humanCode,
    expires_at: result.expiresAt,
  });
});
