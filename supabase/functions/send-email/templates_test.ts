// send-email / templates_test.ts
//
// Unit tests for the PURE templates in ../_shared/email_templates.ts. No
// network: the Resend call goes through a fake fetch. Run: `deno test` in this
// directory (no Deno CI tier yet, same posture as send-push/fcm_test.ts).

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  EMAIL_TEMPLATES,
  escapeHtml,
  isEmailTemplate,
  ORDER_TEMPLATES,
  renderInviteEmail,
  renderTemplate,
  sendResendEmail,
} from "../_shared/email_templates.ts";

const data = {
  reference: "ON-123",
  business_name: "Ada's <Drinks>",
  shopper_name: "Chidi Okafor",
  store_phone: "0803 000 0000",
  reason: "Out of stock",
};

Deno.test("escapeHtml escapes the HTML specials", () => {
  assertEquals(escapeHtml(`<a href="x">&</a>`), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;");
});

Deno.test("isEmailTemplate: the six templates only", () => {
  assertEquals(EMAIL_TEMPLATES.length, 6);
  for (const t of EMAIL_TEMPLATES) assert(isEmailTemplate(t));
  assert(!isEmailTemplate("invite"));
  assert(!isEmailTemplate("order_cancelled_by_customer"));
  assert(!isEmailTemplate(null));
});

Deno.test("every order template renders, escaped, with reference + shop", () => {
  for (const t of ORDER_TEMPLATES) {
    const e = renderTemplate(t, data)!;
    assert(e.subject.includes("ON-123"), t);
    assert(e.html.includes("Ada's &lt;Drinks&gt;"), t);
    assert(!e.html.includes("<Drinks>"), `${t} must escape the shop name`);
    assert(e.html.includes("Hi Chidi,"), t);
    assert(e.html.includes("0803 000 0000"), t);
  }
});

Deno.test("subjects name the event", () => {
  assertEquals(renderTemplate("order_accepted", data)!.subject, "Order ON-123 accepted");
  assertEquals(renderTemplate("order_changed", data)!.subject, "Order ON-123 changed");
  assertEquals(renderTemplate("order_declined", data)!.subject, "Order ON-123 declined");
  assertEquals(renderTemplate("order_cancelled", data)!.subject, "Order ON-123 cancelled");
  assertEquals(renderTemplate("order_sent_out", data)!.subject, "Order ON-123 sent out");
});

Deno.test("declined / cancelled carry the reason; accepted does not", () => {
  assert(renderTemplate("order_declined", data)!.html.includes("Reason: Out of stock"));
  assert(renderTemplate("order_cancelled", data)!.html.includes("Reason: Out of stock"));
  assert(!renderTemplate("order_accepted", data)!.html.includes("Reason:"));
});

Deno.test("order templates skip when reference or shop is missing", () => {
  assertEquals(renderTemplate("order_accepted", { ...data, reference: "" }), null);
  assertEquals(renderTemplate("order_accepted", { ...data, business_name: 3 }), null);
});

Deno.test("account_deleted renders without order data", () => {
  const e = renderTemplate("account_deleted", { shopper_name: "<b>Bo</b>" })!;
  assertEquals(e.subject, "Your Reebaplus account has been deleted");
  assert(e.html.includes("Hi &lt;b&gt;Bo&lt;/b&gt;"));
  assert(renderTemplate("account_deleted", {})!.html.includes("Your account has been deleted."));
});

Deno.test("invite email keeps its code, escaped business and expiry", () => {
  const e = renderInviteEmail({ code: "AB12CD", businessName: "A&B", expiresAt: null });
  assertEquals(e.subject, "Your invite code for A&B");
  assert(e.html.includes("AB12CD"));
  assert(e.html.includes("A&amp;B"));
  assert(e.html.includes("It can be used once."));
});

Deno.test("sendResendEmail posts one message and reports failures", async () => {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const ok = await sendResendEmail({
    apiKey: "k",
    from: "F <f@x.com>",
    to: "s@x.com",
    email: { subject: "S", html: "<p>h</p>" },
    fetcher: (async (url: string, init: RequestInit) => {
      calls.push({ url, body: JSON.parse(init.body as string) });
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch,
  });
  assertEquals(ok, { ok: true });
  assertEquals(calls[0].url, "https://api.resend.com/emails");
  assertEquals(calls[0].body.to, ["s@x.com"]);

  const bad = await sendResendEmail({
    apiKey: "k",
    from: "f",
    to: "s@x.com",
    email: { subject: "S", html: "h" },
    fetcher: (async () => new Response("nope", { status: 422 })) as unknown as typeof fetch,
  });
  assertEquals(bad, { ok: false, status: 422, detail: "nope" });
});
