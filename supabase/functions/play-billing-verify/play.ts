// play-billing-verify / play.ts
//
// PURE logic for Google Play subscription verification (#90 slice B). No I/O:
// the Google API calls and DB writes live in index.ts, so everything here is
// unit-testable (play_test.ts).

export const PRODUCT_IDS = ["reebaplus_basic", "reebaplus_premium"] as const;
export const BASE_PLAN_IDS = ["monthly", "yearly"] as const;

/** Play SubscriptionPurchaseV2 `subscriptionState`, prefix stripped. */
export type PlayState =
  | "PENDING"
  | "ACTIVE"
  | "PAUSED"
  | "IN_GRACE_PERIOD"
  | "ON_HOLD"
  | "CANCELED"
  | "EXPIRED"
  | "PENDING_PURCHASE_CANCELED"
  | "UNSPECIFIED";

export interface VerifiedPurchase {
  productId: string;
  basePlanId: string;
  orderId: string | null;
  state: PlayState;
  expiryTime: string | null; // ISO
  acknowledged: boolean;
  obfuscatedAccountId: string | null;
  linkedPurchaseToken: string | null;
  /** Deferred plan switch (#589): the product taking over at renewal. */
  deferredProductId: string | null;
}

const KNOWN_STATES: PlayState[] = [
  "PENDING",
  "ACTIVE",
  "PAUSED",
  "IN_GRACE_PERIOD",
  "ON_HOLD",
  "CANCELED",
  "EXPIRED",
  "PENDING_PURCHASE_CANCELED",
];

export function normalizeState(raw: unknown): PlayState {
  if (typeof raw !== "string") return "UNSPECIFIED";
  const s = raw.replace(/^SUBSCRIPTION_STATE_/, "");
  return (KNOWN_STATES as string[]).includes(s) ? (s as PlayState) : "UNSPECIFIED";
}

/** Parse a purchases.subscriptionsv2.get response; null if unusable. */
export function parseSubscriptionV2(body: unknown): VerifiedPurchase | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, any>;
  const items = Array.isArray(b.lineItems) ? b.lineItems : [];
  // Pick our own product's line item; the latest expiry wins.
  const ours = items
    .filter((i) => (PRODUCT_IDS as readonly string[]).includes(i?.productId))
    .sort((a, c) =>
      Date.parse(c.expiryTime ?? "") - Date.parse(a.expiryTime ?? "")
    );
  // Deferred plan switch (#589): the item the user OWNS now carries
  // deferredItemReplacement and keeps the entitlement until it expires; the
  // item being switched to is not owned yet (no latestSuccessfulOrderId), so
  // it never counts until Play renews into it.
  const holder = ours.find((i) => typeof i?.deferredItemReplacement?.productId === "string");
  const owned = ours.find((i) => typeof i?.latestSuccessfulOrderId === "string");
  const item = holder ?? owned ?? ours[0];
  if (!item) return null;
  const basePlanId = item.offerDetails?.basePlanId;
  if (!(BASE_PLAN_IDS as readonly string[]).includes(basePlanId)) return null;
  return {
    productId: item.productId,
    basePlanId,
    orderId: item.latestSuccessfulOrderId ?? null,
    state: normalizeState(b.subscriptionState),
    expiryTime: typeof item.expiryTime === "string" ? item.expiryTime : null,
    acknowledged: b.acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
    obfuscatedAccountId: b.externalAccountIdentifiers?.obfuscatedExternalAccountId ??
      null,
    linkedPurchaseToken: b.linkedPurchaseToken ?? null,
    deferredProductId: holder?.deferredItemReplacement?.productId ?? null,
  };
}

/** Whether a state is waiting on acknowledgement (only ACTIVE/grace/cancel-pending ones are). */
export function needsAcknowledge(p: VerifiedPurchase): boolean {
  return !p.acknowledged && (p.state === "ACTIVE" || p.state === "IN_GRACE_PERIOD");
}

export function isEntitled(p: Pick<VerifiedPurchase, "state" | "expiryTime">, now = Date.now()): boolean {
  if (p.state === "ACTIVE" || p.state === "IN_GRACE_PERIOD") return true;
  return p.state === "CANCELED" && !!p.expiryTime && Date.parse(p.expiryTime) > now;
}

export type BillingIssue = "grace" | "hold" | null;

