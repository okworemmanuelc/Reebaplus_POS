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
  const item = ours[0];
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
