// share-barcode-photo
//
// Copies the first photo saved for a factory barcode into the shared
// barcode-catalogue-photos bucket (ADR 0029 §5, issue #331). The copy stays:
// a later shop's photo never replaces it, and the source shop changing or
// deleting its own photo never breaks it.
//
// Invocation: NOT called by the app client. Two server-side callers, both
// through public.barcode_catalogue_request_share (migration 0182) → pg_net:
//   * { record }  — the AFTER INSERT/UPDATE trigger on public.products, for a
//                   product with a photo and a factory barcode whose GTIN has
//                   no shared photo yet. Only record.id is trusted: the product
//                   is re-read, so a stale payload can't share a stale photo.
//   * { gtin14 }  — the one-time backfill and the photo-removal runbook. Walks
//                   that GTIN's products oldest first and shares the first
//                   photo whose hash isn't blocked.
//
// Auth: no user JWT on this path (deploy with verify_jwt = false). The caller
// sends a shared secret in `x-barcode-catalogue-hook-secret`
// (BARCODE_CATALOGUE_HOOK_SECRET, the same value as the Vault secret
// `barcode_catalogue_hook_secret`); that secret is the only gate.
//
// The sharing rule itself lives in share.ts (pure, unit-tested). This file is
// the HTTP shell plus the Supabase adapters behind SharePorts.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { handlePreflight } from "../_shared/cors.ts";
import { errorResponse, okResponse } from "../_shared/errors.ts";
import { getServiceClient } from "../_shared/db.ts";
import {
  type Candidate,
  type Photo,
  SHARED_BUCKET,
  type SharedRow,
  shareFirstUnblocked,
  type SharePorts,
  SOURCE_BUCKET,
} from "./share.ts";

const GTIN14_RE = /^[0-9]{14}$/;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface CandidateRow {
  gtin14: string;
  product_id: string;
  business_id: string;
  image_url: string;
}

function isCandidateRow(r: unknown): r is CandidateRow {
  if (!r || typeof r !== "object") return false;
  const row = r as Record<string, unknown>;
  return typeof row.gtin14 === "string" &&
    typeof row.product_id === "string" &&
    typeof row.business_id === "string" &&
    typeof row.image_url === "string";
}

// ── Storage error shapes ────────────────────────────────────────────────────
//
// storage-js reports a failed download as a StorageUnknownError wrapping the
// raw Response, and a failed upload as a StorageApiError carrying the HTTP
// status. Storage has answered both "not found" and "already exists" with a
// 400 whose message says so, as well as with 404 / 409, so all are checked.

function errorStatus(error: unknown): number | undefined {
  const e = error as {
    status?: unknown;
    statusCode?: unknown;
    originalError?: { status?: unknown };
  };
  for (const s of [e?.status, e?.statusCode, e?.originalError?.status]) {
    const n = typeof s === "string" ? Number(s) : s;
    if (typeof n === "number" && Number.isFinite(n)) return n;
  }
  return undefined;
}

function errorMessage(error: unknown): string {
  const m = (error as { message?: unknown })?.message;
  return typeof m === "string" ? m : String(error);
}

function isNotFound(error: unknown): boolean {
  const status = errorStatus(error);
  return status === 404 || status === 400 ||
    /not.?found/i.test(errorMessage(error));
}

function isAlreadyExists(error: unknown): boolean {
  return errorStatus(error) === 409 ||
    /already exists|duplicate/i.test(errorMessage(error));
}

// ── Supabase adapters ───────────────────────────────────────────────────────

async function download(
  service: SupabaseClient,
  bucket: string,
  objectPath: string,
): Promise<Photo | null> {
  const { data, error } = await service.storage.from(bucket).download(
    objectPath,
  );
  if (error) {
    if (isNotFound(error)) return null;
    throw new Error(`download ${bucket}/${objectPath}: ${errorMessage(error)}`);
  }
  return {
    bytes: new Uint8Array(await data.arrayBuffer()),
    contentType: data.type,
  };
}

