// play-billing-verify
//
// Google Play Billing server side (#90 slice B). Two entry points, one URL:
//
//  (a) APP: POST {business_id, purchase_token, product_id} with the caller's
//      user JWT. Verifies the caller owns the business, verifies the token via
//      purchases.subscriptionsv2.get, acknowledges it, upserts
//      play_subscription_purchases and calls apply_play_purchase (0225).
//
//  (b) PLAY RTDN: Pub/Sub PUSH to `?secret=<PLAY_RTDN_SECRET>`. Decodes the
//      notification, re-fetches the purchase from Google (the notification is
//      only a nudge; Google is authoritative), updates the row + business.
//
// Deploy with --no-verify-jwt: Pub/Sub carries no Supabase JWT, so the (a) path
// checks the JWT itself and the (b) path is gated by the shared secret.
//
// Secrets: GOOGLE_PLAY_SERVICE_ACCOUNT_JSON, PLAY_PACKAGE_NAME,
// PLAY_RTDN_SECRET (+ the standard SUPABASE_* ones).

import { corsHeaders, handlePreflight } from "../_shared/cors.ts";
import { getCallerClient, getServiceClient } from "../_shared/db.ts";
import {
  businessForUnknownToken,
  decideApply,
  decodeRtdn,
  needsAcknowledge,
  replacedToken,
  parseSubscriptionV2,
  secretMatches,
  type VerifiedPurchase,
} from "./play.ts";

const API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders },
  });
}

// ── Google OAuth (service account -> access token), as in send-push ─────────
function b64u(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64uJson = (v: unknown) => b64u(new TextEncoder().encode(JSON.stringify(v)));

async function getAccessToken(): Promise<string> {
  const raw = Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON not set");
  const sa = JSON.parse(raw) as { client_email: string; private_key: string };
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64uJson({ alg: "RS256", typ: "JWT" })}.${
    b64uJson({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/androidpublisher",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    })
  }`;
  const der = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(der), (c) => c.charCodeAt(0)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${b64u(new Uint8Array(sig))}`,
    }),
  });
  if (!res.ok) throw new Error(`token exchange failed: ${res.status}`);
  const j = await res.json() as { access_token?: string };
  if (!j.access_token) throw new Error("no access token");
  return j.access_token;
}

async function fetchPurchase(pkg: string, token: string, at: string): Promise<{ raw: unknown; parsed: VerifiedPurchase | null } | null> {
  const res = await fetch(
    `${API}/${pkg}/purchases/subscriptionsv2/tokens/${encodeURIComponent(token)}`,
    { headers: { Authorization: `Bearer ${at}` } },
  );
  if (res.status === 404 || res.status === 400 || res.status === 410) return null;
  if (!res.ok) throw new Error(`play get failed: ${res.status} ${await res.text()}`);
  const raw = await res.json();
  return { raw, parsed: parseSubscriptionV2(raw) };
}

async function acknowledge(pkg: string, productId: string, token: string, at: string): Promise<boolean> {
  const res = await fetch(
    `${API}/${pkg}/purchases/subscriptions/${productId}/tokens/${encodeURIComponent(token)}:acknowledge`,
    { method: "POST", headers: { Authorization: `Bearer ${at}`, "content-type": "application/json" }, body: "{}" },
  );
  if (!res.ok) console.error("acknowledge failed", res.status, await res.text());
  return res.ok;
}

type Service = ReturnType<typeof getServiceClient>;

async function persistAndApply(
  service: Service,
  businessId: string,
  token: string,
  v: VerifiedPurchase,
  raw: unknown,
  acknowledged: boolean,
  notificationType: number | null,
) {
  // The row as it was BEFORE this update (for decideApply).
  const { data: prior, error: priorErr } = await service.from("play_subscription_purchases")
    .select("state, expiry_time, replaced_by_token").eq("purchase_token", token).maybeSingle();
  if (priorErr) throw new Error(`lookup failed: ${priorErr.message}`);
  const now = new Date().toISOString();
  const { error: upErr } = await service.from("play_subscription_purchases").upsert({
    business_id: businessId,
    purchase_token: token,
    product_id: v.productId,
    base_plan_id: v.basePlanId,
    order_id: v.orderId,
    state: v.state,
    expiry_time: v.expiryTime,
    acknowledged,
    raw,
    linked_purchase_token: v.linkedPurchaseToken,
    updated_at: now,
  }, { onConflict: "purchase_token" });
  if (upErr) throw new Error(`upsert failed: ${upErr.message}`);

  // Plan switch (#589): this token replaces the linked one, which must never
  // change the plan again (its lapse/RTDN can arrive in any order). Not for a
  // payment still pending: the old one stays live until it goes through.
  const old = replacedToken(token, v);
  if (old && v.state !== "PENDING" && v.state !== "PENDING_PURCHASE_CANCELED") {
    const { error: supErr } = await service.from("play_subscription_purchases")
      .update({ replaced_by_token: token, replaced_at: now, updated_at: now })
      .eq("purchase_token", old).eq("business_id", businessId).is("replaced_by_token", null);
    if (supErr) throw new Error(`supersede failed: ${supErr.message}`);
  }

  const decision = decideApply({
    verified: v,
    replacedBy: prior?.replaced_by_token ?? null,
    prior: prior ? { state: prior.state, expiryTime: prior.expiry_time } : null,
    notificationType,
  });
  if (!decision.apply) return { ok: true, unchanged: true, reason: decision.reason };

  const { data, error } = await service.rpc("apply_play_purchase", {
    p_business_id: businessId,
    p_product_id: v.productId,
    p_base_plan_id: v.basePlanId,
    p_state: v.state,
    p_expiry_time: v.expiryTime,
  });
  if (error) throw new Error(`apply failed: ${error.message}`);
  return data;
}

