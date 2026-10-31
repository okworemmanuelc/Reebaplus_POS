// send-push / fcm.ts
//
// PURE message-shaping + fan-out logic for FCM broadcast push. No I/O lives
// here except through the injectable `FcmSender` seam, so every function is
// unit-testable without touching the network or Firebase (see fcm_test.ts).
// The OAuth2 access-token minting and the concrete HTTP sender live in
// index.ts (the I/O boundary); this file is the part worth testing.

/// The broadcast row as delivered by the AFTER INSERT trigger (0159) — the
/// subset of `public.notifications` columns the push needs. All string.
export interface BroadcastRecord {
  id: string;
  business_id: string;
  type: string;
  message: string;
  severity: string;
}

/// Any record the hook may deliver. Staff pushes carry `business_id`; Shopper
/// pushes (#476) carry `auth_user_id` and no business. `title` is optional
/// (Shopper senders supply their own; staff titles come from severity).
export interface PushRecord {
  id: string;
  type: string;
  message: string;
  severity: string;
  business_id?: string | null;
  auth_user_id?: string | null;
  title?: string | null;
  /// Targeted staff push (#433): the exact `users.id`s to notify (resolved by
  /// the DB trigger from store assignment + permission). Their live tokens are
  /// the `devices` rows whose `last_user_id` is in this list, in `business_id`.
  user_ids?: string[] | null;
  /// Extra string-valued FCM `data` entries (e.g. online_order_id, store_id).
  data?: Record<string, string> | null;
}

/// Who a push goes to. Staff = every live token of a business (unchanged
/// console-broadcast routing). Shopper = every live token of one login — its
/// Shopper-only row, or the business row of a phone that also shops (one row
/// per token, migration 0200).
export type PushRecipient =
  | { audience: "staff"; businessId: string; userIds?: string[] }
  | { audience: "shopper"; authUserId: string };

/// Shopper push types share this prefix (#434 sends `shopper_online_order`). The hook
/// secret is the trust boundary; the prefix keeps a mis-addressed record from
/// ever reaching a phone.
export const SHOPPER_PUSH_TYPE_PREFIX = "shopper_";

const nonEmpty = (v: unknown): v is string =>
  typeof v === "string" && v.length > 0;

/// Targeted staff push types (#433). Routed by an explicit `user_ids` list.
/// `billing_issue` (#591): the owner alone, on entering a Play grace period
/// (0235 trigger).
export const TARGETED_STAFF_PUSH_TYPES = ["online_order", "billing_issue"];

/// Route a hook record to its recipient, or null to skip it. A record never
/// routes by BOTH keys: a Shopper push carrying a business_id is rejected, so
/// a Shopper message can never fan out to a whole business.
export function resolveRecipient(r: unknown): PushRecipient | null {
  if (!r || typeof r !== "object") return null;
  const rec = r as Partial<PushRecord>;
  if (
    !nonEmpty(rec.id) || !nonEmpty(rec.type) ||
    typeof rec.message !== "string" || typeof rec.severity !== "string"
  ) return null;
  if (rec.type === "console_broadcast") {
    return nonEmpty(rec.business_id)
      ? { audience: "staff", businessId: rec.business_id }
      : null;
  }
  if (TARGETED_STAFF_PUSH_TYPES.includes(rec.type)) {
    const ids = Array.isArray(rec.user_ids)
      ? [...new Set(rec.user_ids.filter(nonEmpty))]
      : [];
    return nonEmpty(rec.business_id) && ids.length > 0
      ? { audience: "staff", businessId: rec.business_id, userIds: ids }
      : null;
  }
  if (rec.type.startsWith(SHOPPER_PUSH_TYPE_PREFIX)) {
    if (rec.business_id != null) return null;
    return nonEmpty(rec.auth_user_id)
      ? { audience: "shopper", authUserId: rec.auth_user_id }
      : null;
  }
  return null;
}

