// share-barcode-photo / share.ts
//
// The pure sharing logic for the shared barcode catalogue photo (ADR 0029 §5),
// behind SharePorts so it runs against an in-memory fake in share_test.ts and
// against Supabase Storage + tables in index.ts.
//
// Rule: the first photo saved for a factory barcode is COPIED to
// barcode-catalogue-photos/<gtin14>.png and stays. A blocked hash is never
// shared. Candidates are tried in the order given (the caller passes them
// oldest first); the first one that can be shared wins.
//
// Races: the upload never overwrites (upsert: false) and the row insert is
// ON CONFLICT DO NOTHING, so when two shops race the first upload wins. An
// object found with no row (a crash between upload and insert, or a winner
// whose insert hasn't landed yet) is adopted: its own hash goes on the row,
// unless that hash is blocked, in which case the object is removed and this
// candidate is uploaded in its place.

export const SOURCE_BUCKET = "product-images";
export const SHARED_BUCKET = "barcode-catalogue-photos";

// Same limits as the product-images bucket (0144); the shared bucket (0182)
// enforces them too.
export const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
export const ALLOWED_CONTENT_TYPES: readonly string[] = [
  "image/png",
  "image/jpeg",
  "image/jpg",
  "image/webp",
  "image/heic",
  "image/heif",
];

/** A product whose photo could become the shared one. */
export interface Candidate {
  productId: string;
  businessId: string;
  imageUrl: string;
}

export interface Photo {
  bytes: Uint8Array;
  contentType: string;
}

/** A public.barcode_catalogue_photos row. */
export interface SharedRow {
  gtin14: string;
  objectPath: string;
  sha256: string;
}

export interface SharePorts {
  /** True when barcode_catalogue_photos already has a row for the GTIN. */
  sharedPhotoExists(gtin14: string): Promise<boolean>;
  /** True when the hash is in barcode_catalogue_photo_blocks. */
  isBlocked(sha256: string): Promise<boolean>;
  /** The product-images object, or null when it doesn't exist. */
  downloadSource(objectPath: string): Promise<Photo | null>;
  /** The barcode-catalogue-photos object, or null when it doesn't exist. */
  downloadShared(objectPath: string): Promise<Photo | null>;
  /** Upload without overwriting; "exists" when the object is already there. */
  uploadShared(
    objectPath: string,
    photo: Photo,
  ): Promise<"uploaded" | "exists">;
  removeShared(objectPath: string): Promise<void>;
  /** INSERT ... ON CONFLICT (gtin14) DO NOTHING. */
  insertSharedRow(row: SharedRow): Promise<void>;
}

export type SkipReason =
  | "invalid_source"
  | "source_missing"
  | "too_large"
  | "blocked";

export interface Skip {
  productId: string;
  reason: SkipReason;
}

export interface ShareOutcome {
  status: "shared" | "already_shared" | "nothing_to_share";
  gtin14: string;
  /** The product whose photo was shared (status "shared" only). */
  productId?: string;
  sha256?: string;
  /** An object with no row was found and recorded as the shared photo. */
  adoptedOrphan?: boolean;
  skipped: Skip[];
}

export function sharedObjectPath(gtin14: string): string {
  return `${gtin14}.png`;
}

const SOURCE_PATH_PREFIX = `/storage/v1/object/public/${SOURCE_BUCKET}/`;

/**
 * The product-images object path behind a product's image_url, or null when
 * the URL isn't a product-images public URL inside the product's own business
 * folder (`<businessId>/...`, the path RLS lets that business write).
 *
 * The origin isn't checked: the path is only ever read back from this
 * project's own bucket, never fetched from the URL's host.
 */
export function sourceObjectPath(
  imageUrl: string,
  businessId: string,
): string | null {
  let pathname: string;
  try {
    pathname = new URL(imageUrl).pathname;
  } catch (_e) {
    return null;
  }
  if (!pathname.startsWith(SOURCE_PATH_PREFIX)) return null;

  let path: string;
  try {
    path = decodeURIComponent(pathname.slice(SOURCE_PATH_PREFIX.length));
  } catch (_e) {
    return null;
  }
  const segments = path.split("/");
  if (segments.length < 2) return null;
  if (segments.some((s) => s === "" || s === "." || s === "..")) return null;
  if (segments[0].toLowerCase() !== businessId.toLowerCase()) return null;
  return path;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  // The copy pins the view to a plain ArrayBuffer, which newer lib typings
  // require of a BufferSource.
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function storedContentType(contentType: string): string {
  const type = contentType.split(";")[0].trim().toLowerCase();
  return ALLOWED_CONTENT_TYPES.includes(type) ? type : "image/png";
}

/**
 * Shares the first candidate whose photo can be shared, unless the GTIN
 * already has a shared photo. Candidates are tried in order.
 */
export async function shareFirstUnblocked(
  ports: SharePorts,
  gtin14: string,
  candidates: readonly Candidate[],
): Promise<ShareOutcome> {
  const skipped: Skip[] = [];
  if (await ports.sharedPhotoExists(gtin14)) {
    return { status: "already_shared", gtin14, skipped };
  }

  const objectPath = sharedObjectPath(gtin14);

  for (const c of candidates) {
    const sourcePath = sourceObjectPath(c.imageUrl, c.businessId);
    if (sourcePath === null) {
      skipped.push({ productId: c.productId, reason: "invalid_source" });
      continue;
    }
    const source = await ports.downloadSource(sourcePath);
    if (source === null) {
      skipped.push({ productId: c.productId, reason: "source_missing" });
      continue;
    }
    if (source.bytes.byteLength > MAX_PHOTO_BYTES) {
      skipped.push({ productId: c.productId, reason: "too_large" });
      continue;
    }
    const sha256 = await sha256Hex(source.bytes);
    if (await ports.isBlocked(sha256)) {
      skipped.push({ productId: c.productId, reason: "blocked" });
      continue;
    }

    const photo: Photo = {
      bytes: source.bytes,
      contentType: storedContentType(source.contentType),
    };

    if ((await ports.uploadShared(objectPath, photo)) === "exists") {
      if (await ports.sharedPhotoExists(gtin14)) {
        return { status: "already_shared", gtin14, skipped };
      }
      const orphan = await ports.downloadShared(objectPath);
      if (orphan !== null) {
        const orphanSha = await sha256Hex(orphan.bytes);
        if (!(await ports.isBlocked(orphanSha))) {
          await ports.insertSharedRow({
            gtin14,
            objectPath,
            sha256: orphanSha,
          });
          return {
            status: "already_shared",
            gtin14,
            adoptedOrphan: true,
            skipped,
          };
        }
        await ports.removeShared(objectPath);
      }
      // The object was blocked (now removed) or vanished: one more try.
      if ((await ports.uploadShared(objectPath, photo)) === "exists") {
        return { status: "already_shared", gtin14, skipped };
      }
    }

    await ports.insertSharedRow({ gtin14, objectPath, sha256 });
    return {
      status: "shared",
      gtin14,
      productId: c.productId,
      sha256,
      skipped,
    };
  }

  return { status: "nothing_to_share", gtin14, skipped };
}
