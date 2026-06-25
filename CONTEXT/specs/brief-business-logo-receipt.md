# Brief — Optional business logo upload + show on receipts

> Executor prompt. Read `context/architecture.md` (Invariants #1 local-first,
> #4 outbox, "Sanctioned direct-Supabase exceptions"), `context/code-standards.md`
> (Data & Storage, Styling), and `context/ui-context.md` (component library,
> `AppDrawer` 56×56 logo avatar pattern). **Split into the units below — do not
> land storage + UI + receipts in one step** (`ai-workflow-rules.md` "When to
> Split Work"). Update `context/progress-tracker.md` after each unit.

## Goal (one sentence)

A business can optionally upload a logo on **CEO Settings → Business Info**, and
that logo renders beside the business name at the top of receipts (in-app/shared
image receipts; thermal is a stretch goal).

## What already exists (do not rebuild)

- `businesses.logoUrl` column exists **locally** (`app_database.dart:37`,
  `TextColumn get logoUrl`) and **cloud** (`0001_initial.sql`), and is already on
  the businesses **push whitelist** (`supabase_sync_service.dart`, `'logo_url'`).
  So the field already syncs across devices — no migration needed for the column.
- Deps already in `pubspec.yaml`: `image_picker`, `image`, `path_provider`,
  `file_picker`.
- Receipts read the name via `currentBusinessNameProvider`; the full row is
  `currentBusinessProvider` (`app_providers.dart`, `BusinessData` with `logoUrl`).
- Receipt header renders the name in `lib/shared/widgets/receipt_widget.dart`
  (~line 164) and `ThermalReceiptService.buildReceipt`
  (`lib/features/pos/services/receipt_builder.dart`, ~line 80).

## Storage decision (resolve in progress-tracker before coding — recommend A)

The app is **offline-first**; a receipt must render with no network. `logoUrl`
implies a remote URL, but receipts can't depend on a live fetch.

- **Option A (recommended): cloud upload + local cache.** Upload the picked image
  to a Supabase **Storage** bucket (`business-logos/<businessId>.png`); store the
  resulting public URL in `businesses.logoUrl` (syncs via existing whitelist).
  Also save the resized bytes to the app documents dir keyed by businessId so
  receipts render the **local file** offline. On other devices, when `logoUrl` is
  present but no local cache exists, download once and cache. This gives
  cross-device logos AND offline receipts.
- **Option B (simplest): local-only.** Save the image to app docs dir; store the
  *local path* in `logoUrl`. No Storage, no cross-device logo (path is device
  specific) — the logo won't appear on other tills. Only choose if the requester
  accepts single-device logos.

Below assumes **Option A**. Flag the Supabase Storage upload as a **new
sanctioned direct-Supabase call** in `lib/core/services/` (it is not a tenant
row write, so it does not go through the outbox; document this exception in
`architecture.md` alongside `redeem_invite_code` and Sync Issues).

## Units

### Unit 1 — Logo storage service (`lib/core/services/`)
- [ ] New `BusinessLogoService` (constructor-injected `SupabaseClient`; exposed via
      a Riverpod provider). Methods:
  - `pickAndProcess()` → uses `image_picker` to pick from gallery/camera, then
    `image` package to decode, **resize** (e.g. max 512×512), and re-encode PNG.
    Return the processed bytes (`Uint8List`).
  - `save({required String businessId, required Uint8List bytes})` →
    (a) write bytes to `<appDocs>/business_logos/<businessId>.png` via
    `path_provider`; (b) upload to Storage bucket `business-logos`
    (`upsert: true`, content-type png); (c) return the public URL.
  - `localPathFor(businessId)` and `ensureCached({businessId, logoUrl})` →
    returns the local file path, downloading from `logoUrl` once if the cache is
    missing (uses the Storage client / http). Returns null if neither exists.
  - `clear(businessId)` → deletes local file + Storage object + is callable when
    the user removes the logo.
- [ ] All methods return `Result<T, AppError>` (no throwing across boundaries,
      code-standards "Error handling"). No widget imports in this file.
- [ ] **Supabase setup (operator step, document in progress-tracker):** create a
      public `business-logos` bucket with RLS allowing a member of the business to
      upload/replace `<businessId>.*` and public read. Provide the SQL/policy in
      the brief output for the operator (`supabase db push` is pre-authorized but
      bucket creation may need the dashboard).

### Unit 2 — Business Info screen upload UI
- [ ] In `lib/core/settings/business_info_screen.dart` add a logo section at the
      top of the form card: a 56×56 (or larger preview) rounded avatar
      (`AppRadius.md`, mirror the `AppDrawer` header logo avatar in ui-context),
      showing the current logo (from `ensureCached`) or a placeholder icon.
- [ ] Buttons: **Upload / Change logo** (calls `pickAndProcess` → `save`) and,
      when a logo exists, **Remove** (calls `clear` + nulls `logoUrl`). Use
      `AppButton` variants; feedback via `AppNotification` (no raw SnackBar).
- [ ] Persist `logoUrl` through `BusinessesDao.updateInfo` (extend it to accept an
      optional `logoUrl`; full-row enqueue so the synced column pushes — see memory
      note "businesses table sync path" re: explicit `lastUpdatedAt`). Re-check
      `settings.manage` at the write site (the screen already does this in `_save`).
- [ ] Keep all spacing/colour/radius token-based (code-standards "Styling").
      Gate the section on `settings.manage` like the rest of the screen.

### Unit 3 — Provider + receipt rendering (image receipt)
- [ ] Add `currentBusinessLogoPathProvider` (autoDispose) that watches
      `currentBusinessProvider`, calls `ensureCached`, and exposes the local file
      path (nullable). Place it next to `currentBusinessNameProvider`.
- [ ] Add a nullable `logoPath` (or `logoBytes`) param to `ReceiptWidget`
      (`receipt_widget.dart`); when present, render an `Image.file` logo **beside
      / above** the business name in the header (~line 164), sized via
      `context.getRSize`, with graceful fallback to name-only when null.
- [ ] Thread the new param at every `buildReceipt`/`ReceiptWidget` construction
      site (the call-site audit in `progress-tracker.md` lists them:
      `checkout_page.dart` ~1222/1420, `orders_screen.dart` ~1052/1192,
      `customer_detail_screen.dart`), passing the provider value next to the
      existing `businessName:`.

### Unit 4 (stretch) — Thermal receipt logo
- [ ] In `ThermalReceiptService.buildReceipt` add optional logo bytes; convert to
      a monochrome ESC/POS raster via the `image` package (threshold/dither) and
      emit before the business-name line. If the printer lib in use lacks raster
      support, **defer and log an open question** in progress-tracker rather than
      forcing it. Keep name-only behaviour when no logo.

### Tests
- [ ] `BusinessLogoService`: resize produces ≤512px PNG; `localPathFor` round-trips
      saved bytes; `ensureCached` returns null when neither local nor URL exists.
      (Mock Storage/file IO; no live network in tests.)
- [ ] `ReceiptWidget` renders logo when path provided and falls back cleanly when
      null (widget test).
- [ ] `BusinessesDao.updateInfo` persists `logoUrl` and enqueues a businesses push
      with `logo_url` in the payload.

### Docs
- [ ] `architecture.md`: document the new Supabase Storage sanctioned direct call
      + the `business-logos` bucket in the storage model.
- [ ] `project-overview.md`: add logo upload to the Business Info / receipts scope.
- [ ] `ui-context.md`: note the receipt logo placement + Business Info avatar.
- [ ] `progress-tracker.md` + dated `BUILD_LOG`.

## Acceptance criteria
- CEO can pick an image on Business Info, see the preview, save; the logo persists
  across app restart and appears on the next image/shared receipt beside the name.
- A second device in the same business pulls `logo_url`, caches it once, and shows
  the same logo on its receipts (Option A).
- Removing the logo clears it everywhere and receipts fall back to name-only.
- Receipts render the logo with **no network** once cached (offline-first).
- `flutter analyze` clean; `flutter test` green; `dart run build_runner build` run
  if `BusinessesDao.updateInfo` signature/model changes touch generated code.

## Out of scope
- Multiple logos / per-store logos (one logo per business).
- Logo on anything other than receipts (drawer already has its own avatar).
- The `logoUrl` column/migration (already exists and is whitelisted).
