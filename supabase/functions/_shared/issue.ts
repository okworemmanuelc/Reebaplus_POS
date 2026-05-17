// Shared invite-issuance pipeline used by send-invite and resend-invite.
//
// Runs the full pre-check ladder, generates an 8-character human_code, and
// inserts the invites row via the service client (bypasses RLS).
//
// Rev 3 simplifications vs rev 2:
//   • No email/SMS dispatch. The admin shares the code via WhatsApp / SMS /
//     Email / paper from the modal success screen. notify.ts is gone.
//   • No URL token. The reebaplus://invite?token=... deep-link path is dead
//     (no producer ships tokens to recipients anymore). The token_hash and
//     8-char `code` columns on invites stay (column drop is a separate
//     migration); we write a copy of human_code into `code` to satisfy the
//     legacy NOT NULL, and leave token_hash NULL.
//   • TTL is read from settings.onboarding.invite_ttl_days (default 7).
//   • phone is no longer captured at invite time (staff phone is collected
//     in the signup wizard via accept_invite RPC instead).

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import type { CallerContext } from "./auth.ts";
import {
  generateCode,
  isDisposableEmail,
  isUuid,
  isValidEmail,
  isValidGranularRole,
} from "./validation.ts";
import type { InviteErrorCode } from "./errors.ts";

const DAILY_LIMIT = parseInt(
  Deno.env.get("INVITE_DAILY_LIMIT_PER_BUSINESS") ?? "50",
  10,
);
const DEFAULT_TTL_DAYS = 7;

export interface IssueInviteInput {
  email: string;
  role: string;
  warehouseId: string | null;
  // Skips for the resend path: the prior pending invite was just revoked,
  // so an invite_pending check would return our own ghost. already_member
  // was false at the original send and can't have flipped to true without
  // a separate action.
  skipPendingCheck?: boolean;
  skipMemberCheck?: boolean;
}

export type IssueResult =
  | {
    ok: true;
    inviteId: string;
    humanCode: string;
    expiresAt: string;
    row: Record<string, unknown>;
  }
  | {
    ok: false;
    error: InviteErrorCode;
    details?: Record<string, unknown>;
  };

export async function issueInvite(
  service: SupabaseClient,
  ctx: CallerContext,
  input: IssueInviteInput,
): Promise<IssueResult> {
  const email = (input.email ?? "").trim().toLowerCase();

  // --- cheap pre-checks (no DB) ----------------------------------------
  if (!isValidEmail(email)) return { ok: false, error: "invalid_email" };
  if (isDisposableEmail(email)) {
    return { ok: false, error: "disposable_email" };
  }
  if (email === ctx.email) return { ok: false, error: "self_invite" };
  if (!isValidGranularRole(input.role)) {
    return { ok: false, error: "invalid_payload" };
  }
  if (input.role === "ceo") return { ok: false, error: "forbidden_role" };
  if (input.warehouseId !== null && !isUuid(input.warehouseId)) {
    return { ok: false, error: "invalid_payload" };
  }

  // --- DB pre-checks ---------------------------------------------------
  if (!input.skipMemberCheck) {
    const { data: isMember, error: memErr } = await service.rpc(
      "is_business_member_email",
      { p_business_id: ctx.businessId, p_email: email },
    );
    if (memErr) return { ok: false, error: "internal" };
    if (isMember === true) return { ok: false, error: "already_member" };
  }

  const { data: isOwner, error: ownErr } = await service.rpc(
    "is_other_business_owner",
    { p_email: email, p_exclude_business_id: ctx.businessId },
  );
  if (ownErr) return { ok: false, error: "internal" };
  if (isOwner === true) return { ok: false, error: "other_business_owner" };

  if (!input.skipPendingCheck) {
    const { data: pending } = await service
      .from("invites")
      .select("id, expires_at")
      .eq("business_id", ctx.businessId)
      .ilike("email", email)
      .eq("status", "pending")
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    if (pending) {
      return {
        ok: false,
        error: "invite_pending",
        details: {
          invite_id: pending.id,
          expires_at: pending.expires_at,
        },
      };
    }
  }

  if (input.warehouseId) {
    const { data: wh } = await service
      .from("warehouses")
      .select("id")
      .eq("id", input.warehouseId)
      .eq("business_id", ctx.businessId)
      .maybeSingle();
    if (!wh) return { ok: false, error: "invalid_warehouse" };
  }

  // Atomic rate limit derived from the invites table itself.
  const startOfDay = new Date();
  startOfDay.setUTCHours(0, 0, 0, 0);
  const { count, error: cntErr } = await service
    .from("invites")
    .select("id", { count: "exact", head: true })
    .eq("business_id", ctx.businessId)
    .gte("created_at", startOfDay.toISOString());
  if (cntErr) return { ok: false, error: "internal" };
  if ((count ?? 0) >= DAILY_LIMIT) return { ok: false, error: "rate_limited" };

  // TTL — settings.onboarding.invite_ttl_days, fallback 7. Same key the
  // server-side regenerate_invite_code RPC reads (0027), so changing the
  // setting affects both the first issuance and any later regeneration.
  let ttlDays = DEFAULT_TTL_DAYS;
  const { data: ttlRow } = await service
    .from("settings")
    .select("value")
    .eq("business_id", ctx.businessId)
    .eq("key", "onboarding.invite_ttl_days")
    .maybeSingle();
  if (ttlRow?.value) {
    const parsed = parseInt(ttlRow.value, 10);
    if (!isNaN(parsed) && parsed > 0 && parsed <= 90) ttlDays = parsed;
  }

  // --- write the row ---------------------------------------------------
  // Retry up to 3 times on uniqueness collisions (uq_invites_pending_human_code,
  // 23505). 32^8 ≈ 1.1T possible codes — collisions are vanishingly rare
  // but the partial unique index can still fire on a same-business pending
  // collision.
  const expiresAt = new Date(Date.now() + ttlDays * 86400 * 1000).toISOString();
  for (let attempt = 0; attempt < 3; attempt++) {
    const humanCode = generateCode(8);

    const { data, error } = await service
      .from("invites")
      .insert({
        business_id: ctx.businessId,
        email,
        // Legacy `code` column is NOT NULL on the schema; populate with the
        // same value as human_code so legacy consumers keep functioning until
        // a future migration drops the column. token_hash stays NULL.
        code: humanCode,
        human_code: humanCode,
        role: input.role,
        warehouse_id: input.warehouseId,
        created_by: ctx.callerUserId,
        // invitee_name is legacy NOT NULL. Wizard collects the real name
        // during signup (lands on users.name via accept_invite). 'Unknown'
        // matches the 0021 backfill normalisation.
        invitee_name: "Unknown",
        status: "pending",
        expires_at: expiresAt,
      })
      .select("*")
      .single();

    if (error) {
      if ((error as { code?: string }).code === "23505") continue;
      return { ok: false, error: "internal" };
    }

    return {
      ok: true,
      inviteId: data.id as string,
      humanCode: data.human_code as string,
      expiresAt: data.expires_at as string,
      row: data as Record<string, unknown>,
    };
  }

  return { ok: false, error: "internal" };
}
