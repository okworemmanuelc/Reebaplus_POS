// share-barcode-photo / share_test.ts
//
// Unit tests for the PURE sharing logic (share.ts). No network, no Supabase:
// storage and tables are an in-memory fake behind SharePorts. Run: `deno test`
// in this directory. (Not wired into CI — there is no Deno test tier in this
// repo, same posture as send-push/fcm_test.ts.)

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type Candidate,
  MAX_PHOTO_BYTES,
  type Photo,
  sha256Hex,
  sharedObjectPath,
  type SharedRow,
  shareFirstUnblocked,
  type SharePorts,
  sourceObjectPath,
} from "./share.ts";

const BIZ_A = "0199a1b2-0000-7000-8000-00000000000a";
const BIZ_B = "0199a1b2-0000-7000-8000-00000000000b";
const BIZ_C = "0199a1b2-0000-7000-8000-00000000000c";
const GTIN14 = "06150001234561";
const BASE = "https://ref.supabase.co/storage/v1/object/public/product-images";

function photo(text: string, contentType = "image/png"): Photo {
  return { bytes: new TextEncoder().encode(text), contentType };
}

function candidate(productId: string, businessId: string): Candidate {
  return {
    productId,
    businessId,
    imageUrl: `${BASE}/${businessId}/${productId}.png`,
  };
}

// In-memory storage + tables. `sources` is the product-images bucket keyed by
// object path, `shared` the barcode-catalogue-photos bucket.
class FakePorts implements SharePorts {
  sources = new Map<string, Photo>();
  shared = new Map<string, Photo>();
  rows = new Map<string, SharedRow>();
  blocked = new Set<string>();
  uploads: string[] = [];
  removed: string[] = [];

  // Runs once, right after the first upload attempt is rejected as "exists",
  // to stage what a concurrent winner did in between.
  onUploadExists: (() => void) | null = null;

  sharedPhotoExists(gtin14: string): Promise<boolean> {
    return Promise.resolve(this.rows.has(gtin14));
  }
  isBlocked(sha256: string): Promise<boolean> {
    return Promise.resolve(this.blocked.has(sha256));
  }
  downloadSource(objectPath: string): Promise<Photo | null> {
    return Promise.resolve(this.sources.get(objectPath) ?? null);
  }
  downloadShared(objectPath: string): Promise<Photo | null> {
    return Promise.resolve(this.shared.get(objectPath) ?? null);
  }
  uploadShared(objectPath: string, p: Photo): Promise<"uploaded" | "exists"> {
    this.uploads.push(objectPath);
    if (this.shared.has(objectPath)) {
      const stage = this.onUploadExists;
      this.onUploadExists = null;
      stage?.();
      return Promise.resolve("exists");
    }
    this.shared.set(objectPath, p);
    return Promise.resolve("uploaded");
  }
  removeShared(objectPath: string): Promise<void> {
    this.removed.push(objectPath);
    this.shared.delete(objectPath);
    return Promise.resolve();
  }
  insertSharedRow(row: SharedRow): Promise<void> {
    if (!this.rows.has(row.gtin14)) this.rows.set(row.gtin14, row);
    return Promise.resolve();
  }

  addSource(c: Candidate, p: Photo): void {
    this.sources.set(`${c.businessId}/${c.productId}.png`, p);
  }
}

// ── sourceObjectPath ─────────────────────────────────────────────────────────

Deno.test("sourceObjectPath: the product's own product-images object", () => {
  assertEquals(
    sourceObjectPath(`${BASE}/${BIZ_A}/p1.png`, BIZ_A),
    `${BIZ_A}/p1.png`,
  );
  // A cache-busting query string is ignored.
  assertEquals(
    sourceObjectPath(`${BASE}/${BIZ_A}/p1.png?t=123`, BIZ_A),
    `${BIZ_A}/p1.png`,
  );
  // Business ids compare case-insensitively.
  assertEquals(
    sourceObjectPath(`${BASE}/${BIZ_A.toUpperCase()}/p1.png`, BIZ_A),
    `${BIZ_A.toUpperCase()}/p1.png`,
  );
});

