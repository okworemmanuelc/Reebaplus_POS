// send-push / fcm_test.ts
//
// Unit tests for the PURE FCM logic (fcm.ts). No network, no Firebase — the
// send path is exercised through a fake FcmSender. Run: `deno test` in this
// directory. (Not yet wired into CI — there is no Deno test tier in this repo,
// same posture as the env-gated RPC golden tier.)

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  ANNOUNCEMENTS_CHANNEL_ID,
  type BroadcastRecord,
  buildFcmMessages,
  type FcmSender,
  type PushRecord,
  resolveRecipient,
  sendAll,
  titleForSeverity,
  tokenFilterFor,
} from "./fcm.ts";

const record: BroadcastRecord = {
  id: "notif-1",
  business_id: "biz-1",
  type: "console_broadcast",
  message: "Scheduled maintenance Sunday 2am.",
  severity: "info",
};

Deno.test("titleForSeverity is driven by severity, unknown → neutral", () => {
  assertEquals(titleForSeverity("alert"), "Reebaplus — Alert");
  assertEquals(titleForSeverity("warning"), "Reebaplus — Important");
  assertEquals(titleForSeverity("info"), "Reebaplus Announcement");
  assertEquals(titleForSeverity("nonsense"), "Reebaplus Announcement");
});

Deno.test("buildFcmMessages: one message per token, body = message", () => {
  const msgs = buildFcmMessages(record, ["tokA", "tokB"]);
  assertEquals(msgs.length, 2);
  assertEquals(msgs[0].message.token, "tokA");
  assertEquals(msgs[1].message.token, "tokB");
  assertEquals(msgs[0].message.notification.body, record.message);
  assertEquals(msgs[0].message.notification.title, "Reebaplus Announcement");
  assertEquals(
    msgs[0].message.android.notification.channel_id,
    ANNOUNCEMENTS_CHANNEL_ID,
  );
  assertEquals(msgs[0].message.android.priority, "high");
});

Deno.test("buildFcmMessages: severity drives the title", () => {
  const msgs = buildFcmMessages({ ...record, severity: "alert" }, ["t"]);
  assertEquals(msgs[0].message.notification.title, "Reebaplus — Alert");
});

Deno.test("buildFcmMessages: data block carries all ids as strings", () => {
  const data = buildFcmMessages(record, ["t"])[0].message.data;
  assertEquals(data.notification_id, "notif-1");
  assertEquals(data.type, "console_broadcast");
  assertEquals(data.severity, "info");
  assertEquals(data.business_id, "biz-1");
  for (const v of Object.values(data)) assert(typeof v === "string");
});

Deno.test("buildFcmMessages: empty tokens → no messages", () => {
  assertEquals(buildFcmMessages(record, []).length, 0);
});

Deno.test("sendAll: counts accepted and collects tokens to prune", async () => {
  // Fake sender: 'dead' is UNREGISTERED, 'boom' fails but is NOT prunable.
  const fake: FcmSender = (_at, _pid, msg) => {
    const token = msg.message.token;
    if (token === "dead") {
      return Promise.resolve({ token, ok: false, unregistered: true });
    }
    if (token === "boom") {
      return Promise.resolve({ token, ok: false, unregistered: false });
    }
    return Promise.resolve({ token, ok: true, unregistered: false });
  };
  const msgs = buildFcmMessages(record, ["live1", "dead", "boom", "live2"]);
  const { sent, prune } = await sendAll(fake, "at", "proj", msgs);
  assertEquals(sent, 2); // live1 + live2
  assertEquals(prune, ["dead"]); // only the UNREGISTERED one
});

// ── #476: recipient routing (staff by business, Shopper by auth user) ────────

const shopperRecord: PushRecord = {
  id: "push-1",
  type: "shopper_order_update",
  message: "Your order was accepted.",
  severity: "info",
  auth_user_id: "auth-1",
  title: "Order accepted",
};

Deno.test("resolveRecipient: console broadcast routes by business (unchanged)", () => {
  const r = resolveRecipient(record);
  assertEquals(r, { audience: "staff", businessId: "biz-1" });
  assertEquals(tokenFilterFor(r!), { column: "business_id", value: "biz-1" });
});

Deno.test("resolveRecipient: Shopper push routes by auth user id", () => {
  const r = resolveRecipient(shopperRecord);
  assertEquals(r, { audience: "shopper", authUserId: "auth-1" });
  assertEquals(tokenFilterFor(r!), { column: "auth_user_id", value: "auth-1" });
});

Deno.test("resolveRecipient: never routes by both keys or by neither", () => {
  // A Shopper push carrying a business must not fan out to that business.
  assertEquals(resolveRecipient({ ...shopperRecord, business_id: "biz-1" }), null);
  assertEquals(resolveRecipient({ ...shopperRecord, auth_user_id: null }), null);
  assertEquals(resolveRecipient({ ...record, business_id: "" }), null);
  // Other types never push, whatever key they carry.
  assertEquals(resolveRecipient({ ...record, type: "low_stock" }), null);
  assertEquals(
    resolveRecipient({ ...shopperRecord, type: "sale_rejected" }),
    null,
  );
  assertEquals(resolveRecipient(null), null);
  assertEquals(resolveRecipient({ id: "x" }), null);
});

Deno.test("buildFcmMessages: audience tags a shared phone's two roles", () => {
  const staff = buildFcmMessages(record, ["t"])[0].message;
  assertEquals(staff.data.audience, "staff");
  assertEquals(staff.data.business_id, "biz-1");

  const shopper = buildFcmMessages(shopperRecord, ["t"], "shopper")[0].message;
  assertEquals(shopper.data.audience, "shopper");
  assertEquals(shopper.data.type, "shopper_order_update");
  assert(!("business_id" in shopper.data));
  assertEquals(shopper.notification.title, "Order accepted");
  assertEquals(
    buildFcmMessages({ ...shopperRecord, title: null }, ["t"], "shopper")[0]
      .message.notification.title,
    "Reebaplus",
  );
});
