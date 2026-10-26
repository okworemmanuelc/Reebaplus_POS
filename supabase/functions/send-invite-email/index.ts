// send-invite-email
//
// Server-side delivery of staff invite codes by email, branded as Reebaplus.
//
// Invocation: this function is NOT called by the app client. It is called by
// an AFTER INSERT trigger on public.invite_codes (via pg_net) the moment a
// freshly-synced invite row lands in Postgres. That keeps the client thin and
// makes the email fire even for invites created offline — the email goes out
// when the row finally syncs. The instant Copy / SMS / WhatsApp share on the
// device covers the offline window.
//
// Auth: the trigger sends a shared secret in the `x-invite-hook-secret`
// header (INVITE_EMAIL_HOOK_SECRET). There is no user JWT on this path, so the
// secret is the only gate — reject anything that doesn't match.
//
// Idempotency: the function stamps invite_codes.invite_email_sent_at on
// success. The trigger is AFTER INSERT only, so the sync engine's re-push
// upserts (which fire UPDATE, not INSERT) never re-invoke this. The sent-at
// stamp is belt-and-suspenders and gives operators an observable timestamp.
//
// #434: the HTML and the Resend call live in ../_shared/email_templates.ts,
// shared with `send-email`. This function's contract is unchanged.

import { handlePreflight, corsHeaders } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { isValidEmail } from "../_shared/validation.ts";
import { getServiceClient } from "../_shared/db.ts";
import {
  renderInviteEmail,
  sendResendEmail,
} from "../_shared/email_templates.ts";

interface InviteRecord {
  id: string;
  code: string;
  email: string;
  business_id: string;
  expires_at: string | null;
  invite_email_sent_at?: string | null;
}

interface HookPayload {
  record: InviteRecord;
}

const FROM = Deno.env.get("INVITE_EMAIL_FROM") ??
  "Reebaplus <no-reply@reebaplus.com>";

function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse("invalid_payload");
  }

  // Shared-secret gate — this path has no user JWT.
  const expectedSecret = Deno.env.get("INVITE_EMAIL_HOOK_SECRET");
  const providedSecret = req.headers.get("x-invite-hook-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return errorResponse("unauthenticated");
  }

  let payload: HookPayload;
  try {
    payload = await req.json() as HookPayload;
  } catch (_e) {
    return errorResponse("invalid_payload");
  }

  const record = payload?.record;
  if (
    !record ||
    typeof record.id !== "string" ||
    typeof record.code !== "string" ||
    typeof record.email !== "string" ||
    typeof record.business_id !== "string"
  ) {
    return errorResponse("invalid_payload");
  }

  const emailAddress = record.email.trim().toLowerCase();
  if (!isValidEmail(emailAddress)) {
    return errorResponse("invalid_email");
  }

  // Already emailed — never double-send.
  if (record.invite_email_sent_at) {
    return okResponse({ skipped: "already_sent" });
  }

  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) {
    console.error("RESEND_API_KEY not configured");
    return errorResponse("internal");
  }

  const service = getServiceClient();

  // Resolve the business name for the email body. Fall back to a neutral
  // phrase rather than failing the whole send if the lookup misses.
  let businessName = "your team on Reebaplus";
  const { data: biz, error: bizErr } = await service
    .from("businesses")
    .select("name")
    .eq("id", record.business_id)
    .maybeSingle();
  if (bizErr) {
    console.error("business lookup failed", bizErr.message);
  } else if (biz?.name && typeof biz.name === "string") {
    businessName = biz.name;
  }

  const email = renderInviteEmail({
    code: record.code,
    businessName,
    expiresAt: record.expires_at ?? null,
  });

  const sent = await sendResendEmail({
    apiKey: resendKey,
    from: FROM,
    to: emailAddress,
    email,
  });

  if (!sent.ok) {
    console.error("resend send failed", sent.status, sent.detail);
    return jsonResponse(
      { ok: false, error: "email_send_failed", status: sent.status },
      502,
    );
  }

  // Stamp the sent timestamp (observability + double-send guard).
  const { error: stampErr } = await service
    .from("invite_codes")
    .update({ invite_email_sent_at: new Date().toISOString() })
    .eq("id", record.id);
  if (stampErr) {
    // Email already went out; log but don't fail the request.
    console.error("invite_email_sent_at stamp failed", stampErr.message);
  }

  return okResponse({ sent: true });
});