Deno.test("sourceObjectPath: anything else is not a source", () => {
  const rejects = [
    "",
    "not a url",
    `${BASE}/${BIZ_B}/p1.png`, // another business's folder
    `${BASE}/p1.png`, // no business folder
    `${BASE}/${BIZ_A}/`, // no file
    `${BASE}/${BIZ_A}/../${BIZ_B}/p1.png`,
    `${BASE}/${BIZ_A}/%2e%2e/p1.png`,
    `https://ref.supabase.co/storage/v1/object/public/business-logos/${BIZ_A}/p1.png`,
    `https://ref.supabase.co/storage/v1/object/sign/product-images/${BIZ_A}/p1.png`,
  ];
  for (const url of rejects) {
    assertEquals(sourceObjectPath(url, BIZ_A), null, url);
  }
});

// ── sha256Hex / sharedObjectPath ─────────────────────────────────────────────

Deno.test("sha256Hex: lower-case hex of the bytes", async () => {
  assertEquals(
    await sha256Hex(new TextEncoder().encode("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

Deno.test("sharedObjectPath: <gtin14>.png", () => {
  assertEquals(sharedObjectPath(GTIN14), "06150001234561.png");
});

// ── shareFirstUnblocked ──────────────────────────────────────────────────────

Deno.test("shares the first candidate: object at <gtin14>.png + its row", async () => {
  const ports = new FakePorts();
  const a = candidate("pa", BIZ_A);
  ports.addSource(a, photo("photo-a", "image/jpeg"));

  const out = await shareFirstUnblocked(ports, GTIN14, [a]);

  const sha = await sha256Hex(new TextEncoder().encode("photo-a"));
  assertEquals(out.status, "shared");
  assertEquals(out.productId, "pa");
  assertEquals(out.sha256, sha);
  assertEquals(ports.rows.get(GTIN14), {
    gtin14: GTIN14,
    objectPath: "06150001234561.png",
    sha256: sha,
  });
  const stored = ports.shared.get("06150001234561.png");
  assertEquals(new TextDecoder().decode(stored!.bytes), "photo-a");
  assertEquals(stored!.contentType, "image/jpeg");
});

Deno.test("an unknown content type is stored as image/png", async () => {
  const ports = new FakePorts();
  const a = candidate("pa", BIZ_A);
  ports.addSource(a, photo("photo-a", "application/octet-stream"));

  await shareFirstUnblocked(ports, GTIN14, [a]);

  assertEquals(
    ports.shared.get("06150001234561.png")!.contentType,
    "image/png",
  );
});

Deno.test("a GTIN that already has a shared photo is left alone", async () => {
  const ports = new FakePorts();
  const first = {
    gtin14: GTIN14,
    objectPath: "06150001234561.png",
    sha256: "x",
  };
  ports.rows.set(GTIN14, first);
  const b = candidate("pb", BIZ_B);
  ports.addSource(b, photo("photo-b"));

  const out = await shareFirstUnblocked(ports, GTIN14, [b]);

  assertEquals(out.status, "already_shared");
  assertEquals(ports.uploads, []);
  assertEquals(ports.rows.get(GTIN14), first);
});

Deno.test("a blocked hash is skipped and the next candidate shared, in order", async () => {
  const ports = new FakePorts();
  const a = candidate("pa", BIZ_A);
  const b = candidate("pb", BIZ_B);
  const c = candidate("pc", BIZ_C);
  ports.addSource(a, photo("photo-a"));
  ports.addSource(b, photo("photo-b"));
  ports.addSource(c, photo("photo-c"));
  ports.blocked.add(await sha256Hex(new TextEncoder().encode("photo-a")));

  const out = await shareFirstUnblocked(ports, GTIN14, [a, b, c]);

  assertEquals(out.status, "shared");
  assertEquals(out.productId, "pb");
  assertEquals(out.skipped, [{ productId: "pa", reason: "blocked" }]);
  assertEquals(
    new TextDecoder().decode(ports.shared.get("06150001234561.png")!.bytes),
    "photo-b",
  );
});

Deno.test("every candidate blocked → nothing shared, bucket untouched", async () => {
  const ports = new FakePorts();
  const a = candidate("pa", BIZ_A);
  ports.addSource(a, photo("photo-a"));
  ports.blocked.add(await sha256Hex(new TextEncoder().encode("photo-a")));

  const out = await shareFirstUnblocked(ports, GTIN14, [a]);

  assertEquals(out.status, "nothing_to_share");
  assertEquals(out.skipped, [{ productId: "pa", reason: "blocked" }]);
  assertEquals(ports.uploads, []);
  assertEquals(ports.rows.size, 0);
});

Deno.test("no candidates → nothing shared", async () => {
  const out = await shareFirstUnblocked(new FakePorts(), GTIN14, []);
  assertEquals(out.status, "nothing_to_share");
  assertEquals(out.skipped, []);
});

Deno.test("foreign URL, missing source and oversized source are skipped", async () => {
  const ports = new FakePorts();
  const foreign: Candidate = {
    productId: "pf",
    businessId: BIZ_A,
    imageUrl: "https://example.com/cat.png",
  };
  const missing = candidate("pm", BIZ_B);
  const huge = candidate("ph", BIZ_C);
  ports.addSource(huge, {
    bytes: new Uint8Array(MAX_PHOTO_BYTES + 1),
    contentType: "image/png",
  });
  const good = candidate("pg", BIZ_A);
  ports.addSource(good, photo("photo-g"));

  const out = await shareFirstUnblocked(ports, GTIN14, [
    foreign,
    missing,
    huge,
    good,
  ]);

  assertEquals(out.status, "shared");
  assertEquals(out.productId, "pg");
  assertEquals(out.skipped, [
    { productId: "pf", reason: "invalid_source" },
    { productId: "pm", reason: "source_missing" },
    { productId: "ph", reason: "too_large" },
  ]);
});

Deno.test("race lost: the object exists and the winner's row landed → no overwrite", async () => {
  const ports = new FakePorts();
  const b = candidate("pb", BIZ_B);
  ports.addSource(b, photo("photo-b"));
  const winner = photo("photo-a");
  const winnerRow = {
    gtin14: GTIN14,
    objectPath: "06150001234561.png",
    sha256: await sha256Hex(winner.bytes),
  };
  ports.shared.set("06150001234561.png", winner);
  ports.onUploadExists = () => ports.rows.set(GTIN14, winnerRow);

  const out = await shareFirstUnblocked(ports, GTIN14, [b]);

  assertEquals(out.status, "already_shared");
  assertEquals(ports.rows.get(GTIN14), winnerRow);
  assertEquals(
    new TextDecoder().decode(ports.shared.get("06150001234561.png")!.bytes),
    "photo-a",
  );
  assertEquals(ports.removed, []);
});

Deno.test("an object with no row is adopted: first upload wins, row gets its hash", async () => {
  const ports = new FakePorts();
  const b = candidate("pb", BIZ_B);
  ports.addSource(b, photo("photo-b"));
  ports.shared.set("06150001234561.png", photo("photo-a"));

  const out = await shareFirstUnblocked(ports, GTIN14, [b]);

  assertEquals(out.status, "already_shared");
  assertEquals(out.adoptedOrphan, true);
  assertEquals(
    ports.rows.get(GTIN14)!.sha256,
    await sha256Hex(new TextEncoder().encode("photo-a")),
  );
  assertEquals(
    new TextDecoder().decode(ports.shared.get("06150001234561.png")!.bytes),
    "photo-a",
  );
});

Deno.test("an orphan object with a blocked hash is removed and replaced", async () => {
  const ports = new FakePorts();
  const b = candidate("pb", BIZ_B);
  ports.addSource(b, photo("photo-b"));
  ports.shared.set("06150001234561.png", photo("bad-photo"));
  ports.blocked.add(await sha256Hex(new TextEncoder().encode("bad-photo")));

  const out = await shareFirstUnblocked(ports, GTIN14, [b]);

  assertEquals(out.status, "shared");
  assertEquals(out.productId, "pb");
  assertEquals(ports.removed, ["06150001234561.png"]);
  assertEquals(
    new TextDecoder().decode(ports.shared.get("06150001234561.png")!.bytes),
    "photo-b",
  );
  assertEquals(
    ports.rows.get(GTIN14)!.sha256,
    await sha256Hex(new TextEncoder().encode("photo-b")),
  );
});

Deno.test("the shared photo never touches the source object", async () => {
  const ports = new FakePorts();
  const a = candidate("pa", BIZ_A);
  ports.addSource(a, photo("photo-a"));

  await shareFirstUnblocked(ports, GTIN14, [a]);
  ports.sources.clear(); // the shop deletes its own photo

  assert(ports.shared.has("06150001234561.png"));
  assert(ports.rows.has(GTIN14));
});
