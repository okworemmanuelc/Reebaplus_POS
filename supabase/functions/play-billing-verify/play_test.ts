import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  billingIssueForState,
  businessForUnknownToken,
  decideApply,
  decodeRtdn,
  RTDN_REVOKED,
  replacedToken,
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

// ── #589 plan switching ──────────────────────────────────────────────────────

Deno.test("upgrade: linkedPurchaseToken names the token it replaces", () => {
  const p = parseSubscriptionV2({ ...base, linkedPurchaseToken: "old" })!;
  assertEquals(p.linkedPurchaseToken, "old");
  assertEquals(replacedToken("new", p), "old");
  assertEquals(replacedToken("old", p), null); // never itself
  assertEquals(replacedToken("new", parseSubscriptionV2(base)!), null);
});

Deno.test("deferred downgrade keeps the owned higher plan until renewal", () => {
  const p = parseSubscriptionV2({
    ...base,
    linkedPurchaseToken: "old",
    lineItems: [
      { // being switched to: not owned yet, later expiry
        productId: "reebaplus_basic",
        expiryTime: "2099-06-01T00:00:00Z",
        offerDetails: { basePlanId: "monthly" },
      },
      { // owned now, ends at renewal
        productId: "reebaplus_premium",
        expiryTime: "2099-01-01T00:00:00Z",
        latestSuccessfulOrderId: "GPA.1",
        offerDetails: { basePlanId: "yearly" },
        deferredItemReplacement: { productId: "reebaplus_basic" },
      },
    ],
  })!;
  assertEquals(p.productId, "reebaplus_premium");
  assertEquals(p.basePlanId, "yearly");
  assertEquals(p.expiryTime, "2099-01-01T00:00:00Z");
  assertEquals(p.deferredProductId, "reebaplus_basic");
});

Deno.test("deferred same-product cycle change (yearly -> monthly) keeps yearly", () => {
  const p = parseSubscriptionV2({
    ...base,
    lineItems: [
      {
        productId: "reebaplus_premium",
        expiryTime: "2099-02-01T00:00:00Z",
        offerDetails: { basePlanId: "monthly" },
      },
      {
        productId: "reebaplus_premium",
        expiryTime: "2099-01-01T00:00:00Z",
        latestSuccessfulOrderId: "GPA.1",
        offerDetails: { basePlanId: "yearly" },
        deferredItemReplacement: { productId: "reebaplus_premium" },
      },
    ],
  })!;
  assertEquals(p.basePlanId, "yearly");
});

Deno.test("after renewal into the deferred plan, the new plan applies", () => {
  const p = parseSubscriptionV2({
    ...base,
    lineItems: [{
      productId: "reebaplus_basic",
      expiryTime: "2099-02-01T00:00:00Z",
      latestSuccessfulOrderId: "GPA.2",
      offerDetails: { basePlanId: "monthly" },
    }],
  })!;
  assertEquals(p.productId, "reebaplus_basic");
  assertEquals(p.deferredProductId, null);
});

const NOW = Date.parse("2026-06-01T00:00:00Z");
const paidPrior = { state: "ACTIVE", expiryTime: "2026-07-01T00:00:00Z" };

Deno.test("a replaced token never changes the plan, whatever it says", () => {
  for (const state of ["EXPIRED", "ACTIVE", "CANCELED", "ON_HOLD"] as const) {
    assertEquals(
      decideApply({
        verified: { state, expiryTime: "2026-07-01T00:00:00Z" },
        replacedBy: "new",
        prior: paidPrior,
        notificationType: 13,
        now: NOW,
      }),
      { apply: false, reason: "replaced" },
    );
  }
});

Deno.test("old-token lapse arriving BEFORE the new token is held, not downgraded", () => {
  assertEquals(
    decideApply({
      verified: { state: "EXPIRED", expiryTime: "2026-06-01T00:00:00Z" },
      replacedBy: null,
      prior: paidPrior,
      notificationType: 13,
      now: NOW,
    }),
    { apply: false, reason: "early_lapse_held" },
  );
});

Deno.test("a revoke (refund) applies at once even mid-period", () => {
  assertEquals(
    decideApply({
      verified: { state: "EXPIRED", expiryTime: "2026-06-01T00:00:00Z" },
      replacedBy: null,
      prior: paidPrior,
      notificationType: RTDN_REVOKED,
      now: NOW,
    }),
    { apply: true },
  );
});

Deno.test("a natural lapse after the paid period applies", () => {
  assertEquals(
    decideApply({
      verified: { state: "EXPIRED", expiryTime: "2026-05-31T00:00:00Z" },
      replacedBy: null,
      prior: { state: "CANCELED", expiryTime: "2026-05-31T00:00:00Z" },
      notificationType: 13,
      now: NOW,
    }),
    { apply: true },
  );
  // ON_HOLD / unknown prior / entitled updates are never held.
  assertEquals(
    decideApply({
      verified: { state: "ON_HOLD", expiryTime: null },
      replacedBy: null,
      prior: paidPrior,
      notificationType: 5,
      now: NOW,
    }).apply,
    true,
  );
  assertEquals(
    decideApply({
      verified: { state: "EXPIRED", expiryTime: null },
      replacedBy: null,
      prior: null,
      notificationType: 13,
      now: NOW,
    }).apply,
    true,
  );
  assertEquals(
    decideApply({
      verified: { state: "ACTIVE", expiryTime: "2026-07-01T00:00:00Z" },
      replacedBy: null,
      prior: paidPrior,
      notificationType: 2,
      now: NOW,
    }).apply,
    true,
  );
});

Deno.test("an unknown RTDN token binds only through a known linked token", () => {
  assertEquals(businessForUnknownToken({ obfuscatedAccountId: null }, "biz-1"), "biz-1");
  assertEquals(businessForUnknownToken({ obfuscatedAccountId: "biz-1" }, "biz-1"), "biz-1");
  assertEquals(businessForUnknownToken({ obfuscatedAccountId: "biz-2" }, "biz-1"), null);
  assertEquals(businessForUnknownToken({ obfuscatedAccountId: "biz-1" }, null), null);
});

Deno.test("billing issue (#591): grace and hold from the Play state, else cleared", () => {
  assertEquals(billingIssueForState("IN_GRACE_PERIOD"), "grace");
  assertEquals(billingIssueForState("ON_HOLD"), "hold");
  for (const s of ["ACTIVE", "CANCELED", "EXPIRED", "PAUSED", "PENDING", "UNSPECIFIED"] as const) {
    assertEquals(billingIssueForState(s), null);
  }
  // Parsed straight from a Play response.
  const grace = parseSubscriptionV2({ ...base, subscriptionState: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" })!;
  assertEquals(billingIssueForState(grace.state), "grace");
  const hold = parseSubscriptionV2({ ...base, subscriptionState: "SUBSCRIPTION_STATE_ON_HOLD" })!;
  assertEquals(billingIssueForState(hold.state), "hold");
});

Deno.test("billing issue (#591): ON_HOLD and grace always reach apply_play_purchase", () => {
  for (const state of ["ON_HOLD", "IN_GRACE_PERIOD"] as const) {
    assertEquals(
      decideApply({
        verified: { state, expiryTime: "2026-06-01T00:00:00Z" },
        replacedBy: null,
        prior: { state: "ACTIVE", expiryTime: "2026-06-01T00:00:00Z" },
        notificationType: state === "ON_HOLD" ? 5 : 6,
        now: Date.parse("2026-06-02T00:00:00Z"),
      }).apply,
      true,
    );
  }
});
