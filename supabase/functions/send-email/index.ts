// send-email
//
// One server-side email sender with templates (#434): Shopper order updates
// (order_accepted / order_changed / order_declined / order_cancelled /
// order_sent_out) and the account-deletion confirmation (account_deleted).
// Templates + the Resend call live in ../_shared/email_templates.ts, shared
// with send-invite-email (whose contract is unchanged).
//
// Invocation: NOT called by the app client. The 0218 triggers on
// public.online_orders / online_order_lines POST here via pg_net for Shoppers
// who are not reachable by Android push (web-link and iPhone Shoppers).
// Body: { template, to, data }.
//
// Auth: no user JWT on this path (deploy with --no-verify-jwt). The trigger
// sends the shared DB-hook secret in `x-push-hook-secret` (PUSH_HOOK_SECRET,
// the same Edge secret send-push already uses; Vault `push_hook_secret`).
// That secret is the only gate — reject anything that doesn't match.
//
// Config: RESEND_API_KEY (already set for send-invite-email); sender address
// EMAIL_FROM, falling back to INVITE_EMAIL_FROM, then the Reebaplus default.

import { handlePreflight, corsHeaders } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { isValidEmail } from "../_shared/validation.ts";
import {
  isEmailTemplate,
  renderTemplate,
  sendResendEmail,
} from "../_shared/email_templates.ts";

const FROM = Deno.env.get("EMAIL_FROM") ??
  Deno.env.get("INVITE_EMAIL_FROM") ??
  "Reebaplus <no-reply@reebaplus.com>";

function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders },
  });
}

interface EmailPayload {
  template?: unknown;
  to?: unknown;
  data?: unknown;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") return errorResponse("invalid_payload");

  // Shared-secret gate — this path has no user JWT.
  const expected = Deno.env.get("PUSH_HOOK_SECRET");
  const provided = req.headers.get("x-push-hook-secret");
  if (!expected || provided !== expected) {
    return errorResponse("unauthenticated");
  }

  let payload: EmailPayload;
  try {
    payload = await req.json() as EmailPayload;
  } catch (_e) {
    return errorResponse("invalid_payload");
  }

  // Unknown templates are skipped, never sent.
  if (!isEmailTemplate(payload?.template)) {
    return okResponse({ skipped: "unknown_template" });
  }
  if (typeof payload.to !== "string") return errorResponse("invalid_payload");
  const to = payload.to.trim().toLowerCase();
  if (!isValidEmail(to)) return errorResponse("invalid_email");

  const data = payload.data && typeof payload.data === "object"
    ? payload.data as Record<string, unknown>
    : {};
  const email = renderTemplate(payload.template, data);
  if (!email) return okResponse({ skipped: "missing_data" });

  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) {
    console.error("RESEND_API_KEY not configured");
    return errorResponse("internal");
  }

  const sent = await sendResendEmail({ apiKey: resendKey, from: FROM, to, email });
  if (!sent.ok) {
    console.error("resend send failed", sent.status, sent.detail);
    return jsonResponse(
      { ok: false, error: "email_send_failed", status: sent.status },
      502,
    );
  }
  return okResponse({ sent: true });
});