/**
 * Failed renewal (#591): the businesses.billing_issue a Play state means.
 * Mirrors apply_play_purchase (0235): IN_GRACE_PERIOD keeps the plan and is
 * 'grace'; ON_HOLD is 'hold'; every other state clears it. The SQL refines two
 * cases: an ON_HOLD lapse kept by a manual grant or another entitled purchase
 * clears it (the shop keeps a paid plan), and PENDING leaves it unchanged.
 */
export function billingIssueForState(state: PlayState): BillingIssue {
  if (state === "IN_GRACE_PERIOD") return "grace";
  if (state === "ON_HOLD") return "hold";
  return null;
}

/** RTDN SUBSCRIPTION_REVOKED: refunded/revoked, access ends now. */
export const RTDN_REVOKED = 12;

export type ApplyDecision =
  | { apply: true }
  | { apply: false; reason: "replaced" | "early_lapse_held" };

/**
 * Whether a verified purchase may change the business's plan (#589).
 *
 *  - A token REPLACED by a newer one (its row has replaced_by_token) never
 *    changes entitlement again: the newer token owns it. Covers every order of
 *    RTDNs once the new token is known.
 *  - An EXPIRED that cuts a still-paid period short (the stored row was
 *    entitled with an expiry in the future) and is not a revoke is what a plan
 *    switch does to the old token. It may arrive before the new token is
 *    verified, so it is HELD: the business keeps its plan and end date, and
 *    business_effective_plan() lapses it at that end date anyway if no new
 *    token ever shows up. A revoke (refund) always applies at once.
 */
export function decideApply(args: {
  verified: Pick<VerifiedPurchase, "state" | "expiryTime">;
  replacedBy: string | null;
  prior: { state: string; expiryTime: string | null } | null;
  notificationType: number | null;
  now?: number;
}): ApplyDecision {
  const now = args.now ?? Date.now();
  if (args.replacedBy) return { apply: false, reason: "replaced" };
  const v = args.verified;
  const p = args.prior;
  if (
    v.state === "EXPIRED" &&
    args.notificationType !== RTDN_REVOKED &&
    p !== null &&
    !!p.expiryTime &&
    Date.parse(p.expiryTime) > now &&
    isEntitled({ state: normalizeState(p.state), expiryTime: p.expiryTime }, now)
  ) {
    return { apply: false, reason: "early_lapse_held" };
  }
  return { apply: true };
}

/** The older token this purchase replaces, if any (never itself). */
export function replacedToken(token: string, v: Pick<VerifiedPurchase, "linkedPurchaseToken">): string | null {
  const l = v.linkedPurchaseToken;
  return l && l !== token ? l : null;
}

/**
 * Business for an RTDN token we have never seen: only when Play links it to a
 * token we know (a plan switch) and the account tag, if any, agrees.
 */
export function businessForUnknownToken(
  v: Pick<VerifiedPurchase, "obfuscatedAccountId">,
  linkedRowBusinessId: string | null,
): string | null {
  if (!linkedRowBusinessId) return null;
  if (v.obfuscatedAccountId && v.obfuscatedAccountId !== linkedRowBusinessId) return null;
  return linkedRowBusinessId;
}

export interface RtdnTarget {
  packageName: string;
  purchaseToken: string;
  subscriptionId: string | null;
  notificationType: number | null;
}

/**
 * Decode a Pub/Sub push body into the subscription notification it carries.
 * Returns null for anything that is not a subscription RTDN (test pings,
 * one-time products, voided purchases) - the caller just acks those 200.
 */
export function decodeRtdn(body: unknown): RtdnTarget | null {
  const data = (body as any)?.message?.data;
  if (typeof data !== "string") return null;
  let json: any;
  try {
    json = JSON.parse(new TextDecoder().decode(
      Uint8Array.from(atob(data), (c) => c.charCodeAt(0)),
    ));
  } catch {
    return null;
  }
  const n = json?.subscriptionNotification;
  if (!n || typeof n.purchaseToken !== "string" || typeof json.packageName !== "string") {
    return null;
  }
  return {
    packageName: json.packageName,
    purchaseToken: n.purchaseToken,
    subscriptionId: typeof n.subscriptionId === "string" ? n.subscriptionId : null,
    notificationType: typeof n.notificationType === "number" ? n.notificationType : null,
  };
}

/** Constant-time-ish secret compare for the push endpoint's shared secret. */
export function secretMatches(expected: string | undefined, provided: string | null): boolean {
  if (!expected || !provided || expected.length !== provided.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ provided.charCodeAt(i);
  }
  return diff === 0;
}
