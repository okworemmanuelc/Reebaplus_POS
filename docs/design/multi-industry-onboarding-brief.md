# Multi-Industry Onboarding & App Morphing — Grilling Brief

> **Purpose.** Seed document for the `/ask-matt` main flow
> (`/grill-with-docs` → `/to-prd` → `/to-issues`). It restructures and
> elaborates the raw request into a shape the grilling can sharpen and the
> PRD/issues can be split from. It is **not** the final spec — the open
> questions in §7 are deliberately unresolved so the interview can settle them.

---

## 1. One-line ask

Unlock **every** industry at onboarding (not just Beverage distributor), add two
brand-new industries (**Phone & Gadgets**, **Frozen Foods & Grocery**), and make
the app's **language, guidance, presets, form fields, and feature surfaces morph
to fit the industry the CEO chose** — starting with an optional **product image**
on the Add / Update Product forms for all industries.

## 2. Why (problem statement)

The app is currently hard-built for a Beverage distributor. Onboarding shows all
seven master-plan industries but only **Beverage distributor** is selectable; the
other six are greyed-out "coming soon." Worse, the whole interior of the app
speaks **beverage** — "crates," "bottles," "empties," "manufacturers" — so even
if we flipped the other industries on today, a Pharmacy or Boutique owner would
be managing "crates of drinks." The product is not yet **industry-aware**; it is
beverage-aware with disabled doors.

We want the app to **become the industry it was set up for**: the words on the
Add Product form, the category and unit suggestions, the guides and empty-state
hints, and eventually which tabs/fields/flows exist, should all reflect the
selected industry.

## 3. The nine-industry catalogue

Existing seven (from `lib/core/data/business_types.dart`, plan order):

1. Restaurant
2. Supermarket
3. Bar *(crate-eligible)*
4. Beverage distributor *(crate-eligible — the one currently live)*
5. Pharmacy
6. Building Materials
7. Boutique

Add two **new**:

8. **Phone & Gadgets**
9. **Frozen Foods & Grocery**

All nine selectable at onboarding once this program ships (rollout strategy is an
open question — see §7).

## 4. Current state (code grounding — verified, not assumed)

- **Industry list is duplicated.** Canonical display strings live in
  `lib/core/data/business_types.dart` (`kBusinessTypes`); the CEO sign-up screen
  keeps its **own** private `_businessTypes` record list
  (`ceo_sign_up_screen.dart`) coupling each label to an `IconData` and a
  `comingSoon` bool. Two sources of truth to reconcile.
- **Stored value is a display string, with a legacy quirk.** `businesses.type`
  stores a string (the DB canonical for the live one is `'Beer distributor'`,
  mapped to the display label "Beverage distributor" at load/save). There is
  **no stable industry-id enum column** today. Older tenants stored
  non-canonical casings — hence `isCrateBusiness()` normalises case.
- **Only one industry-driven gate exists.** `isCrateBusiness(type)` (Bar / Beer
  distributor) **AND** the `businesses.tracks_empty_crates` opt-in flag together
  gate every empty-crate surface. This is the *only* precedent for morphing a
  feature surface by industry, and it is a good pattern to generalise.
- **No terminology / lexicon abstraction exists.** "crate"/"bottle" wording is
  hardcoded across ~23 feature files. Nothing centralises industry copy.
- **Product image is half-built and local-only.** `products.imagePath` (a local
  file path column) already exists; `update_product_sheet.dart` already picks a
  local image via `image_picker`; **`add_product_screen.dart` has no image UI**;
  and `imagePath` is **not** in the sync registry/push whitelist, so images do
  **not** cross devices (same situation the business logo solved with
  `BusinessLogoService` + a Supabase Storage bucket).
- **Invariants that constrain the design** (`context/architecture.md`):
  offline-first, Drift is source of truth, every cloud write goes through the
  outbox, `*_kobo` columns are bigint, new synced tables need a `SyncedTable`
  registry entry + the `current_user_business_ids()` RLS helper, permissions are
  data not code, entry is never blocked on a pull.

## 5. Proposed decomposition (epics → candidate issues)

