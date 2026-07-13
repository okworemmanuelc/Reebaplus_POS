// send-push / fcm.ts
//
// PURE message-shaping + fan-out logic for FCM broadcast push. No I/O lives
// here except through the injectable `FcmSender` seam, so every function is
// unit-testable without touching the network or Firebase (see fcm_test.ts).
// The OAuth2 access-token minting and the concrete HTTP sender live in
// index.ts (the I/O boundary); this file is the part worth testing.

/// The broadcast row as delivered by the AFTER INSERT trigger (0153) — the
/// subset of `public.notifications` columns the push needs. All string.
export interface BroadcastRecord {
  id: string;
  business_id: string;
  type: string;
  message: string;
  severity: string;
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
export function buildFcmMessages(
  record: BroadcastRecord,
  tokens: string[],
): FcmMessage[] {
  const title = titleForSeverity(record.severity);
  const data: Record<string, string> = {
    notification_id: record.id,
    type: record.type,
    severity: record.severity,
    business_id: record.business_id,
  };
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
