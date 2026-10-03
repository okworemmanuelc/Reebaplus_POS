// share-barcode-photo / share.ts
//
// The pure sharing logic for the shared barcode catalogue photo (ADR 0029 §5),
// behind SharePorts so it runs against an in-memory fake in share_test.ts and
// against Supabase Storage + tables in index.ts.
//
// Rule: the first photo saved for a factory barcode is COPIED to
// barcode-catalogue-photos/<gtin14>.<ext> and stays, where <ext> follows the
// photo's real type (jpg, png, webp, heic, heif; owner amendment on #331).
// The row's object_path records that name. A blocked hash is never shared.
// Candidates are tried in the order given (the caller passes them oldest
// first); the first one that can be shared wins.
//
// Races: the upload never overwrites (upsert: false) and the row insert is
// ON CONFLICT DO NOTHING, so the first row wins. Two shops racing with the
// same type collide on the object name: the first upload wins, and an object
// found with no row (a crash between upload and insert, or a winner whose
// insert hasn't landed yet) is adopted: its own hash goes on the row, unless
// that hash is blocked, in which case the object is removed and this
// candidate is uploaded in its place. Two shops racing with different types
// both upload; the one whose row didn't land removes its own object.

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
  /** The object_path of the GTIN's barcode_catalogue_photos row, or null. */
  sharedPhotoPath(gtin14: string): Promise<string | null>;
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
  | "unsupported_type"
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

// File extension per stored content type. Every ALLOWED_CONTENT_TYPES entry
// has one.
const EXTENSIONS: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "image/heif": "heif",
};

/** `<gtin14>.<ext>`, the extension following the photo's content type. */
export function sharedObjectPath(gtin14: string, contentType: string): string {
  const ext = EXTENSIONS[contentType];
  if (ext === undefined) {
    throw new Error(`no shared file extension for ${contentType}`);
  }
  return `${gtin14}.${ext}`;
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

function startsWith(bytes: Uint8Array, at: number, sig: number[]): boolean {
  if (bytes.byteLength < at + sig.length) return false;
  return sig.every((b, i) => bytes[at + i] === b);
}

/** JPEG, PNG or WebP told apart by their leading bytes, else null. */
function sniffContentType(bytes: Uint8Array): string | null {
  if (startsWith(bytes, 0, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (startsWith(bytes, 0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return "image/png";
  }
  if (
    startsWith(bytes, 0, [0x52, 0x49, 0x46, 0x46]) && // "RIFF"
    startsWith(bytes, 8, [0x57, 0x45, 0x42, 0x50]) // "WEBP"
  ) {
    return "image/webp";
  }
  return null;
}

/**
 * The photo's real type: what its bytes say (JPEG, PNG, WebP), else the
 * stored content type when it is an allowed image type (HEIC/HEIF), else
 * null (not a photo the shared bucket takes). `image/jpg` is normalised to
 * `image/jpeg`.
 */
export function photoContentType(photo: Photo): string | null {
  const sniffed = sniffContentType(photo.bytes);
  if (sniffed !== null) return sniffed;
  const declared = photo.contentType.split(";")[0].trim().toLowerCase();
  if (!ALLOWED_CONTENT_TYPES.includes(declared)) return null;
  return declared === "image/jpg" ? "image/jpeg" : declared;
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
  if ((await ports.sharedPhotoPath(gtin14)) !== null) {
    return { status: "already_shared", gtin14, skipped };
  }

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
    const contentType = photoContentType(source);
    if (contentType === null) {
      skipped.push({ productId: c.productId, reason: "unsupported_type" });
      continue;
    }
    const sha256 = await sha256Hex(source.bytes);
    if (await ports.isBlocked(sha256)) {
      skipped.push({ productId: c.productId, reason: "blocked" });
      continue;
    }

    const objectPath = sharedObjectPath(gtin14, contentType);
    const photo: Photo = { bytes: source.bytes, contentType };

    if ((await ports.uploadShared(objectPath, photo)) === "exists") {
      if ((await ports.sharedPhotoPath(gtin14)) !== null) {
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
    if ((await ports.sharedPhotoPath(gtin14)) !== objectPath) {
      // Another type's upload got its row in first: ours is a stray copy.
      await ports.removeShared(objectPath);
      return { status: "already_shared", gtin14, skipped };
    }
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
