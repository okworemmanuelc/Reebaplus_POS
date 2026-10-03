# ADR 0029: Shared barcode catalogue across businesses

**Status:** accepted (2026-10-03). Build is **on hold** (issue #322 stays `on-hold`).  
**Context:** Issue #322 (owner grilling, 2026-10-03). Follows PRD #316 / ADR 0017.  
**Amends:** architecture.md invariant #5 (cross-business data access) with one named exception.

---

## Context

When a shop scans a barcode it has never saved, Add Product opens with only the
barcode filled in (#320). Most of what scanners see are factory products that
some other Reebaplus shop has already typed in. The owner wants those details
to pre-fill for everyone.

Until now every byte a client can read belongs to its own business. Invariant #5
says cross-business access is impossible and is enforced by RLS through
`current_user_business_ids()`. This is the first feature that deliberately lets
information cross between businesses, so it needs its own decision.

## Decision

### 1. What crosses, and what never does

Only three things are shared, keyed by barcode: the product **name** (which
already carries the size: the form tells people to write "Coca-Cola 50cl"),
the **unit**, and **one photo**. Nothing else crosses: no price, stock,
supplier, category, manufacturer, crate size, product id, business id, or
business name. No response from the catalogue says which shop, or how many
shops, a value came from.

Sharing is automatic for every business. **There is no opt-out setting.** The
owner chose this so the list fills quickly; the terms and privacy policy must
say that product names, units and photos are pooled (an owner action, not code).

### 2. Only real factory barcodes take part

A barcode takes part only if it is a valid **factory GTIN**:

- digits only, length 8, 12, 13 or 14, with a correct GS1 mod-10 check digit;
- not all zeros;
- not a GS1 restricted-circulation number, which shops and scales mint for
  themselves and which mean different things in different shops: GTIN-13
  prefixes `02`, `04` and `2`; UPC-A (GTIN-12) number systems `2` and `4`;
  GTIN-8 starting `0` or `2`; GTIN-14 judged on its inner GTIN-13.

Anything else ("001", "A12", a scale label) never goes in, and a lookup for it
returns nothing without touching the database. Barcodes are free text in
`products.barcode` and stay that way; this filter only decides what is shared.

The catalogue key is the **GTIN-14 form** (left-padded with zeros), so a UPC-A
read as 12 digits and the same code read as EAN-13 with a leading `0` are one
entry. One rule lives in two places that must agree: a SQL function
`public.is_factory_gtin(text)` / `public.gtin14(text)` (both `IMMUTABLE`) and a
pure Dart parser. A shared vector fixture keeps them in lockstep.

### 3. Names and units are computed live from `public.products`. No vote table.

There is **no stored catalogue of names**. The lookup computes the answer at
request time from the cloud `products` table that every shop already syncs to:

1. Take every non-deleted product whose `gtin14(barcode)` matches.
2. **One shop, one vote:** for each business, only its most recently updated
   matching product counts. A shop with duplicates (#318) still votes once.
3. Normalise names before counting: trim, collapse runs of whitespace, compare
   case-insensitively. Remove any normalised name on the block list (§6).
4. **The most votes wins; a tie goes to the most recent** (`max(last_updated_at)`
   in the group). The name returned is the most common exact spelling within
   the winning group (tie: the most recent one).
5. The unit is a separate vote over the same per-business products, under the
   same rules. Products with no unit don't vote. If nobody has a unit, no unit
   is suggested.
6. One shop is enough to produce a suggestion.

Because the answer is derived, several decisions take care of themselves:
renaming moves a shop's vote, deleting a product removes it, a deleted business
(hard-deleted by `delete_business`) stops voting, and **no backfill is needed
for names and units**. Every existing product is counted from day one.

Known approximation: `last_updated_at` bumps on *any* update (a price change,
say), not only a rename, so in a tie the shop that last touched its product
wins. Accepted for a tie-break.

Performance: an expression index on `gtin14(barcode)` restricted to
`is_factory_gtin(barcode) AND NOT is_deleted`.

### 4. The lookup is one read-only definer RPC

`public.barcode_suggestion(p_barcode text)` is `SECURITY DEFINER` with a pinned
`search_path`, executable by `authenticated` only (revoked from `anon` and
`public`). It returns zero rows, or one row of `(name, unit, photo_url)`. It is
the **only** way across the tenant boundary. No client gets `SELECT` on another
business's `products` rows, and RLS on `products` is unchanged.

It returns zero rows when the code is not a factory GTIN, when nothing matches,
or when the kill switch (§7) is off.

### 5. One photo per barcode: the first one stays

Photos can't be voted on, so the **first photo saved for a barcode becomes the
shared photo and stays**. A later shop's photo never replaces it.

- **Shared copy.** It is a *copy*, held in a new public-read bucket
  `barcode-catalogue-photos` at `<gtin14>.png`, recorded in
  `public.barcode_catalogue_photos (gtin14 pk, object_path, sha256, created_at)`.
  The source shop changing or deleting its own photo never breaks it.
  The bucket and table have **no client write policies**; only the service role
  writes.
- **Who copies.** An `AFTER INSERT OR UPDATE OF image_url, barcode` trigger on
  `public.products` fires when the row has an `image_url`, a factory GTIN, and
  no shared photo yet for that GTIN. It calls the Edge Function
  `share-barcode-photo` through `pg_net`, using the same secret-header pattern as
  `send-push` (it does nothing when the project is unconfigured). The function
  re-checks, downloads the source image from its public URL, hashes it, skips a
  blocked hash (§6), uploads with `upsert: false`, and inserts the row
  `ON CONFLICT DO NOTHING`. So when two shops race, the first one wins.
- **One code path for seeding.** The same function also accepts `{gtin14}` and
  walks that GTIN's candidate products **oldest first**, skipping blocked hashes.
  The one-time photo backfill runs it over every GTIN that has a photo, and the
  removal runbook (§6) reuses it to promote the next photo.
- **What the receiving shop gets.** If they keep the suggested photo, the app
  downloads its bytes and saves them through `ProductImageService` as **that
  shop's own photo** (`product-images/<businessId>/<productId>.png`, the normal
  #78 path, including offline pending upload). From then on it is theirs, and
  removing the shared photo never breaks their product.
- **Account deletion.** A shared photo stays when its source shop deletes a
  product or its whole account. It carries no shop identity, and keeping a
  source-shop column only to delete it later would be exactly the
  business-to-catalogue link this design avoids.

### 6. Bad entries: removed by hand, and a removal sticks

No review UI and no in-app "report" button in this version. Reports arrive
through support, and a developer applies them with the service role:

- **Name:** insert `(gtin14, normalised_name)` into
  `public.barcode_catalogue_name_blocks`. The lookup ignores that name for that
  GTIN, so the shop that sent it can't bring it back by saving again. The vote
  falls to the next name.
- **Photo:** insert its `sha256` into `public.barcode_catalogue_photo_blocks`,
  delete the row and the object, then call `share-barcode-photo` with
  `{gtin14}` to promote the next-oldest unblocked photo.

Both block tables have RLS on and no policies (service role only). A review page
in the Admin Hub is a separate, later piece of work.

### 7. Kill switch, Reebaplus-only

A new `public.platform_settings (key text pk, value jsonb, updated_at)` table,
with RLS on and no policies (service role only, read by the definer RPC). The key
`barcode_catalogue.suggestions_enabled` is seeded `true`. When it is false,
`barcode_suggestion` returns zero rows. Every shop then sees empty boxes, as
before, with no app release. Photo copying keeps running while it is off, so the
list keeps growing. Shops never see this switch. It moves into the Admin Hub
with the review page.

### 8. Client behaviour

- **Where:** Add Product only, in both entry paths: the POS unknown-scan route
  (`prefilledBarcode`) and typing or scanning into the barcode box. Both Fast-Add
  and classic layouts.
- **When:** only while adding a **brand-new** product. Never on edit, never when
  an existing product is selected for restock, never in the #321 link flow.
- **What:** fills only **empty** boxes: the name, the unit (empty = "No unit"),
  and the photo (if none is picked). A late answer still fills only what is
  empty, and is dropped if the barcode box no longer holds that code. The
  suggested unit is added to the unit dropdown if the business's starter list
  lacks it. Picking `Bottle` turns empties tracking on, as it already does.
- **Note:** each filled field shows "Filled in from the Reebaplus product list.
  Check it before saving." No accept button, no extra screen.
- **Offline:** online lookup only, about **2 s** timeout, any failure is silent
  (no toast, no retry) and leaves the boxes empty. Nothing is cached on the
  phone. Saving the product never waits on the lookup.
- **Boundary:** a `BarcodeCatalogueService` in `lib/core/services/` makes the RPC
  call and downloads the photo. It is added to architecture.md's list of
  sanctioned direct-Supabase exceptions: a read-only RPC, plus fetching a public
  Storage object. No feature code calls Supabase directly. Contribution needs no
  client code at all. It comes from the products a shop already syncs, which
  also covers the web POS.

## Consequences

- **Invariant #5 gains one named exception.** No *row* of another business is
  ever readable. Only the aggregate answer of `barcode_suggestion` and the
  shared photos cross, and neither carries business identity.
- **Enumeration.** A signed-in user can ask about any barcode and learn that
  *some* Reebaplus shop stocks it, plus its consensus name, unit and photo.
  Never which shop or how many. Accepted.
- **Privacy depends on two filters**, the factory-GTIN rule and the manual block
  lists. A shop's own mix rarely carries a factory GTIN, so it rarely shares. A
  photo showing a shop's interior can leak until someone reports it and it is
  removed. Accepted, given the owner's no-opt-out choice.
- **Deploy order is forgiving.** If the app ships before the RPC, lookups fail
  silently. A trigger with no Edge Function configuration does nothing. The
  only hard order is to deploy the Edge Function before running the photo
  backfill.
- **No Drift schema change** and no new synced table. All new tables are
  cloud-only and service-role-written.

## Rejected alternatives

- **A stored vote table maintained by triggers.** It duplicates what `products`
  already holds, needs a backfill, and drifts on deletes. The live aggregate
  over an index is simpler and always right.
- **Per-business opt-out or opt-in.** The owner rejected it so the list fills.
- **The most recent photo wins.** Any shop could swap in a bad picture at any
  time. The owner chose stability.
- **Removing a deleted shop's shared photo.** It would require storing which
  shop sent each photo.
- **A local cache of popular codes.** A new sync surface for other shops' data.
  Online-only is enough.
- **Seeding from public GTIN databases (Open Food Facts).** ODbL share-alike
  licensing, thin Nigerian coverage, and names and units that don't fit. It can
  be a later issue after a licence review.
