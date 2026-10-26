// send-push
//
// Server-side OS push for CONSOLE BROADCASTS via Firebase Cloud Messaging.
//
// Invocation: NOT called by the app client. An AFTER INSERT trigger on
// public.notifications (filtered to type = 'console_broadcast') POSTs the new
// row here via pg_net (migration 0159) — mirroring send-invite-email/0126.
//
// Auth: no user JWT on this path (deploy with verify_jwt = false). The trigger
// sends a shared secret in `x-push-hook-secret` (PUSH_HOOK_SECRET); that secret
// is the only gate — reject anything that doesn't match.
//
// What it does: resolve every live FCM Device Token for the record's
// recipient (service_role) — a console broadcast goes to its business; a
// Shopper push (#476, type `shopper_*`, keyed by `auth_user_id`, no business)
// goes to that login's phones — send one hybrid notification+data message per token
// over FCM HTTP v1, prune tokens FCM reports dead, and stamp
// notifications.push_sent_at (observability). Push is an alert only — it never
// writes the notification row of record; that arrives via the Sync Engine
// (ADR 0018).
//
// #433: also routes a targeted staff push (type `online_order`) carrying an
// explicit `user_ids` list (resolved by the 0215 trigger); same secret, same
// FCM path. Console-broadcast and Shopper behaviour is unchanged.
//
// Config (Edge Function secrets): PUSH_HOOK_SECRET (shared with the Vault
// secret the trigger reads) and FCM_SERVICE_ACCOUNT (the Firebase service
// account JSON). If FCM_SERVICE_ACCOUNT is absent the function degrades to
// "no push" rather than erroring — the broadcast still reaches the in-app bell.

import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { getServiceClient } from "../_shared/db.ts";
import {
  buildFcmMessages,
  type FcmMessage,
  type FcmSender,
  type FcmSendResult,
  type PushRecord,
  resolveRecipient,
  sendAll,
  tokenFilterFor,
} from "./fcm.ts";

interface HookPayload {
  record?: Partial<PushRecord> | null;
}

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
}

// ── OAuth2: mint a short-lived FCM access token from the service account ──────

function base64Url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlJson(value: unknown): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  // Strip the PEM armor (both `-----…-----` guard lines) and all whitespace,
  // leaving the base64 PKCS8 body. Generic marker match — no literal key text.
  const der = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(der), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    bytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64UrlJson(header)}.${base64UrlJson(claims)}`;
  const key = await importPrivateKey(sa.private_key);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64Url(new Uint8Array(signature))}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) {
    throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  }
  const json = await res.json() as { access_token?: string };
  if (!json.access_token) throw new Error("token exchange returned no token");
  return json.access_token;
}

// ── Concrete FCM HTTP v1 sender ──────────────────────────────────────────────

const httpFcmSender: FcmSender = async (
  accessToken: string,
  projectId: string,
  msg: FcmMessage,
): Promise<FcmSendResult> => {
  const token = msg.message.token;
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(msg),
    },
  );
  if (res.ok) return { token, ok: true, unregistered: false };
  const detail = await res.text();
  // A stale/removed token: FCM returns 404 or an UNREGISTERED/NOT_FOUND code.
  const unregistered = res.status === 404 ||
    /UNREGISTERED|NOT_FOUND/i.test(detail);
  console.error("fcm send failed", res.status, detail);
  return { token, ok: false, unregistered };
};

// ── Request handler ──────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") return errorResponse("invalid_payload");

  // Shared-secret gate — this path has no user JWT.
  const expected = Deno.env.get("PUSH_HOOK_SECRET");
  const provided = req.headers.get("x-push-hook-secret");
  if (!expected || provided !== expected) {
    return errorResponse("unauthenticated");
  }

  let payload: HookPayload;
  try {
    payload = await req.json() as HookPayload;
  } catch (_e) {
    return errorResponse("invalid_payload");
  }

  const record = payload?.record;
  if (!record || typeof record !== "object") {
    return errorResponse("invalid_payload");
  }

  // Defence in depth: only console broadcasts (by business) and Shopper pushes
  // (by auth user, never a business) route. Anything else — or a record that
  // is missing its routing key — is skipped, never sent.
  const recipient = resolveRecipient(record);
  if (!recipient) return okResponse({ skipped: "not_routable" });
  const push = record as PushRecord;

  // Firebase not configured yet → degrade to "no push" (the broadcast still
  // appears in the bell on the next pull). Never a 500 for a config gap.
  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!saRaw) {
    console.error("FCM_SERVICE_ACCOUNT not configured — skipping push");
    return okResponse({ skipped: "fcm_unconfigured" });
  }
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(saRaw) as ServiceAccount;
  } catch (_e) {
    console.error("FCM_SERVICE_ACCOUNT is not valid JSON");
    return errorResponse("internal");
  }

  const service = getServiceClient();

  // Resolve every live token for the recipient (dedup — one push per device,
  // and a token maps to one row by the 0159 uniqueness trigger anyway).
  const filter = tokenFilterFor(recipient);
  let query = service
    .from("devices")
    .select("fcm_token")
    .eq(filter.column, filter.value)
    .not("fcm_token", "is", null);
  // Targeted staff push (#433): only the phones last used by the listed users.
  if (filter.userIds) query = query.in("last_user_id", filter.userIds);
  const { data: rows, error: tokenErr } = await query;
  if (tokenErr) {
    console.error("token lookup failed", tokenErr.message);
    return errorResponse("internal");
  }
  const tokens = [
    ...new Set(
      (rows ?? [])
        .map((r) => (r as { fcm_token: string | null }).fcm_token)
        .filter((t): t is string => typeof t === "string" && t.length > 0),
    ),
  ];
  if (tokens.length === 0) return okResponse({ sent: 0 });

  let accessToken: string;
  try {
    accessToken = await getAccessToken(sa);
  } catch (e) {
    console.error("access token mint failed", (e as Error).message);
    return errorResponse("internal");
  }

  const messages = buildFcmMessages(push, tokens, recipient.audience);
  const { sent, prune } = await sendAll(
    httpFcmSender,
    accessToken,
    sa.project_id,
    messages,
  );

  // Prune dead tokens so the recipient's token set stays live.
  if (prune.length > 0) {
    const { error: pruneErr } = await service
      .from("devices")
      .update({ fcm_token: null, fcm_token_updated_at: new Date().toISOString() })
      .in("fcm_token", prune);
    if (pruneErr) console.error("token prune failed", pruneErr.message);
  }

  // Stamp observability on the broadcast's notifications row (never read by
  // the client; a re-push upsert can't clobber it — the column is absent from
  // the Drift schema). Shopper records are not notifications rows.
  if (recipient.audience === "staff" && push.type === "console_broadcast") {
    const { error: stampErr } = await service
      .from("notifications")
      .update({ push_sent_at: new Date().toISOString() })
      .eq("id", push.id);
    if (stampErr) console.error("push_sent_at stamp failed", stampErr.message);
  }

  return okResponse({ sent, pruned: prune.length });
});
