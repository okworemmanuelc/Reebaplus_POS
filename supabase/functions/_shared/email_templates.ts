// _shared/email_templates.ts
//
// PURE email rendering shared by `send-email` (#434) and `send-invite-email`.
// No I/O except `sendResendEmail`, whose fetch is injectable for tests. Every
// value that reaches HTML goes through escapeHtml; subjects are plain text.

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export interface RenderedEmail {
  subject: string;
  html: string;
}

/// The Reebaplus card layout. [heading] and [body] are ALREADY-ESCAPED HTML.
export function emailLayout(opts: {
  heading: string;
  body: string;
  footnote?: string;
}): string {
  const footnote = opts.footnote
    ? `<tr>
              <td style="padding:16px 32px 28px 32px;">
                <p style="margin:0;font-size:13px;color:#6b7280;line-height:1.5;">${opts.footnote}</p>
              </td>
            </tr>`
    : `<tr><td style="padding:0 0 20px 0;"></td></tr>`;
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
                <p style="margin:0 0 8px 0;font-size:16px;color:#111827;font-weight:600;">${opts.heading}</p>
                ${opts.body}
              </td>
            </tr>
            ${footnote}
          </table>
          <p style="margin:16px 0 0 0;font-size:12px;color:#9ca3af;">Sent by Reebaplus</p>
        </td>
      </tr>
    </table>
  </body>
</html>`;
}

const para = (escapedHtml: string) =>
  `<p style="margin:0 0 16px 0;font-size:14px;color:#4b5563;line-height:1.5;">${escapedHtml}</p>`;

// ── Staff invite (send-invite-email) ─────────────────────────────────────────

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

export function renderInviteEmail(opts: {
  code: string;
  businessName: string;
  expiresAt: string | null;
}): RenderedEmail {
  const code = escapeHtml(opts.code);
  const business = escapeHtml(opts.businessName);
  return {
    subject: `Your invite code for ${opts.businessName}`,
    html: emailLayout({
      heading: `You've been invited to join ${business}.`,
      body: `<p style="margin:0 0 20px 0;font-size:14px;color:#4b5563;line-height:1.5;">
                  Install Reebaplus POS, tap <b>Join with invite code</b>, and enter the code below to set up your account.
                </p>
                <div style="background:#eef2ff;border:1px solid #c7d2fe;border-radius:12px;padding:20px;text-align:center;">
                  <div style="font-size:32px;font-weight:700;letter-spacing:8px;color:#1e293b;font-family:monospace;">${code}</div>
                </div>`,
      footnote: `${
        expiryLine(opts.expiresAt)
      } If you weren't expecting this invitation, you can safely ignore this email.`,
    }),
  };
}

// ── Shopper templates (send-email, #434) ─────────────────────────────────────

export const ORDER_TEMPLATES = [
  "order_accepted",
  "order_changed",
  "order_declined",
  "order_cancelled",
  "order_sent_out",
] as const;
export const EMAIL_TEMPLATES = [
  ...ORDER_TEMPLATES,
  "account_deleted",
] as const;
export type EmailTemplate = typeof EMAIL_TEMPLATES[number];

export function isEmailTemplate(v: unknown): v is EmailTemplate {
  return typeof v === "string" &&
    (EMAIL_TEMPLATES as readonly string[]).includes(v);
}

/// String fields a template may use. Missing / non-string values read as "".
export type TemplateData = Record<string, unknown>;

const str = (d: TemplateData, k: string): string => {
  const v = d[k];
  return typeof v === "string" ? v.trim() : "";
};

const firstName = (d: TemplateData): string =>
  str(d, "shopper_name").split(/\s+/)[0] ?? "";

const MY_ORDERS_LINE = "You can follow every order in My Orders.";

/// Render one Shopper template, or null when required data is missing (the
/// caller skips the send rather than mailing a half-empty message).
export function renderTemplate(
  template: EmailTemplate,
  data: TemplateData,
): RenderedEmail | null {
  if (template === "account_deleted") {
    const name = firstName(data);
    return {
      subject: "Your Reebaplus account has been deleted",
      html: emailLayout({
        heading: `${name ? `Hi ${escapeHtml(name)}, y` : "Y"}our account has been deleted.`,
        body: para(
          "Your Reebaplus shopping account and its saved details have been removed. " +
            "Shops keep the record of orders you placed with them, without your account.",
        ),
        footnote:
          "If you didn't ask for this, reply to this email and we'll look into it.",
      }),
    };
  }

  const ref = str(data, "reference");
  const biz = str(data, "business_name");
  if (!ref || !biz) return null;
  const eRef = escapeHtml(ref);
  const eBiz = escapeHtml(biz);
  const reason = str(data, "reason");
  const phone = str(data, "store_phone");
  const name = firstName(data);
  const greeting = name ? para(`Hi ${escapeHtml(name)},`) : "";
  const reasonLine = reason ? para(`Reason: ${escapeHtml(reason)}`) : "";
  const phoneLine = phone
    ? para(`Questions? Call the shop on ${escapeHtml(phone)}.`)
    : "";

  let subject: string;
  let heading: string;
  let body: string;
  switch (template) {
    case "order_accepted":
      subject = `Order ${ref} accepted`;
      heading = `${eBiz} accepted your order ${eRef}.`;
      body = para("They are getting it ready. You pay when it is delivered.");
      break;
    case "order_changed":
      subject = `Order ${ref} changed`;
      heading = `${eBiz} changed your order ${eRef}.`;
      body = para(
        "Some items were reduced or removed before the shop accepted it. " +
          "Open My Orders to see what is coming.",
      );
      break;
    case "order_declined":
      subject = `Order ${ref} declined`;
      heading = `${eBiz} declined your order ${eRef}.`;
      body = reasonLine;
      break;
    case "order_cancelled":
      subject = `Order ${ref} cancelled`;
      heading = `${eBiz} cancelled your order ${eRef}.`;
      body = reasonLine;
      break;
    case "order_sent_out":
      subject = `Order ${ref} sent out`;
      heading = `${eBiz} has sent out your order ${eRef}.`;
      body = para("It is on its way. You pay when it is delivered.");
      break;
  }
  return {
    subject,
    html: emailLayout({
      heading,
      body: greeting + body + phoneLine,
      footnote: MY_ORDERS_LINE,
    }),
  };
}

// ── Resend transport ─────────────────────────────────────────────────────────

export type Fetcher = typeof fetch;

export async function sendResendEmail(opts: {
  apiKey: string;
  from: string;
  to: string;
  email: RenderedEmail;
  fetcher?: Fetcher;
}): Promise<{ ok: true } | { ok: false; status: number; detail: string }> {
  const res = await (opts.fetcher ?? fetch)("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${opts.apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from: opts.from,
      to: [opts.to],
      subject: opts.email.subject,
      html: opts.email.html,
    }),
  });
  if (res.ok) return { ok: true };
  return { ok: false, status: res.status, detail: await res.text() };
}