// ── (a) App purchase verification ───────────────────────────────────────────
async function handleAppVerify(req: Request): Promise<Response> {
  const pkg = Deno.env.get("PLAY_PACKAGE_NAME");
  if (!pkg) return json({ ok: false, error: "internal" }, 500);

  const { data: userData } = await getCallerClient(req).auth.getUser();
  const uid = userData?.user?.id;
  if (!uid) return json({ ok: false, error: "unauthenticated" }, 401);

  let body: { business_id?: string; purchase_token?: string; product_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid_payload" }, 400);
  }
  const { business_id: businessId, purchase_token: token } = body;
  if (!businessId || !token || typeof businessId !== "string" || typeof token !== "string") {
    return json({ ok: false, error: "invalid_payload" }, 400);
  }

  const service = getServiceClient();
  const { data: biz } = await service.from("businesses").select("id, owner_id").eq("id", businessId).maybeSingle();
  if (!biz || biz.owner_id !== uid) return json({ ok: false, error: "forbidden" }, 403);

  // A token already bound to another business can never be re-claimed.
  const { data: existing } = await service.from("play_subscription_purchases")
    .select("business_id").eq("purchase_token", token).maybeSingle();
  if (existing && existing.business_id !== businessId) {
    return json({ ok: false, error: "token_in_use" }, 409);
  }

  try {
    const at = await getAccessToken();
    const got = await fetchPurchase(pkg, token, at);
    if (!got || !got.parsed) return json({ ok: false, error: "invalid_purchase" }, 400);
    const v = got.parsed;
    // The app tags the purchase with the business id (obfuscatedAccountId);
    // refuse a token bought for a different business.
    if (v.obfuscatedAccountId && v.obfuscatedAccountId !== businessId) {
      return json({ ok: false, error: "account_mismatch" }, 403);
    }
    let acked = v.acknowledged;
    if (needsAcknowledge(v)) acked = await acknowledge(pkg, v.productId, token, at);
    const applied = await persistAndApply(service, businessId, token, v, got.raw, acked, null);
    return json({ ok: true, state: v.state, expiry_time: v.expiryTime, applied });
  } catch (e) {
    console.error("verify failed", e);
    return json({ ok: false, error: "internal" }, 500);
  }
}

// ── (b) Real-time Developer Notification (Pub/Sub push) ─────────────────────
async function handleRtdn(req: Request): Promise<Response> {
  const pkg = Deno.env.get("PLAY_PACKAGE_NAME");
  const body = await req.json().catch(() => null);
  const target = decodeRtdn(body);
  // Not a subscription event / wrong app: 200 so Pub/Sub does not retry.
  if (!target || !pkg || target.packageName !== pkg) return json({ ok: true, ignored: true });

  const service = getServiceClient();
  const { data: row } = await service.from("play_subscription_purchases")
    .select("business_id").eq("purchase_token", target.purchaseToken).maybeSingle();

  try {
    const at = await getAccessToken();
    const got = await fetchPurchase(pkg, target.purchaseToken, at);
    if (!got || !got.parsed) return json({ ok: true, ignored: row ? "unparseable" : "unknown_token" });
    const v = got.parsed;
    let businessId: string | null = row?.business_id ?? null;
    if (!businessId) {
      // Unknown token: bind it only when it replaces a token we know (a plan
      // switch, #589), so the switch lands even if the app never verifies it.
      // Otherwise the app's verify call is authoritative; ack so Pub/Sub does
      // not hammer us.
      const linked = v.linkedPurchaseToken
        ? (await service.from("play_subscription_purchases")
          .select("business_id").eq("purchase_token", v.linkedPurchaseToken).maybeSingle()).data
        : null;
      businessId = businessForUnknownToken(v, linked?.business_id ?? null);
      if (!businessId) return json({ ok: true, ignored: "unknown_token" });
    }
    let acked = v.acknowledged;
    if (needsAcknowledge(v)) acked = await acknowledge(pkg, v.productId, target.purchaseToken, at);
    const applied = await persistAndApply(
      service, businessId, target.purchaseToken, v, got.raw, acked, target.notificationType,
    );
    return json({ ok: true, state: v.state, applied });
  } catch (e) {
    console.error("rtdn failed", e);
    return json({ ok: false, error: "internal" }, 500); // non-2xx => Pub/Sub retries
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  const pre = handlePreflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ ok: false, error: "invalid_payload" }, 400);

  const secret = new URL(req.url).searchParams.get("secret");
  if (secret !== null) {
    if (!secretMatches(Deno.env.get("PLAY_RTDN_SECRET"), secret)) {
      return json({ ok: false, error: "unauthenticated" }, 401);
    }
    return await handleRtdn(req);
  }
  return await handleAppVerify(req);
});
