# ADR 0029: Shared barcode catalogue across businesses

**Status:** accepted (2026-10-03); §6 amended the same day (in-app reports). Build in progress: #330 (lookup) and #331 (shared photo) are built; #332 and #335 are not.  
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
  `barcode-catalogue-photos` at `<gtin14>.<ext>`, recorded in
  `public.barcode_catalogue_photos (gtin14 pk, object_path, sha256, created_at)`.
  The extension follows the photo's real type (owner amendment on #331,
  2026-10-03): `.jpg` for JPEG, `.png` for PNG, `.webp` for WebP, `.heic` /
  `.heif` for HEIC / HEIF. The type is read from the file's own bytes (JPEG,
  PNG, WebP), else the stored content type when it is one of those image
  types; anything else is not shared. The upload carries that content type and
  `object_path` records the real name, so readers always go through
  `object_path`, never a guessed name. Product photos move to JPEG in #340, so
  new shared photos will be `.jpg`; older PNG photos picked up by the backfill
  keep `.png`.
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
  `ON CONFLICT DO NOTHING`. So when two shops race, the first row wins. When
  the racing photos have different types (two different object names), the
  shop whose row didn't land removes its own copy.
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

### 6. Bad entries: reported in the app, removed by hand, and a removal sticks

*(Amended 2026-10-03: the owner added an in-app report on product details. The
first version of this section said reports would come through support.)*

**Reporting.** Product details shows a small **"Report a problem with the shared
details"** link, only when the product's barcode is a factory GTIN. It opens a
sheet that loads the current `barcode_suggestion` for that barcode, so the shop
reports what is actually shared, not its own product's edited copy. The shop
ticks one or more of **Wrong name**, **Wrong unit** and **Bad or private photo**,
adds an optional note (≤ 500 characters), and taps Send. If nothing is shared
for that code right now (no match, or the kill switch is off), the sheet says
so and has no Send button. Sending needs internet; offline, the sheet says
"Connect to the internet to send this report." Nothing is queued on the phone.

Reports are **structured rows in the online database**, not email:
`public.barcode_catalogue_reports (id uuid pk, gtin14, reasons text[]` (non-empty
subset of `wrong_name`, `wrong_unit`, `bad_photo`), `note, shown_name,
shown_unit, shown_photo_url, business_id` (→ `businesses`, `ON DELETE SET
NULL`), `reported_by` (→ `users`, `ON DELETE SET NULL`), `status` (`open` |
`resolved` | `dismissed`), `created_at, resolved_at)`. RLS is on with no
policies. The only write path is the definer RPC
`report_barcode_catalogue_entry(...)`, which takes the business and reporter
from the caller (membership checked through `current_user_business_ids()`, never
trusted from the client), rejects a non-GTIN code, and allows **one open report
per business per GTIN**: a repeat updates that report's reasons and note instead
of adding a new row. Shops never read reports back.

Reports **do** record which shop and which person sent them, so Reebaplus can
follow up. That is a deliberate, owner-approved difference from the catalogue
itself: reports are private to Reebaplus and are never shown to other shops.
When a shop deletes its account, its reports stay, but their shop and person
links are set to null.

Not a synced table and not in Drift. The client writes through
`BarcodeCatalogueService`, the same sanctioned exception as the lookup.

**Removal.** A developer reads open reports with the service role and applies
the fix:

- **Name:** insert `(gtin14, normalised_name)` into
  `public.barcode_catalogue_name_blocks`:
  ```sql
  INSERT INTO public.barcode_catalogue_name_blocks (gtin14, normalised_name)
  VALUES (
    public.gtin14('<barcode>'),
    public.barcode_catalogue_normalise_name('<bad name>')
  );
  ```
  The lookup ignores that name for that GTIN, so the shop that sent it can't
  bring it back by saving again. The vote falls to the next name.
- **Photo:** insert its `sha256` into `public.barcode_catalogue_photo_blocks`,
  delete the row and the object, then call `share-barcode-photo` with
  `{gtin14}` to promote the next-oldest unblocked photo:
  ```sql
  -- 1. Block the hash (taken from the current row).
  INSERT INTO public.barcode_catalogue_photo_blocks (sha256, gtin14)
  SELECT sha256, gtin14 FROM public.barcode_catalogue_photos
   WHERE gtin14 = public.gtin14('<barcode>');
  -- 2. Delete the row. Note the object_path it returns (e.g.
  --    06150001234561.jpg): the extension follows the photo's type, so don't
  --    guess it.
  DELETE FROM public.barcode_catalogue_photos
   WHERE gtin14 = public.gtin14('<barcode>')
  RETURNING object_path;
  ```
  3. Delete the object `barcode-catalogue-photos/<object_path>` (the name step 2
     returned) in the Storage dashboard (SQL can't delete Storage objects).
     Don't skip this: the URL is guessable and stays public while the object
     exists. The CDN can keep serving a cached copy for up to an hour.
  ```sql
  -- 4. Promote the next-oldest unblocked photo (returns a pg_net request id;
  --    NULL means the Vault secret is missing). Check the outcome in
  --    net._http_response.
  SELECT public.barcode_catalogue_request_share(
    jsonb_build_object('gtin14', public.gtin14('<barcode>')));
  ```
  If no other shop has an unblocked photo, the code simply has no shared
  photo until one is saved. If step 3 was forgotten, the function removes the
  blocked object itself only when the next photo it shares for that code has
  the same type (the same object name); a photo of another type gets its own
  name and the blocked object stays public. So never skip step 3.

Then mark the report `resolved` (or `dismissed`) with `resolved_at`. Both block
tables have RLS on and no policies (service role only). A review page in the
Admin Hub that reads `barcode_catalogue_reports` is a separate, later piece of
work.

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
