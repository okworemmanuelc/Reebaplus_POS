// check-invite-email — UX-only pre-validation for the InviteModal step 1.
//
// Authenticated. Runs every check that does NOT require role/warehouse —
// i.e. everything the admin can know about an email before picking the
// rest of the invite. send-invite re-runs all of these (defense in depth);
// this endpoint exists so the modal can short-circuit before showing
// step 2 when the email is hopeless.
//
// Does NOT write a row. Does NOT consume any rate-limit budget. Returns
// `{ok: true}` or one of: invalid_email, disposable_email, self_invite,
// already_member, other_business_owner, invite_pending, rate_limited,
// forbidden, unauthenticated.

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import {
  isDisposableEmail,
  isValidEmail,
} from "../_shared/validation.ts";
import { getCallerClient, getServiceClient } from "../_shared/db.ts";
import { loadCaller } from "../_shared/auth.ts";

const DAILY_LIMIT = parseInt(
  Deno.env.get("INVITE_DAILY_LIMIT_PER_BUSINESS") ?? "50",
  10,
);

Deno.serve(async (req) => {
  const pre = handlePreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") {
    return errorResponse("invalid_payload");
  }

  let body: { email?: string };
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_payload");
  }

  const email = (body.email ?? "").trim().toLowerCase();

  const service = getServiceClient();
  const caller = getCallerClient(req);
  const ctx = await loadCaller(caller, service);
  if (!ctx) return errorResponse("unauthenticated");
  if (ctx.roleTier < 5) return errorResponse("forbidden");

  if (!isValidEmail(email)) return errorResponse("invalid_email");
  if (isDisposableEmail(email)) return errorResponse("disposable_email");
  if (email === ctx.email) return errorResponse("self_invite");

  const { data: isMember, error: memErr } = await service.rpc(
    "is_business_member_email",
    { p_business_id: ctx.businessId, p_email: email },
  );
  if (memErr) return errorResponse("internal");
  if (isMember === true) return errorResponse("already_member");

  const { data: isOwner, error: ownErr } = await service.rpc(
    "is_other_business_owner",
    { p_email: email, p_exclude_business_id: ctx.businessId },
  );
  if (ownErr) return errorResponse("internal");
  if (isOwner === true) return errorResponse("other_business_owner");

  const { data: pending } = await service
    .from("invites")
    .select("id, expires_at")
    .eq("business_id", ctx.businessId)
    .ilike("email", email)
    .eq("status", "pending")
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  if (pending) {
    return errorResponse("invite_pending", {
      invite_id: pending.id,
      expires_at: pending.expires_at,
    });
  }

  // Rate limit derived from the table itself — same query send-invite
  // runs. Done last so admins hit the cheaper errors first.
  const startOfDay = new Date();
  startOfDay.setUTCHours(0, 0, 0, 0);
  const { count, error: cntErr } = await service
    .from("invites")
    .select("id", { count: "exact", head: true })
    .eq("business_id", ctx.businessId)
    .gte("created_at", startOfDay.toISOString());
  if (cntErr) return errorResponse("internal");
  if ((count ?? 0) >= DAILY_LIMIT) return errorResponse("rate_limited");

  return okResponse({});
});