/// The `devices` column + value whose live tokens address [recipient].
/// Shopper pushes go to Android app phones only (#434): web-link and iPhone
/// Shoppers are told by email instead (the 0218 trigger picks the channel).
export function tokenFilterFor(
  recipient: PushRecipient,
): {
  column: "business_id" | "auth_user_id";
  value: string;
  userIds?: string[];
  platform?: "android";
} {
  return recipient.audience === "staff"
    ? {
      column: "business_id",
      value: recipient.businessId,
      ...(recipient.userIds ? { userIds: recipient.userIds } : {}),
    }
    : { column: "auth_user_id", value: recipient.authUserId, platform: "android" };
}

/// One FCM HTTP v1 message envelope (POST body to messages:send).
export interface FcmMessage {
  message: {
    token: string;
    notification: { title: string; body: string };
    data: Record<string, string>;
    android: { priority: "high"; notification: { channel_id: string } };
  };
}

/// Result of attempting to send one message. `unregistered` marks a token FCM
/// says is dead (404 / UNREGISTERED / NOT_FOUND) so the caller can prune it.
export interface FcmSendResult {
  token: string;
  ok: boolean;
  unregistered: boolean;
}

/// Injectable transport — real one in index.ts, a fake in tests.
export type FcmSender = (
  accessToken: string,
  projectId: string,
  msg: FcmMessage,
) => Promise<FcmSendResult>;

// The Android notification channel the client (flutter_local_notifications,
// Slice 2) registers for announcements. Must stay in sync with the client.
export const ANNOUNCEMENTS_CHANNEL_ID = "reebaplus_announcements";

/// Server-synthesized push title, driven by the operator's chosen Severity, so
/// it always reads as a platform message (not the shop's own business name).
export function titleForSeverity(severity: string): string {
  switch (severity) {
    case "alert":
      return "Reebaplus — Alert";
    case "warning":
      return "Reebaplus — Important";
    default: // "info" and any unknown value degrade to the neutral title.
      return "Reebaplus Announcement";
  }
}

/// Build one hybrid notification+data message per device token. Empty tokens →
/// empty result (no send). `data` values are all strings, as FCM v1 requires.
/// `audience` tells the client which side of a shared phone a tap belongs to;
/// a Shopper push never carries a business_id.
export function buildFcmMessages(
  record: PushRecord,
  tokens: string[],
  audience: PushRecipient["audience"] = "staff",
): FcmMessage[] {
  const title = audience === "shopper"
    ? (nonEmpty(record.title) ? record.title : "Reebaplus")
    : (TARGETED_STAFF_PUSH_TYPES.includes(record.type) &&
        nonEmpty(record.title))
    ? record.title
    : titleForSeverity(record.severity);
  const data: Record<string, string> = {
    notification_id: record.id,
    type: record.type,
    severity: record.severity,
    audience,
  };
  if (audience === "staff" && nonEmpty(record.business_id)) {
    data.business_id = record.business_id;
  }
  // Extra data keys: targeted staff pushes (#433) and Shopper order updates
  // (#434: online_order_id, event). Never overrides the routing keys above.
  if (
    (audience === "shopper" || TARGETED_STAFF_PUSH_TYPES.includes(record.type)) &&
    record.data
  ) {
    for (const [k, v] of Object.entries(record.data)) {
      if (typeof v === "string" && !(k in data)) data[k] = v;
    }
  }
  return tokens.map((token) => ({
    message: {
      token,
      notification: { title, body: record.message },
      data,
      android: {
        priority: "high",
        notification: { channel_id: ANNOUNCEMENTS_CHANNEL_ID },
      },
    },
  }));
}

/// Fan a batch of messages out through the injectable sender and summarize:
/// how many were accepted, and which tokens FCM reported dead (to prune).
export async function sendAll(
  sender: FcmSender,
  accessToken: string,
  projectId: string,
  messages: FcmMessage[],
): Promise<{ sent: number; prune: string[] }> {
  const results = await Promise.all(
    messages.map((m) => sender(accessToken, projectId, m)),
  );
  return {
    sent: results.filter((r) => r.ok).length,
    prune: results.filter((r) => r.unregistered).map((r) => r.token),
  };
}
