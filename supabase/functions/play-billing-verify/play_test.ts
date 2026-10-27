import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  decodeRtdn,
  isEntitled,
  needsAcknowledge,
  parseSubscriptionV2,
  secretMatches,
} from "./play.ts";

const base = {
  subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
  acknowledgementState: "ACKNOWLEDGEMENT_STATE_PENDING",
  externalAccountIdentifiers: { obfuscatedExternalAccountId: "biz-1" },
  lineItems: [{
    productId: "reebaplus_premium",
    expiryTime: "2099-01-01T00:00:00Z",
    latestSuccessfulOrderId: "GPA.1",
    offerDetails: { basePlanId: "yearly" },
  }],
};

Deno.test("parses an active premium yearly purchase", () => {
  const p = parseSubscriptionV2(base)!;
  assertEquals(p.productId, "reebaplus_premium");
  assertEquals(p.basePlanId, "yearly");
  assertEquals(p.state, "ACTIVE");
  assertEquals(p.obfuscatedAccountId, "biz-1");
  assertEquals(needsAcknowledge(p), true);
});

Deno.test("rejects unknown product / base plan / junk", () => {
  assertEquals(parseSubscriptionV2(null), null);
  assertEquals(
    parseSubscriptionV2({ ...base, lineItems: [{ productId: "other", offerDetails: { basePlanId: "monthly" } }] }),
    null,
  );
  assertEquals(
    parseSubscriptionV2({ ...base, lineItems: [{ productId: "reebaplus_basic", offerDetails: { basePlanId: "weekly" } }] }),
    null,
  );
});

Deno.test("entitlement by state", () => {
  const now = Date.parse("2026-01-01T00:00:00Z");
  assertEquals(isEntitled({ state: "ACTIVE", expiryTime: null }, now), true);
  assertEquals(isEntitled({ state: "IN_GRACE_PERIOD", expiryTime: null }, now), true);
  assertEquals(isEntitled({ state: "CANCELED", expiryTime: "2026-02-01T00:00:00Z" }, now), true);
  assertEquals(isEntitled({ state: "CANCELED", expiryTime: "2025-12-01T00:00:00Z" }, now), false);
  assertEquals(isEntitled({ state: "ON_HOLD", expiryTime: "2026-02-01T00:00:00Z" }, now), false);
  assertEquals(isEntitled({ state: "EXPIRED", expiryTime: null }, now), false);
});

Deno.test("acknowledged purchases need no ack", () => {
  const p = parseSubscriptionV2({ ...base, acknowledgementState: "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" })!;
  assertEquals(needsAcknowledge(p), false);
});

Deno.test("decodes subscription RTDN, ignores others", () => {
  const enc = (o: unknown) => btoa(JSON.stringify(o));
  const t = decodeRtdn({ message: { data: enc({
    packageName: "com.x", subscriptionNotification: { notificationType: 13, purchaseToken: "tok", subscriptionId: "reebaplus_basic" },
  }) } })!;
  assertEquals(t.purchaseToken, "tok");
  assertEquals(t.notificationType, 13);
  assertEquals(decodeRtdn({ message: { data: enc({ packageName: "com.x", testNotification: {} }) } }), null);
  assertEquals(decodeRtdn({ message: { data: "!!!" } }), null);
  assertEquals(decodeRtdn({}), null);
});

Deno.test("secret compare", () => {
  assertEquals(secretMatches("abc", "abc"), true);
  assertEquals(secretMatches("abc", "abd"), false);
  assertEquals(secretMatches(undefined, "abc"), false);
  assertEquals(secretMatches("abc", null), false);
});