Ordered so the foundation lands before the morph. `/to-issues` will split these;
this is a starting cut, not the final issue list.

### Epic 0 — Industry model foundation *(blocking prerequisite)*
- Introduce a single **`IndustryProfile` registry** keyed by a stable industry
  **id** (retiring the duplicated list). Each profile carries: `id`,
  `displayName`, `icon`, `lexicon` (the noun set — what one product is called,
  what a "unit" is, what "inventory"/"supplier"/"category" are called),
  default **categories**, default **units of measure**, **feature flags**
  (`tracksEmptyCrates`, `tracksExpiry`, `tracksSerialOrImei`, `tracksColdChain`,
  price-tier model, …), the **Add/Update Product field set**, and
  **guidance/help copy**.
- Decide the canonical identifier and the **migration** for existing tenants
  (see §7).

### Epic 1 — Enable all industries at onboarding
- Remove `comingSoon`; add Phone & Gadgets + Frozen Foods & Grocery; icons +
  ordering; keep the crate opt-in visible **only** for crate-eligible industries.

### Epic 2 — Terminology morph (lexicon layer)
- Expose the active business's lexicon via a provider; replace hardcoded strings
  **starting with Add/Update Product**, then POS, inventory, guides, empty
  states, suggestions. Beverage keeps its exact current wording (no regression).

### Epic 3 — Optional product image (all industries, cross-device)
- Add image picker to **Add Product**; unify with Update Product; sync images
  cross-device (Supabase Storage bucket, mirror `BusinessLogoService`); local
  cache for offline grid/receipt; surface in POS grid + receipt (open question:
  where it shows).

### Epic 4+ — Per-industry functional morph *(one industry per PR, sequential)*
- **Phone & Gadgets:** per-unit serial/IMEI, warranty, no expiry/crate.
- **Frozen Foods & Grocery:** expiry + cold-chain emphasis, weight/batch, no crate.
- **Pharmacy:** batch + expiry, regulated categories (barcode deferred).
- **Restaurant / Supermarket / Building Materials / Boutique:** their own field
  sets, categories, and terminology.

## 6. Constraints & invariants to respect
- Offline-first; Drift source of truth; all cloud writes via the outbox.
- New synced column/table ⇒ registry entry + `bigint` for money + the
  `current_user_business_ids()` RLS pattern.
- Product image must never block a save and must render offline (local cache).
- No AI attribution in commits/PRs (repo rule); log verified fixes to BUILD_LOG.

## 7. Open questions for the grilling (the "pictures" to resolve)
1. **Canonical industry id:** keep the display string in `businesses.type`, or
   add a stable `industry_id` enum column? What migration for existing tenants
   (incl. the `'Beer distributor'` legacy casing)?
2. **Lexicon depth:** just nouns, or full guidance/help/onboarding tips per
   industry? Who authors the copy and in what tone?
3. **Editable after onboarding?** `tracks_empty_crates` is editable in Settings —
   should the *industry* be too? What happens to existing data if an industry is
   switched?
4. **Feature flags vs opt-ins:** which surfaces are strictly industry-driven vs a
   per-business toggle (crate tracking is already decoupled from type)?
5. **Product image specifics:** one image or many? Cloud sync now or local-first?
   Storage bucket, size caps, cost? Show in POS grid, receipt, both?
6. **New industries' defaults:** starter categories, units, and price-tier
   semantics for Phone & Gadgets and Frozen Foods & Grocery.
7. **Price tiers:** do non-beverage industries want Retailer/Wholesaler tiers, or
   a different tiering (or none)?
8. **Scanning:** barcode/IMEI scanning is currently deferred — in or out for the
   new industries?
9. **Rollout:** ship all nine at once, or feature-flag the newly enabled ones?

## 8. Delivery approach
Epic 0–1 (foundation + onboarding) first; Epic 2 (terminology) and Epic 3
(image) can run in parallel once the profile registry exists; Epic 4+ ships
**one industry per PR** so each is independently reviewable and grabbable. Each
resulting issue must be independently implementable per `/to-issues`.
