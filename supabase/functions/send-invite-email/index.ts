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

import { handlePreflight, corsHeaders } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { isValidEmail } from "../_shared/validation.ts";
import { getServiceClient } from "../_shared/db.ts";

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

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function expiryLine(expiresAt: string | null): string {
  if (!expiresAt) return "It can be used once.";
  const d = new Date(expiresAt);
  if (Number.isNaN(d.getTime())) return "It can be used once.";
  const formatted = d.toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
  });
  return `It expires on ${formatted} and can be used once.`;
}

function buildHtml(opts: {
  code: string;
  businessName: string;
  expiresAt: string | null;
}): string {
  const code = escapeHtml(opts.code);
  const business = escapeHtml(opts.businessName);
  const expiry = expiryLine(opts.expiresAt);
  return `<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#f4f5f7;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 0;">
      <tr>
        <td align="center">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:16px;overflow:hidden;">
            <tr>
              <td style="padding:28px 32px 8px 32px;">
                <div style="font-size:20px;font-weight:700;color:#111827;">Reebaplus</div>
              </td>
            </tr>
            <tr>
              <td style="padding:8px 32px 0 32px;">
                <p style="margin:0 0 8px 0;font-size:16px;color:#111827;font-weight:600;">You've been invited to join ${business}.</p>
                <p style="margin:0 0 20px 0;font-size:14px;color:#4b5563;line-height:1.5;">
                  Install Reebaplus POS, tap <b>Join with invite code</b>, and enter the code below to set up your account.
                </p>
              </td>
            </tr>
            <tr>
              <td style="padding:0 32px;">
                <div style="background:#eef2ff;border:1px solid #c7d2fe;border-radius:12px;padding:20px;text-align:center;">
                  <div style="font-size:32px;font-weight:700;letter-spacing:8px;color:#1e293b;font-family:monospace;">${code}</div>
                </div>
              </td>
            </tr>
            <tr>
              <td style="padding:16px 32px 28px 32px;">
                <p style="margin:0;font-size:13px;color:#6b7280;line-height:1.5;">
                  ${expiry} If you weren't expecting this invitation, you can safely ignore this email.
                </p>
              </td>
            </tr>
          </table>
          <p style="margin:16px 0 0 0;font-size:12px;color:#9ca3af;">Sent by Reebaplus POS</p>
        </td>
      </tr>
    </table>
  </body>
</html>`;
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

  const email = record.email.trim().toLowerCase();
  if (!isValidEmail(email)) {
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

  const html = buildHtml({
    code: record.code,
    businessName,
    expiresAt: record.expires_at ?? null,
  });

  const resendRes = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from: FROM,
      to: [email],
      subject: `Your invite code for ${businessName}`,
      html,
    }),
  });

  if (!resendRes.ok) {
    const detail = await resendRes.text();
    console.error("resend send failed", resendRes.status, detail);
    return jsonResponse(
      { ok: false, error: "email_send_failed", status: resendRes.status },
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