function supabasePorts(service: SupabaseClient): SharePorts {
  return {
    async sharedPhotoPath(gtin14: string): Promise<string | null> {
      const { data, error } = await service
        .from("barcode_catalogue_photos")
        .select("object_path")
        .eq("gtin14", gtin14)
        .maybeSingle();
      if (error) throw new Error(`photo row lookup: ${error.message}`);
      const path = (data as { object_path?: unknown } | null)?.object_path;
      return typeof path === "string" ? path : null;
    },

    async isBlocked(sha256: string): Promise<boolean> {
      const { data, error } = await service
        .from("barcode_catalogue_photo_blocks")
        .select("sha256")
        .eq("sha256", sha256)
        .maybeSingle();
      if (error) throw new Error(`block lookup: ${error.message}`);
      return data !== null;
    },

    downloadSource: (objectPath: string) =>
      download(service, SOURCE_BUCKET, objectPath),

    downloadShared: (objectPath: string) =>
      download(service, SHARED_BUCKET, objectPath),

    async uploadShared(
      objectPath: string,
      photo: Photo,
    ): Promise<"uploaded" | "exists"> {
      const { error } = await service.storage.from(SHARED_BUCKET).upload(
        objectPath,
        photo.bytes,
        { contentType: photo.contentType, upsert: false },
      );
      if (!error) return "uploaded";
      if (isAlreadyExists(error)) return "exists";
      throw new Error(`upload ${objectPath}: ${errorMessage(error)}`);
    },

    async removeShared(objectPath: string): Promise<void> {
      const { error } = await service.storage.from(SHARED_BUCKET).remove([
        objectPath,
      ]);
      if (error) throw new Error(`remove ${objectPath}: ${error.message}`);
    },

    async insertSharedRow(row: SharedRow): Promise<void> {
      const { error } = await service
        .from("barcode_catalogue_photos")
        .upsert(
          {
            gtin14: row.gtin14,
            object_path: row.objectPath,
            sha256: row.sha256,
          },
          { onConflict: "gtin14", ignoreDuplicates: true },
        );
      if (error) throw new Error(`photo row insert: ${error.message}`);
    },
  };
}

// ── Request handler ──────────────────────────────────────────────────────────

interface HookPayload {
  record?: unknown;
  gtin14?: unknown;
}

// The candidates for one product ({ record }) or one GTIN ({ gtin14 }), or
// null for a malformed payload. Eligibility (factory GTIN, not deleted, has a
// photo) and the oldest-first order live in the SQL function, so this file
// never needs its own copy of the factory-barcode rule.
function candidateParams(
  payload: HookPayload,
): { p_product_id: string } | { p_gtin14: string } | null {
  if (payload.record !== undefined) {
    const id = (payload.record as { id?: unknown } | null)?.id;
    return typeof id === "string" && UUID_RE.test(id)
      ? { p_product_id: id }
      : null;
  }
  if (typeof payload.gtin14 === "string" && GTIN14_RE.test(payload.gtin14)) {
    return { p_gtin14: payload.gtin14 };
  }
  return null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") return errorResponse("invalid_payload");

  // Shared-secret gate — this path has no user JWT.
  const expected = Deno.env.get("BARCODE_CATALOGUE_HOOK_SECRET");
  const provided = req.headers.get("x-barcode-catalogue-hook-secret");
  if (!expected || provided !== expected) {
    return errorResponse("unauthenticated");
  }

  let payload: HookPayload;
  try {
    payload = await req.json() as HookPayload;
  } catch (_e) {
    return errorResponse("invalid_payload");
  }
  const params = payload && typeof payload === "object"
    ? candidateParams(payload)
    : null;
  if (params === null) return errorResponse("invalid_payload");

  const service = getServiceClient();

  try {
    const { data, error } = await service.rpc(
      "barcode_catalogue_photo_candidates",
      params,
    );
    if (error) throw new Error(`candidates: ${error.message}`);
    const rows = (Array.isArray(data) ? data : []).filter(isCandidateRow);

    const gtin14 = "p_gtin14" in params ? params.p_gtin14 : rows[0]?.gtin14;
    if (gtin14 === undefined) {
      // { record }: the product no longer qualifies (photo removed, barcode
      // changed, deleted) — nothing to do.
      return okResponse({ status: "not_eligible" });
    }

    const candidates: Candidate[] = rows.map((r) => ({
      productId: r.product_id,
      businessId: r.business_id,
      imageUrl: r.image_url,
    }));
    const outcome = await shareFirstUnblocked(
      supabasePorts(service),
      gtin14,
      candidates,
    );
    return okResponse({ ...outcome });
  } catch (e) {
    console.error("share-barcode-photo failed", errorMessage(e));
    return errorResponse("internal");
  }
});
