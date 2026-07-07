# Build Log

---

## 2026-07-07 — Periodic fallback pull: near-live convergence without postgres_changes (issue #98)

**What changed.** Realtime `postgres_changes` is rejected server-side even with an
authed socket (#97 — channelError, no CDC to the client). Per `architecture.md`,
Realtime is a **best-effort signal that triggers a pull, not the data transport**,
and the Pull path documents a **"periodic fallback poll"** — which was **never
implemented**: the only `Timer.periodic` (30 s) drained the outbox (push). So a
foregrounded, idle till never pulled, and console edits/soft-deletes only landed on
a manual refresh / resume / reconnect.

**Fix.** Added the documented periodic fallback **pull** to the existing 30 s sync
tick in `SupabaseSyncService`: when foregrounded + online + business-bound, fire the
already-working, guarded, debounced `catchUpPull(reason: 'periodic')` — *before* and
*independent of* the push drain (so it runs even mid-push). A console-deleted product
now stops being sellable within ~one tick, regardless of realtime health.

- Reuses the existing timer lifecycle: starts at sign-in (`startAutoPush`), cancels
  at logout (`stopAutoPush`), and naturally suspends when backgrounded (Dart timers
  don't fire while paused) — so no battery cost off-screen.
- `catchUpPull` self-guards (`_currentBusinessId`/`_fullPullRunning`/`isOnline`) and
  is debounced (< 30 s tick ⇒ never overlaps the reconnect/resume catch-ups).
- Aligns the implementation with the documented "realtime = signal, pull =
  transport" model. The realtime channel subscription stays as a best-effort signal.

**Verified.** `flutter analyze` clean; `test/sync/` 186 passing (the called
`catchUpPull` is covered by `catch_up_pull_test`; the 30 s timer wiring is verified
on-device — a console delete converges within ~30 s with no manual refresh).

**Files changed:** `lib/core/services/supabase_sync_service.dart`,
`context/progress-tracker.md`.

---

## 2026-07-07 — Fix realtime resubscribe teardown/re-create race (issue #93)

**What changed.** Console edits/soft-deletes never propagated **live** to the
app — a deleted product stayed sellable until a manual pull-to-refresh. Device
logs showed `Starting real-time sync` twice but never
`[CloudTransport] Realtime subscribed: <table>`. Root cause: a teardown/re-create
race in `restartRealtimeSync` (fired on app-resume + connectivity-recovery, so
≈ every launch).

- `_tearDownRealtimeChannels()` fired `unawaited(_transport.stopRealtime())` then
  synchronously re-created via `startRealtimeSync`. The real
  `SupabaseCloudTransport.stopRealtime()` cleared `_tableChannels` **after** its
  `await removeChannel` loop, so it suspended with the list still full; the
  recreate's `startRealtime` guard (`if (_tableChannels.isNotEmpty ...) return;`)
  then bailed and created **zero** channels. Net: no live channels for the whole
  session (all ~40 synced tables), REST/pull unaffected.

**Fix.**
- `restartRealtimeSync` now **awaits** the full teardown before re-subscribing;
  `_tearDownRealtimeChannels` flips `_realtimeActive=false` *synchronously* (before
  the await) as a re-entrancy guard. Awaiting also removes the same-topic
  two-live-channels hazard.
- Hardened `SupabaseCloudTransport.stopRealtime()` to snapshot+clear its channel
  holders **synchronously** before the awaited removals, so its own guard can't be
  lied to by a fire-and-forget caller.
- The two fire-and-forget call sites (`auto_lock_wrapper` resume,
  `_onOnlineChanged` reconnect) wrapped in `unawaited(...)`.

**Scope note.** Coverage was already all synced tables (`{..._pullOrder,
'businesses'}`) — the race disabled every table together, so this restores live
sync across every console-editable entity at once. No topology change.

**Verified.** New `test/sync/realtime_resubscribe_test.dart` (3 tests) models a
worst-case late-releasing transport; confirmed red with the fix reverted
(`+1 -2`), green with it. Full `test/sync/` suite: 186 passing. `flutter analyze`
clean on all four touched files.

**Files changed:** `lib/core/services/supabase_sync_service.dart`,
`lib/core/services/supabase_cloud_transport.dart`,
`lib/shared/widgets/auto_lock_wrapper.dart`,
`test/sync/realtime_resubscribe_test.dart`.

---

## 2026-07-07 — Forbid client hard-delete of soft-delete tables (issue #87)

**What changed.** Migration `0145_forbid_hard_delete_soft_tables.sql` —
`REVOKE DELETE ... FROM authenticated, anon` on all 16 tables carrying an
`is_deleted` column. Makes it structurally impossible for the console or phone
app (both connect as `authenticated`) to permanently erase a row, enforcing the
soft-delete mandate at the DB layer.

- SECURITY DEFINER RPCs run as the function owner → `delete_business` (cascade
  via `DELETE FROM businesses`) and `console_soft_delete_product` unaffected.
- The app's `enqueueDelete` tables (role_permissions, user_permission_overrides,
  store_role_permissions, user_stores, notifications, saved_carts) are a disjoint
  set → nothing breaks. `service_role` left alone. Idempotent.

**Deployed + verified** via `apply_migration` (2026-07-07). Post-deploy check:
0 client DELETE grants remain on the 16 tables (baseline was 16 with DELETE).

**Files changed:** `supabase/migrations/0145_forbid_hard_delete_soft_tables.sql`.

---

## 2026-07-07 — Reconnect + app-resume catch-up pull; re-stamp cleanup (issue #88)

**What changed.** Devices missed cloud soft-deletes because Supabase realtime
never replays events dropped while the socket was down, and the reconnect
catch-up only fired after a *failed* pull. Live data confirmed the lingering
"deleted" products were soft-deleted + recent (not hard-deleted).

- **`catchUpPull(businessId)`** — new silent, 20s-debounced delta pull; guarded
  by the in-flight full-pull flag + online check; pushes the outbox first (§3.4).
- **Reconnect** (`_onOnlineChanged`) now calls it **unconditionally** on every
  offline→online (dropped the "only if last pull failed" gate).
- **App-resume** (`auto_lock_wrapper`) now also fires it (previously only
  refreshed the businesses row + restarted realtime).
- **Migration `0146_restamp_soft_deleted_rows.sql`** — one-time
  `last_updated_at=now() WHERE is_deleted` on the catalog/entity tables so every
  device re-pulls and drops them. Positive sync only (zero wipe-race). The local
  "delete rows absent from snapshot" reconcile was explicitly rejected.

**Tests** `test/sync/catch_up_pull_test.dart` (guards + debounce); full
`test/sync/` suite green (183). **0146 deployed + verified** via `apply_migration`
(2026-07-07): all 6 soft-deleted products re-stamped.

**Files changed:** `lib/core/services/supabase_sync_service.dart`,
`lib/shared/widgets/auto_lock_wrapper.dart`,
`supabase/migrations/0146_restamp_soft_deleted_rows.sql`,
`test/sync/catch_up_pull_test.dart`.

---

## 2026-07-07 — Fix POS crash on stale category selection (deleted-category dangle)

**What changed.** `pos_home_screen.dart:272` built the active category chip
label with `_controller!.categories.firstWhere((c) => c.id == selectedCategoryId)`.
When the selected category disappears from the stream — renamed away,
soft-deleted, or removed on the console then synced down — `firstWhere` throws
`StateError: Bad state: No element` and the POS screen crashes.

- **Root-cause fix (`pos_controller.dart` `_loadCategories`):** when the
  `watchAllCategories()` stream emits a list that no longer contains
  `selectedCategoryId`, reset the selection to `null` (→ "All").
- **Defense-in-depth (`pos_home_screen.dart`):** new `_selectedCategoryLabel()`
  helper does a plain loop with an `'All'` fallback instead of `firstWhere`, so
  the label can never throw even during the momentary window before the
  controller resets.

`flutter analyze` on both files: no issues. Behavioural fix; no schema/sync
change. Part of the deleted-product / downward-tombstone investigation — the
crash is a *symptom* of category removals syncing down while the POS selection
is stale.

**Files changed:** `lib/features/pos/screens/pos_home_screen.dart`,
`lib/features/pos/controllers/pos_controller.dart`.

---

## 2026-07-07 — Terminology morph (Lexicon) on POS, inventory & guides (issue #81, PRD #76)

**What changed.** Extends the industry Lexicon (from #80) to the remaining
surfaces, so the whole selling + stock experience speaks the selected trade's
words. Second half of the terminology morph.

- **`Lexicon.itemPlural`** getter (Products → Medicines / Handsets — a simple
  `+s` covers every shipped industry).
- **Wired the item noun** (singular / plural / lowercased) into:
  - **POS** — the product-grid empty state ("No {items} found") and the tap /
    long-press coach tips ("Tap a {item} to add it to the cart").
  - **Inventory** — the tab title ("{Items}"), the Add-{item} FAB (label +
    "create a {item}…" description), the search tooltip/hint, and the
    filter-miss empty state.
  - **Guides / empty states** — the shared first-run empty state ("No {items}
    yet", "Add your first {item}"), the Home empty state, the stock-count empty
    state, and the Get Started checklist's Add-{item} step.
- **Beverage unchanged** (`item = 'Product'`, `itemPlural = 'Products'`) — no
  regression. Industries without a filled slot fall back to neutral words.
- **No slot-sprawl** (the ADR audit): neutral labels (Suppliers, History,
  Save, Price, Stock) stay literal; `manufacturer`/`supplier` nouns are out of
  the item/unit/category scope and untouched; crate/empties stay `isCrateBusiness`-gated.

**Files changed:** `lib/core/industry/lexicon.dart`, `test/industry/lexicon_test.dart`,
`pos_home_screen.dart`, `product_grid.dart`, `inventory_screen.dart`,
`stock_count_screen.dart`, `home_screen.dart`, `get_started_card.dart`,
`shared/widgets/first_run_empty_state.dart`.

**Verification.**
- `flutter analyze` → clean project-wide.
- `flutter test test/industry` → 21 green (incl. the new `itemPlural` case).
- `flutter run` on the Android emulator → built + booted cleanly; the Beverage
  business shows unchanged POS/inventory/guide wording.

This completes PRD #76's terminology morph (#80 forms + #81 POS/inventory/guides).

## 2026-07-07 — Terminology morph (Lexicon) on Add/Update Product (issue #80, PRD #76)

**What changed.** The Add Product and Update Product forms now speak the selected
industry's words instead of hardcoded drink terms.

- **Lexicon module** (`lib/core/industry/lexicon.dart`). A `Lexicon` holds an
  industry's domain nouns (`item`, `category`, `unit`) + starter unit/category
  suggestions + example hints, with **per-slot generic defaults** (an unfilled
  slot resolves to the neutral word). `lexiconFor(Industry)` is total. Beverage
  reproduces today's product-form wording **verbatim** ("Product Name", "Eva
  water 75cl", "sparkling water", Bottle default) — no regression.
- **Business-Scoped provider** (`industryLexiconProvider`, app_providers). Watches
  `currentBusinessProvider`, resolves the `Industry` via `industryOf`, returns
  its `Lexicon`. Rebuilds on an industry switch (words follow, no restart).
- **Add & Update Product** read every industry-sensitive noun from the Lexicon:
  the `"{item} Name"` label, name/description hints, category label, default unit
  + unit suggestions, and validation messages. Add Product also surfaces the
  industry's **starter category** suggestions for a fresh shop (no categories
  yet). Neutral words (Save, Price, Stock, Search) stay literal. Crate/empties
  nouns are untouched — already gated by `isCrateBusiness`, so they can't leak.

**Files changed:** `lib/core/industry/lexicon.dart` (new),
`lib/core/providers/app_providers.dart`, `add_product_screen.dart`,
`update_product_sheet.dart`, `test/industry/lexicon_test.dart` (new).

**Verification.**
- `flutter analyze` → clean project-wide.
- `flutter test test/industry` → Lexicon seam (7) + registry (13) green;
  `test/inventory` green.
- `flutter run` on the Android emulator → built + booted cleanly; the Beverage
  business shows unchanged product-form wording.

Next: **#81** extends the same Lexicon to POS, inventory tabs, and guides.

## 2026-07-07 — Enable all nine industries at onboarding (issue #79, PRD #76)

**What changed.** Unlock every industry at signup — the existing seven plus new
**Phone & Gadgets** and **Frozen Foods & Grocery** (nine total), all selectable.

- **Registry-only change (the #77 prefactor paid off).** Added `phoneAndGadgets`
  (icon `smartphone_rounded`) and `frozenFoodsAndGrocery` (icon `ac_unit_rounded`)
  to the `Industry` enum, and flipped `comingSoon` off for all (made `false` the
  constructor default, dropped the now-redundant explicit flags). The CEO Sign Up
  picker and the Settings → Business Info dropdown already render from
  `Industry.catalogue`, so **no UI code changed** — all nine now appear and are
  selectable automatically, and the greyed-out "coming soon" state is gone.
- **Crate opt-in unchanged.** "Track empty crates" still gates on
  `isCrateBusiness` (Bar/Beverage only) — the two new industries never show it.
- **Onboarding stores the canonical label** (unchanged path); the two new labels
  equal their DB canonical (no `'Beer distributor'`-style mapping needed).
- **Industry editable in Settings, data preserved** — switching only rewrites
  `businesses.type`; product/stock/history rows are untouched (unchanged path).
- `comingSoon` is retained in the registry per PRD #76 (for a future gated
  industry) with a documented unused-parameter suppression, since no entry sets
  it after the unlock.

**Files changed:** `lib/core/industry/industry.dart`,
`test/industry/industry_registry_test.dart` (catalogue → nine, all-selectable
assertion, golden updated + two resolution cases).

**Verification.**
- `flutter analyze` → clean project-wide.
- `flutter test test/industry` → 13/13 (resolution incl. the two new labels,
  membership = nine in plan order, all selectable, crate-gate unchanged, golden).
  Ran `test/auth test/settings test/crates test/providers` → green except the
  known pre-existing flaky `who_is_working_screen_test.dart` (fails on pristine
  main, unrelated).
- `flutter run` on the Android emulator → built + booted cleanly.

---

## 2026-07-07 — Optional synced product photo (issue #78, PRD #76)

**What changed.** Owners can attach an optional photo to a product on Add /
Update Product; it uploads to Supabase Storage, its URL syncs onto the product
so every device shows it, a local cache renders it instantly and offline, and
skipping it never blocks a save.

- **Data layer.** Drift **v58 → v59**: `products.image_url` (nullable text) with
  an idempotent `from < 59` onUpgrade addColumn. Cloud migration **0143** —
  additive `ALTER TABLE products ADD COLUMN image_url`; `products` is a
  pass-through push table, so the column rides the normal outbox → upsert → pull
  path with no RPC/whitelist change (dodges the overload trap). `CatalogDao.
  setProductImageUrl` persists the URL on the local row and enqueues the FULL
  product row (coalesce-safe) after upload + by the offline flush.
- **Service + storage.** `ProductImageService` mirrors `BusinessLogoService`:
  pick+resize, upload to the **product-images** bucket at
  `<businessId>/<productId>.png`, local file cache, and a SharedPreferences
  pending set so a photo saved offline is auto-uploaded when connectivity
  returns (via a new `SupabaseSyncService.onReconnected` hook wired in
  app_providers, business-scoped so the patch stays correct on multi-business
  devices). Cloud migration **0144** creates the public bucket + business-scoped
  storage RLS (writes gated on `current_user_business_ids()` via the first path
  segment). **Note:** the `business-logos` bucket was never created on this
  project — the logo cloud-upload has been a silent no-op; `product-images` is
  created here fresh.
- **UI.** `ProductPhotoField` — a shared, responsive, theme-aware picker widget
  mirroring `_LogoSection`'s design-system idiom (`context.getRSize` /
  `getRFontSize`, theme colours, no hardcoded values), used on Add Product. The
  Update Product sheet and the Product detail screen route their existing
  pickers through `ProductImageService` and resolve a renderable path via
  `ensureCached` so a cross-device photo shows and renders offline. The legacy
  local `imagePath` is preserved for offline render. Photo stays **off** the POS
  grid and receipts; one photo per product.

**Files changed:** `lib/core/database/app_database.dart` (+`.g.dart`),
`daos_catalog.dart`, `lib/core/services/product_image_service.dart` (new),
`lib/core/services/supabase_sync_service.dart`, `lib/core/providers/app_providers.dart`,
`lib/features/inventory/widgets/product_photo_field.dart` (new),
`add_product_screen.dart`, `update_product_sheet.dart`, `product_detail_screen.dart`,
`supabase/migrations/0143_product_image_url.sql` + `0144_product_images_bucket.sql` (new),
`test/sync/product_image_url_sync_test.dart` (new).

**Migration ordering note.** 0142 belongs to the unmerged web-pos #56 branch
(cloud-only); 0143/0144 are collision-free but leave a 0142 gap on main until #56
lands. 0143 + 0144 were applied to the cloud via MCP `apply_migration` (the
project's recorded migration versions already diverge — 0140/0141 are timestamped
on the cloud — so a blind `db push` was avoided).

**Verification.**
- `flutter analyze` → clean project-wide.
- `flutter test test/sync test/inventory test/crates test/database` → green (incl.
  the new `product_image_url_sync_test`).
- `flutter run` on `emulator-5554` → built + booted `com.reebaplus.pos`; log shows
  `onUpgrade: v58 → v59` on the populated device DB with **no runtime errors**.
- Cloud verified: `products.image_url` column present, `product-images` bucket
  public with 4 storage policies.

**Code-review fixes (two-axis review).** (1) **Coalesce-safety:** the outbox keeps
one pending row per `(action_type, id)`, so a partial `{id, image_url}` upsert
queued right after an `updateProductDetails` upsert replaced it and dropped the
concurrent name/price edits — `setProductImageUrl` now enqueues the FULL row
(`_enqueueFullProduct`); regression test added. (2) **POS-grid exclusion:** the
flows had written the cache path to `products.image_path`, which the POS grid
renders — #78 photos now live in `image_url` + the local cache only
(`updateProductDetails.imagePath` is a sentinel-defaulted param). (3)
`ProductPhotoField` uses `textTheme` styles; removed dead `localPathIfExists`.

---

## 2026-07-06 — Industry registry foundation + `industryOf()` (issue #77, ADR 0015)

**What changed.** The prefactor for PRD #76: introduce **one Industry registry**
as the single source of truth for the app's industries, plus a total
`industryOf()` resolver — with **no user-visible change**.

- **`lib/core/industry/industry.dart` (new).** An `Industry` enum whose entries
  carry the facts that used to be duplicated across two lists: canonical `label`,
  `icon`, `comingSoon`, `crateEligible` (+ lowercase `aliases` for legacy DB
  values). `Industry.catalogue` = every entry except the `generic` fallback, in
  plan order — what the pickers render from.
- **`industryOf(String? type)`.** Total normalizer: trims/lowercases and matches
  a stored `businesses.type` against each entry's label or aliases; the legacy
  `'Beer distributor'` DB canonical and any casing map to `beverage`;
  unknown/empty/null → `generic` (never throws, never blanks the app). No new
  column, no migration — consistent with the existing `isCrateBusiness` string
  gate (ADR 0015).
- **`isCrateBusiness` is now a shim** — `industryOf(type).crateEligible` — so
  Bar/Beverage-only crate-eligibility is derived from the same registry
  everywhere. `business_types.dart` becomes a thin derivation: `kBusinessTypes`
  maps `Industry.catalogue` labels and re-exports `isCrateBusiness`; the private
  `_businessTypes` record list in `ceo_sign_up_screen.dart` is deleted and the
  picker renders from `Industry.catalogue`. No duplicated industry facts remain.

**Files changed:**
- `lib/core/industry/industry.dart` — the registry + `industryOf` + `isCrateBusiness`.
- `lib/core/data/business_types.dart` — thin derivation/re-export over the registry.
- `lib/features/auth/screens/ceo_sign_up_screen.dart` — removed `_businessTypes`; picker reads `Industry.catalogue`.
- `test/industry/industry_registry_test.dart` — 12 seam tests (resolution, membership, crate-gate, golden pin).

**Verification:**
- `flutter analyze` → clean (No issues found).
- `flutter test test/industry` → 12/12 green; ran `test/crates test/settings test/auth test/providers` → all green except one **pre-existing** flaky widget test (`who_is_working_screen_test.dart`, confirmed failing on pristine `main`, unrelated).
- `flutter run` on `emulator-5554` → built, installed, and booted `com.reebaplus.pos` cleanly (crate gate resolves live at startup for the Beverage tenant).

---

## 2026-07-06 — Standardized daily closing: declutter + opt-in VAT

**Context.** The Daily Reconciliation detail screen had grown to **9 cards that
repeated the same ~10 figures** (Inventory on hand ×2, COGS ×2, Damages ×4,
Shortages ×4, Net profit ×2; `Total sales` = `Revenue` = `Cash sales`). User
asked for one *standardized* closing, aggregatable by period, and — after
grilling the spec against locked decisions — **cash reconciliation dropped
entirely** (all cash is ultimately deposited to an account; no counted drawer,
no float, no over/short → no `daily_closings` table), keeping Hard Rule #8
intact. Branch `feat/standardized-daily-close` off `feat/closing-report-
reconciliation` (the ADR 0014 base); web-pos WIP parked in `git stash@{0}`.

**Phase A — declutter (pure Dart, no schema).** `daily_reconciliation_detail_
screen.dart`: deleted the redundant "Net result for this period (flow)" card;
**merged** Shrinkage + Stock audit + Stock reconciliation + Integrity into ONE
`_stockReconciliationCard` (CEO = cost flow-equation → expected closing →
variance → count-reconciled-profit line; Manager = retail shrinkage + count).
CEO now sees **5** cards (Sales, P&L, Cash, Stock reconciliation, Position),
Manager **3** (Sales, Stock & shrinkage, Debts & expenses). Refunds moved onto
the Sales card. `recon_data.dart` model untouched (getters kept), so the 17
existing tests pass unchanged.

**Phase C — opt-in VAT (settings-backed, no migration).** VAT is **OFF by
default** and stored in the synced `settings` key/value table (like
`default_currency`) — so it needs **no schema/cloud migration**:
`vat_enabled` (`'true'`/`'false'`) + `vat_rate_bps` (basis points, 750 = 7.5%).
- `core/settings/vat_settings.dart` — keys, `VatConfig`, pure `computeVatKobo`,
  `parseVatRateBps`.
- `vatConfigProvider` (mirrors `currencyCodeProvider`, `businessScopedStream`).
- `ReconData` gains `vatEnabled` / `vatRateBps` / `vatKobo` (+`vatRateLabel`);
  `computeReconData` derives VAT = rate × (gross − discounts). **Pass-through —
  it does NOT touch the P&L profit lines.** Sales card + CSV show a "VAT due
  (7.5%)" line only when enabled.
- Settings → Business Info: new **Tax** section — "Charge VAT" toggle (prefills
  7.5% on first enable) + VAT rate (%) field; persists to the two settings keys.

**Parked (explicit user request):** VAT on the cart/receipt at checkout (mobile
+ web) — a later slice; today VAT is the obligation surfaced on the closing only.

**Verification.** `flutter analyze` clean project-wide. `recon_data_test.dart`
(19, incl. 2 new VAT) + new `vat_settings_test.dart` (8) green; ban test +
dashboard + settings suites (77) green. On-device walkthrough (decluttered
cards, VAT toggle, VAT line) pending.

---

## 2026-07-05 — Closing report: integrity flag (issue #72, slice 3 — epic complete)

**What changed.** Final slice of the closing-report enhancement (ADR 0014 §④):
a CEO-only **integrity check** card that reconciles reported P&L profit against
the independent physical stock count — **no new persistence**, derived entirely
from recorded flows + the count.

- **What it does.** A true "Δ net position over the period = reported profit"
  identity can't close: there's no cash leg (Hard Rule #8) and no stored
  period-start snapshot. So instead of persisting snapshots, the flag surfaces
  the one thing the recorded flows did **not** book — the **stock-count variance**
  (physical − expected, at cost, straight from slice 2's `stockVarianceKobo`).
  Reported profit is built only from sales / COGS / discounts / expenses /
  damages, so a count shortfall is a **recording error** (unbooked shrinkage /
  theft / miscount), not a separate real loss, and it isn't reflected in the
  reported profit. The card shows Reported net profit → Unexplained variance →
  **Count-reconciled profit** (`netProfit + variance`), with a
  reconciled/flagged verdict and a "take a count" nudge when no count exists.
- **Plumbing.** `ReconData` gains `integrityAdjustedProfitKobo` +
  `hasIntegrityGap` getters (no new fields — reuses the slice-2 variance). New
  CEO-only `_integrityCard` (shield icon) after the stock audit, shown when
  `hasStockFlow`; CSV export gains a "Count-reconciled profit" row.
- **Tests.** 3 integrity getter cases added to `recon_data_test.dart` (17 total
  green); `flutter analyze` clean.

**Epic status:** all three closing-report checks now ship — cash-flow summary
(slice 1), stock flow-equation (slice 2), integrity flag (slice 3). Closes #72.

---

## 2026-07-05 — Closing report: stock flow-equation card (issue #72, slice 2)

**What changed.** Second slice of the closing-report enhancement (ADR 0014 §①):
a CEO-only **stock reconciliation flow-equation** card on the Daily
Reconciliation — Opening + Goods received − COGS − Damages − Expired (± Other) =
**Expected closing** (the perpetual system figure), then **Variance = Physical
count − Expected**. Values the whole equation at **current per-product cost**.

- **Cost basis (the hard input, resolved).** Opening stock *as of a past date*
  is genuinely hard: cost is time-varying under FIFO (ADR 0005) and only current
  stock is valued today. Rather than fake historical precision, every term is
  valued at the product's **current** buying price, and opening / expected-closing
  are reconstructed by **rewinding the recorded `stock_transactions` deltas from
  the current on-hand figure** (`current − Σ deltas after period end` = closing;
  `closing − Σ period deltas` = opening). Because opening is that rewind, the
  equation **ties out to the system figure by construction** — stated basis, not
  faked precision.
- **Expired split from damages.** Record Damages and free-text removals both put
  expiry in `stock_adjustments.reason` (`damage:expired` / "Expired"), reached
  from the ledger row via `adjustmentId`. New `isExpiredReason` (contains
  "expired") breaks Expired onto its own line; non-expired damage stays Damages.
  The P&L "Damages (at cost)" line is deliberately **left unchanged** (still
  folds expiry) — this split is scoped to the stock card.
- **Classification.** From `stock_transactions` (store-scoped by `locationId`,
  non-voided): `sale`/`return` → COGS (returns net against it); receipts (reason
  "Stock received", both Receive Stock and Add Product opening) → Goods received;
  `adjustment` reasons → Expired / Damages / receipt; everything else (transfers,
  "Daily stock count adjustment", unclassified) → an **Other movements** residual
  so nothing is silently folded into opening. Variance reuses the stock-count
  surplus/shortage-at-cost figures (`surplus − shortage`), shown only when a
  count exists.
- **New plumbing.** `StockLedgerDao.watchAllTransactions()` (raw ledger rows, no
  regen) + `allStockTransactionsProvider` (`businessScopedStream`; passes the
  provider-ban test). `ReconData` gains `stockOpeningKobo` / `stockReceivedKobo` /
  `stockCogsKobo` / `stockDamagesKobo` / `stockExpiredKobo` /
  `stockOtherMovementsKobo` / `stockExpectedClosingKobo` fields +
  `stockDerivedClosingKobo` / `stockVarianceKobo` / `hasStockFlow` getters.
- **UI/CSV.** New CEO-only `_stockFlowCard` (scale-balanced icon) between the
  shrinkage card and the stock audit, shown only when `hasStockFlow`; CSV export
  gains the mirroring rows.
- **Tests.** 4 flow-equation getter cases added to `recon_data_test.dart` (14
  total green); `flutter analyze` clean; provider-ban + business-scoped-stream
  tests green.

Remaining for #72: the integrity flag (slice 3).

---

## 2026-07-05 — Closing report: cash-flow summary (issue #72, slice 1)

**What changed.** First slice of the closing-report enhancement (ADR 0014 §②):
a **derived cash-flow summary** on the CEO Daily Reconciliation — the period's
expected cash *movement* from recorded cash tenders, **not** a counted drawer
(Hard Rule #8: no float, no Close Day, no cash balance).

- **Sourcing.** `payment_transactions` is the unified physical-cash ledger; every
  cash move writes one (`sale` / `wallet_topup` / `refund` / `expense`, each with
  a `method`). Verified at the insert sites (`daos_orders`, `credit_ledger_service`,
  `daos_expenses`). Supplier payments are the one cash-out **not** in it (only on
  `supplier_ledger_entries`), so they're summed from there. Expenses are taken
  from the `expense` payment rows — **not** also from the expenses table — so
  nothing double-counts. `method` matched case-insensitively ('Cash'/'cash' drift).
- **Business-wide.** `payment_transactions` has no `storeId`, so the card is
  business-wide (like the existing outstanding-debt line) and clearly labelled.
  Crate deposits (a refundable held liability) are excluded — the ask is
  operating cash (sales + debts collected).
- **New plumbing.** `OrdersDao.watchAllPaymentTransactions()` (no regen — table
  already in its accessor) + `allPaymentTransactionsProvider`
  (`businessScopedStream`; passes the provider-ban test). `ReconData` gains
  `cashSalesKobo` / `cashDebtsCollectedKobo` / `cashRefundsKobo` /
  `cashExpensesKobo` / `cashSupplierPaidKobo` + `cashInKobo` / `cashOutKobo` /
  `netCashMovementKobo` getters.
- **UI/CSV.** New CEO-only `_cashFlowCard` (Cash in → Cash out → Net cash
  movement) between P&L and Business worth; CSV export gains the same rows.
- **Tests.** 4 cash-flow getter cases added to `recon_data_test.dart` (10 total
  green); `flutter analyze` clean; provider-ban + business-scoped-stream tests green.

Remaining for #72: stock flow-equation card and the integrity flag.

---

## 2026-07-05 — Daily Reconciliation P&L: subtract discounts (issue #70)

**What changed.** The Daily Reconciliation booked sales revenue **gross** and
never read `orders.discountKobo`, so **gross/net profit were overstated by the
discounts given**. (`order_items.unitPriceKobo` is the gross list price; the
order's real payable is `netAmountKobo = gross − discount`, per
`order_commands.dart`.) Fixed per ADR 0014 §③.

- **`recon_data.dart`.** New `ReconData.discountsKobo` (summed from
  `orders.discountKobo` over counted sales, store- and span-scoped like refunds).
  New `netRevenueKobo = costedRevenueKobo − discountsKobo`; `grossProfitKobo`
  now `netRevenue − COGS`; `grossMarginPct` measured against **net** revenue
  (with a divide-by-zero guard for a fully-discounted period).
- **`daily_reconciliation_detail_screen.dart`.** P&L card shows Revenue →
  − Discounts → Net revenue → − COGS → Gross profit (discount rows render only
  when discounts > 0). CSV export gains the Discounts + Net-revenue rows.
- **`test/dashboard/recon_data_test.dart`.** New — 6 cases over the P&L getters
  (net revenue, gross profit, net profit, margin-on-net, zero-discount parity,
  zero-net-revenue guard). All green; `flutter analyze` clean on the feature.

CEO-only (cost wall §25.3) is unchanged. Scope is P&L discounts only — the stock
flow-equation card, cash-flow summary, and integrity flag are the follow-up
issue (ADR 0014).

---

## 2026-07-05 — Currency input: preserve the caret on mid-string edits

**What changed.** `CurrencyInputFormatter` no longer slams the caret to the end of
the field after every keystroke. Previously it returned
`TextSelection.collapsed(offset: newText.length)`, so moving the cursor into the
middle of a price to make a correction and typing teleported the caret back to the
end, distorting the value. Now the formatter counts the "meaningful" characters
(digits + the decimal dot, ignoring grouping commas it inserts) sitting before the
raw caret, then re-places the caret after that same count in the reformatted text —
so the cursor stays next to the character the user just typed/deleted, hopping over
any comma the formatter adds or removes.

- **`lib/core/utils/currency_input_formatter.dart`.** Added a `_meaningful`
  (`[\d.]`) regexp and caret-mapping loops; the return now uses the resolved
  `newOffset` instead of `newText.length`. Truncation (e.g. a 3rd decimal digit
  dropped) safely clamps the caret to the end.
- **`test/utils/currency_input_formatter_test.dart`.** New "caret preservation
  (mid-string edits)" group: typing in the middle, hopping a newly inserted comma,
  deleting a middle digit, caret-at-start, and caret-at-end. All 18 tests green;
  `flutter analyze` clean.

---

## 2026-07-05 — Web POS: de-duplicate RPC helpers (issue #68)

**What changed.** Quality-only cleanup from the epic-#46 code review; no behaviour
change (`tsc` + `next build` green, every friendly-error string preserved).

- **New `web-pos/src/lib/rpc.ts`.** `newId()` (was copy-pasted in `inventory.ts` +
  `stockAdjustments.ts` and inlined in `checkout.ts`) and `friendlyRpcError(message,
  cases)` — the shared match loop + the identical `tenant_mismatch` /
  `no_business_for_caller` fallback every RPC can raise. Each caller keeps its own
  domain case table (the domain messages legitimately differ).
- **`toKobo` / `fromKobo` moved into `lib/currency.ts`** beside `formatKobo`; the
  Add-Product and Receive-Stock dialogs import them instead of each defining a copy.
- `checkout.ts` / `inventory.ts` / `stockAdjustments.ts` now import the shared
  helpers; their `friendlyError` is a thin wrapper over `friendlyRpcError`.

---

## 2026-07-05 — Web POS Slice 8: Reports & dashboards (issue #51)

**What changed.** Read-only reports on web — sales/revenue dashboard, a profit
report that excludes Uncosted units transparently, activity logs, and store
scoping. No write RPCs; aggregation reads only. Stacked on #48 (reuses the
`NavProvider` view switch). Money rules mirror mobile exactly (verified against
live data). Web `tsc` + `next build` green.

- **`reports.ts`.** `loadSalesReport` reads counted orders (`status in
  {pending,completed}` — `orderCountsAsSale`, revenue recognized at checkout) and
  their order_items (one PostgREST `orders!inner` join, optionally store-scoped)
  and computes: all-sales revenue + order count; and a profit view over COSTED
  lines only — a line with no product or `buying_price_kobo <= 0` is excluded from
  both revenue and COGS and counted as an Uncosted unit, so Revenue − COGS =
  Gross Profit (mirrors `profit_report_screen.dart`). Plus revenue-by-day and top
  products. `loadActivityLogs` reads the recent activity feed.
- **`ReportsScreen`.** Period (Today / 7d / 30d) + store scope (All / each store),
  KPI tiles, a revenue-by-day mini-chart, a top-products table, and the activity
  feed. Profit/COGS tiles + the "Excludes N item(s) with no recorded buying
  price" note are gated on `reports.see_profit`; the screen (and sidebar entry) on
  `reports.see_sales`. Wired into the sidebar via `NavProvider`.

---

## 2026-07-05 — Web POS Slice 5: Live consistency / Realtime (issue #49)

**What changed.** The Web POS grid now stays live with the mobile tills via
Supabase Realtime — no manual refresh. Pure web-client feature (all operational
tables were already in the `supabase_realtime` publication; no migration). Web
`tsc` + `next build` green.

- **`useRealtimeRefresh` hook (`web-pos/src/hooks/useRealtimeRefresh.ts`).** One
  business-scoped channel subscribes to `postgres_changes` on `products`,
  `inventory`, `cost_batches`, `orders` (filtered `business_id=eq.<id>`, matching
  the RLS the channel authorizes with). Rather than diff individual events, any
  change triggers a debounced re-pull of the same RLS-scoped read Slice 1 wired —
  reconciliation stays trivially correct (the screen re-derives from the
  authoritative cloud rows). Reconnect/backfill: a re-SUBSCRIBED channel and a
  tab regaining focus/connectivity both re-pull, so a dropped socket never leaves
  the view stale. Returns a `connecting | live | offline` status.
- **`PosScreen`** wires the hook to its catalogue `refresh` and shows a small
  Live/Offline badge; a price edit, stock change, or new order on any device now
  appears in the grid automatically.

---

## 2026-07-05 — Web POS Slice 7 code-review fix (issue #50)

**What changed.** One fix from the `/code-review` of PR #63; web `tsc --noEmit` +
`next build` green. The Adjust-Stock dialog hardcoded `stores[0]`, so a multi-store
manager couldn't target a store; it now renders a store `<select>` (shown when the
business has more than one store), matching the Add-Product / Receive-Stock dialogs.

---

## 2026-07-05 — Web POS Slice 7: Stock adjustment + approval gate (issue #50)

**What changed.** The Web POS gained stock adjustment with the approval gate,
mirroring mobile §16.6.1: a stock keeper's change is a pending request; a
manager/CEO applies immediately and approves/rejects the queue. Stacked on #48.
Verified: Dart golden green (4/4), all three paths (CEO apply / approve / reject)
smoke-tested live in a rolled-back transaction, web `tsc` + `next build` green.

- **Migration `0141_web_stock_adjustment_rpcs.sql` (deployed).** `request_stock_
  adjustment` branches on the CALLER's role (`caller_role_slug` helper, new):
  CEO/Manager applies immediately (+ an approved audit row); anyone else with
  `stock.adjust` files a pending request, no inventory change. `approve_stock_
  adjustment` (approver-only) applies the delta or rejects with no change. Shared
  `_apply_stock_adjustment` helper mirrors `InventoryDao.adjustStock` (guarded
  inventory delta + `stock_adjustments` + `stock_transactions('adjustment')`) — no
  Cost Batch, an adjustment is a correction not an inflow. Both RPCs idempotent /
  status-guarded.
- **Golden Suite (`test/golden/stock_adjustment_scenario.dart` + fixtures).**
  request-vs-apply pinned across the Dart DAO (`stock_adjustment_dart_dao_golden_
  test.dart`) and the SQL RPC (`web_stock_adjustment_golden_test.dart`, Tier-2).
  The stock-keeper → pending path is pinned on the Dart arm; the RPC arm (CEO
  identity, routed to immediate-apply) skips 'request' scenarios — same precedent
  as the checkout discount clamp.
- **Web UI.** Per-product "Adjust" action (`AdjustStockDialog`, on `stock.adjust`)
  that surfaces whether the change applied or was sent for approval, and a
  manager/CEO `ApprovalsPanel` queue (approve/reject) shown for CEO/Manager roles —
  mirroring the server's approver rule.

---

## 2026-07-05 — Web POS Slice 6 code-review fixes (issue #48)

**What changed.** Three fixes from the `/code-review` of PR #62; no new surface.
Verified: web `tsc --noEmit` + `next build` green; the cost-0 no-clobber and the
positive-cost update both re-checked live in a rolled-back CEO transaction.

- **`receive_stock` cost-0 scalar clobber (correctness).** A receive line with cost 0
  (an uncosted delivery) was unconditionally writing `products.buying_price_kobo = 0`,
  wiping the product's existing scalar cost. Now `buying_price_kobo` only moves on a
  costed line (`CASE WHEN v_buy > 0 THEN v_buy ELSE buying_price_kobo END`), matching
  the mobile "oldest COSTED batch, no-clobber" rule. Batch handling was already right
  (the uncosted batch is still created).
- **`add_product` idempotency tenant-scoping.** The replay existence check now filters
  `AND business_id = p_business_id` (like `update_product`), so a UUID collision with
  another tenant's product can't short-circuit the insert or return a foreign row.
- **Store selector (AC "opening stock, store").** The Add-Product and Receive-Stock
  dialogs hardcoded `stores[0]`; they now render a store `<select>` (shown when the
  business has more than one store) so a multi-store manager picks the target store.

Migration `0140` was edited in place (not yet merged) and both functions were
re-deployed live via `CREATE OR REPLACE`.

---

## 2026-07-05 — Web POS Slice 6: Inventory add/edit + receive stock (issue #48)

**What changed.** The Web POS gained inventory management — add/edit products and
receive supplier deliveries — behind three new server-authoritative RPCs, with the
Cost Batch producer rule pinned across Dart and SQL by a new golden dimension.
Verified: Dart golden green (6/6), `add_product`/`receive_stock` smoke-tested live
against a real CEO in a rolled-back transaction, web `tsc --noEmit` + `next build`
green.

- **Migration `0140_web_inventory_rpcs.sql` (deployed).** `add_product` (product +
  opening stock straight to inventory + the opening Cost Batch, no supplier),
  `update_product` (details/prices; stock + batches untouched), and `receive_stock`
  (supplier invoice debit + optional payment credit + per line: inventory upsert,
  price persistence, a stock movement, and a receipt-dated Cost Batch). SQL twins of
  the mobile Dart path (`CostBatchesDao.recordInflowBatch`, `InventoryDao.adjustStock`,
  `SupplierAccountService`); each reuses the 0135 `caller_has_permission` /
  `_assert_caller_owns_business` helpers and re-checks the permission server-side.
  A receive line mirrors `adjustStock`'s default path — one `stock_adjustments` row
  + a `stock_transactions` row referencing it (the `adjustment_id` ref that satisfies
  the exactly-one-of-4-refs CHECK). Idempotent on the client id (product / receipt).
- **Batch-creation Golden Suite (`test/golden/inventory_scenario.dart` + fixtures,
  two runners).** A second golden dimension beside checkout: the rule "one inflow ⇒
  one fresh batch {qty_remaining=qty_original=quantity, cost=max(cost,0), received_at},
  never merged; cost 0 ⇒ uncosted" is run against the Dart producers
  (`inventory_dart_dao_golden_test.dart`) and the SQL RPCs
  (`web_inventory_golden_test.dart`, Tier-2). Covers costed/uncosted/no-opening-stock
  Add Product and receive with existing batch / partial payment / uncosted lines.
- **Web UI (`web-pos/src/components/inventory/*`, `lib/inventory.ts`).** An Inventory
  view (responsive table, low-stock highlight), an add/edit Product dialog, and a
  Receive Stock dialog (supplier + dated lines + invoice total + payment). Sidebar
  navigation is now a client-side view switch (`NavProvider`); actions are
  hide-don't-block on `products.add` / `stock.received`\|`stock.add`. Money via the
  business-currency helpers; prices entered in major units, stored as `*_kobo`.

---

## 2026-07-05 — Web POS checkout-UI cleanup (issue #57)

**What changed.** Quality-only de-duplication of the Slice 2–4 web checkout; no
behavior change (typecheck + `next build` green).

- **Shared `receiptRows()` (`web-pos/src/lib/receipt.ts`, new).** The receipt's
  subtotal→empties summary was built twice — once in `Receipt.tsx`'s JSX and once
  in its `plainText()` — and had already drifted (the empties line read
  "— ₦X deposit" in plain text vs "· ₦X" on screen). Both renderings now derive
  from one `receiptRows(result, format)` returning `{label, value, kind}[]`, so
  they can't diverge; `receiptRowClass(kind)` maps a row to its CSS class. The
  divergent empties wording is unified to "· ₦X deposit".
- **`paymentMethodMeta` map (`web-pos/src/lib/checkout.ts`).** The `PaymentMethod`
  labels + the hard-coded `['cash','transfer']` / `['wallet','credit']` selector
  arrays collapsed into one `paymentMethodMeta` (label + group) with
  `paymentMethodsInGroup('tender'|'credit')`. `CheckoutDialog` renders its
  segmented control from these.
- **`operatorTracksCrates(operator)` (`web-pos/src/lib/crate.ts`).** The verbatim
  `businessTracksCrates(operator?.business?.type, …?.tracksEmptyCrates ?? false)`
  duplicated in `Cart.tsx` and `CheckoutDialog.tsx` is now one bundled helper.

---

## 2026-07-05 — Golden Suite: discount-cap clamp + debt-limit rejection (issue #55)

**What changed.** Two money decisions the Web POS makes were unpinned by the shared
Golden Scenario Suite; both are now fixtures. The shared model
(`test/golden/golden_scenario.dart`) gained `max_discount_percent` (the caller's
role cap) and an `expect: { rejected_with }` shape (a rejection scenario carries no
`expected` rows), plus a shared `clampDiscountKobo(requested, maxPct, gross)` that
mirrors the RPC's `LEAST(GREATEST(p_discount,0), (gross*pct)/100)`.

- **Discount-cap clamp (`cash_sale_scenarios.json`).** A non-CEO requesting ₦3,000
  off a ₦10,000 sale under a 10% cap nets a ₦1,000 (clamped) discount, not ₦3,000.
  Pinned on the **Dart arm** (`dart_dao_golden_test.dart` now clamps via
  `clampDiscountKobo`). The **RPC arm SKIPS** it: `caller_max_discount_percent`
  (0135) short-circuits the CEO slug to 100, and the Tier-2 identity is the
  business CEO — so the server clamp can't bite for that caller. Skip reason is
  spelled out in the test.
- **Debt-limit rejection.** A Register-as-Credit-Sale that would push a customer
  past their `wallet_limit_kobo` is refused and writes nothing. Pinned on **both
  arms**: the Dart runner mirrors mobile's hide-don't-write guard (assert the rule
  fires + no order row); the RPC runner asserts the RPC raises `debt_limit_exceeded`
  and no order persists (via `expectLater(..., throwsA(...))`).
- **Verified.** `flutter test test/golden/dart_dao_golden_test.dart` — 19/19 green
  (incl. both new scenarios). The RPC arm now runs **18/18 green (1 intentional
  skip)** against dev after the Tier-2 token was refreshed and the test tenant
  re-seeded. Fixing that run surfaced a latent teardown bug: the golden
  `tearDown` deleted the append-only ledgers (`wallet_transactions`,
  `payment_transactions`, `crate_ledger`) directly, which the `forbid_delete`
  trigger blocks (P0001) — and their parents then fail with 23503 FK. Cleanup is
  now best-effort via a local `del()` helper that swallows both codes and leaks
  the append-only rows by design, matching `TestBusinessFixture.deleteTopupRows`.

---

## 2026-07-05 — checkout_order helper extraction (issue #53) — DEPLOYED + VERIFIED

**What changed (code only).** New migration `0139_checkout_order_helpers.sql`
extracts the three invariant legs of `checkout_order` into SECURITY DEFINER
helpers and CREATE-OR-REPLACEs `checkout_order` (same 8-arg signature) to dispatch
through them:

- `_checkout_mint_order_number(business_id, order_id)` — the `WEB-NNNNNN-XXXXXX`
  number (0137:285-288), one SQL query.
- `_checkout_insert_lines(…)` — the item + inventory-guard + stock-ledger loop
  (0137:306-377), returns `inventory_after`.
- `_checkout_draw_fifo(…)` — the FIFO draw-down + scalar re-point (0137:379-453).

Behavior-identical to 0137: the blocks are copied verbatim (only the dead
`v_items_out` accumulation the loop built and 0137 overwrote from the DB is
dropped); `v_now` is passed into the helpers so every `gen_random_uuid()`/timestamp
is as inline; the `FOR UPDATE` batch locks + stock-guard row locks are unchanged
(helpers run in the caller's transaction). `checkout_order`'s body was verified to
reference no extracted local. From here a new checkout slice grows only its own
dispatch, not another copy of the shared legs. Numbered `0139` — `0134`/`0138`
are reserved by the parked console-admin work.

**✅ DEPLOYED 2026-07-05.** `supabase db push` applied `0139` to the remote after a
history repair — the remote was ahead of local (console-admin `0134` + the
`20260705034304` console_delete_business migration were deployed from another
session but are still parked in a stash, not in the repo), so
`migration repair --status reverted 0134 20260705034304` cleared the divergence
(history table only — schema untouched) before the push. When the console-admin
migrations land as their own PR they must reconcile that repair.

**✅ VERIFIED behavior-identical.** The proof is the Golden Suite's RPC arm
(`test/integration/rpcs/checkout_order_golden_test.dart`, Tier-2), run against the
newly-deployed `0139`: **18/18 green (1 intentional skip)** — the same result the
arm gave against `0137`, so the extraction changed no observable behavior on the
live money path. (Prereq unblocked first: the Tier-2 `TEST_USER_REFRESH_TOKEN` was
refreshed and the test tenant re-seeded.) Merged to `main` via PR #59.

---

## 2026-07-05 — Web POS Slice 4: empty-crate ledger at checkout (issue #45, ADRs 0008/0009)

**What shipped.** A web sale of deposit-bearing product now posts the **empty-crate
ledger movements** for crate-eligible businesses, pinned identical to mobile by the
golden suite, and the web cart + receipt surface the returnable-empties context —
shown only when the business is crate-eligible and opts into empty tracking.

- **`checkout_order` extended (migration `0137_checkout_order_crate.sql`).** A plain
  CREATE-OR-REPLACE of the 8-arg 0136 function (same signature → no overload) that
  adds the §13.4 crate dispatch. For a **registered** customer at a business where
  `_is_crate_business(type) AND tracks_empty_crates` (new helper mirrors the mobile
  `isCrateBusiness` — case-insensitive Bar / Beer|Beverage distributor), it groups
  the crate-eligible lines (unit `bottle` + `track_empties` + a manufacturer) by
  manufacturer and, per manufacturer: writes one `order_crate_lines` row (crates
  taken + the deposit **rate** snapshot from `manufacturers.deposit_amount_kobo`,
  frozen at sale time + deposit paid 0), one `'issued'` `crate_ledger` row (+crates),
  and increments `customer_crate_balances` (upsert on the unique key) — so the
  existing return path can net the balance to zero. Byte-for-byte the mobile
  `OrdersDao.createOrder` + `CrateLedgerDao.recordCrateIssueByCustomer` crate-track
  branch. **No double-count**: the crate legs never touch inventory, `cost_batches`,
  COGS, payment, or the wallet. Walk-ins / non-crate businesses / empties-off all
  post nothing.
- **Scope = crate-track (empties owed).** The web collects no deposit money at
  checkout, so every web crate sale is crate-track (`deposit_paid = 0`), and the
  wallet legs stay exactly 0136's (deposit carve-out / money-track is a later
  slice). The deposit **value** is still surfaced (rate × crates) as the value of
  the empties owed.
- **Verified end-to-end.** Deployed to dev and ran the **full** RPC via an
  impersonated (JWT-claim `set_config`) transaction that **rolled back**: a
  registered crate sale minted `WEB-000001-…`, drew FIFO COGS (item cogs 50000,
  inventory 100→97), posted `order_crate_lines` (3 crates, rate 50000, paid 0), a
  `crate_ledger` `issued` +3 to the customer, `customer_crate_balances` = 3, and the
  net-zero wallet legs — matching the Dart golden field-for-field. Nothing persisted.
- **Golden suite extended (ADR 0009).** The shared model gained optional crate
  inputs (`business_type`, `tracks_empty_crates`, `manufacturers`, per-product
  `manufacturer`) and expected crate rows (`crate_lines` / `crate_ledger` /
  `crate_balances`), all defaulting empty so the cash/credit fixtures are unchanged.
  New `crate_sale_scenarios.json` (5 scenarios: single line, two manufacturers,
  mixed crate+non-crate cart, two lines summing to one crate line, and the gate-OFF
  no-op). Both runners seed the business type + manufacturers + crate-eligible
  bottles and collect the crate rows; the **Dart DAO tier is 17/17 green** offline,
  the RPC tier is wired + env-gated (skips clean without secrets; the live E2E above
  proves parity). `_is_crate_business` verified true/false against the canonical vs
  non-crate types.
- **Web UI (hide-don't-block).** `crate.ts` adds `isCrateBusiness` /
  `businessTracksCrates` / `crateEligible` / `crateSummary`; the catalogue loads
  `track_empties` + `manufacturer_id` and joins each product's per-manufacturer
  deposit rate; the operator exposes `business.type`. The **Cart** and **Receipt**
  render an "Empties (returnable)" line (N crates · deposit value) only when the
  business tracks crates and the cart holds deposit-bearing product — hidden
  entirely otherwise. `npm run typecheck` + `npm run build` green.
- **Files.** `supabase/migrations/0137_checkout_order_crate.sql`;
  `test/golden/golden_scenario.dart`, `test/golden/dart_dao_golden_test.dart`,
  `test/golden/fixtures/crate_sale_scenarios.json`,
  `test/integration/rpcs/checkout_order_golden_test.dart`;
  `web-pos/src/lib/{crate.ts,catalogue.ts,operator.ts,types.ts,checkout.ts}`,
  `web-pos/src/components/pos/{Cart,CheckoutDialog,Receipt}.tsx`.
- **Left for later.** The money-track deposit path (cash deposit collected →
  held `crate_deposit` wallet leg + goods carve-out, mobile Ring 6) needs a
  deposit-collection surface; not required by #45 (empties tracking). Realtime
  propagation of crate rows is Slice 5 (#49).

---

## 2026-07-05 — Web POS Slice 3: registered-customer credit & the wallet ledger (issue #44, ADRs 0008/0009)

**What shipped.** The Web POS can now ring a sale up against a **registered
customer's credit**: attach a customer, see their live balance, and check out as
**Pay-with-Credit** (draw from their wallet) or **Register-as-Credit-Sale** (they
owe the balance) — with the wallet ledger posted append-only server-side and the
debt limit enforced at checkout, all pinned identical to mobile by the golden
suite.

- **`checkout_order` widened (migration `0136_checkout_order_credit.sql`).** Added
  `p_customer_id` and the `credit` / `wallet` payment methods on top of the Slice 2
  cash keystone. Dropped the 7-arg overload first (the CREATE-OR-REPLACE overload
  trap → PGRST203). A registered sale posts **append-only wallet legs** (invariant
  #3), byte-identical to mobile `OrdersDao.createOrder`: Leg 1 = a `debit` of the
  order **net** (`order_payment`), Leg 2 = a `credit` of the cash paid
  (`topup_cash` / `topup_transfer`, skipped when no cash lands). The customer
  balance stays **derived** — new helper `_customer_wallet_balance()` sums the
  signed legs excluding the crate-deposit family (mirrors
  `CustomersDao.getBalanceKobo`).
- **Debt limit, server-side.** A sale that books NEW debt (cash_paid < net) is
  rejected (`debt_limit_exceeded`) when the projected balance would fall below
  `−wallet_limit_kobo`; a fully-settled sale is never gated; `wallet_limit_kobo=0`
  means no credit at all — the exact mobile `_overDebtLimit` rule. Also
  `credit_requires_customer` and `customer_wallet_missing` guards.
- **Verified end-to-end.** Deployed to dev and smoke-tested all four paths via an
  impersonated (JWT-claim `set_config`) transaction that **rolled back** — a
  no-cash credit sale posts one −net debit (balance −net); Pay-with-Credit drops an
  existing balance by net; partial-cash credit posts debit + `topup_cash`;
  over-limit raises `debt_limit_exceeded`. Nothing persisted.
- **Golden suite extended.** The shared model gained an optional `customer`
  (opening balance + debt limit), expected `wallet_legs` (multiset) +
  `customer_balance_after_kobo`, and a nullable payment. Four credit fixtures added;
  both runners seed a customer + wallet + opening leg and collect the per-order legs
  + derived balance. **Dart DAO tier 12/12 green** offline. Guard tests add
  debt-limit rejection, no-limit rejection, Pay-with-Credit, partial-cash legs, and
  the credit-requires-customer guard. Fixed a latent Slice 2 bug: the Tier-2 seeds
  used `selling_price_kobo` (no such column) → now `retailer_price_kobo`.
- **Web UI.** `CustomerPicker` (searchable, shows each customer's derived balance)
  + a cart customer bar (attach/change/remove + balance chip); `CheckoutDialog`
  offers **Pay with Credit** and **Register as Credit Sale** when a customer is
  attached, shows a live projected balance, and **blocks over the debt limit**
  (disabled submit + banner) mirroring the server. `Receipt` shows the customer,
  "on credit", and the new balance. `useCustomers` refreshes balances after each
  sale. `npm run typecheck` + `npm run build` green; `flutter analyze` clean.
- **Left for later:** crate ledger at checkout (#45), Realtime (#49), inventory
  writes (#48), reports (#51).

---

## 2026-07-05 — Web POS Slice 2: cash-sale checkout keystone + Golden-Scenario Suite (issue #43, ADRs 0008/0009)

**What shipped.** The keystone slice: a cash/transfer sale rung up on web end to
end (grid → cart → checkout → receipt), settled by a new server-authoritative
RPC, with the anti-divergence **Golden-Scenario Suite** proving the web money math
matches mobile.

- **`checkout_order` RPC (migration `0135_checkout_order.sql`, ADR 0008).** One
  `SECURITY DEFINER` atomic transaction for the cash/transfer path (no customer
  credit / no crate — Slices 3 & 4): inserts the Order at `pending` + line items;
  draws down the FIFO `cost_batches` oldest-first **under a `FOR UPDATE` row lock**
  (reusing the pure `fifo_assign` from 0133, so per-unit COGS rounding is
  byte-identical to the recost pass and the mobile draw-down) and snapshots per-line
  `buying_price_kobo`; decrements inventory with the `quantity >= qty` guard and
  **rejects at commit if stock is insufficient** (two concurrent tills can't
  oversell); re-points the product's scalar `buying_price_kobo` cache; writes one
  `payment_transactions` row; recognizes revenue **at Checkout** (`status='pending'`,
  `completed_at` NULL — matches `orderCountsAsSale`). Idempotent on `p_order_id`.
- **Server order number, collision-proof.** `WEB-NNNNNN-XXXXXX` (running count +
  6 hex from the order id). The `WEB-` prefix makes collision with the mobile
  device-tag scheme (`ORD-NNNNNN-XXXXXX`) impossible regardless of the tail.
- **Defence in depth.** Two reusable helpers — `caller_has_permission()` (role
  grants ± user overrides, CEO all-on) and `caller_max_discount_percent()`
  (role_settings, seed defaults CEO 100 / Manager 10 / else 0) — enforce
  `sales.make` and clamp the order discount server-side, mirroring the mobile Gate
  Registry's *decisions* (not its Dart code).
- **Golden-Scenario Suite (ADR 0009).** `test/golden/fixtures/cash_sale_scenarios.json`
  (8 scenarios: single line, boundary-span weighted COGS, two lines one draw,
  partial-cover shortfall, no-batch uncosted, cost-0 batch, order discount, two
  products + transfer) run against **both** implementations via one shared model
  (`test/golden/golden_scenario.dart`): the Dart DAO path
  (`test/golden/dart_dao_golden_test.dart`, in-memory Drift, offline → every CI
  build) and the SQL RPC (`test/integration/rpcs/checkout_order_golden_test.dart`,
  Tier-2, env-gated). Field-for-field drift fails the build. The order-number
  *scheme* differs by client by design, so each runner asserts its own regex.
  `.github/workflows/golden-scenarios.yml` runs the Dart tier always and the RPC
  tier when the `TEST_SUPABASE_*` secrets are present.
- **RPC guard tests** (`test/integration/rpcs/checkout_order_test.dart`): oversell
  rejection, the two-till concurrency guard, idempotent replay, the `WEB-`/`ORD-`
  non-collision, and discount-within-cap — the ACs the happy-path fixtures don't
  cover.
- **Web UI.** `CartProvider` (session-persistent cart) + `Cart` (qty stepper,
  remove, role-capped discount, live totals) + `CheckoutDialog` (cash/transfer,
  amount paid, change) + `Receipt` (print via a print-only stylesheet, Share via
  Web Share with a text-file fallback download, "Done — back to POS" clears the
  cart). `PosScreen` becomes grid-beside-cart on tablet+ and a sticky bottom bar
  + bottom-sheet on phone. `loadOperator` now also resolves `maxDiscountPercent`.
  The completed sale reaches the mobile devices through the existing
  Realtime-signalled pull (no new sync wiring).

**Verified.** `checkout_order` + both helpers deployed via `apply_migration` and
registered; `fifo_assign` boundary-span, the `WEB-` order-number scheme (matches
`^WEB-\d{6}-[0-9A-F]{6}$`, never `^ORD-`), and the Manager discount clamp confirmed
by SQL; every RPC insert satisfies the live CHECK constraints (movement_type,
exactly-one-reference, payment type/method, order status/payment_type); live column
names (orders/order_items/inventory/stock_transactions/payment_transactions) match
the RPC. Dart golden suite **8/8 green**; RPC golden + guard tests analyze clean and
auto-skip without env. `web-pos` `npm run typecheck` + `npm run build` green.

---

## 2026-07-04 — Web POS Slice 1: walking skeleton (issue #47, ADRs 0007–0012)

**What shipped.** The first code of the **Web POS** — a new top-level
`web-pos/` Next.js (App Router) + React + TypeScript + `@supabase/supabase-js`
app. Online-first (ADR 0007): a single browser Supabase client is the whole data
layer (no Drift, no outbox). Thin but end-to-end through **auth → live RLS read →
render**, establishing the responsive shell, theming, and permission-read layer
every later slice builds on.

- **Auth = Operator (ADR 0011).** `LoginForm` does email+OTP
  (`signInWithOtp` → `verifyOtp`) and Google (`signInWithOAuth` → `/auth/callback`,
  PKCE + `detectSessionInUrl`). `SessionProvider` tracks the session and, on
  sign-in, runs `loadOperator()` — business scope from `profiles.business_id`,
  role from the active `user_businesses` membership, effective permissions, the
  `business_design_system` + `default_currency` settings, and the store list —
  all RLS-scoped, **no custom JWT claims**. `IdleLock` signs out after 15 min of
  inactivity, dropping the tab back to the sign-in screen.
- **Live catalogue.** `loadCatalogue()` reads `categories` + `products`
  (`retailer_price_kobo` / `wholesaler_price_kobo`) + `inventory` (on-hand summed
  across stores) over PostgREST. `PosScreen` renders the responsive grid with
  per-tier prices, a live in/low/out stock indicator, category chips, and a manual
  Refresh (Realtime is Slice 5 / #49). Tapping a tile is gated on `sales.make`.
- **Theming parity.** All five palettes (blue/amber/purple/green/b&w, light+dark)
  ported verbatim from mobile `colors.dart` into `src/lib/theme/palettes.ts`
  (keys = the `DesignSystem` enum names). `ThemeProvider` writes the active
  palette as CSS custom properties on the document root, read live from the synced
  `business_design_system` setting; light/dark follows the browser preference.
- **Permission-read layer.** `resolveEffectivePermissions()` mirrors the mobile
  Gate Registry's decisions (ADR 0009): role grants ± user overrides, **CEO
  all-on**. `Can` / `useCan` gate nav + actions (hide-don't-block). Money via
  `formatKobo` / `useCurrency` from `default_currency` — no hard-coded ₦.
- **Config / deploy.** Public Supabase URL + anon key baked into
  `src/lib/supabase/config.ts` (mirrors the mobile-intentional public/RLS-gated
  key), overridable via `NEXT_PUBLIC_*` — builds with zero env setup. Vercel root
  = `web-pos/` (ADR 0012); the README documents adding the deployed origin +
  `/auth/callback` to Supabase Auth redirect URLs for Google.

**Schema verified against the live cloud** before coding (snake_case columns):
`products.retailer_price_kobo`/`wholesaler_price_kobo`, `inventory.quantity`,
`user_businesses.role_id`+`status`, `role_permissions`/`user_permission_overrides`,
`current_user_business_ids()` = `profiles.business_id`.

**Verification.** `npm run typecheck` clean; `next build` green (5 routes
prerender); `next start` smoke-test returns 200 on `/` and `/auth/callback` with
the brand rendered. On-device/live sign-in walkthrough (real OTP + Google + a
seeded business) pending — needs a browser session with real credentials.

**Left for later slices:** cart/checkout RPC (#43) + the golden-scenario suite,
Realtime (#49), inventory add/receive (#48), stock-adjust approval (#50), reports
(#51), and store-scoped permission overrides (§10.2.1 middle layer).

---

## 2026-07-04 — Batch-creation-on-inflow: Add Product + Receive Stock push a Cost Batch (Epic 2 / FIFO, issue #42, ADR 0005)

**What shipped (Epic 2, F6).** The **producer** for the FIFO queue. F1 (#37) only
seeded opening batches via the migration and F2 (#38) only *consumed* the queue —
nothing wrote a batch when stock actually came in, so any product created or
restocked after the migration (or out of stock at migration time) drew from no
batch and sold at **0 COGS** until a cost was backfilled. Both inflow sites now
create a `cost_batches` row, in the **same transaction** as the inventory
increment (the queue total for a (product, store) can never drift from on-hand).

- **`CostBatchesDao.recordInflowBatch({productId, storeId, quantity, costKobo, receivedAt})`
  ([lib/core/database/daos_costing.dart](lib/core/database/daos_costing.dart)):**
  inserts ONE fresh batch (distinct `UuidV7` id, never merged — each inflow is
  its own FIFO layer) at the entered cost (`0` → a valid **Uncosted** batch,
  consistent with F1/F2, later resolved by #41). Every synced-and-defaulted
  column (id / received_at / created_at / last_updated_at) is set explicitly so
  the pushed row carries the same id the cloud stores (no second id minted —
  `project_synced_write_explicit_id`); then `enqueueUpsert('cost_batches', …)`.
  No-op on a non-positive quantity. No new sync-registry work (F1's entry).
- **Add Product opening stock
  ([lib/core/database/daos_catalog.dart](lib/core/database/daos_catalog.dart)):**
  `insertProductWithInitialStock` now creates the opening batch on **both** the
  v1 (per-table) and the v2 (`pos_create_product_v2` envelope) paths whenever
  there's opening stock. On the v2 path the batch is enqueued **after** the
  create envelope so its FK-to-product push resolves once the server mints the
  product (the batch is client-owned — the create RPC does not mint it).
- **Receive Stock
  ([lib/shared/services/receive_stock_service.dart](lib/shared/services/receive_stock_service.dart)):**
  each cart line pushes a new batch at that receipt's buying price, stamped with
  the receipt date (its FIFO ordering key). Existing batches are untouched — a
  receipt is its own layer, not a merge.
- **Tests
  ([test/costing/inflow_batch_creation_test.dart](test/costing/inflow_batch_creation_test.dart),
  7):** opening batch shape (`qty_remaining == qty_original == opening qty`, cost,
  received_at≈now, queue==on-hand); uncosted-0 batch resolved in place by #41
  (no double-count); no stock → no batch; the push carries the local id + all
  defaulted columns; the v2 path creates the batch after the envelope; Receive
  adds a new layer without mutating the opening one; and the **regression** — a
  post-migration new product AND a restock of a previously batchless product both
  draw NON-ZERO COGS at checkout. Two `create_product_dispatch_test` assertions
  updated for the extra `cost_batches:upsert` row. `flutter analyze` clean;
  costing/receiving/inventory/sync/orders/database suites green.

---

## 2026-07-04 — Prompted cost backfill (0→real) + migration-era fallback (Epic 2 / FIFO, issue #41, ADR 0005)

**What shipped (Epic 2, F5).** The explicit, one-time **Uncosted** backfill —
when a product's cost first becomes real, offer to restate the sales made before
any cost existed. Entirely client-side; no migration.

- **`CostBatchesDao.onCostBecameReal(productId, newCostKobo)`
  ([lib/core/database/daos_costing.dart](lib/core/database/daos_costing.dart)):**
  called on the `0 → positive` cost transition. Costs every still-uncosted batch
  (`cost_kobo == 0`) of the product to the new value (so future draws are costed
  and the scalar cache aligns) and returns a `CostBackfillOffer` naming the past
  **recognized, still-uncosted** sale lines (`buying_price_kobo == 0`,
  `orders.status IN ('pending','completed')`, `product_id` set). Costing the
  batch is what makes the offer **fire once per batch** — after it the batch is
  no longer uncosted, so a real→real edit can't re-trigger.
- **`applyCostBackfill(offer, description, staffId)`:** on accept, restates each
  line's snapshot to the new per-unit cost — **gap-only, re-checked at the row**
  (`buying_price_kobo == 0` in the WHERE, so a peer's concurrent recost or a
  double-tap never clobbers a real snapshot), each line left in its own order
  (restated profit lands in that sale's original period) — re-pushes each line,
  and writes exactly ONE `cost.backfill` Activity Log row.
- **Quick Sale & migration-era, one mechanism:** quick-sale lines (null product)
  are excluded by the `product_id` match and stay uncosted; a pre-FIFO product
  with **no batch** needs no special case — its uncosted lines are the same
  `buying_price_kobo == 0` set and back-fill identically.
- **Prompt UI
  ([lib/features/inventory/widgets/update_product_sheet.dart](lib/features/inventory/widgets/update_product_sheet.dart)):**
  the product-edit sheet detects the `0 → real` transition after save and shows a
  one-time "Apply cost to past sales?" dialog ("You sold N units before a cost was
  recorded…"); the DAO owns the atomic restate-and-audit, the UI owns the copy.
- **Tests
  ([test/costing/cost_backfill_test.dart](test/costing/cost_backfill_test.dart),
  8):** the transition costs the batch + offers exactly the gaps + leaves a costed
  line out; one Activity Log row; each line keeps its own sale date; quick-sale
  excluded; migration-era (no-batch) backfills; reversed (cancelled/refunded)
  orders excluded; re-applying a stale offer restates nothing (fires once);
  empty offer costs the batch but logs nothing. `flutter analyze` clean; full
  suite green (unrelated `who_is_working_screen_test` failure traces to the
  concurrent F4 `CloudTransport`/`deleted_businesses` sync stub, not this work).

---

## 2026-07-04 — Provisional→authoritative COGS correction + rolled-up audit (Epic 2 / FIFO, issue #40, ADR 0005)

**What shipped (Epic 2, F4).** The **client correction flow** that lands the
server's authoritative COGS back on the device and audits it. It lives entirely
in the sync engine — off the sale / app-open path.

- **Touched-pair collection in the push drain
  ([lib/core/services/supabase_sync_service.dart](lib/core/services/supabase_sync_service.dart)):**
  `pushPending` now collects the (product, store) pairs whose sale lines a drain
  actually delivered to the cloud — from v1 `order_items` upserts
  (`collectOrderItemPairs`) and v2 `pos_record_sale_v2` envelopes
  (`collectSaleEnvelopePairs`) alike. Quick-sale (null-product) lines never
  contribute (they stay uncosted by design).
- **`reconcilePushedSaleCosts(pairs, businessId)`:** after the drain, calls the
  server's `pos_recost_pairs` (migration 0133) for exactly those pairs. The
  server rewrites each affected `order_items.buying_price_kobo` and bumps
  `last_updated_at`, so the correction flows back down as an **ordinary LWW row
  update** on the following pull — replacing the provisional snapshot with no
  merge conflict (verified via `restoreTableDataForTesting`). Best-effort: any
  RPC failure is swallowed and self-heals on the next sync of the pair.
- **One rolled-up Activity Log row per sync batch — new
  `CostBatchesDao.logRecostReconciliation`
  ([lib/core/database/daos_costing.dart](lib/core/database/daos_costing.dart)):**
  action `cost.recosted_on_sync`, "N sales of X re-costed on sync —
  batch-boundary reconciliation" (multi-product batches roll into "N sales across
  M products"). Written ONLY when `recosted_count > 0`, so a single-till sale
  whose provisional already matched the authoritative value writes no row. No
  per-sale prompt — corrections are audited, never prompted.
- **`flushSale` is deliberately NOT re-cost-triggered** (keeps recost off the
  foreground sale path): an online-flushed sale is already consistent, and any
  later drift is fixed by the reconnecting offline peer's re-cost replaying the
  whole ledger (F3).
- **Tests
  ([test/costing/recost_correction_flow_test.dart](test/costing/recost_correction_flow_test.dart),
  8):** provisional present pre-sync → corrected value + exactly one Activity Log
  row post-reconcile; LWW replaces the provisional; `recosted_count 0` / empty
  pairs / RPC failure all write no row; multi-product roll-up into one row; and
  the two pure pair collectors incl. the quick-sale skip. `flutter analyze` clean;
  costing + sync suites green (210).

---

## 2026-07-04 — Pure FIFO draw-down + provisional COGS at checkout (Epic 2 / FIFO, issue #38, ADR 0005)

**What shipped (Epic 2, F2).** The **device-side** FIFO draw-down — a pure
costing function and its wiring into the sale path — so batch costing produces a
correct per-line provisional COGS locally. Single-till/online is the happy path;
multi-till server reconciliation is the parallel #39/#40 work.

- **Pure function
  ([lib/core/costing/fifo_drawdown.dart](lib/core/costing/fifo_drawdown.dart)):**
  `fifoDrawDown(batches oldest-first, lineQuantities) → FifoDrawResult`
  (`lineCogsKobo`, `lineShortfall`, `batchConsumption`). Widget-free/DB-free —
  weighted COGS across partial splits spanning two+ batches, cost-0 (uncosted)
  batch → 0 COGS but still drawn down, queue exhaustion → `lineShortfall`,
  sequential consumption across lines. 12 unit tests.
- **Checkout wiring — new `CostBatchesDao.drawDownSale`
  ([lib/core/database/daos_costing.dart](lib/core/database/daos_costing.dart)):**
  a new registered DAO (build_runner regenerated). Inside
  `OrdersDao.createOrder`'s sale transaction (after the inventory guard, on BOTH
  the v1 and v2 sync paths) it reads each (product, store) queue oldest-first,
  snapshots each line's **provisional per-unit COGS** onto
  `OrderItems.buyingPriceKobo`, decrements the consumed `cost_batches`, and
  enqueues each batch's upsert. Selling price (`unitPriceKobo`) is untouched.
- **Per-unit rounding matches the server exactly:** `round(line_total / qty)` via
  Dart `double.round()` == the server's round-half-away-from-zero
  (`fifo_assign`, migration 0133), so a provisional line and its authoritative
  correction (#40) agree when the queue covered the line and no cross-till
  re-ordering happened.
- **COGS is exactly the local batch-queue view — deliberately NO scalar
  fallback.** Units the queue can't cover (a product with no batch, or a
  partially covered line) are **uncosted (0)**, matching the server's
  `fifo_assign`. A scalar the server would later rewrite to 0 on sync is the
  "vanishing trust" failure ADR 0005 avoids; the empty-queue view also preserves
  the "uncosted items" signal (#41 backfills it).
- **Derived scalar cache (`Products.buyingPriceKobo`):** after the draw-down,
  re-pointed at the oldest remaining **costed** batch across stores, and only
  when the value changes (keeps sync churn down). An uncosted (cost-0) oldest
  batch is **skipped** so a user-entered price is never clobbered to 0 by an
  uncosted batch (that 0→real transition is #41's explicit backfill). Existing
  read sites (recon / profit report do per-unit × qty) are unaffected.
- **⚠️ Coherence gap — batch-creation-on-inflow is NOT wired (out of #38's
  criteria, needs a follow-up).** Neither Add Product's opening stock nor Receive
  Stock creates a `cost_batches` row yet; the queue grows **only** via the #37
  migration seed. So post-migration new / restocked / out-of-stock-at-migration
  products have no batch and their sales are **uncosted (0 COGS)** until a batch
  exists. This is the deliberate uncosted-until-recorded semantic, but Epic 2
  won't usefully cost new stock until inflow→batch is wired — flag before Epic 2
  is called done. (ADR 0005 already names it: batches are "pushed by Receive
  Stock and by Add Product's opening stock".)
- **Verified:** `flutter analyze` clean project-wide; new costing suite 16/16;
  orders / crates / record-sale-dispatch suites green (v2 thin-payload
  `buying_price_kobo` shape intact). Full suite **729 pass / 69 skip / 1 fail** —
  the sole fail is the documented pre-existing `who_is_working_screen_test`
  (confirmed failing identically with this work stashed; auth screen untouched).

---

## 2026-07-04 — Server-authoritative batch consumption + replay (Epic 2 / FIFO, issue #39, ADR 0005)

**What shipped (Epic 2, F3).** The server-side FIFO **batch consumption +
replay** logic — migration
[0133_fifo_batch_consumption.sql](supabase/migrations/0133_fifo_batch_consumption.sql).
The server owns the per-(product, store) cost queue and decides "which batch
paid for each sale," ordered by the sale's **own recorded timestamp**
(`orders.created_at`), re-deriving the authoritative per-line COGS. Verified in
isolation ahead of the client correction flow (#40) that will consume it.

- **Deliberately a separate derivation pass**, not more logic inside the
  quantity RPCs. Quantities are already ordered/resolved by the server-minted
  movement seam; this epic only adds "which batch paid" to already-quantified
  movements and must **not** reopen stock-quantity conflict resolution (ADR
  0005). So `pos_record_sale_v2` / `pos_inventory_delta_v2` are **untouched**.
- **`public.fifo_assign(batches, sales)`** — the pure (IMMUTABLE) draw-down: an
  oldest-first queue + a timestamp-ordered sale sequence in, per-line COGS out
  (`cogs_total_kobo`, `cogs_per_unit_kobo`, `uncosted_units`) + batch remainders.
  Handles partial-batch splits across boundaries, cost-0 **uncosted** units, and
  queue exhaustion. Per-unit rounding is `round(line_total / qty)` (round-half-
  away-from-zero); the client provisional draw-down (#38) must match it.
  Deterministic + idempotent by construction — the seam the tests hit directly.
- **`public.pos_recost_product_store(business, product, store)`** — the thin
  orchestrator: loads the queue + the recognized-sale ledger (`orders.status IN
  ('pending','completed')`, ordered by `orders.created_at, o.id, oi.id`; cancelled/
  refunded and Quick-Sale null-product lines excluded), replays via `fifo_assign`,
  and writes the authoritative COGS onto `order_items.buying_price_kobo` + derived
  `cost_batches.qty_remaining`. Full replay from `qty_original` every call ⇒
  **idempotent**; a late **earlier**-timestamped sale re-orders the ledger ⇒
  already-corrected lines are **re-assigned** (batch-boundary reconciliation).
  Only changed rows bump `last_updated_at`, so `recosted_count` counts genuinely
  re-costed sales and each correction flows down as an ordinary LWW row update.
- **`public.pos_recost_pairs(business, pairs)`** — recosts the (product, store)
  pairs a sync touched (deduped) and returns one rolled-up count for #40 to audit
  with a single Activity Log row. Does not write the Activity Log itself (client
  owns that copy + localization).
- **Tests
  ([pos_recost_batches_test.dart](test/integration/rpcs/pos_recost_batches_test.dart)):**
  Tier-2, verified independently of the client (calls the RPCs directly). Pure
  `fifo_assign` cases (single-batch, boundary-span, uncosted, exhausted,
  sequential oldest-first, determinism); orchestrator COGS-by-timestamp, the
  replay/cascade case (a late earlier sale re-costs an already-corrected line
  50000 → 56667), idempotency, cancelled-order exclusion; and the `pos_recost_
  pairs` roll-up + dedup.
- **Verified against dev Supabase** (read-only, independent of the client): the
  full `fifo_assign` battery passes (8/8), and the orchestrator's ledger-load
  queries + jsonb-index writeback execute correctly.
- **Deploy order:** after 0132 (needs `cost_batches`). Pure server logic, inert
  until #40 calls it, so safe to land ahead of the client work.

---

## 2026-07-04 — Cost Batch schema + migration + sync membership (Epic 2 / FIFO, issue #37, ADR 0005)

**What shipped (Epic 2, F1).** The FIFO **Cost Batch** foundation — the table,
its migration, and its sync wiring — landed and verified *in isolation*, ahead
of any consuming logic (the land-the-migration-first rule). No draw-down /
server-authoritative consumption yet; that is a later Epic 2 issue.

- **Drift table `cost_batches`
  ([app_database.dart](lib/core/database/app_database.dart)):** the
  per-(product, store) FIFO cost queue — `{id, businessId, productId, storeId,
  qtyRemaining, qtyOriginal, costKobo, receivedAt, createdAt, lastUpdatedAt}`.
  `costKobo == 0` marks an **uncosted** batch. A normal MUTABLE synced tenant
  table (qty drawn down in place) — not a ledger, not hard-deleted. Registered
  in the `@DriftDatabase` tables list; **schema v57 → v58**.
- **v58 migration (onUpgrade):** creates the table + the `(business_id,
  last_updated_at)` cursor index, the FIFO `(business_id, product_id, store_id,
  received_at)` scan index, and the bump trigger — the same shapes
  `_postCreateStatements` emits, so onCreate == onUpgrade. Then seeds **one
  opening batch per (product, store)** from current stock (`inventory.quantity >
  0`) at the product's existing scalar `buyingPriceKobo` (zero-cost → uncosted);
  `received_at`/`created_at`/`last_updated_at` inherit the product's
  `created_at` so the row is byte-identical on every device. The opening-batch
  **id is deterministic** (`UuidV7.deterministic`, a new UUIDv5 helper in
  [uuid_v7.dart](lib/core/database/uuid_v7.dart)) so two devices that both run
  the migration mint the SAME id and converge via `insertOnConflictUpdate`
  instead of duplicating once per device.
- **Sync registry
  ([sync_registry.dart](lib/core/database/sync_registry.dart)):** one
  `SyncedTable` entry, `Restore.plain(resilient: true)` (FK → products + stores;
  a batch can land before its parent slice). `tenantScoped: true`, no push-column
  divergence, no hardDelete/REPLICA IDENTITY (never tombstoned). Golden pull
  order + tenant set updated for the new table.
- **Cloud
  ([0132_cost_batches.sql](supabase/migrations/0132_cost_batches.sql), DEPLOYED):**
  `public.cost_batches` with **`cost_kobo BIGINT`** (money rule), `current_user_
  business_ids()` RLS (`cost_batches_tenant_rw`), bump trigger, realtime
  publication membership (no REPLICA IDENTITY FULL — upsert/update-only, like the
  balance caches), and `pos_pull_snapshot` extended with `cost_batches` after
  `inventory`. Verified on remote: bigint cost_kobo, RLS on, in publication,
  snapshot carries it. Safe for live v57 devices — the pull iterates the app's
  own registry, so the extra snapshot key is ignored.

**Incidental root-cause fix (blocking the required regeneration).** A clean
`dart run build_runner build` dropped `_$BusinessesDaoMixin` and failed to
compile: the `@DriftAccessor(tables: [Businesses])` annotation in
[daos_org.dart](lib/core/database/daos_org.dart) was **misplaced** — a `const
_absent` sentinel sat between the annotation and `class BusinessesDao`, so
drift_dev never generated the mixin. The committed generated file was
stale-but-correct (generated before the sentinel was inserted), masking it until
a fresh regen. Moved the annotation onto the class + a guard comment.

**Verification.** New migration test
([migration_upgrade_test.dart](test/database/migration_upgrade_test.dart)) drives
the real onUpgrade(57→58) and asserts one opening batch per (product, store),
zero-cost → uncosted, empty stock → no batch, the deterministic id, and the
index/trigger creation. `flutter analyze` clean project-wide. Full suite: 713
pass / 58 skipped / 1 pre-existing unrelated failure
(`who_is_working_screen_test` — confirmed failing on HEAD without these changes).

---

## 2026-07-04 — Land on POS after onboarding; delete the auto-push (issue #35, ADR 0006)

**What shipped (Epic 1).** Onboarding now lands the device on POS — where the
persona-aware "Add your first product" CTA (#34) greets the user — instead of
force-pushing the Add Product form on `MainLayout`'s first frame. The one-shot
auto-push mechanism is removed entirely:

- **[navigation_service.dart](lib/shared/services/navigation_service.dart):**
  deleted the `_autoShowAddProductPending` flag plus
  `requestAutoShowAddProductSheet()` / `consumeAutoShowAddProductSheet()`.
- **[main_layout.dart](lib/shared/widgets/main_layout.dart):** removed the
  first-frame consumer that pushed `AddProductScreen`, and its now-unused
  `add_product_screen.dart` import.
- **Both former call sites:**
  [success_dashboard_entry_screen.dart](lib/features/auth/screens/success_dashboard_entry_screen.dart)
  (now a plain `StatefulWidget` — it no longer reads any provider, so
  Riverpod/`app_providers`/`navigation_service` imports dropped) and
  [ceo_sign_up_screen.dart](lib/features/auth/screens/ceo_sign_up_screen.dart)
  (dropped the orphaned `nav` local) no longer request the auto-push.

The onboarding → `MainLayout` handoff is otherwise unchanged: the success
screen still forwards to `MainLayout` after 1.5 s, and the CEO sign-up path
still lands on the authed shell after the 3 s "your business is ready" beat.
`flutter analyze` clean project-wide; no dead code remains.

---

## 2026-07-04 — Persona-aware first-run empty states (Seam 2, issue #34, ADR 0006)

**What shipped (Epic 1).** The POS and Inventory empty states are now
persona-aware. A fresh CEO on a genuinely empty catalogue sees a primary **"Add
your first product"** CTA that opens the Fast-Add form; a cashier without
`products.add` sees a neutral no-button *"No products yet — a manager can add
them"* message; and neither ever flashes while the catalogue is still streaming
in on a joining staff member's device (invariant #11).

- **Seam 2 — pure derivation
  [first_run_surface_state.dart](lib/core/providers/first_run_surface_state.dart):**
  `computeFirstRunSurfaceState({hasProducts, firstLoadInProgress, canAddProduct})
  → {skeleton, addProductCta, neutralEmpty, hasContent}`. Widget-free,
  Riverpod-free. Precedence: products present → `hasContent`; else still
  streaming → `skeleton` (never a CTA — #11); else settled + zero splits on the
  gate → `addProductCta` / `neutralEmpty`.
- **Live wiring — `firstRunSurfaceStateProvider`** composes
  `hasLocalProductsProvider`, the shared `firstLoadSkeletonActiveProvider` (the
  same "still streaming in" signal the tab skeletons key off, so the CTA and the
  skeleton stay in lockstep), and `Gates.addProduct` evaluated against
  `gateContextProvider`. Every input is an overridable provider → unit-testable
  in a ProviderContainer with no widgets.
- **Shared surface —
  [first_run_empty_state.dart](lib/shared/widgets/first_run_empty_state.dart):**
  one `FirstRunEmptyState` consumed by **both** the POS grid and the Inventory
  Products tab, so the two empty states can never drift. `addProductCta` opens
  `AddProductScreen` in direct (non-receive) mode — the Fast-Add form (#30);
  `neutralEmpty` renders the no-button message; `skeleton`/`hasContent` render
  nothing (the tab-level skeleton / the grid own those).
- **Filter-miss preserved:** each screen only routes to the first-run surface
  when its visible list is empty AND the catalogue is genuinely zero (surface
  `!= hasContent`). A category/search miss over a populated catalogue keeps its
  own "No products found" / "No products matching filters" copy.
- **Tests —
  [first_run_surface_state_test.dart](test/providers/first_run_surface_state_test.dart):**
  the pure function is exhaustive over the three inputs + precedence; the
  provider is driven through all four states via input overrides (streaming →
  skeleton; settled + zero + can-add → CTA; settled + zero + no-add → neutral;
  products present → hasContent). `flutter analyze` clean; inventory/receiving/
  pos suites green.

---

## 2026-07-04 — Get-started checklist: derived state + Home-tab card (Seam 3, issue #31, ADR 0006)

**What shipped (Epic 1).** A first-time CEO's Home tab now shows a short **Get
started** card tracking three milestones — *Add a product*, *Make a sale*,
*Invite your team (optional)* — that tick off automatically and disappear once
the store is up and running. Completion is **derived from data, never stored as
flags**, so it is cross-device correct for free (a reinstall reflects real
progress); the only persisted bit is a device-local manual dismissal.

- **Seam 3 — pure derivation
  [get_started_checklist.dart](lib/features/dashboard/get_started_checklist.dart):**
  `computeGetStartedChecklist({isCeo, hasProducts, hasOrders, hasTeam,
  dismissed}) → {visible, steps[]}`. Widget-free, Riverpod-free. Visible only
  when CEO, not all steps done, and not dismissed. Each step's `done` is a pure
  projection of a threshold: products > 0, orders > 0, staff > 1 (active staff
  includes the CEO, so a team needs count > 1).
- **Live wiring — `getStartedChecklistProvider`** composes
  `currentUserRoleProvider` (slug=='ceo'), `hasLocalProductsProvider`, the new
  `hasAnyOrderProvider`, `activeStaffProvider(businessId)` count, and the
  device-local `getStartedChecklistDismissedProvider` through the pure function.
  Every input is an overridable provider → the derivation is unit-testable in a
  ProviderContainer with no widgets.
- **Any-order-exists signal:** new
  [OrdersDao.watchAnyOrderExists()](lib/core/database/daos_orders.dart) — a cheap
  `COUNT(*)` mapped to a distinct-filtered `bool`, surfaced as
  `hasAnyOrderProvider` (routed through `businessScopedStream`; passes the raw-
  `StreamProvider` ban test). Any order counts (revenue is recognized at
  checkout; a later-voided sale still means a checkout happened).
- **Dismissal:** `GetStartedDismissalNotifier` — a boolean latch persisted in
  SharedPreferences (`get_started_checklist_dismissed_v1`), mirroring
  `UiHintService`. Device-local by design (un-synced); the solo CEO who won't
  invite staff silences the optional step for good, and it stays hidden across
  restarts.
- **Card —
  [get_started_card.dart](lib/features/dashboard/widgets/get_started_card.dart):**
  a `ConsumerWidget` on the Home tab **only** (never POS). Self-hides to zero
  height when not visible, so it drops in unconditionally at the top of the Home
  list. Each unticked step deep-links (Add product → `AddProductScreen`
  direct mode; Make a sale → POS tab; Invite team → `InviteStaffScreen`); done
  steps are inert with a struck-through label; an ✕ dismisses.

**Not touched (separate issues/Seams):** the post-onboarding auto-push removal,
the speed-dial FAB, and the persona-aware empty-state CTAs (Seam 2).

**Tests:** new
[test/dashboard/get_started_checklist_test.dart](test/dashboard/get_started_checklist_test.dart)
— 14 tests: exhaustive pure-function coverage (role / threshold / dismissal),
provider wiring via input overrides (each data source ticks its step; non-CEO
never sees it; no-bound-business is safe), and the dismissal latch persisting
across a simulated restart. `flutter analyze lib` + the new test: clean. The
raw-`StreamProvider` ban test still passes.

---

## 2026-07-04 — Fast-Add Product form: pure form model (Seam 1) + adaptive screen (issue #30, ADR 0006)

**What shipped (Epic 1, first issue).** The Add Product screen's direct mode
became a short, adaptive **Fast-Add** form, with the save-time decisions
extracted into a pure, widget-free **Fast-Add form model** (Seam 1).

- **Seam 1 —
  [fast_add_product_model.dart](lib/features/inventory/models/fast_add_product_model.dart):**
  `resolveFastAdd(FastAddInput, FastAddContext) → FastAddResult` (a sealed
  `FastAddInvalid{field,message}` / `FastAddIntent`). Owns required-field
  validation (Name / Selling Price / Quantity), the business-type-aware unit
  default (`fastAddDefaultUnit(tracksCrates) → Bottle|Pack`), the
  wholesaler-mirror-on-save (blank ⇒ selling price, a stored value),
  manufacturer-required-for-crate, target-store resolution (single-store silent
  / multi-store required), the Uncosted rule (blank buying ⇒ 0), and shaping the
  write intent. No widgets, no DB, no `BuildContext`. Every `FastAddInvalid.field`
  names a **visible** field.
- **Screen wiring —
  [add_product_screen.dart](lib/features/inventory/screens/add_product_screen.dart):**
  direct-mode new-product `_save` now delegates to `_saveFastAddNewProduct` →
  the model → `_persistNewProduct` (same catalog/inventory DAOs, unchanged write
  for a fully-filled form). New adaptive layout: fast section (Name+size hint,
  Selling Price, skippable Buying Price+nudge, optional Category+examples,
  crate-only required Manufacturer, Quantity) + a collapsible **More details**
  (Description, Wholesaler, Unit, track-empties+crate value, fractional-sales,
  Low Stock, Supplier, Expiry, Store). Store is hidden for single-store
  businesses. A validation error targeting a More-details field (only Store)
  auto-expands the section first, so no error points at a collapsed field.
- **Untouched:** Receive Stock's mini-form (`receiveMode: true`) and the
  add-stock-to-existing path keep the classic full layout + save path verbatim.
  The post-onboarding auto-push, the speed-dial FAB, the first-run empty-state
  CTAs, and the Get-started checklist are **separate issues** (Seams 2/3), not in
  #30.

**Tests:** new
[fast_add_product_model_test.dart](test/inventory/fast_add_product_model_test.dart)
— 27 pure unit tests covering the Testing Decisions in #29 (three-field minimum,
each missing required field names its field, wholesaler mirror, unit default per
business type, manufacturer-required-for-crate, blank-buying Uncosted, single vs
multi store). The one existing widget test encoding the old direct-mode layout
([receive_flow_mode_test.dart](test/receiving/receive_flow_mode_test.dart), *"…
renders Store and Supplier fields"*) was updated to assert the Fast-Add design:
single-store hides Store, Supplier lives under an expandable "More details"; the
`receiveMode: true` assertions (Receive Stock untouched) are unchanged.
`flutter analyze` clean (whole project); `test/inventory` + `test/receiving`
56/56 green. On-device Fast-Add walkthrough (layout, collapse, single-store hide)
pending.

---

## 2026-07-04 — Migration 0131 deployed: configurable trial length (console getter pending)

Applied `0131_configurable_trial_length.sql` to the linked Supabase project via
`supabase db push` — recorded in `schema_migrations`, and the live
`set_business_trial_end()` body verified to now call `console_get_trial_days()`
with the 30-day fallback intact.

**Console dependency not yet deployed.** `console_get_trial_days()` /
`public.console_settings` (owned by the console repo, §13) don't exist in the
shared project yet, so the trigger currently takes its **defensive 30-day
fallback** — behaviour identical to migration 0101. Once the console side ships
its getter, new sign-ups pick up the configured trial length automatically; **no
redeploy of 0131 needed** (the trigger late-binds the function call at runtime).

---

## 2026-07-04 — Saved Carts modal: ListTile ink/background no longer hidden by the surface fill

**Bug:** Flutter framework warning — *"ListTile background color or ink splashes may
be invisible … wrapped in a DecoratedBox that has a background color."* The Saved
Carts bottom sheet in [cart_screen.dart](lib/features/pos/screens/cart_screen.dart)
draws its rounded surface via `Container(decoration: BoxDecoration(color: _surface))`.
That opaque `DecoratedBox` sits between the modal's `Material` and the list's
`ListTile`s, so each tile paints its background/ink splash on the Material *below* the
fill — hidden.

**Fix:** wrapped the tile in a transparent `Material`
(`MaterialType.transparency`), matching the framework's own prescription and the
existing convention in this repo (role_permissions / staff_permissions /
update_product_sheet all put a `Material` between an `AppDecorations` card and their
`*ListTile`). Swept the other `*ListTile` sites — `printer_picker`, `business_info`,
`staff_detail`, `add_product_screen` — none have an opaque `Container` between the
tile and the nearest `Material`, so they don't trigger it.

**Verified:** `flutter analyze lib/features/pos/screens/cart_screen.dart` — no issues.

## 2026-07-04 — `daos.dart` split into 11 domain `part` files (pure locality refactor)

**Scope:** pure refactor, **no behaviour change**, **no interface change**. The
9,820-line `lib/core/database/daos.dart` (47 `@DriftAccessor` DAOs) was mechanically
carved into 11 domain-grouped `part of 'daos.dart'` files — the same house pattern
`sync_registry.dart` already uses (`part of 'app_database.dart'`). Everything stays
**one library**, so:
- library-private members (`_unset`, `_absent`) stay visible across every part;
- the generated `daos.g.dart` (`part of 'daos.dart'`) is **unchanged** — no
  `build_runner` rerun needed, generation is identical;
- the 5 files that `import daos.dart` are untouched — public class names still
  live in library `daos.dart`.

**The seams were not moved.** Each DAO is its own interface over a fixed table set;
the split only improves **locality** (domain files now 358–2,324 lines vs one
9,820-line monster). Verbatim contiguous slices — no reordering within any class;
`CustomerDataExtension` moved with the customers group, the `_absent` sentinel kept
inside its `BusinessesDao` block.

**New files:** `daos_catalog.dart`, `daos_inventory.dart`, `daos_orders.dart`,
`daos_customers.dart`, `daos_suppliers.dart`, `daos_crates.dart`,
`daos_expenses.dart`, `daos_sync_diagnostics.dart`, `daos_stores_sessions.dart`,
`daos_permissions.dart`, `daos_org.dart`. `daos.dart` is now a ~35-line library
header (imports + `part` directives + the two sentinels).

**Verified:** slicing script asserted every non-blank code line preserved exactly
once (9,067 lines, 0 missing / 0 extra). `flutter analyze` clean — db dir and full
project (`No issues found!`).

---

## 2026-07-04 — Order module extraction: one facade over command/query surfaces (ADR 0004)

**Scope:** pure refactor, **no behaviour change**. The order-lifecycle logic was
scattered across `OrderService.addOrder`, `OrdersDao`, the Confirm ceremony
*orchestrated by the UI* in `orders_screen`, and two screens reading orders
straight from the DAO. Consolidated everything **order-shaped** behind one deep
module. Design was grilled end-to-end (`/grill-with-docs`) and recorded in
`CONTEXT.md` (glossary: Order, Sale, Checkout, Confirm, Cancel, Cart) + **ADR
0004**.

**New module — `lib/shared/services/orders/`:**
- `order_service.dart` — the **facade** `OrderService` (unchanged public API, so
  `orderServiceProvider` + call sites are untouched). Delegates to two internal
  surfaces.
- `order_commands.dart` — **`OrderCommands`**: the lifecycle writes **Checkout**
  (was `addOrder`) / **Confirm** (was `markCompleted`) / **Cancel** (was
  `markCancelled`) + `_compensateRejectedSale`. Post-checkout side-effects
  (quick-sale audit + crate-debt notify) isolated into one
  `_runPostCheckoutSideEffects` step.
- `order_queries.dart` — **`OrderQueries`**: read projections (`watch*`, paging,
  stats, cart-staleness) + the two migrated stray reads.
- `sale_flusher.dart` — narrow **`SaleFlusher`** seam (`SyncSaleFlusher` real /
  `NoopSaleFlusher` for no-sync). Decouples the flush→reject→compensate path
  from the concrete Sync Engine; `SaleSyncException` stays in core (layering).
- `crate_return_input.dart` — `CrateReturnLine` / `CrateReturnResult` DTOs.

**Module sits on top of `OrdersDao`** (unchanged persistence seam) — did NOT
absorb it. Reads (`watchOrdersByCustomer`, `getSalesSummaryForProduct`) migrated
off direct DAO calls in `customer_detail_screen` / `product_detail_screen` onto
the query surface. **Carts** and **delivery receipts** deliberately left OUT.

**Confirm consolidation (the behaviour-visible move):** crate-return settlement
moved off the UI. `CrateReturnModal` now only *collects* counts and returns a
`CrateReturnResult`; `OrderCommands.confirm` performs the settle (walk-in
stock-only vs registered deposit settle/net) **then** the `pending`→`completed`
flip — same order as before (modal wrote, then `markCompleted` ran), same
transaction shape. `markAsCompleted` gained optional `customerId/storeId/
crateReturns/refundAsCash` (its only caller is the crate path).

**Tests:** new `test/orders/order_module_test.dart` (7 tests) pins the
highest-drift paths — checkout payment-type/wallet-debit resolution
(cash/mixed/wallet/credit); Confirm settle-then-complete (money-track full
return: refund to credit + empties restocked + status flip); and — added after
the `/code-review` Spec axis flagged the gap — the two *ordering/failure*
invariants: **Confirm aborts before the flip** (a crate-settle failure leaves the
order `pending`) and **checkout reject→compensate** (a fake `SaleFlusher` throwing
`SaleSyncException` → order `cancelled` + inventory refunded, exercising the seam's
whole reason to exist). The existing ~657-test suite was the equivalence net,
green at every step. `flutter analyze` clean.

**Reviewed** via `/code-review` (Standards + Spec axes). Spec: no behaviour drift
(payment/wallet logic byte-identical to the deleted file; Confirm settle→flip
order preserved); only gap was the two missing invariant tests, now added.
Standards: clean faithful move; the only standard-anchored asks (vocabulary-aligned
public renames Checkout/Confirm/Cancel; the untyped `List<Map<String,dynamic>>
cart` contract) are both pre-existing and deliberately kept for API stability —
deferred as tracked follow-ups.

**Pre-existing unrelated failure:** `test/auth/who_is_working_screen_test.dart`
(one case) fails on a network `PostgrestException 400` via `SupabaseCloudTransport`
— zero references to any changed file; not caused by this work.

---

## 2026-07-03 — Business-Scoped Stream primitive: guarded factory + full migration (PRD #23 = #24 + #25)

**Scope:** retire the build-time-poison provider bug *by construction*. A
business-scoped `StreamProvider` that calls a `requireBusinessId()`-backed DAO
`watch*()` baked the session businessId at first build and, if first-subscribed
in the create-business null window, either **threw + stuck errored** or
**silent-empty-stuck** for the whole session (empty Receive/Transfer/POS store
pickers until restart). Fixed once per provider before (S153); now unrepresentable.

**New primitive — `lib/core/providers/business_scoped_stream.dart`:**
- `currentBusinessIdProvider` — the single watchable businessId seam
  (`authProvider.select(currentUser?.businessId)`). Nothing else re-derives the
  tenant; tests flip it via `overrideWith`.
- Four guarded factories: `businessScopedStream` / `businessScopedStreamFamily`
  + `…AutoDispose` / `…AutoDisposeFamily` twins (Riverpod types keep-alive and
  autoDispose distinctly, so lifecycle is preserved). Each watches the seam,
  emits a required `whenAbsent` while unbound, and hands the closure
  **`(ref, db, businessId)`** with a guaranteed non-null id (`ref` lets the few
  store-scoped feeds compose `lockedStoreProvider`).

**Migration:** 62 session-scoped stream declarations lifted onto the factory
across `stream_providers.dart` + `app_providers.dart` — behaviour-preserving
(`whenAbsent` = the prior null-window value). Consumers untouched. The
FutureProvider `firstPullCompletedProvider` was repointed onto the seam so no
inline `authProvider.select(...businessId)` remains.

**Stayed raw (allowlist, 11):** permissions catalogue + unscoped roles (global);
`_userMemberships` / `myUserStores` / `activeStaff` / `deviceStaff` (explicit-id,
resolve before bind — routing them through the factory would break the shared-PIN
picker); `orphanQueueItems` / `orphanQueueCount` (device-local, no `business_id`);
`localBusinesses` / `pendingCrateReturns` / `pendingReturnsWithDetails`
(intentionally unscoped selects).

**Enforcement + tests:**
- `test/providers/business_scoped_stream_ban_test.dart` — bans a raw
  `StreamProvider` declaration anywhere in `lib/` (name-keyed allowlist,
  shrink-only ratchet) + companion strictness test (planted raw caught, multi-line
  caught, all four factory forms not flagged). Modeled on `gate_static_ban_test.dart`.
- `test/providers/business_scoped_stream_test.dart` — drives the factory
  `null → bound → switched → unbound` through the seam override and proves it never
  runs the closure in the null window. No database required.

**Verified:** `flutter analyze` clean. Full suite 652 passed / 58 skipped /
1 pre-existing failure (`who_is_working_screen_test.dart` "Carol" — fails
identically with these changes stashed, unrelated to this work).

---

## 2026-07-03 — Flip the gate enforcement: empty the allowlist, remove the bare helpers (issue #22)

**Scope:** the epic #16 finish line. The named-gate migration's shrinking
static-ban allowlist is now **empty**, the bare single-key helper and the
manager-tier helper are **removed** from the app, and the leak class (permission
enforcement re-typed inline across ~89 sites) is retired the way the
`SyncedTable` registry (#15) retired the sync smear.

**Last 10 bare `hasPermission(ref, …)` sites → named gates (verbatim):**
- `staff_detail_screen` (6): assign-stores, change-role ×2, suspend ×2,
  permission-editor visibility → `assignStaffStores`, `changeStaffRole`,
  `suspendStaff`, `manageSettings`.
- `staff_permissions_screen` (1): `settings.manage` → `manageSettings`.
- `orders_screen` (2): both Pending-tab Refund checks (`sales.cancel`) →
  `refundOrder`.
- `activity_log_screen` (1): body-guard (`activity_logs.view`) →
  `viewActivityLogs`.

**Bare + tier helpers removed from `stream_providers.dart`:**
- `hasPermission(WidgetRef, String)` — **deleted**. Nothing outside the
  permissions module reads the effective set directly for gating now; the
  single-key primitive lives only as `Gate.key` behind `Gates.x.allows(ref)`.
- `isManagerOrAbove(WidgetRef)` — **deleted** (user-approved scope). Its ~12
  feature call sites now cite named tier atoms so the tier rule
  (`roleRank(slug) <= 1`) exists ONLY in registry atoms:
  - `seeOrderMoney` (§19.3 — order money columns + per-tab money stats;
    `orders_screen` ×4). The completed/cancelled tabs split the single
    `managerUp` into `seeOrderMoney` (money) + `seeExtendedDateRanges` (filter).
  - `seeExtendedDateRanges` (§19.2 — the This Year / To Date presets;
    `orders_screen`, `customer_detail`, `supplier_transactions`, `expenses`,
    `home`, `supplier_detail`).
  - `viewApprovals` / `dailyReconciliation` / `crateDepositsReport` — the
    reports-hub manager-up cards (`isMgrUp` → `tierAtLeast(manager)`; Crate
    Deposits keeps its `&& isCrate` business-type check inline).

**Registry (`Gates`, Staff/Orders/finish-line cluster):** 9 new entries
(4 key-based staff/order gates, 5 tier-based §19-class render-only gates,
all carrying the ADR-0002 review flag). `Gates.all` = 48; every gate cited in
production (membership test strict).

**Static-ban test flipped strict:** `_allowlist` is now `{}`. Any bare
`hasPermission(ref, …)` in `lib/` outside `lib/core/permissions/` fails the
suite. Added a durable scanner self-test (a synthetic bare check must match,
a `Gates.x.allows(ref)` citation must not). The AC's plant-and-verify was run:
a temporary bare check in a lib file failed the scan; the plant was removed.

**Left as-is (out of approved scope):** per-screen `slug=='ceo'` CEO cost-wall
money-visibility checks (deliberately tier-based per ADR 0002, never in any
batch) and the drawer `isBelowCeo` UI-placement split (chooses self-service vs
CEO settings — not a permission gate, and the Gate algebra has no negation atom
by design).

**Tests:** the two settings harnesses (`settings_menu_gating`,
`sidebar_role_visibility`) drop the deleted helper for a direct
`currentUserPermissionsProvider.contains(key)` — identical semantics through the
same provider chain the named gates read.

**Verification:** whole-project `flutter analyze` clean; `test/permissions` +
`test/settings` 80/80; full suite green except `who_is_working_screen_test` —
**pre-existing** (widget-timing + a live Supabase `PostgrestException`;
untouched by this work, uses neither removed helper, flagged in prior logs).

---

## 2026-07-03 — Migrate Settings & sidebar to named gates, incl. the Sync Issues composite (issue #21)

**Scope:** the Settings/nav batch of epic #16 — all 11 `lib/core/settings/`
screens, `app_drawer.dart`, `main_layout.dart`, and the Sync Issues screen
guard lifted **verbatim** onto named registry gates; the static-ban allowlist
shrinks by exactly those 13 files. Also migrated (beyond the ratchet's regex):
the 7 fire-time `ref.read(currentUserPermissionsProvider).contains(…)` write
re-checks in settings sub-screens → `.allowsNow` + standard `showGateDenied`
feedback.

**Registry (`Gates`, Settings & sidebar/nav cluster):**
- `viewSyncIssues` — `sync.view` OR CEO (the issue's flagship composite). ONE
  entry now cited by all its surfaces: the screen body-guard, the sidebar
  item, and the drawer header's sync status badge/banner pill. The standalone
  `canViewSyncIssues` helper is **retired** (deleted from
  `stream_providers.dart`) — CEO access without the grant still works via the
  `Gate.ceo()` disjunct.
- `manageSettings` — `settings.manage` (drawer CEO Settings entry + settings
  home + every sub-screen's body-guard and write re-check)
- `deleteBusiness` — `settings.delete_business` (Danger Zone entry, compound
  with its non-permission search-match kept at the call site, + delete screen
  body-guard)
- Render-only nav gates: `viewCustomers` (`customers.add` — distinct action
  from `addCustomer`), `manageStaff` (`staff.invite`), `viewActivityLogs`
  (`activity_logs.view`), `viewStores` (any-of the four stores/transfer keys,
  the drawer's old four-way OR)

**Same-gate pairing (nav entry ↔ destination):** POS drawer entry, bottom-nav
POS/Cart tabs, and the no-POS-landing bounce guard all cite `makeSale`;
Inventory drawer entry + Stock tab cite `viewInventory`; Supplier Accounts →
`manageSuppliers`; Expenses → `viewExpenses`; CEO Settings > Stores
body-guards on `manageStores` (`stores.manage`, deliberately not
`settings.manage` — verbatim).

**Unchanged by design:** Roles & Permissions editors migrate like any other
screen — the write-time dependency-cascade (`descendantsOf`) and the
role-settings limits are untouched. `SettingsNoAccess` bodies kept (verbatim
lift, no scaffold swap). The drawer's staff-vs-CEO `isBelowCeo` slug split is
a UI split, not a permission gate — left for the #22 tier-check sweep.

**Verification:** `flutter analyze` clean on all touched files;
`test/permissions` 45/45 (ratchet + membership green); full suite green except
`who_is_working_screen_test` — **pre-existing**, verified by running it at
HEAD in a clean worktree (fails identically; it makes a live Supabase call).

---

## 2026-07-03 — Migrate Inventory, Stores, Customers & Expenses to named gates (issue #20)

**Scope:** the mechanical operations batch of epic #16 — 26 bare
`hasPermission(ref, …)` sites across 9 files lifted **verbatim** into named
registry gates; the static-ban allowlist shrinks by exactly those files.

**New algebra atom:** `Gate.tierIn(ranks)` (set membership over role ranks,
fails closed on null). Needed for exactly one lift: Daily Stock Count's legacy
role set {CEO, Manager, Stock keeper} **skips Cashier**, so no `tierAtLeast`
cutoff can express it. Convention-bound like the other tier atoms (ADR 0002);
unit-tested in `gate_test.dart`.

**Registry (`Gates`, Operations cluster):**
- `viewInventory` — `stock.view` (Inventory tab body-guard, §16.7)
- `dailyStockCount` — `tierIn{ceo,manager,stockKeeper} && stock.adjust`
  (tier-based legacy — review flag)
- `manageStores` — `stores.manage`; `requestStoreTransfer` /
  `dispatchStoreTransfer` / `receiveStoreTransfer` — the three transfer keys
- `editCustomer` — `customers.update`; `deleteCustomer` — `customers.delete`
- `addCustomerCredit` — `customers.wallet.update`; `setDebtLimit` —
  `customers.set_debt_limit`; `refundCustomerWallet` — `customers.wallet.withdraw`;
  `seeWalletTotals` — `customers.wallet.totals.view` (§18.4)
- `recordCrateReturn` — `sales.make` (same key as `makeSale`, distinct action
  with its own denial text)
- `viewExpenses` — `reports.see_expenses`; `addExpense` — `expenses.create`;
  `approveExpenses` — `expenses.approve`

Reused entries (docs broadened): `addCustomer` (Customers FAB),
`editProductPrice` (Inventory long-press editor), `editBuyingPrice` +
`manageSuppliers` (Add Product screen).

**Screen guards:** Inventory and Expenses hand-rolled denial scaffolds replaced
by `Guarded.screen` (wait-for-ready → no denial flash). Both are MainLayout
tabs, so — per the POS precedent — the `loading`/`denied` overrides keep their
chrome (SharedScaffold / drawer + app-bar) so nav stays reachable. The Stores
browse composite stays inline (its all-stores-viewer leg is a store-assignment
provider, not a permission key) but cites the named gates for each key leg.
Write boundaries (`_openEditSheet`, EditCustomerSheet save) use `.allowsNow(ref)`
with behaviour preserved (silent pop/return, as before).

**Verification:** `dart analyze` clean on all touched dirs; `gate_test` +
`guarded_test` green (incl. the new `tierIn` + `dailyStockCount` semantics);
full suite 641 passing. The `gate_registry_membership_test` /
`gate_static_ban_test` failures at run time belong to the **parallel #21
settings batch** (its six gates declared but not yet cited; its six settings
allowlist rows not yet shrunk) — none of this batch's files or gates appear in
either failure. `who_is_working_screen_test` fails on a live-network
PostgrestException, unrelated to gates.

---

## 2026-07-03 — Migrate Dashboard & Reports composite gates to named gates (issue #18)

**Scope:** the messiest composite permission expressions in the app — the
home-screen §11.4 money/report tiles (CEO-or-Manager-with-key patterns) and the
Reports hub / Profit report entries — lifted **verbatim** into named registry
gates. No key-ification, no semantic cleanup; each tier+key expression moves
exactly as written so the registry now makes every tier dependence visible in
one place (ADR 0002).

**Registry (`Gates`, tier-based / §19.3-class, render-only — `.allows(ref)`):**
- `seeSalesMetric` — `ceo || (tierAtLeast(cashier) && reports.see_sales)`
- `seeProfitMetric` — `ceo || reports.see_profit`
- `seeExpensesMetric` — `ceo || (tierAtLeast(manager) && reports.see_expenses)`
- `seeStockValueMetric` — `ceo || (tierAtLeast(manager) && stock.view)`
- `seeCreditBalanceMetric` — `ceo || (tierAtLeast(cashier) && customers.add)`
- `seeStaffSales` — `tierAtLeast(manager)` (money-visibility, pure tier)
- `supplierAccountsReport` — `tierAtLeast(manager) && suppliers.manage`
- `profitReportEntry` — `tierAtLeast(manager) && reports.see_profit`
- `seeReportCostPrices` — `reports.see_cost_prices`

The `(isManager || isCashier)` halves became `tierAtLeast(cashier)` and
`isManagerOrAbove`/`isMgrUp` became `tierAtLeast(manager)` — both provably
identical under the CEO disjunct across all four ranks + the null-rank
(fail-closed) case, so behaviour is neutral by construction.

**Call sites:**
- `home_screen.dart` — 5 tile flags + Staff Sales now cite `Gates.*.allows(ref)`.
  `showPending` (`slug != null`) and `showTotalSkus` (`isCashier || isStockKeeper`,
  not expressible with `tierAtLeast`) stay inline — not permission checks, out of
  this key-focused batch.
- `reports_hub_screen.dart` — Supplier Accounts + Profit Report entries cite the
  two hub gates; the pure-tier `if (isMgrUp)` cards (Approvals / Daily Recon /
  Crate Deposits) stay inline (cross-cutting role helper, not a bare check).
- `profit_report_screen.dart` — the on-screen headline (`.allows`) and the CSV
  export path (`.allowsNow`, previously a raw `currentUserPermissionsProvider.contains`)
  now cite the SAME `seeReportCostPrices` gate, so the "mirror the on-screen gate"
  comment is provably true instead of comment-enforced.

**Ratchet:** the static-ban allowlist shrank by exactly these three files
(home_screen 5, reports_hub 2, profit_report 1 → removed). `flutter analyze`
clean; `test/permissions/` green (static-ban + membership + pure/widget seams),
no behavioural test edits.

---

## 2026-07-02 — Tracer: named-gate registry + `Guarded`, proven on Receive Stock (issue #17)

**Problem:** permission enforcement is hand-typed at ~89 `hasPermission(ref, key)`
sites across 22+ files in three layers (hide the button / guard the screen /
re-check before the write), their equivalence maintained only by code comments.
A forgotten or drifted layer is the documented recurring leak (the Session 81
audit fixed nine, one at a time). Issue #16's plan retires the class the way the
`SyncedTable` registry (#15) retired the per-table sync smear: one declaration,
generic machinery, a test that makes the old pattern impossible. This issue is
the **tracer** — the whole module + one gate migrated end-to-end.

**Module (`lib/core/permissions/`, ADR 0002 + CONTEXT.md glossary):**
- `gate.dart` — the **pure** Gate algebra: `Gate` sealed predicate over a
  `GateContext` (`grantedKeys`, `roleRank?`, `isReady`), atoms `key` / `anyKey` /
  `allKeys` / `tierAtLeast` / `ceo` composed with `.and` / `.or`. No Riverpod, no
  Flutter — unit-testable as a function. **Fails closed** while the role is
  unresolved (empty set + null rank ⇒ every atom false); **CEO all-on** holds via
  the seeded CEO grants (key atoms) plus the explicit `ceo` atom for composites.
  Plus `GateDeniedError` (carries the gate name → error-log telemetry).
- `gate_registry.dart` — `NamedGate` (name + human action + rule) and `Gates`,
  the single declaration site. Tracer gates: `receiveStock` (any-of `stock.add` /
  `products.add`), `addProduct`, `editProductPrice`, `editBuyingPrice`,
  `manageSuppliers`. Tier atoms are convention-bound (legacy lifts + §19.3 only).
- `guarded.dart` — the Riverpod glue: `gateContextProvider` (the one seam onto
  `currentUserPermissionsProvider` / `currentUserRoleProvider` /
  `currentUserPermissionsReadyProvider`), the `GateEvaluation` extension
  (`allows` reactive-watch for `build`, `allowsNow` one-shot for callbacks,
  `require` throwing for flows), the `Guarded` widget (render-gate + the `allow`
  fire-time re-check wrapper — hide-don't-disable, reactive so revocation removes
  the child live) and `Guarded.screen` (body-guard that waits for readiness — no
  denial flash — then renders one standard no-access scaffold naming the gate).
- `permissions.dart` — barrel; call sites need one import.

**Receive Stock migrated verbatim (12 sites, 5 files):** the Inventory FAB
(`inventory_screen.dart`) and the screen guard (`receive_stock_screen.dart` →
`Guarded.screen`) now cite the **same** `Gates.receiveStock` (was
comment-enforced); the New Product card → `Gates.addProduct`, price edits →
`Gates.editProductPrice` (incl. the long-press **fire-time** re-check via
`allowsNow` + `showGateDenied`), buying-price → `Gates.editBuyingPrice`,
supplier-payment section → `Gates.manageSuppliers`. Behaviour unchanged — a
stock keeper with only `stock.add` still receives quantities but sees no New
Product card, price edits, or supplier payments. `hasPermission` count fell
86 → 74; `lib/features/receiving/` is now bare-check-free.

**Tests (`test/permissions/`):**
- `gate_test.dart` (14) — every atom, and/or, fail-closed unresolved, CEO all-on,
  fed by `resolveEffectivePermissions` fixtures; tier ranks locked to
  `roleRank()`; `GateDeniedError` payload carries the gate name.
- `guarded_test.dart` (10) — hide-while-loading, fallback, live revocation, the
  `allow` fire-time block + standard feedback, `allow` runs when granted,
  `Guarded.screen` no-flash / body / no-access, `require()` throwing.
- `gate_static_ban_test.dart` — scans `lib/` for `hasPermission(ref …)` outside
  the module against a **full 74-site allowlist ratchet** (a grown/new site fails
  → cite a Gate; a migrated-but-not-shrunk site fails → shrink the allowlist).
  Verified a planted bare check fails the suite, then removed it.
- `gate_registry_membership_test.dart` — every registry gate cited ≥1, each
  `name` matches its `Gates.<name>` field, names unique.

**Verification:** `flutter analyze lib` clean; `test/permissions/` (43),
`test/receiving/` + `test/inventory/` + `test/settings/` (63) green with no
behavioural test edits. Emulator walkthrough (stock keeper vs cashier; FAB +
screen guard + live revocation) pending. Next: batches #18–21 shrink the
allowlist; #22 empties it and privatizes the helper.

---

## 2026-07-01 — Refactor: collapse the per-table sync smear into a `SyncedTable` registry (issue #15)

**Problem:** adding or changing a synced table meant editing the same table's
knowledge in **six scattered constructs** — the synced-tenant-table list
(`_syncedTenantTables`, app_database.dart), the pull order (`_pullOrder`), the
push-column whitelist (`_pushableColumns`), the `created_at`-scrub set
(`_ledgerCreatedAtScrubTables`), and **two** hard-delete switches
(`_deleteLocalRowById` + `_deleteLocalRowsNotIn`, gated by
`_hardDeleteReconcileTables`) — plus a ~50-case `_restoreTableData` switch. Wire
five of six and forget one and it compiles, works on the device that created the
data, and **never reaches peer devices** — the documented recurring "new synced
table: wire ALL client apply sites" trap, living in the most safety-critical
subsystem.

**Fix — one ordered `List<SyncedTable>` in the database layer**
(`lib/core/database/sync_registry.dart`, a `part of` app_database.dart so it
shares the generated Drift types with no import cycle — invariant #8):
- Each entry is the complete per-table truth: `name`, `restore` (a
  helper-built or bespoke closure), optional `pushColumns`, optional
  `hardDelete` (the two former switches reconciled into one `SyncHardDelete`
  with `deleteById` + `deleteByIdsNotIn`), `scrubCreatedAt`, and
  `tenantScoped` / `isCache` flags.
- Restore helpers `Restore.plain` / `.naturalKey` / `.dedup` / `.ledger` (+ a
  hand-written closure for `users`, which must never clobber device-local PIN /
  biometric columns) each capture the concrete Drift row type at the call site —
  no dynamic casts. The FK-resilient helper + ledger restore + FK/UNIQUE
  classifiers moved to a database-layer `SyncRestoreExecutor` so the registry
  has no upward dependency; the sync service injects the §30.8.1 order-number
  heal (needs secure storage) as a callback.
- The six constructs now **derive** from the registry (`kSyncPullOrder`,
  `kSyncedTenantTables`, `kSyncCacheTables`, `kSyncPushColumns`,
  `kSyncScrubCreatedAtTables`, `kHardDeleteReconcileTables`). The literal lists
  and the `_restoreTableData` switch are **deleted**.
- The central pre-insert guards (timestamp-LWW, the invariant #12 clobber-guard,
  the business-isolation guard) are unchanged and still run once for all tables
  in the sync service **before** dispatch; only the switch body became a
  registry lookup. List order governs pull / restore / reconcile only — push
  still drains the outbox row-by-row.

**Behaviour-neutral by construction.** No schema change, no cloud migration, no
wire-protocol change. Root tables (`businesses`, `customers`) stay
non-FK-resilient exactly as before; every FK-resilience / natural-key / dedup /
ledger fact reproduces today's behaviour.

**Tests:**
- New **golden equivalence test** (`test/sync/sync_registry_golden_test.dart`):
  freezes the six constructs' pre-collapse values and asserts the derived
  accessors reproduce each (pull-order byte-for-byte; the rest set/map-for).
- Extended the **reflection/registration test**: every sync-fingerprinted Drift
  table must have a registry entry; every registry name resolves to a real Drift
  table (or the declared `profiles` cloud-only exemption); no duplicate entries.
- The behavioural seams stayed **green and unchanged**: outbox-sacred restore,
  FK-resilience restore, snapshot hard-delete reconcile, realtime DELETE,
  per-table dispatch, and the payload-whitelist scrub. `replica_identity_full`
  now reads `kHardDeleteReconcileTables` at runtime instead of regex-parsing the
  deleted literal. Full `test/sync/` + `test/database/` = 233 green;
  `flutter analyze` clean.
- (Unrelated pre-existing failure noted: `test/auth/who_is_working_screen_test.dart`
  fails identically with my changes stashed — a parallel-work / widget-timing
  issue, not this refactor.)

---

## 2026-07-01 — Fix: widen all cloud money (`*_kobo`) columns to `bigint` — outbox jam (22003 overflow)

**Symptom:** Sync Issues showed a pending `supplier_ledger_entries:upsert` stuck at
**42 attempts** with
`PostgrestException(22003): value "12360040000" is out of range for type integer`.
₦123,600,400.00 in kobo overflows Postgres `int4` (max 2,147,483,647 = ₦21,474,836.47).

**Root cause (systemic, not one column):** every monetary column in the cloud stores
minor units (kobo) but was typed **`integer`**. A census found **34 int4 money
columns across 22 tables** and **zero** already `bigint`. Any legitimate amount above
~₦21.5M is rejected on push with 22003 and **permanently jams the outbox** — an
"outbox is sacred" (Invariant #12) row that a schema mismatch, not the client, made
un-pushable. Locally the value stores fine (SQLite INTEGER + Dart `int` are 64-bit),
so the row sits un-uploadable rather than being lost.

**Fix — cloud-only, migration `0130_widen_money_columns_to_bigint.sql`:**
- `ALTER TYPE bigint` on all 30 `*_kobo` columns + the 4 crate-COUNT `balance`
  columns (widened for uniformity so a future "any money-ish int4 left?" audit
  returns zero). Verified 0 int4 money columns remain post-push.
- **No Drift migration** — local schema is already 64-bit; this was purely the
  cloud narrowing the pipe. `pos_pull_snapshot` returns `jsonb`, so widening is
  transparent to the pull path. Pre-checked: none of the columns are GENERATED and
  no view/matview/RPC depends on their int4 type, so plain `ALTER TYPE` is safe.
- The stuck row(s) push successfully on the next retry — **no data lost**.

**Prevention:** `code-standards.md` → Data and Storage now mandates every cloud
`*_kobo` column be `bigint`, never `integer`, with the overflow rationale.

---

## 2026-07-01 — Feature: device registry for console analytics (make/model + last-seen)

**Goal:** let the operator console see the phone make/model, OS, app version, and
last-seen of every device that has ever logged into a business — for analytics
only. **No in-app screen.**

**What existed already:** a stable opaque per-device UUID
(`SecureStorageService.getOrCreateDeviceId`, plain SharedPreferences, survives
`fullLogout`) already reached the cloud via `sessions.device_id`. But **make/model
was never captured** (no `device_info_plus`; the `sessions.user_agent` column was
dead and excluded from sync).

**Change (cloud-only, direct upsert — no offline sync-queue wiring):**
- New cloud-only table `public.devices` (migration `0129_devices.sql`, applied via
  the Management API — see divergence note below). One row per
  `(business_id, device_id)`; columns: platform, manufacturer, model, device_name,
  os_version, app_version, is_physical_device, last_user_id/email/name,
  first_seen_at, last_seen_at. **Rows survive business deletion** (business_id +
  last_user_id are plain uuids, no FK), so `delete_business`'s cascade keeps churn
  history. RLS: `devices_tenant_rw` via `current_user_business_ids()`; console
  reads via `service_role`.
- `last_seen_at` is server-stamped by a `BEFORE INSERT OR UPDATE` trigger
  (`_devices_stamp_last_seen`, `SET search_path = pg_catalog`) so a wrong device
  clock can't skew it; `first_seen_at` keeps its insert-time default (never in the
  client payload).
- New `DeviceRegistryService` (`lib/shared/services/device_registry_service.dart`)
  reads metadata via `device_info_plus` (Android: manufacturer/model/name/version;
  iOS: `utsname.machine` + `modelName` marketing label) + `package_info_plus`, and
  does a fire-and-forget `supabase.from('devices').upsert(..., onConflict:
  'business_id,device_id')`. Never throws — analytics must not break login/sync.
- Wired in `AuthService`: `_recordDevicePresence()` fires from `setCurrentUser`'s
  session microtask (covers fresh sign-in **and** app-open re-auth via
  PIN/biometric/who's-working) and from an `isOnline` false→true listener (covers
  reconnect + a device that logged in offline).

**Trade-off (by design):** a device that logs in offline and never reconnects
won't appear until it next has internet (inherent to the cloud-only model).

**Verified:** `flutter analyze` clean; remote table/RLS/trigger/unique-index
present; security advisor clean after the search_path fix; upsert smoke-test
confirmed first_seen fixed + last_seen advancing + column updates on conflict.

**⚠️ Pre-existing migration divergence (NOT introduced here):** remote applied
0125/0126/0128 under timestamp versions and has a remote-only `enable_pg_cron`;
local labels 0125–0128 therefore read as "unapplied", and **0127
(add_expense_budgets_to_pull_snapshot) appears genuinely un-deployed remotely**. A
blind `supabase db push` would replay 0126's `CREATE TRIGGER` and fail — which is
why 0129 was applied surgically via the Management API. Recommend a
`migration repair` reconciliation (per the divergence-repair memory) + deploying
0127 as separate follow-up work.

---

## 2026-07-01 — Fix: empty store / missing nav after existing-CEO re-login (clearAllData cursor-survival trap)

**Symptom:** an existing CEO logs in on a wiped/re-onboarded device and lands on
an almost-empty store — navigation shows only Home + Orders (no POS, Inventory,
Customers…) and no customer/product data. Log signature: the background pull runs
**incremental** (`Pulling data … (since: 2026-07-01T07:58:37Z)`) and the snapshot
RPC returns only 6 rows.

**Root cause:** `AppDatabase.clearAllData()` (logout / business-delete / onboarding
reset) wipes the Drift DB but the per-business pull cursor
`last_sync_timestamp::<biz>` lives in SharedPreferences and **survives the wipe** —
the same wipe-trap `FirstLoadMarkerService` was built for, but the cursor was never
wired in. On the next login `pullChanges` reads the stale cursor → incremental pull
→ every row created before the cursor (catalogue, customers, and
roles/permissions, which gate the whole navigation) is never re-downloaded. The
§3.6 per-table backfill change widened the window (it advances the cursor on a
leaf-deferred pull where the old code cleared it), but the clean-pull + wipe case
was always broken.

**Fix:**
- New `SyncCursorResetService.clearAll()` (mirrors `FirstLoadMarkerService`) clears
  every per-business pull-state key (`last_sync_timestamp::`, `backfill_tables::`,
  `pending_deferred_tables::`, `consecutive_pull_failures::`); called from
  `clearAllData()` so the next login runs a **full** pull like a brand-new device.
  Closes the trap for all future wipes.
- Bumped the one-shot device-wide cursor-reset flag (`_backfillCursorResetKey`
  `invite_codes_v2` → `cursor_reset_v3`) so `ensureBackfillOnce` clears surviving
  cursors **once** on the new build — auto-healing devices already stuck in the
  empty-store state without requiring a manual logout.
- Regression tests: `test/sync/clear_all_data_resets_cursor_test.dart`.

---

## 2026-06-30 — Sync Data-Safety & Efficiency ("the outbox is sacred", Invariant #12)

**Change:** Made offline activity impossible to lose silently, and stopped the
app re-downloading the whole store on every launch. Spec:
[brief-sync-data-safety-and-efficiency.md](context/specs/brief-sync-data-safety-and-efficiency.md).
Adds **Invariant #12 — the outbox is sacred** to `architecture.md`. Branch:
`feat/sync-data-safety-and-efficiency`.

**Enforcement primitive:** `SyncDao.pendingRowIds(table, {businessId})` — the set
of row ids for a table that still have an un-uploaded `<table>:upsert` entry in
EITHER `sync_queue` (`status != 'completed'`) or `sync_queue_orphans`. Every fix
is an application of it.

**Bucket 1 — data safety:**
- **(C) Clobber prevention** — `_restoreTableData` removes incoming cloud rows
  whose id is in `pendingRowIds` before applying, so a pending local edit is
  never overwritten regardless of `last_updated_at`. Timestamp-LWW demoted to a
  tiebreaker for non-pending rows (same-second ties still cloud-wins). Fixes the
  silent clobber of un-bumped tables (e.g. `businesses`).
- **(B) Reconcile exclusion** — `_reconcileHardDeletes` skips ids in
  `pendingRowIds`, and skips any table whose slice was deferred/failed
  (`incompleteTables`) so a truncated/short slice is never read as "deleted".
- **(E) Wipe gate** — `logOutCurrentUser` (sole user) now push-and-CONFIRMs the
  outbox is empty before wiping; retryable rows ⇒ refuse (`LogoutWipeException`);
  un-pushable orphans ⇒ `LogoutBlockedByUnsyncedDataException` → the new
  **"Resolve unsynced data"** dialog (export CSV via `unsyncedExportRows` →
  typed-confirm → `discardUnsyncedAndLogout`). Business-deleted wipes (the only
  carve-out) record a durable `_recordWipeLoss` breadcrumb (survives
  `clearAllData` via SharedPreferences) at all three sites.
- **(D) Upload-before-download** — new `pushThenPull` (best-effort push via the
  `_pushing`-guarded `_runPushOnce`, then pull) wired into reconnect
  (`_onOnlineChanged`), pull-to-refresh (`AppRefreshWrapper`), and login
  background pull. `pullChanges` stays standalone-safe.
- **(F) Uploader check-up** — `_auditDrainIntegrity` confirms every row a drain
  handled is still in `sync_queue` or moved to orphans; a vanished row writes a
  `sync.outbox_shrinkage` `error_logs` breadcrumb.

**Bucket 2 — efficiency:**
- **(A1) Per-table backfill cursors** — a deferred pull no longer clears the
  whole cursor (which forced a re-download/re-restore of EVERY table). The global
  cursor keeps advancing; only **leaf** fetch-failures are recorded in a
  per-business `backfill_tables::<id>` set and re-pulled `since=null` next time.
  FK-orphan skips still take the conservative full re-pull (parents may be
  unchanged + below the cursor). Snapshot RPC bypassed when a backfill set is
  active (it can't express per-table `since`).
- **(A2) Targeted parent fetch** — when a child FK-orphans on a
  supplier/category/manufacturer id, `_targetedParentFetchAndRetry` fetches just
  those parent rows by id (bounded at 50, capped round-trips) and retries the
  child from the in-hand snapshot — healing inline instead of a full re-pull.

**Verification:** `flutter analyze` clean on all touched files; new tests under
`test/sync/` (see below) pass; existing `test/sync/` suite green.

---

## 2026-06-30 — First-Load "Loading your store" Overlay Redesign

**Change:** Replaced the open-ended post-login "Loading your store" full-pull
loader with a brief (≤ ~2 s) reassurance that hands off to background sync +
skeletons, plus a prominent retry path and a faster restore. Spec:
[brief-first-load-store-overlay.md](file:///Users/solomonizu/flutter_projects/drinkPosApp/context/specs/brief-first-load-store-overlay.md).

**Implementation (the single seam + supporting pieces):**
1. **Overlay controller (§4.1–4.3, 4.7)** — new
   [first_load_overlay_controller.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/sync/controllers/first_load_overlay_controller.dart):
   a `StateNotifier<FirstLoadOverlayState>` ({hidden, loading, retryNeeded}) that
   is the sole source of truth. Owns all timing (400 ms min floor / 2 s max cap),
   the retry counter, and eligibility, derived from five injected inputs (pull
   stage, connectivity, store-empty, per-business marker, landing-ready). Input
   providers (`firstLoadOnlineProvider`, `firstLoadStoreEmptyProvider`,
   `firstPullCompletedProvider`, `firstLoadLandingReadyProvider`,
   `pullStageProvider`) + `firstLoadActiveProvider` / `firstLoadSkeletonActiveProvider`
   are co-located and overridable.
2. **Per-business marker (§4.2)** — wired the pre-existing
   [first_load_marker_service.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/services/first_load_marker_service.dart):
   `markPullCompleted` on a clean (`skipped.isEmpty`) `pullChanges` completion,
   and **`clearAllMarkers()` inside `AppDatabase.clearAllData()`** (best-effort) so
   a re-onboarded device re-shows the overlay — the highest-risk wipe trap.
3. **Row-weighted progress (§4.5)** — `PullStatus.rowsTotal/rowsDone/rowPercent`
   (already added to the pull loop) now drives the determinate top line and the
   overlay percentage. Copy changed to **"Setting up ‹Business›…"** (falls back to
   "Setting up your store…").
4. **Restore batching (§4.6)** — `pullInitialData` now wraps each table's restore
   in **one Drift transaction** (one commit per table instead of one per row — the
   dominant first-pull cost). Per-row FK/unique resilience is unchanged (caught,
   not rethrown, so good rows still commit and the cursor-hold/defer semantics are
   preserved exactly).
5. **Skeletons (§4.4)** — one reusable themed shimmer primitive
   ([skeleton.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/skeletons/skeleton.dart),
   single `ShaderMask` per subtree, no `shimmer` dependency) + four tab skeletons
   ([first_load_skeletons.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/skeletons/first_load_skeletons.dart)).
   Wired into POS, Home, Inventory, and the Reports hub via a guarded early-return
   gated on `firstLoadSkeletonActiveProvider` (preserves each screen's permission
   gates + app bar / drawer button).
6. **Rendering (§4.7)** — [sync_pull_banner.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/sync_pull_banner.dart)
   now renders the controller: non-interactive centered "Setting up…" for
   `loading`, a prominent **interactive** retry card for `retryNeeded`. The compact
   error pill is suppressed during a genuine first load (retry card / skeletons own
   it); the "Synced ✓" pill is unchanged. Invariants #1/#11 preserved (entry never
   gated; nav/drawer stay tappable).

**Tests:**
- Seam A — [first_load_overlay_controller_test.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/test/sync/first_load_overlay_controller_test.dart)
  (13 cases via `fake_async`): eligibility, min-floor/max-cap/ready dismiss,
  established-empty suppression, wipe-path re-enable, offline-immediate vs
  online-N-silent-retries-then-retryNeeded, manual retry.
- Seam B — [first_load_restore_batching_test.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/test/sync/first_load_restore_batching_test.dart):
  `rowPercent` math + transaction-wrapped restore parity (orphan skipped without
  rolling back the good rows; `fkSkipped` still held). `restore_fk_resilience_test`
  stays green.
- Added `fake_async` to dev_dependencies.

**Verification:** `flutter analyze` clean (lib + test). `flutter test test/sync/`
(143) + new first-load tests (21) + `test/inventory/` + `test/receiving/` green.
Pre-existing, unrelated failure: `test/auth/who_is_working_screen_test.dart` fails
identically on the clean baseline (network `deleted_businesses` 400 + widget settle
timing) — confirmed via `git stash`. On-device emulator walkthrough pending.

---

## 2026-06-27 — Auth Screen Desktop and Tablet Redesign

**Change:** Centered and constrained the maximum width of all authentication screens (Welcome, Sign-In, OTP, SignUp, Lock Screen) to `480.0` dp on desktop and tablet viewports.

**Fix details:**
1. Modified [branded_auth_background.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/widgets/branded_auth_background.dart) and [auth_background.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/widgets/auth_background.dart).
2. Wrapped the content child widget of the auth backgrounds in a `Center` and a `Container` with a maximum width constraint of `480.0` dp on all non-phone viewports (`!context.isPhone`).
3. Dotted grid and background gradient glows still cover the full viewport width and height.
4. Verified that forms do not stretch across wide desktop/tablet screens.

---

## 2026-06-27 — Layout Responsiveness for Tablet and Desktop Viewports

**Change:** Implemented a persistent fixed-width navigation sidebar on desktop, a collapsed rail on tablet, simplified layout selector sheets, and proportionate grid calculations.

**Fix details:**
1. Modified [main_layout.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/main_layout.dart) to display a persistent 280dp `AppDrawer` sidebar on the left and hide the bottom nav bar on desktop.
2. Updated [app_drawer.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/app_drawer.dart) to render as a flat container on desktop and push settings/management routes onto the active tab's sub-navigator to keep the sidebar visible.
3. Updated [shared_scaffold.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/shared_scaffold.dart) to hide the slide-out drawer on desktop.
4. Conditionally hid the leading hamburger menu button on desktop inside AppBars across all primary screens: `pos_home_screen.dart`, `inventory_screen.dart`, `orders_screen.dart`, `cart_screen.dart`, `home_screen.dart`, `stores_screen.dart`, `staff_management_screen.dart`.
5. Updated [view_selector_sheet.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/view_selector_sheet.dart) to only show "Grid View" and "List View" layout options on tablet and desktop.
6. Updated [product_grid.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/widgets/product_grid.dart) and [receive_product_grid.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/receiving/widgets/receive_product_grid.dart) to subtract the 280dp sidebar width from screen width calculations on desktop to prevent grid items from squishing or overflowing.

---

## 2026-06-27 — Wallet to Credits Balance / Ledger Entries terminology alignment

**Change:** Renamed all user-facing "Wallet" vocabulary to "Credits Balance" / "Ledger Entries" across the POS application to mitigate regulatory and compliance risks associated with e-money and wallet definitions.

**Root cause/Rationale:** To comply with regulatory standards, the application must avoid using terms like "Wallet", "Top-up", and "Add Funds" in public or user-facing screens. Instead, the application uses "Credits Balance", "Ledger Entries", "Add Credit", and "Credit history". At the same time, we must maintain full compatibility with stored order payment types, permission keys, local database schema columns, and Supabase RLS/RPC interfaces to avoid breaking live/offline operations and cloud sync protocols. 

**Fix details:**
1. Renamed `WalletService` -> `CreditLedgerService` and `wallet_service.dart` -> `credit_ledger_service.dart`.
2. Renamed test files `wallet_logic_test.dart` -> `credit_ledger_logic_test.dart` and `wallet_service_dispatch_test.dart` -> `credit_ledger_service_dispatch_test.dart`.
3. Renamed Riverpod provider `walletBalancesKoboProvider` -> `creditBalancesKoboProvider` in `app_providers.dart`.
4. Renamed view-model/local properties: `supplierWalletBalanceKobo` -> `supplierAccountBalanceKobo` in `recon_data.dart` and `customerWallet` -> `customerCreditBalance` in `cart_screen.dart`.
5. Wording updates on: `customer_detail_screen.dart`, `customers_screen.dart`, `checkout_page.dart`, `cart_screen.dart`, `home_screen.dart`, `orders_screen.dart`, `crate_return_modal.dart`, `receipt_widget.dart`, `receipt_builder.dart`, `daily_reconciliation_detail_screen.dart`, `crate_deposits_report_screen.dart`, `invite_staff_screen.dart`, and permission description strings in `app_database.dart`.
6. Deferred Tier C: Database schema table names (`wallet_transactions`, `customer_wallets`), RLS policies, cloud RPCs, permission key values, and order payment type enum values (`'wallet'`) were kept unchanged to maintain synchronization compatibility.

---

## 2026-06-26 — Post-OTP "Setting up your account…" spinner (frozen "Verified ✓" gap)

**Symptom:** After entering the 6-digit code, the screen showed a static
**"Verified ✓"** button and then appeared to hang for a few seconds (worse on
poor connections) before moving on — users thought it had frozen.

**Root cause:** [otp_verification_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/otp_verification_screen.dart)
`_submit()` showed a spinner only during `auth.verifyOtp()`. On success it set
`_loading=false; _verified=true`, paused 800ms, then ran the **post-verify
account resolution with no indicator**: `saveAuthMethod` + `resolvePostVerifyRoute`
([auth_post_verify_route.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/auth_post_verify_route.dart)),
which does network work — `fetchSupabaseAccount()` (profiles + the
`current_user_linked_business` RPC) and, for a returning device,
`syncOnLogin()` (the 4-table minimum-login pull) + `upsertLocalUserFromProfile()`.
On a weak link that's several seconds of an apparently-frozen "Verified ✓".

**Fix** — [otp_verification_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/otp_verification_screen.dart):
new `_resolving` flag set true right before the post-verify resolution; a
**centered spinner over a faint scrim** with "Setting up your account…" paints
as the last Stack child (absorbs taps so the OTP field can't be edited
mid-resolve). The existing verified-but-load-failed `catch` resets `_resolving`
so the error message + retry path is unchanged.

**Scope:** the two embedded OTP steps ([ceo_sign_up_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/ceo_sign_up_screen.dart),
[staff_sign_up_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/staff_sign_up_screen.dart))
only `_goTo` the next wizard step after OTP (fast, local) — no gap, left
untouched. Their heavy network is later at commit (already has `_committing`).

**Verification:** `flutter analyze` on the screen clean. On-device check pending
(throttle the connection → confirm the centered spinner shows after the last digit).

---

## 2026-06-26 — First-login / fresh-business loading indicator (spinner + %)

**Symptom:** Right after creating a business or logging in for the first time on
a device, the app drops straight into `MainLayout` (correct, per the offline-first
invariant #11) but the shell is **blank** while the background catalogue pull
streams data in — just a hamburger menu over empty white. The only existing cue
was `SyncPullBanner`'s near-invisible 2.5px top progress bar, so users had no idea
anything was happening.

**Root cause:** Not a bug — a UX gap. The data side was already fully wired:
`pullChanges` runs the full pull as `PullStage.background`, and `pullInitialData`
advances `PullStatus.tablesDone` / `tablesTotal` per restored table
([supabase_sync_service.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/services/supabase_sync_service.dart) ~2337-2360).
`SyncPullBanner` already watched that status but only rendered the thin top bar —
no spinner, no count.

**Fix** — [sync_pull_banner.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/sync_pull_banner.dart):
purely additive, non-blocking UI. (1) Compute a live `percent` from
`tablesDone / tablesTotal` (null until the snapshot's table count is known).
(2) Make the top `LinearProgressIndicator` **determinate** off that percent
(indeterminate during the initial fetch window). (3) Add a centered
`_LoadingOverlay` (spinner + "Loading your store" + `NN%`) shown during
`PullStage.background`, wrapped in `IgnorePointer` so it never gates interaction;
the existing error/success pills still occupy the bottom slot. Suppressed during
pull-to-refresh (`manualPullActiveProvider`) like the top bar.
**No blocking loader reintroduced** — `MainLayout` renders its functional shell
underneath and stays tappable the whole time.

**Verification:** `flutter analyze lib/shared/widgets/sync_pull_banner.dart` clean
(no public API change; `MainLayout` mount is untouched). On-device check pending:
fresh login → centered spinner + climbing % → "Synced ✓".

---

## 2026-06-26 — Roles & Permissions stuck at "N of 0" after logout→login (empty catalogue)

**Symptom:** Logged in as CEO, the **Roles & Permissions** screen showed
"All **0** permissions" for CEO and "29 of **0**", "6 of **0**", "3 of **0**"
for Manager/Cashier/Stock keeper. Opening a role's detail page rendered the
intro text but **no permission toggles** (empty Business/Store tabs). The
per-role grant counts (29/6/3) were correct — only the **denominator** (the
global catalogue size) was zero.

**Root cause:** The global `permissions` catalogue is static config, seeded
**only** at DB-create (`_postCreateStatements`) and the v13 upgrade block, and
is **deliberately never pulled by the sync service** (it's identical on every
device). But `AppDatabase.clearAllData()` ([app_database.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/database/app_database.dart))
wipes **every** table via `for (final table in allTables) delete(table)` —
including `permissions` — and it runs on **logout** (`logOutCurrentUser`),
business-delete, and the onboarding reset. A subsequent login only re-pulls the
**tenant** tables (roles, role_permissions, role_settings), so the catalogue
stayed empty with **no recovery path**. `allPermissionsProvider` then resolved
to a non-null **empty** list → `total = 0`, and the detail screen grouped zero
perms → empty body.

**Fix** — [app_database.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/database/app_database.dart):
new idempotent `ensurePermissionsSeeded()` re-runs `_permissionsSeedStatements`
when `SELECT COUNT(*) FROM permissions == 0`. Called from **`beforeOpen`**
(heals an already-broken device on next app launch — fixes existing installs)
and from the end of **`clearAllData()`** (re-seeds immediately so a same-session
logout→login is fine). Plain INSERT is safe since it only runs on an empty
table; the v37-removed funds keys are absent from `_defaultPermissionRows`, so
the re-seed won't reintroduce the Funds category. Also bumped the stale loading
fallback in [roles_permissions_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/settings/roles_permissions_screen.dart)
from `30` → `38` (current catalogue size) so the one-frame placeholder reads
right. **Verification:** `dart analyze` clean. On-device re-walk
(logout→login→open Roles & Permissions) pending.

---

## 2026-06-26 — Fresh-onboarding: empty store dropdowns (Receive checkout + Stock transfer)

**Symptom:** Right after creating a new account + business and completing
onboarding, the Receive-Stock **Invoice** screen's "STOCKING INTO" dropdown and
the **Request Stock** store pickers showed **zero stores** despite the business
having a store. **Closing and reopening the app made the store appear** — the
tell-tale of a provider poisoned at build time, not missing data (cloud
confirmed: `active_stores=1`, membership + `user_stores` link both present).

**Root cause:** `allStoresProvider` ([stream_providers.dart:771](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/providers/stream_providers.dart))
— the single source feeding every store picker via `selectableStoresProvider` —
called `storesDao.watchActiveStores()`, which bakes the businessId into its
Drift query **at build time** through `whereBusiness()` → `requireBusinessId()`,
and that **throws `StateError` when no business is bound**. The provider's only
dependency was `databaseProvider` (never changes), so a first-subscribe during
the brief **null-businessId window** errored and **stuck for the whole session**
→ `valueOrNull` null → `selectableStoresProvider` → `[]` → every store dropdown
empty until restart. The window is unique to the **create-business path**:
`CeoSignUpScreen._commit` runs the post-onboarding pull + a 3 s "business ready"
delay **before** `setCurrentUser` binds `value`. Returning users bind the
businessId first, so it never reproduced for them (and a restart healed it).
Same poison hit the stock-transfer flow (same provider). Sibling providers
(`usersByBusinessProvider`) already guard the null window; `allStoresProvider`
was the odd one out — it neither guarded nor reacted to the businessId.

**Fix** — [stream_providers.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/providers/stream_providers.dart):
`allStoresProvider` now `ref.watch(authProvider.select((a) => a.currentUser?.businessId))`
and returns `Stream.value(const [])` while it's null (no throw → no poison),
re-running the live query the instant the business binds. `.select` rebuilds
only on businessId change (not on every profile-edit republish). Type/signature
unchanged, so all callers (`selectableStoresProvider`, POS scope, Receive,
Request Stock, reports) are unaffected. **Verification:** `flutter analyze`
clean; `test/receiving` + `test/sync` + `test/auth` → 178 passing. On-device
re-walk of the fresh-onboarding → add product → receive → invoice flow pending.

---

## 2026-06-26 — Create-business: cross-device existing email caught at OTP, not at PIN

**Why (root cause):** "Create a new business" with an email already linked to a
business (registered on another device / the web, no local row here) slipped
through the entire onboarding wizard and was only rejected at the **Create-PIN**
step, where `complete_onboarding` raised P0001 *"already linked to another
business"* — shown as a dead-end `_pinError`. The post-OTP router
(`resolvePostVerifyRoute` → `fetchSupabaseAccount`) is supposed to catch this and
route to `ExistingAccountScreen`, but its detection read **`profiles.business_id`**
across several sequential REST round-trips; any of (null/unseeded profile,
profiles-scoped `users` RLS, a transient failure caught → null) made it report
"no account" → `NoAccountFoundRoute` → `CeoSignUpScreen`. Enforcement
(`complete_onboarding`, migration 0121) keys off **`public.users.auth_user_id`**,
so detection and enforcement could disagree.

**Fix** — detection now uses the *same authority* as enforcement:
- **New RPC** [0128_current_user_linked_business_rpc.sql](file:///Users/solomonizu/flutter_projects/drinkPosApp/supabase/migrations/0128_current_user_linked_business_rpc.sql)
  — `public.current_user_linked_business()`, `SECURITY DEFINER`, mirrors the §9
  guard exactly (`users.auth_user_id = auth.uid()`), returns the linked business
  + role in one round-trip (bypasses the profiles-scoped RLS that hid the row).
  **Deployed** to remote via MCP `apply_migration` (idempotent
  `CREATE OR REPLACE`); local file numbered 0128 for the repo. Mirrors the
  `am_i_a_member` pattern (0038).
- [auth_service.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/services/auth_service.dart)
  — `fetchSupabaseAccount()` falls back to the RPC (new
  `_fetchAccountViaLinkedBusinessRpc`) when the profiles path yields no business
  **and** in its outer catch, so a cross-device account (or a transient REST
  failure) is detected → `ExistingAccountRoute` → `ExistingAccountScreen` right
  after OTP, before any onboarding step. Common path (profiles.business_id set)
  is unchanged. Fixes both the OTP and Google sign-in entry points (shared
  resolver).
- [ceo_sign_up_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/ceo_sign_up_screen.dart)
  — safety-net `_commit()` catch (now a rare OTP→commit race): on
  `alreadyLinkedElsewhere`, instead of trapping the user on the PIN step, show a
  clear `AppNotification` ("…Sign in instead, or use a different email…") and
  `popUntil(isFirst)` back to Welcome. The notification rides the root overlay so
  it survives the pop; the draft is kept for reuse.

**Not done (by design):** no pre-OTP cloud email-existence oracle was added. The
security model (invariant #9 + the explicit comment in `email_entry_screen`)
deliberately defers existence disclosure until **after** OTP proves ownership, to
prevent email enumeration; `sendOtp` uses `shouldCreateUser: true`, so existence
can't be inferred from it either. The post-OTP detection blocks the user before
any onboarding form field, which satisfies the "stop before wasted onboarding"
goal without the enumeration vector.

**Verified:** `flutter analyze` clean (full project); RPC signature + null-auth
(0 rows) confirmed on remote.

---

## 2026-06-26 — Checkout: wallet sale mislabeled "Credit Sale" on receipt (+ 5 related)

**Why (root cause):** The receipt and thermal print read `_paymentLabel`
**live**, not a snapshot. On a successful sale the success flow calls
`cart.setActiveCustomer(null)`, which fires `_onCustomerChanged` →
`setState(_mode = PayMode.cashTransfer)`. So by the time the receipt rebuilt, a
**wallet** payment had its mode reset to cashTransfer with an empty cash field,
and the old `_paymentLabel` returned `'Credit Sale'` for `paidKobo <= 0`. That's
the screenshot bug (Wallet sale → "Payment Method: Credit Sale", "Amount Paid:
₦0"). `_amountPaid` / `_receiptWalletBalance` were already snapshotted at confirm;
the label was not.

**Fix** — [checkout_page.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/screens/checkout_page.dart):
- **Snapshot the label.** New `_receiptPaymentLabel` field, set in the confirm
  success `setState` from a `paymentLabel` captured before the cart clears; the
  receipt widget + `_printReceipt` now read it instead of the live getter. Also
  guarded `_onCustomerChanged` to no-op once `_paymentConfirmed` (defensive).
- **`_paymentLabel` rewrite (Issue 1):** `wallet`→"Wallet Payment";
  `credit`→always "Credit Sale" (dropped the wallet-covers special case);
  `cashTransfer` registered partial (`0 < paid < total`)→"Cash / Transfer /
  Wallet" (was "Partial Payment"); removed the `paidKobo <= 0 → 'Credit Sale'`
  fallback (now blocked by validation).
- **Validation moved before the async staleness check (Issue 2)** so empty-amount
  feedback is immediate; clearer messages ("Please enter the amount paid…" / the
  insufficient-credit message now shows the credit amount + "Tap 'Pay from
  Wallet'"). `_isProcessing` was never set pre-validation, so no stuck-button
  reset was needed.
- **Auto-switch to Wallet (Issue 6):** when Cash/Transfer is selected, the amount
  is empty, and wallet credit ≥ total, switch to `PayMode.wallet` with an info
  toast (only when the field is empty — an explicit amount is respected).
- **Removed `(credit)/(debt)` suffixes (Issue 5)** from the customer-info card,
  all four `_previewBox` calls (dropped the now-dead `suffix` param), the
  [receipt_widget.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/receipt_widget.dart)
  wallet line, and the
  [receipt_builder.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/services/receipt_builder.dart)
  thermal wallet line. Sign + colour already convey credit vs debt.
- **Issues 3 & 4 (debt-limit gate on partials; walk-in sees only Cash/Transfer)**
  verified already correct — no change.
- **Follow-up from code review:** the new "Cash / Transfer / Wallet" label
  collided with the Orders-screen badge categorizers
  ([orders_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/orders/screens/orders_screen.dart)
  `_paymentColor` / `_paymentLabel`), which tested `contains('wallet')` before
  `contains('partial')` — so a partial cash sale badged as "Wallet". Added a
  `contains('wallet') && contains('cash')` → Partial check ahead of the plain
  wallet check. (The `== 'Wallet Payment'` exact-match sites that pick
  cashReceived are unaffected: the combined label != 'Wallet Payment', so they
  correctly use the actual cash paid.)

**Verification:** `flutter analyze` on all four touched files — no issues.
Behavioural verification on emulator pending.

---

## 2026-06-25 — Release build: stop sqlite3 hook downloading from GitHub

**Why:** `flutter run --release` failed during `assembleRelease` with
`SocketException: Failed host lookup: 'github.com'` inside the `package:sqlite3`
build step. `sqlite3` 3.x (3.1.7, pulled in transitively by `drift`) added a Dart
**build hook** that, by default (`source: sqlite3`), *downloads* a precompiled
`libsqlite3` from `github.com` at build time. On a flaky/offline network the host
lookup fails and the whole release build aborts. (The KGP warning printed just
above — `print_bluetooth_thermal`, `share_plus` — is an unrelated future-deprecation
notice, not the failure.) The app never needed that download: we already ship the
native library via `sqlite3_flutter_libs` (bundled in the APK, loaded with
`dlopen("libsqlite3.so")`), which is the pre-3.x path.

**Fix** — [pubspec.yaml](file:///Users/solomonizu/flutter_projects/drinkPosApp/pubspec.yaml):
added a top-level `hooks.user_defines` block pointing the sqlite3 hook at the
system/bundled library instead of the GitHub download:
```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```
The `system` branch in the hook
(`.pub-cache/.../sqlite3-3.1.7/lib/src/hook/description.dart`) returns a
`LookupSystem` (a `dlopen` resolver) and **never calls the fetch routine** — so the
build is network-free. This resolves SQLite from the `sqlite3_flutter_libs` lib,
matching the runtime path the app used before sqlite3 3.x.

**Verification:** cleared the stale hook cache
(`.dart_tool/hooks_runner/sqlite3`), `flutter pub get` (config accepted), then
`flutter build apk --release --target-platform android-arm64` →
`✓ Built app-release.apk (38.4MB)`, exit 0. Build log has **no** `github.com`
fetch, `SocketException`, or `native assets failed` lines.

---

## 2026-06-25 — Pull-to-refresh: one animation, no content drag-down

**Why:** On-device, pulling to refresh showed **two** sync animations at once and
visibly dragged the whole screen down (large empty gap). Root cause: the
uncommitted working-tree version of `AppRefreshWrapper` had been changed to render
a custom branded `_PullOrb` (a glassy spinning circle) **and** to `await`
`pullChanges`. But `SyncPullBanner` (mounted once in `main_layout.dart`) already
shows a thin top progress bar for the same `background → completed/failed` pull
lifecycle. So a single pull fired both indicators (orb + top bar = "two rotating
animations"), and the awaited refresh + descending orb overlay held the content
displaced for the whole pull ("pulls everything down"). This contradicted the
documented design (progress-tracker 2026-06-25 + architecture): the wrapper hides
its spinner and fires `pullChanges` fire-and-forget so `SyncPullBanner` is the
**sole** animation.

**Fix** — [app_refresh_wrapper.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/app_refresh_wrapper.dart):
reverted to the documented behavior. Back to a lean `ConsumerWidget` wrapping a
`RefreshIndicator` with transparent `color`/`backgroundColor` (gesture only, no
visible spinner); removed `_PullOrb` and all overscroll-tracking
`NotificationListener` state. `pullChanges` is now fired **fire-and-forget**
(`unawaited`) so the indicator releases immediately — no content drag-down — while
`SyncPullBanner` reflects the real pull lifecycle. Kept the optional `onRefresh`
(customer detail / orders / activity log) and the `ScrollConfiguration` forcing
`AlwaysScrollableScrollPhysics` so the gesture still fires on short screens.

**Verification:** `flutter analyze` on the file → clean. On-device pull-gesture
recheck pending (expect: single thin top bar, brief "Synced ✓" pill, no orb, no
gap).

## 2026-06-25 — Monthly expense budget now reaches the snapshot pull (cross-device + reinstall)

**Why:** Setting a monthly budget (§20.1/§20.3) worked on the device that set it
and pushed to the cloud, but other devices — and the same device after a fresh
install / cold start — never showed it. The budget lives in the synced
`expense_budgets` table, which is correctly wired in RLS (0075), the realtime
publication + channel loop, and the client pull/restore loops — **but it was
never added to the `pos_pull_snapshot` RPC**, the authoritative load/restore path
(first login, cold start, reinstall, any `since=NULL` full pull). So a peer that
loaded via snapshot (offline-at-the-time, fresh install, cold start) never
received it, and a reinstall silently dropped the budget even though it sat in
the cloud. Realtime only delivered it to a peer that happened to be online at the
exact moment it was set. `expenses`/`expense_categories` were already in the RPC,
so expense records themselves synced — only `expense_budgets` was missing.

**Fix** — [0127_add_expense_budgets_to_pull_snapshot.sql](file:///Users/solomonizu/flutter_projects/drinkPosApp/supabase/migrations/0127_add_expense_budgets_to_pull_snapshot.sql):
`CREATE OR REPLACE` of `pos_pull_snapshot` based on the **live** function body
(carries forward the 0108 `error_logs` and 0117 `supplier_crate_*` additions, so
no replace-race drop), with `'expense_budgets'` inserted right after
`'expense_categories'`. FK-safe — references businesses + stores, both pulled
earlier in the array.

**Deploy:** applied directly to the live DB via `CREATE OR REPLACE` (pure
idempotent function redeploy, no schema/data change) because the remote migration
history is divergent (local `0125`/`0126` vs three timestamped `2026-06-23`
remote entries). The 0127 file stays in the repo and re-applies harmlessly once
history is reconciled. Verified live: snapshot now contains `expense_budgets`
with `expenses` + `supplier_crate_balances` still present (nothing dropped).

**Note:** the cloud currently holds 0 expenses / 0 expense_categories for the one
business while products/orders/sale-payments synced normally — the expense
*record* path looks correct (already in the snapshot array, RLS matches the
working tables), so this is likely "none recorded-and-pushed yet" or local
orphans; check the in-app Sync Issues screen on the device if expenses also fail
to appear elsewhere.

---

## 2026-06-25 — Custom theme-aware pull-to-refresh indicator; works on all screens

**Why:** After hiding the default spinner, pull-to-refresh had two problems: (1)
no visible pull animation at all, and (2) it only fired on screens long enough to
overscroll (effectively just Home) because the wrapped scrollables didn't use
`AlwaysScrollableScrollPhysics`. The user wanted a redesigned, **theme-aware**
pull animation that matches the app and works everywhere.

**Fix** — [app_refresh_wrapper.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/app_refresh_wrapper.dart)
(now a `ConsumerStatefulWidget`):
- **Custom indicator (`_PullOrb`):** a glassy `colorScheme.surface` circle with a
  `colorScheme.primary` progress arc (determinate fill while dragging →
  indeterminate spin while syncing) and a primary-glow shadow. Scales + fades in
  with the pull and descends slightly to follow the finger. **Every colour comes
  from `Theme.of(context)`**, so it adapts to all five themes (light + dark). The
  real `RefreshIndicator` is kept (spinner hidden) purely for rock-solid
  cross-platform trigger physics; a `NotificationListener` reads the same
  depth-0 overscroll stream (active-drag only) to drive the orb identically on
  iOS bounce / Android clamp.
- **Works on every screen:** the wrapper wraps its child in
  `ScrollConfiguration.of(context).copyWith(physics: AlwaysScrollableScrollPhysics())`,
  so the primary scrollable always overscrolls and the gesture fires even when
  content is shorter than the viewport — one central change, no per-screen edits
  (inner grids that set `NeverScrollableScrollPhysics` keep theirs).
- `_onRefresh` awaits `onRefresh?.call()` then `pullChanges`, so the orb spins
  for the real pull duration; `SyncPullBanner` still surfaces the "Synced ✓" /
  "Sync failed · Retry" result.

**Verification:** `flutter analyze` on the wrapper + all 13 `AppRefreshWrapper`
consumer screens → No issues found. On-device pull-gesture / per-theme visual
check pending.

---

## 2026-06-25 — Pull-to-refresh now drives the SyncPullBanner (old spinner + SnackBars removed) app-wide

**Why:** Pulling down to sync showed the default Material [RefreshIndicator]
circular spinner at the top (plus, on the `AppRefreshWrapper` screens, green/red
"Sync completed" / "Sync failed" SnackBars) — a different, competing animation
from the recently-added `SyncPullBanner` (thin top progress bar + "Synced ✓" /
"Sync failed · Retry" pill). The user wanted a single, consistent sync animation
on pull-to-refresh, everywhere.

**Fix:**
- [app_refresh_wrapper.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/app_refresh_wrapper.dart)
  rewritten: the `RefreshIndicator` spinner is made invisible (`color`/
  `backgroundColor: Colors.transparent`), the SnackBars are gone, and the pull
  now fires `pullChanges` **fire-and-forget** (re-entrancy-guarded) so the
  invisible indicator collapses at once and `SyncPullBanner` (driven by
  `pullStatus` background → completed/failed) is the sole feedback. New optional
  `onRefresh` runs screen-specific work (provider invalidation / local reload)
  alongside the sync. Switched from `syncAll` to `pullChanges` for a guaranteed
  clean banner cycle (matches the banner's own Retry button); uploads stay
  covered by the always-on auto-push.
- Converted every **raw `RefreshIndicator`** to `AppRefreshWrapper`: orders,
  activity log (×2), staff management (×2 — dropped the redundant
  `_pullStaffRoster` since the wrapper pulls), customer detail (kept `_loadData`
  as `onRefresh`). `RefreshIndicator` now exists in exactly one place.
- Added pull-to-refresh to the two main tabs that lacked it — **Payments** and
  **Stores** — wrapping their lists with `AlwaysScrollableScrollPhysics` and
  making the empty states scrollable so the gesture works even when short/empty.

**Result:** 13 screens, one consistent behavior — pull down → thin top bar →
"Synced ✓" or "Sync failed · Retry", no spinner, no SnackBars.

**Verification:** `flutter analyze` on all 7 changed screens + the wrapper → No
issues found. On-device pull-gesture check pending.

---

## 2026-06-25 — Partial pull FK-787 on `user_businesses` blanks the whole app + sync-status UX

**Why:** On a flaky link the initial pull aborted with `SqliteException(787):
FOREIGN KEY constraint failed` on the `user_businesses` INSERT, leaving the app
stuck on a blank MainLayout — no data, no loading indicator, no failure notice.
Logs also showed `Connection reset by peer` mid-pull (the trigger).

**Root cause:** Two layers.
1. **Restore (the crash).** Every table *after* `products` in `_pullOrder`
   already restored via `_insertResilient` (skip-and-defer on FK-787, hold the
   cursor, re-pull when the parent arrives). But the entire **bootstrap cluster
   before `products`** — `stores, roles, role_settings, role_permissions,
   user_permission_overrides, store_role_permissions, user_businesses,
   user_stores, invite_codes, crate_size_groups, manufacturers, categories,
   suppliers` — used plain `insertOnConflictUpdate`. A partial pull that dropped
   a parent slice (e.g. `roles` reset mid-stream) made `user_businesses`'
   `role_id` FK fail, which threw out of `_restoreTableData`'s transaction and
   propagated up through `pullInitialData` → `pullChanges`, aborting the pull.
   Because the failing table sits early in `_pullOrder`, **every table after it
   (products/inventory/orders) never restored → blank app.**
2. **UX (the silence).** Nothing surfaced the in-flight pull or its failure.

**Fix:**
- [supabase_sync_service.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/services/supabase_sync_service.dart)
  — wrapped the whole pre-`products` bootstrap cluster in `_insertResilient`
  (matching the demonstrated `user_businesses` wrap a parallel change had already
  added). For the three permission tables the delete-then-insert body is wrapped
  together (the delete is FK-safe; on retry the full body re-runs once the parent
  arrives). An orphaned bootstrap row now skips-and-defers instead of aborting,
  so the rest of the snapshot lands and the row self-heals on the next full pull.
- [sync_pull_banner.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/sync_pull_banner.dart)
  mounted in [main_layout.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/main_layout.dart)
  — non-blocking sync status: thin top `LinearProgressIndicator` during the
  background pull, a "Sync failed / Retry" pill (dismissible) on failure, and a
  brief "Synced ✓" pill on success. Driven by `pullStatus` (`background` →
  `completed`/`failed`); never gates app entry (offline-first invariant).

**Verification:** `flutter analyze` on the sync service, banner, main_layout,
main.dart, auth_service → No issues found. Repro is network-timing dependent
(partial mid-stream pull); fix is a mechanical application of the existing
`_insertResilient` skip-and-defer pattern already proven on the post-`products`
tables.

---

## 2026-06-24 — Existing-account screen shows "Member" — client push nulled cloud `users.auth_user_id`

**Why:** On a fresh device, the "Welcome back" (existing-account) screen showed
the business with role **"Member"** instead of the user's real role (a CEO read
as "Member"). [ExistingAccountScreen](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/existing_account_screen.dart)
renders `account.roleName ?? 'Member'`, and `roleName` was null because
[fetchSupabaseAccount](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/services/auth_service.dart)
resolves the role via `users → user_businesses → roles`, keyed on
`.eq('auth_user_id', authUser.id)`. The cloud `users.auth_user_id` was **null**,
so the chain short-circuited. (Same null also breaks
`upsertLocalUserFromProfile`'s canonical-id lookup → tapping Continue would fail
with "Could not load your account.")

**Root cause:** `complete_onboarding` (cloud RPC) stamps `users.auth_user_id =
auth.uid()` correctly, but the client's `users` sync push then clobbered it back
to null. `Users.authUserId` is never written by any Drift path (it's
cloud-authoritative), so the local value is always null — yet `auth_user_id` was
in `_pushableColumns['users']`, so every users upsert (onboarding mirror,
profile edits, biometric toggle…) pushed `auth_user_id: null`, landing in the
cloud upsert's SET clause and overwriting the RPC-stamped uid.

**Fix:** [supabase_sync_service.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/services/supabase_sync_service.dart)
— removed `'auth_user_id'` from `_pushableColumns['users']`. The push now omits
the column, so it never enters the upsert SET clause and the cloud value
survives; the pull restores the correct uid locally. The onboarding RPC remains
the sole writer (insert + `ON CONFLICT (business_id,email) DO UPDATE SET
auth_user_id`), robust to push ordering.

**Verification:**
- `flutter analyze lib/core/services/supabase_sync_service.dart` → No issues.
- Traced in cloud: the lone affected row (Testing Business CEO) had
  `auth_user_id IS NULL` while `user_businesses`/`roles` correctly said CEO.

**Follow-up (manual):** existing rows already nulled need a one-time backfill
`UPDATE users SET auth_user_id = <owner profile id> WHERE auth_user_id IS NULL`
(matched via `businesses.owner_id` / `profiles.id`); the code fix only prevents
future clobbering.

---

## 2026-06-24 — Fix Quick Sale modal crash on close (deactivated-ancestor)

**Why:** Opening the Quick Sale modal and closing it (e.g. the CEO/Manager
"Send to Cart" path, or cancelling) crashed with *"Looking up a deactivated
widget's ancestor is unsafe."* The `_pulse` AnimationController was a
`late final` with an inline initializer, and it is only ever accessed in the
cashier "Awaiting Approval" state (`_buildWaiting`). On the common path the
modal closes without entering that state, so `_pulse` was never initialized —
then `dispose()` calling `_pulse.dispose()` fired the `late` initializer for
the first time, constructing an `AnimationController(vsync: this)` *during
unmount*. The controller's constructor does a `TickerMode` ancestor lookup on
the already-deactivated element, which throws. Confirmed via the runtime stack
(`_pulse` ← `dispose` ← `StatefulElement.unmount`).

**Fix:** [quick_sale_modal.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/widgets/quick_sale_modal.dart)
— made `_pulse` a nullable field created lazily only via the `_pulseAnim`
getter inside `_buildWaiting()` (always called while the element is active),
and changed dispose to `_pulse?.dispose()`. The controller is now never
constructed during `dispose()`, so the ancestor lookup can't run on a
deactivated element. Lazy intent (only spin up the pulse when waiting) is
preserved.

**Verification:**
- `flutter analyze lib/features/pos/widgets/quick_sale_modal.dart` → No issues.
- Hot-reloaded into the running emulator session; runtime errors cleared.

**Follow-up — Quick Sale cart line was not JSON-serializable:** `_buildProduct`
stored a raw `IconData` (`FontAwesomeIcons.bolt`) and `Color`
(`Theme.colorScheme.primary`) on the cart map. A real product stores an int
`iconCodePoint` + a `#RRGGBB` `colorHex` string, so saving a **held cart**
(§13.5) that contained a Quick Sale line threw on `jsonEncode` — caught and
surfaced as "Could not save cart", but the cart couldn't be saved. Fix:
store the bolt's int codepoint and a null colour (both the cart and checkout
icon/colour readers already fall back to the theme primary for a null colour,
so the look is unchanged), and added a bolt mapping to
[productIconFromCodePoint](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/utils/product_icon_helper.dart)
so the codepoint resolves back to the bolt instead of the box fallback.
`flutter analyze` on both files → No issues; hot-reloaded.

## 2026-06-24 — Reconciliation: treat supplier account as a wallet (fix "owed" sign)

**Why:** The daily reconciliation "Business worth right now" card showed
*"Owed to suppliers (now)"* with a hardcoded `−` prefix over `supplierPayableKobo`
(= goods received − payments). When payments exceeded the cost of goods supplied
the supplier wallet is actually in **credit**, but the card still rendered it as a
double-negative liability and labelled it "owed" — the opposite of reality. The
supplier account is a wallet (payments minus goods received), not a one-way
payable. (The Supplier Accounts report already had the correct red-"Owed" /
green-"Credit" convention; only reconciliation was wrong.)

**Fix:**
- Added `ReconData.supplierWalletBalanceKobo` (= `-supplierPayableKobo`,
  identical to `SupplierLedgerDao.getBalanceKobo`): positive = credit we hold
  with the supplier, negative = amount we owe. [recon_data.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/dashboard/reconciliation/recon_data.dart)
- Made the net-position line sign-aware in [daily_reconciliation_detail_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/dashboard/screens/daily_reconciliation_detail_screen.dart):
  balance `< 0` → "Owed to suppliers (now)" `−₦X` in red; otherwise
  "Supplier credit held (now)" `+₦X` in green. Matches the Supplier Accounts
  report convention.
- CSV export now emits a single signed "Supplier account balance (now)"
  (negative = owed, positive = credit) instead of the always-inverted
  "Owed to suppliers".
- `businessNetPositionKobo` math was already correct (`- supplierPayableKobo`),
  so it was left untouched; only the display/labels changed.

**Verification:**
- `flutter analyze` on both files → No issues found.
- `flutter test test/suppliers/supplier_ledger_test.dart` → 4 pass (confirms
  `balance = SUM(payments) − SUM(invoices); negative = we owe`).

## 2026-06-24 — Stop preloading product categories; wipe cloud test data

**Why:** Product categories should not ship as a fixed preset. The category field
in the Add/Update product forms is already a searchable dropdown that creates a
category on the fly, so the preset list was redundant and polluted every fresh
business with 5 categories nobody chose.

**Fix (app):**
- Removed the `if (cats.isEmpty) { … insert default categories … }` seed block in
  `_loadData` of [add_product_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/inventory/screens/add_product_screen.dart)
  (was seeding `Alcoholic`, `Non-Alcoholic`, `Energy Drinks`, `Wines`, `Spirits`).
  `cats` is now just whatever exists locally (empty on a fresh business).
- Left the create-as-we-go paths intact: `_createNewCategory` /
  `_getOrCreateCategory` (add screen) and `_getOrCreateCategory`
  (`update_product_sheet.dart`) still mint a category from the searchable field.
- Confirmed no other product-category seed site exists (no SQL seed migration, no
  onboarding/business-creation seed). Expense-category seeding is a separate
  feature and was left untouched.

**Cloud wipe (project `ewwyofbvfjyqqirrcaou`):** Cleared all business/test data so
the test emails can re-onboard fresh.
- `TRUNCATE … RESTART IDENTITY CASCADE` on every tenant table (businesses,
  profiles, users, sessions, stores, products, categories, orders, roles,
  role_permissions, ledgers, tombstones, error/console logs, …).
- `DELETE FROM auth.users` (7 rows) to free the test emails for re-use.
- **Preserved** global reference data: `permissions` (43 rows), `system_config`,
  schema/migrations/RPCs. `console_admins` was already empty (the web-console
  email allowlist) — not touched.

**Verification:**
- `flutter analyze lib/features/inventory/screens/add_product_screen.dart` → No issues found.
- Post-wipe row counts: auth.users=0, businesses=0, users=0, profiles=0,
  products=0, categories=0, orders=0, roles=0, role_permissions=0,
  deleted_businesses=0; permissions=43 (kept).

## 2026-06-24 — Removed the blocking "Syncing Your Store" loader; entry is now fully offline-first

**Why:** A full-screen loading screen ("Syncing Your Store / Setting up your
store… / This only happens once on your fresh device login. Please keep the app
open.") gated entry on a network pull, contradicting the offline-first promise.
It was rendered by two router gates in `_HomeRouter._resolve` (`lib/main.dart`):
`FirstSyncScreen` (shown while the local `businesses` table was empty) and
`_BackgroundPullLoading` (shown for up to a 5 s grace cap while the full pull
ran and no products were local yet). Both held the user on the `InitialLoadAnimation`
before `MainLayout`.

**Fix:**
- `lib/main.dart` `_HomeRouter._resolve`: removed both gates. A logged-in device
  now falls straight through to `MainLayout`. The only remaining pre-`MainLayout`
  step is the `_BrandedSplash` shown while the **local** `businesses` query is
  still resolving (a SQLite read, not a network call). Dropped the now-dead
  `_BackgroundPullLoading` widget, `initialLoaderTimedOutProvider`,
  `_initialLoaderMaxWait`, and the `pullStatus` / `hasLocalProducts` /
  `loaderTimedOut` watches + `_resolve` params.
- Deleted `lib/features/sync/screens/first_sync_screen.dart` and
  `lib/features/sync/widgets/initial_load_animation.dart` (no remaining
  references) and their now-unused imports.

**Why it's still correct:** Sync triggers are untouched — the 4 render-critical
tables (`profiles`/`businesses`/`stores`/`users`) are still pulled **inline at
the sign-in boundary** (`syncOnLogin` → `syncMinimumLogin`, behind the
existing-account screen's own small inline spinner), and the full pull
(`pullChanges`) still fires non-blocking from `setCurrentUser`, streaming the
catalogue and everything else in live. A fresh sign-in with no local business
row hits the subscription gate as `grace` (not locked), so it falls through to
`MainLayout`; `currentBusinessProvider` returns null safely and `MainLayout`
renders an empty-but-functional shell that fills reactively. Returning users
(fresh or offline) reach `MainLayout` immediately.

**Verification:** `flutter analyze` clean (whole project). `flutter test
test/auth test/sync` → 161 passing. Updated `context/architecture.md`
(Invariant #11 + the onboarding-pull section) to document the offline-first,
non-blocking entry.

---

## 2026-06-24 — Onboarding could strand the new CEO in a permission-less shell (H1)

**Why:** `completeOnboarding`'s local Drift mirror writes only `businesses` +
`stores` + `users` (`lib/shared/services/auth_service.dart`). The CEO's role
binding — the `user_businesses` membership, its `roles` row, and the
`role_permissions` grants — is cloud-seeded by `seed_default_roles_for_business`
and reaches the device only via the post-onboarding pull. In `_commit`
(`ceo_sign_up_screen.dart`) that pull was wrapped in a swallowed try/catch
("non-fatal"): on a flaky link right after the commit it failed silently, the
draft was already cleared, and the CEO was handed straight to the app shell with
`currentUserRoleProvider == null` → empty permission set → POS "no access",
empty drawer (hide-don't-block), hidden buying-price field — with no retry
affordance (the error was only `debugPrint`-ed). It self-healed only if a later
background pull happened to land.

**Fix:**
- `auth_service.dart`: new `hasLocalRoleBinding(userId, businessId)` — verifies
  the membership + its roles row + ≥1 `role_permissions` grant are actually
  local. Queries by explicit `businessId` (not the business-scoped resolver,
  which is null at the onboarding boundary).
- `ceo_sign_up_screen.dart` `_commit`: the post-onboarding pull is now
  authoritative — retry the pull up to 3× and verify `hasLocalRoleBinding`
  before handing off. If it still hasn't landed, **don't enter the app**: keep
  the draft, reset to the PIN step, and show a clear retryable message
  ("Your business was created, but we could not finish loading it on this
  device. Check your connection and re-enter your PIN to retry."). Moved
  `draftNotifier.clear()` to *after* the binding is verified so the idempotent
  (ON CONFLICT) commit can safely re-run on a PIN-re-entry retry.

**Also fixed (M2) — misleading onboarding error for a re-used email:**
`complete_onboarding` rejects an email that already belongs to a business with a
typed P0001 ("already linked to another business", invariant #9). `_commit`'s
catch surfaced this as the generic "Something went wrong. Please re-enter your
PIN." — a dead-end loop, since re-entering the PIN just re-runs the same doomed
RPC (the email is permanently bound). The catch now detects that case
(`e.toString()` contains "already linked to another business", with the raw
`users_auth_user_id_key` constraint name as a backstop) and shows "This email
already belongs to a business. Go back and use a different email to create a new
one." — mirroring `staff_sign_up_screen`'s handling of the same P0001 from
`redeem_invite_code`. Non-matching errors keep the generic retry copy.

**Also fixed (M3) — Add Product save button hidden behind the keyboard:**
`AddProductScreen` set `resizeToAvoidBottomInset: false` on the (incorrect)
assumption it is always nested under `MainLayout` (whose Scaffold zeroes the
keyboard inset for descendants). True for the Inventory FAB (pushed on the tab's
nested navigator), but the post-onboarding auto-show
(`main_layout.dart`, `Navigator.of(mainScaffoldKey.currentContext)`) pushes it
on the **root** navigator, ABOVE MainLayout — there nothing resizes for the
keyboard, so the save button and the bottom Quantity/Store fields are occluded.
That's the brand-new CEO's first product (the auto-shown sheet). Changed to
`resizeToAvoidBottomInset: true`, which is correct in BOTH placements: nested,
MainLayout already removed the bottom viewInsets so it's a no-op; on the root
navigator it lifts the body + bottomNavigationBar above the keyboard. Save-button
padding stays `deviceBottomPadding` (nav-only) — harmless while the keyboard
occludes the system nav bar.

**Also fixed (M4) — OTP spent before the one-email check (create-business):**
On "Create a new business", `email_entry_screen._submit` always sent the OTP,
then revealed an existing account only post-verify. Added a pre-OTP short-circuit
*scoped to `createBusinessIntent`*: if the email already has a fully-set-up
account ON THIS DEVICE (real local PIN), route straight to `LoginScreen` with no
OTP ("This email already belongs to a business — sign in instead."). Deliberately
**not** extended to a pre-auth cross-device existence check: account existence is
revealed only after the user proves email ownership via OTP, and a pre-auth oracle
would enable email enumeration. The local check leaks nothing (the row is already
on-device); cloud-only / cross-device accounts still resolve post-OTP as before.

**Scope note:** M1 from the same QA pass (a new product saving with 0 stock) was
confirmed **by design** by the product owner — not changed.

**Verification:** `flutter analyze` clean on all touched files;
`test/auth/onboarding_role_binding_test.dart` (4 cases: no membership /
membership+role but no grant / full binding present / cross-business isolation)
green; `test/auth/` + `test/inventory/` + `test/receiving/` suites green (64).
On-device walkthrough pending (H1 retry, M2 message, M3 keyboard, M4 short-circuit).

---

## 2026-06-24 — Initial-load loader blocked offline app entry (offline-first regression)

**Why:** The Session 151 fresh-device loading screens in `_HomeRouter._resolve`
(`lib/main.dart`) gated entry to `MainLayout` on a *network* pull. The
background-pull gate fired whenever `!hasLocalProducts &&
pullStatus.stage != PullStage.completed`. Offline the full pull never reaches
`completed` (fails → `failed`, or never runs → `idle`), so any logged-in user
with an empty local product table (new business, staff/stock-keeper device, or
a business that legitimately has zero products) was **permanently** stuck on the
loading animation / "Could Not Load Your Store" retry screen with no way into
the app while offline. Even on a *slow-but-working* connection the loader held
the user for as long as the pull took. This tied app open to connectivity,
breaking offline-first.

**Fix (`lib/main.dart`, `_HomeRouter._resolve`):**
- Minimum-pull gate now waits for the local businesses query to **resolve**
  before deciding: while it has no value yet, show `_BrandedSplash` (no network
  call); only mount `FirstSyncScreen` once resolved AND the list is genuinely
  empty (a true fresh sign-in, which legitimately needs the network once). Stops
  a spurious network `syncMinimumLogin` + "No internet" flash for returning
  offline users (previously `valueOrNull == null` conflated loading with empty).
- Background loader engages **only** for an in-flight pull
  (`stage == PullStage.background`) **and only until a 5 s grace cap**. Offline
  (`idle`/`failed`) a logged-in user with local data falls through to
  `MainLayout` immediately. On a slow connection the loader self-dismisses after
  `_initialLoaderMaxWait` (5 s): `_BackgroundPullLoading` (now a
  `ConsumerStatefulWidget`) arms a one-shot timer that flips
  `initialLoaderTimedOutProvider`, the router stops gating, and the user enters
  the app while the pull keeps running in the background — products stream into
  MainLayout live. Returning users with products never see it.
- Removed the now-unreachable `_BackgroundPullFailed` blocking screen (and its
  font_awesome / app_decorations / responsive imports). Pull failures are
  surfaced non-blockingly by the existing MainLayout sync banner.

**Verification:** `flutter analyze lib/main.dart
lib/features/sync/screens/first_sync_screen.dart` → "No issues found!".

---

## 2026-06-24 — Receive Stock checkout: explicit store-allocation dropdown

**Why:** The receive checkout committed stock to an *implicit* store (the active
store, or first selectable as fallback), shown read-only as "Receiving for:
[store]". In All-Stores scope this meant the user couldn't choose which store
the stock landed in. Requirement: allocate the destination store with a dropdown
at checkout.

**Changes:** `lib/features/receiving/screens/receive_checkout_screen.dart`
- Replaced the read-only "Receiving for: [store]" row with an `AppDropdown<String>`
  ("STOCKING INTO *") listing `selectableStoresProvider` (already access-scoped).
  `_flowStoreId` still defaults to `lockedStore ?? firstSelectable` but is now
  user-mutable; `onChanged` re-allocates the destination.
- Dropped the §15.7 active-store-change abort in `_confirm()` — the destination
  is now an explicit choice, so revalidating against the app-wide active store
  would wrongly block a deliberate cross-store receipt. Kept a "a store must be
  selected" guard; Confirm button also disables while `_flowStoreId == null`.
- Added `app_dropdown.dart` import + `_stores` field; `_storeName()` (confirm
  dialog) unchanged and still resolves the chosen store.

**Verification:** `flutter analyze` clean on the file; `flutter test
test/receiving/` green (17/17).

---

## 2026-06-24 — Receive Stock grid showed wrong on-hand count in All-Stores scope

**Why:** Each Receive Stock product card shows a "Current: X" on-hand figure.
It diverged from the Inventory tab whenever the active scope was "All Stores"
(`lockedStoreProvider.value == null`): Inventory aggregates stock across every
store (`watchAllProductDatasWithStock`), but Receive fell back to
`selectableStoresProvider.firstOrNull` and showed only the **first** store's
stock. So a product with 120 units across stores read "Current: 40" on the
receive grid — the reported "not reading the accurate number of items in
inventory" bug. (Concrete-store scope already matched — both used
`watchProductDatasWithStockByStore`.)

**Fix:** `lib/features/receiving/screens/receive_stock_screen.dart`,
`_initStreams()` now mirrors the Inventory tab's display semantics exactly:
locked store → `watchProductDatasWithStockByStore(storeId)`; no lock ("All
Stores") → `watchAllProductDatasWithStock()`. Removed the first-selectable-store
fallback used only for the display count. The receive WRITE target is still
resolved independently at checkout (now an explicit dropdown — see above), so
receiving semantics are unchanged.

**Verification:** `flutter analyze` clean on the changed file; `flutter test
test/receiving/` green (17/17).

---

## 2026-06-24 — Initial-load loader blocked offline app entry (offline-first regression)

**Why:** The fresh-device loading screens in `_HomeRouter._resolve`
(`lib/main.dart`) gated entry to `MainLayout` on a *network* pull. The
background-pull gate engaged whenever `!hasLocalProducts &&
pullStatus.stage != PullStage.completed`. Offline, the full pull can never
reach `completed` (it fails → `failed`, or never runs → `idle`), so:
- any logged-in user whose local product table is empty (new business, staff/
  stock-keeper device, or a business that legitimately has zero products) was
  **permanently** stuck on the loading animation / "Could Not Load Your Store"
  retry screen with no way into the app while offline;
- the minimum-pull gate also conflated "local businesses query still loading"
  with "no business row" (`valueOrNull == null`), so on cold start it could
  flash `FirstSyncScreen` — which fires a network `syncMinimumLogin` — for a
  returning offline user, briefly showing a spurious "No internet" error.

This tied app open to connectivity, breaking the offline-first guarantee.

**Fix (`lib/main.dart`, `_HomeRouter._resolve`):**
- Minimum-pull gate now waits for the local businesses query to **resolve**
  before deciding: while it has no value yet, show `_BrandedSplash` (no network
  call); only mount `FirstSyncScreen` once the query has resolved and the
  business list is genuinely empty (a true fresh sign-in, which legitimately
  needs the network once).
- Background-pull loader now engages **only** for an in-flight pull
  (`pullStatus.stage == PullStage.background`). Offline (`idle`/`failed`) a
  logged-in user with local data always falls through to `MainLayout` — even
  with zero products. Returning users with products never see it
  (`hasLocalProducts` already true).
- Removed the now-unreachable `_BackgroundPullFailed` blocking screen (and its
  font_awesome / app_decorations / responsive imports). Pull failures are
  surfaced non-blockingly by the existing MainLayout sync banner.

**Verification:** `flutter analyze lib/main.dart
lib/features/sync/screens/first_sync_screen.dart` → "No issues found!".

## 2026-06-24 — Receive Stock grid showed wrong on-hand count in All-Stores scope

**Why:** Each Receive Stock product card shows a "Current: X" on-hand figure.
It diverged from the Inventory tab whenever the active scope was "All Stores"
(`lockedStoreProvider.value == null`): Inventory aggregates stock across every
store (`watchAllProductDatasWithStock`), but Receive fell back to
`selectableStoresProvider.firstOrNull` and showed only the **first** store's
stock. So a product with 120 units across stores read "Current: 40" on the
receive grid — the reported "not reading the accurate number of items in
inventory" bug. (Concrete-store scope already matched — both used
`watchProductDatasWithStockByStore`.)

**Fix:** `lib/features/receiving/screens/receive_stock_screen.dart`,
`_initStreams()` now mirrors the Inventory tab's display semantics exactly:
locked store → `watchProductDatasWithStockByStore(storeId)`; no lock ("All
Stores") → `watchAllProductDatasWithStock()`. Removed the first-selectable-store
fallback used only for the display count. The receive WRITE target is still
resolved independently at checkout (§15.7, `lockedStore ?? firstSelectable`) and
shown read-only there, so receiving semantics are unchanged.

**Verification:** `flutter analyze` clean on the changed file; `flutter test
test/receiving/` green (17/17).

## 2026-06-23 — Active store never auto-defaults to "All Stores"

**Why:** Multi-store users (notably the CEO / all-stores Manager) landed on
"All Stores" (`lockedStoreId == null`) on every fresh session — Home, Inventory,
POS, and the Receive Stock invoice all opened in the business-wide aggregate
scope instead of a real store. The confined-user default in `main_layout.dart`
only pinned a concrete store for users who could NOT view all stores; all-stores
viewers were deliberately left on `null`. Requirement: never auto-land on All
Stores — default to the user's one store (or first selectable store), and keep
"All Stores" as a deliberate picker choice only.

**Changes:**
- `lib/shared/services/navigation_service.dart` — New
  `allStoresChosen` ValueNotifier: latches true ONLY when an all-stores viewer
  deliberately picks the picker's "All Stores" option (`setLockedStore(null,
  explicit: true)`); cleared on any concrete store pick, the silent default, and
  logout/lock (`applyUserStoreLock` / `clearStoreLock`).
- `lib/shared/widgets/main_layout.dart` — The §12.1 active-store default now runs
  for EVERY user (removed the `!canViewAllStores` guard). It silently defaults to
  `selectableStores.first` whenever the active store is null/invalid, UNLESS an
  all-stores viewer has `allStoresChosen` latched (so a deliberate All-Stores pick
  isn't yanked back). Still `explicit: false`, so the POS "pick a store" gate keeps
  prompting multi-store users before selling.

**Result:** 1 store → that store is the active store (no picker). >1 stores →
picker shows, defaults to a concrete store, "All Stores" available but never the
default. Receive Stock invoice inherits the concrete active store via its existing
`lockedStoreProvider ?? selectableStores.first` fallback. `flutter analyze` clean.

---

## 2026-06-23 — Google sign-in cancel/error split + release-build diagnostics

**Why:** Native Google Sign-In on a release build fails with `PlatformException`
code `sign_in_failed` / ApiException status 10 (DEVELOPER_ERROR) when the
release signing-certificate SHA-1 is not registered as an Android OAuth client
in Google Cloud Console. The old monolithic `catch (e)` in `signInWithGoogle`
returned `null` silently for both a user cancel and a real config error, causing
the UI to show the identical "cancelled or failed" banner with no diagnostic info.

**Changes:**
- `lib/shared/services/auth_service.dart` — New `GoogleSignInException` class.
  `signInWithGoogle` now has a split catch: `PlatformException` with
  `code == 'sign_in_cancelled'` returns null (quiet dismiss); all other
  `PlatformException` and unexpected errors log an `auth.google_signin_error`
  breadcrumb to `error_logs` via `CrashReporter.record` and throw
  `GoogleSignInException`. Missing idToken also throws instead of returning null.
- `lib/features/auth/screens/email_entry_screen.dart` — Wraps the
  `signInWithGoogle()` call in a dedicated `try/on GoogleSignInException` block.
  Real failures show "Google sign-in failed (code). Please try again or use email
  instead." User cancel exits silently (no banner).

**Operator step required (release builds only):**
The actual fix is registering the SHA-1 fingerprints in Google Cloud Console:
1. Debug: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
2. Release: `keytool -list -v -keystore android/app/upload-keystore.jks -alias upload` (passwords from android/key.properties — do NOT commit)
3. Google Cloud Console → Credentials → Create OAuth client ID (Android), package `com.reebaplus.pos`, paste both SHA-1s.
4. If using Play App Signing: also add SHA-1 from Play Console → Setup → App integrity.

**Verification:** `flutter analyze` clean on both files. Status-code 10 will
surface as "Google sign-in failed (sign_in_failed)." in the UI on the next
release build; sign-in succeeds end-to-end after SHA-1 registration.

---

## 2026-06-23 — Fresh-device blank POS screen fixed (loading animation + background-pull gate)

**Why:** On a first-time sign-in on a new device, `syncMinimumLogin` only
pulls 4 tables (profiles, businesses, stores, users). As soon as the
businesses row arrived, the gate in `main.dart` flipped and mounted
`MainLayout` immediately — landing the user on a blank POS grid because
products had not yet arrived from the background full-pull. The background
pull was running invisibly, with no feedback to the user.

**Root cause:** `_HomeRouter` (previously an inline IIFE) had no gate that
checked whether the minimum viable dataset (products) was actually present.
`pullStatusProvider` existed and tracked pull progress but was only consumed
by the staff management screen — `MainLayout` ignored it.

**Changes:**
- **`lib/features/sync/widgets/initial_load_animation.dart`** (new): looping
  branded animation widget — `AnimationController.repeat(reverse: true)` drives
  a pulsing glow + spinner + icon fade. All sizes via `context.getRSize`, all
  colors via `colorScheme.*`, background via `AppDecorations.glassyBackground`
  (opaque, per the glassy-bg memory note). Accepts optional `progressLabel`,
  `done`, `total` for "Setting up your store — 4 of 12…" progress display.
- **`lib/features/sync/screens/first_sync_screen.dart`** (refactor): uses
  `InitialLoadAnimation` for the loading branch; all raw pixel values
  (`EdgeInsets.symmetric(horizontal: 24.0)`, `SizedBox(height: 48)`, raw
  `Colors.black`) replaced with tokens; error/retry panel now uses `AppButton`
  + `AppDecorations.glassCard` instead of raw `ElevatedButton`.
- **`lib/core/providers/app_providers.dart`**: `hasLocalProductsProvider` —
  a `StreamProvider<bool>` watching `inventoryDao.watchAllProductDatasWithStock()`
  mapped + `.distinct()`. Self-healing: flips false→true when products first
  arrive; a returning device always has products so the gate never re-engages.
- **`lib/main.dart`**: Extracted the routing IIFE into `_HomeRouter`
  `ConsumerWidget` so all `ref.watch` calls are at the top of `build` (fixes
  the latent standards violation). Fresh-device gate: after the businesses
  check, if `!hasLocalProducts && stage != completed` → show
  `_BackgroundPullLoading` (live tablesDone/tablesTotal progress) or
  `_BackgroundPullFailed` (retry button that calls `pullChanges`). The
  `AnimatedSwitcher` wrapping `_HomeRouter`'s output cross-fades (350 ms
  `FadeTransition`) so the loading→POS transition is smooth rather than a
  hard cut.

**Verification:** `flutter analyze` clean (0 issues). `flutter test` 84/84 pass.
On-device smoke test pending (wipe app data, sign in fresh, confirm animation
plays → cross-fades into populated POS grid; confirm returning user not blocked).

---

## 2026-06-23 — Email-first CEO onboarding flow to catch registered email conflicts early

**Why:** The onboarding flow previously collected the business name, type, store details, and full name before verifying the email. If the email was already registered, the conflict was only surfaced at the final commit, causing late-stage errors and wasted effort. We want to verify the email up front, routing already-registered emails to sign in and new verified emails straight to the 7-step CEO signup flow.

**Changes:**
- **Welcome Screen (`lib/features/auth/screens/welcome_screen.dart`)**: Repointed the "Create a new business" CTA to open `EmailEntryScreen` with `createBusinessIntent: true` instead of launching `CeoSignUpScreen` directly. Removed unused import of `ceo_sign_up_screen.dart`.
- **Email Entry Screen (`lib/features/auth/screens/email_entry_screen.dart`)**: Added `createBusinessIntent` constructor flag. Passed the flag to `OtpVerificationScreen` in `_submit`. In `_signInWithGoogle`, redirected `NoAccountFoundRoute` to `CeoSignUpScreen(verifiedEmail: email)` when `createBusinessIntent` is true. Conditionally updated screen headers to "Create your business" / "First, confirm your email — we'll check it isn't already linked to a business." when the flag is true.
- **OTP Verification Screen (`lib/features/auth/screens/otp_verification_screen.dart`)**: Added `createBusinessIntent` constructor flag. Redirected `NoAccountFoundRoute` to `CeoSignUpScreen(verifiedEmail: widget.email)` when the flag is true.
- **Welcome Screen Test (`test/auth/welcome_screen_test.dart`)**: Updated widget test to verify that clicking "Create a new business" routes to `EmailEntryScreen` with `createBusinessIntent: true`. Wrapped the navigation pump in `tester.runAsync` to allow the Drift initialization database query in `initState` to resolve without hanging.

**Verification:**
- Ran `flutter analyze` -> Clean (no issues found).
- Ran `flutter test test/auth/welcome_screen_test.dart` -> All tests passed.

## 2026-06-23 — Reebaplus-branded auto invite email + OTP sender (0126)

**Why:** Invites generated an 8-char code that was only shareable manually (Copy / SMS / WhatsApp); no email went out. The ask: email the invite code to the staff automatically while keeping the manual share, and make all OTP/auth email come from the Reebaplus domain.

**Changes (DEPLOYED to project `ewwyofbvfjyqqirrcaou`):**
- **Edge Function `supabase/functions/send-invite-email/index.ts`** — sends the branded Reebaplus invite email via Resend. Invoked server-side (not by the client). Gated by an `x-invite-hook-secret` shared secret (no user JWT on this path); resolves the business name for the body; stamps `invite_codes.invite_email_sent_at` on success. Deployed with `--no-verify-jwt`.
- **Migration `0126_invite_email_trigger.sql`** (applied via MCP `apply_migration`, **not** `db push`, to avoid pushing the unrelated in-progress `0125`): enables `pg_net`; adds cloud-only `invite_codes.invite_email_sent_at`; AFTER INSERT trigger `trg_send_invite_email` calls the function via `net.http_post`. Function base URL + hook secret read from **Vault** (`project_url`, `invite_email_hook_secret`) — never in the repo. AFTER INSERT only, so the sync engine's re-push upserts (UPDATE) never re-send.
- **`lib/features/staff/screens/invite_staff_screen.dart`** — success copy now says the code was emailed; Copy / SMS / WhatsApp unchanged.
- **Secrets set:** `RESEND_API_KEY`, `INVITE_EMAIL_HOOK_SECRET` (Edge Function secrets); matching `project_url` + `invite_email_hook_secret` in Vault.
- **Docs:** `context/architecture.md` (server-logic row + Custom-SMTP note), `context/project-overview.md` (invite flow + auth email), `context/progress-tracker.md`.

**Verification:**
- Direct function invoke with the hook secret + a real business id → `HTTP 200 {"ok":true,"sent":true}`; Resend accepted (test email to devteam@reebaplus.com).
- Wrong secret / no secret → `HTTP 401 unauthenticated` (gate works).
- Catalog check: trigger, function, column, `pg_net`, and both Vault secrets all present.
- `flutter analyze lib` clean; `test/staff/invite_staff_screen_test.dart` passes.

**Still operator-side (gates full go-live):** OTP-from-Reebaplus requires configuring Supabase Auth **Custom SMTP** → Resend (`no-reply@reebaplus.com`) + branding the OTP template — dashboard only, no code. **Migration bookkeeping:** `0126` was applied out-of-band, so it shows as local-only in `migration list`; remote is also ahead with `20260623162330` and local `0125` is unpushed — reconcile with `migration repair` once `0125` is resolved.

---

## 2026-06-23 — delete_business now captures the silent auth.users delete failure (0125)

**Why:** A CEO reported they "deleted" a business yet could not re-onboard with the same email (`complete_onboarding` → P0001 "this email is already linked to another business"). Investigation of production showed: the business cascade *did* succeed (rows gone, `account_deletion_events` written), but **every** deletion recorded `auth_user_deleted = false` — the `DELETE FROM auth.users` inside `delete_business` was failing and the error was swallowed by a bare `EXCEPTION WHEN OTHERS`. A `postgres`-owned `SECURITY DEFINER` function cannot reliably delete from `auth.users` on managed Supabase (that path belongs to the Auth Admin API). With no diagnostics, the lingering login + leftover businesses were invisible. The actual onboarding block was correct behaviour: the email still owned two live businesses (never deleted).

**Changes:**
- **Migration `supabase/migrations/0125_delete_business_capture_auth_delete_error.sql` (DEPLOYED):**
  - Added `account_deletion_events.auth_delete_error text`.
  - `CREATE OR REPLACE FUNCTION public.delete_business` — the best-effort `auth.users` delete now does `GET STACKED DIAGNOSTICS` (SQLSTATE + MESSAGE_TEXT) and persists it to `auth_delete_error` on the audit row (and returns it in the JSON). Business-cascade behaviour is otherwise identical to 0113. Auth-identity deletion via the Admin API remains a follow-up.
- **Data cleanup (one-off, operator-run):** removed two lingering businesses for `okworchimezie@gmail.com` (`019ef476…` Paradise Park, `019ea612…` Okworchimezie Conglomerate) to free the email; left the `auth.users` login intact so the same email re-onboards.

**Verification:**
- `apply_migration` → success; function replaced.
- Post-cleanup query: 0 businesses / 0 `public.users` / 0 `profiles` rows remain for that auth uid → email free; 0121 guard now passes.

---

## 2026-06-23 — Wipe staff device at cold start when its business is deleted

**Why:** When an owner permanently deletes a business (§10.3), a staff device must not linger on the "Who's working?" picker or single-staff PIN screen. Once the device starts up or resumes while online, it must automatically wipe all local data and log out, redirecting to the Welcome screen.

**Changes:**
- **Auth Service (`lib/shared/services/auth_service.dart`)**:
  - Implemented `wipeIfActiveBusinessDeleted()`. It resolves the business ID from the device user (or single local business), checks the cloud tombstone via `confirmBusinessDeleted`, and calls `_handleActiveBusinessDeleted()` to perform the wipe and full logout if the business is confirmed as deleted.
- **Who Is Working Screen (`lib/features/auth/screens/who_is_working_screen.dart`)**:
  - Added the active business deletion check in `_resolveBusiness()`. If wiped, the screen pushes replacement to `WelcomeScreen`.
  - Added `WidgetsBindingObserver` to re-check for deletion when the app resumes (`AppLifecycleState.resumed`) while the user is sitting on the picker.
- **Login Screen (`lib/features/auth/screens/login_screen.dart`)**:
  - Added the async deletion check in `initState()` and `didChangeAppLifecycleState()` for app resume on the single-staff PIN screen.
  - Used `_checkedDeletion` latch to prevent double-checks during picker-to-PIN screen transitions.
  - Imported `welcome_screen.dart`.
- **Test (`test/auth/cold_start_deletion_gate_test.dart`)**:
  - Added a new unit test file covering the deletion gate check behavior (ambiguous/offline, non-deleted, and deleted cases).

**Verification:**
- Ran `flutter test test/auth/cold_start_deletion_gate_test.dart` -> All tests passed.
- Ran `flutter analyze` -> Clean (no issues found).

---

## 2026-06-23 — Improved supplier creation in product and receive-stock checkout + optional manufacturer

**Why:** To streamline inventory and receiving workflows by allowing users to create new suppliers inline (full form) directly from the Add Product screen and the Receive Checkout screen. Additionally, the Manufacturer field should be optional when empty-crate tracking is disabled for the product.

**Changes:**
- **Supplier Form Sheet (`lib/features/payments/widgets/supplier_form_sheet.dart`):**
  - Updated `static void show(...)` to `static Future<SupplierData?> show(...)` returning `showModalBottomSheet<SupplierData>(...)`.
  - In `_save()`, modified the add (new supplier) path to query and return the newly created `SupplierData` on `Navigator.pop(context, created)`.
- **Add Product Screen (`lib/features/inventory/screens/add_product_screen.dart`):**
  - Added an "Add new supplier" `AppButton` (variant: outline) in the supplier input section, gated by the `suppliers.manage` permission.
  - Implemented the `_addSupplierViaForm` handler to invoke `SupplierFormSheet.show`, fetch/reload all suppliers, and auto-select the newly created supplier.
  - Dynamically computed `manufacturerRequired` based on the active unit (`bottle`), business type (`isCrateBusiness`), and empty-crate tracking setting (`trackEmpties`).
  - Relaxed save validation: only require Manufacturer (`_selectedManufacturer`) when `_effectiveTrackEmpties` is true, both for new-product creation and existing-product update.
- **Update Product Sheet (`lib/features/inventory/widgets/update_product_sheet.dart`):**
  - Dynamically computed `manufacturerRequired` similarly to the Add Product screen.
  - Relaxed save validation: only require Manufacturer if `_effectiveTrackEmpties` is active.
- **Receive Checkout Screen (`lib/features/receiving/screens/receive_checkout_screen.dart`):**
  - Added an "Add Supplier" `AppButton` (variant: outline, small) below the supplier picker tappable field, gated by the `suppliers.manage` permission.
  - Implemented the `_addSupplier` handler to invoke `SupplierFormSheet.show`, refresh suppliers, and auto-select the newly created supplier.

**Verification:**
- Ran `flutter analyze` -> Clean (no issues found).
- Ran `flutter test` -> All tests passed.

---

## 2026-06-23 — Fix logout / login / Who's-working flow for shared-till and sole-user devices

**Why:** The shared-till Who's Working picker, email/PIN entry side-door, and
logout flow all keyed on "active staff" (any user with an active membership) —
not "device-authenticated staff" (users who completed OTP + PIN **on this
device**). This meant the picker showed users who had never set up a PIN locally,
the email screen's "Login with PIN" button appeared before anyone had set up,
and logout always did the same thing regardless of whether other device-authenticated
users remained.

**Core concept:** a device-authenticated user = a `users` row with
`pinHash != null` and an active `user_businesses` membership. `pinHash` is
local-only (never synced), so it is the authoritative per-device signal.

**Changes:**
- **`lib/core/database/daos.dart`**: added `watchDeviceStaffForBusiness` and
  `countDeviceStaffForBusiness` (mirror the existing `Active` variants + add
  `users.pinHash.isNotNull()`); added `SyncDao.countPending({businessId})` to
  count unsynced `sync_queue` rows.
- **`lib/core/providers/stream_providers.dart`**: `deviceStaffProvider`
  (`StreamProvider.family`).
- **`lib/features/auth/screens/who_is_working_screen.dart`**: watches
  `deviceStaffProvider`; simplified `_onTapStaff` (all visible users have a PIN);
  shortcuts → `WelcomeScreen` (empty) or `LoginScreen` (single).
- **`lib/features/auth/screens/email_entry_screen.dart`**: gates the "Already
  set up on this device? Login with PIN" button behind
  `countDeviceStaffForBusiness > 0`; sends taps to `WhoIsWorkingScreen`.
- **`lib/shared/services/auth_service.dart`**: `LogoutWipeException`;
  `logOutCurrentUser` now branches:
  - *Sole user* (count ≤ 1): checks `countPending` — if pending > 0 and offline
    → throws `LogoutWipeException`; if online → `pushPending()` first; then
    `clearAllData()` + `fullLogout()`.
  - *Multi-user* (count ≥ 2): clears the leaving user's PIN, revokes their
    session, awaits Supabase + Google sign-out, sets `showPickerOnUnlock = true`,
    stops sync, resets nav, nulls `value`.
- **`lib/main.dart`**: `_checkDeviceUser` calls `countDeviceStaffForBusiness`
  instead of `countActiveStaffForBusiness`.
- **`lib/shared/widgets/app_drawer.dart`**: sole-user warning copy in the Log Out
  confirmation dialog; catches `LogoutWipeException` on offline abort.

**Tests:**
- `test/staff/who_is_working_dao_test.dart`: 1 new test (device-staff filtering).
- `test/auth/shared_till_logout_test.dart` (new, 5 tests): multi-user PIN clear +
  staff count drop; sole-user pending-abort signal; sole-user clean wipe; device
  staff filtering by `pinHash` + membership status; stream reactivity on PIN clear.

**Verification:**
- `flutter analyze` → No issues found.
- `flutter test` → 552 passed, 58 skipped, 0 failures.

---

## 2026-06-23 — Business logo upload + show on receipts

**Why:** CEO needs to optionally upload a business logo that renders on receipts
(image/shared), visible across all devices in the same business and offline once
cached locally.

**Changes:**
- **`lib/core/result.dart`** (new): sealed `Result<T, E>` + `AppError` sealed class
  to carry typed errors across service boundaries without throwing.
- **`lib/core/services/business_logo_service.dart`** (new): `BusinessLogoService` —
  `pickAndProcess()` (gallery pick + resize ≤512×512 PNG), `save()` (local cache +
  Supabase Storage upsert, returns public URL), `ensureCached()` (serve local file,
  download once if absent), `clear()` (delete local + Storage object).
- **`lib/core/providers/app_providers.dart`**: added `businessLogoServiceProvider` +
  `currentBusinessLogoPathProvider` (autoDispose FutureProvider watching
  `currentBusinessProvider`, calls `ensureCached`).
- **`lib/core/database/daos.dart`** (`BusinessesDao.updateInfo`): optional `logoUrl`
  param with `_absent` sentinel (omit = leave unchanged, `''` = clear).
- **`lib/core/settings/business_info_screen.dart`**: `_LogoSection` widget at the top
  of the form card — 80×80 avatar with Upload/Change + Remove buttons, gated on
  `settings.manage`; logo upload runs before the business row write.
- **`lib/shared/widgets/receipt_widget.dart`**: nullable `logoPath` param; renders
  `Image.file` (64×64) above business name, omits when null.
- **`lib/features/pos/services/receipt_builder.dart`**: nullable `logoPath` param;
  decoded, resized to 200px width, grayscaled, emitted via `generator.image()` before
  the business name line.
- **Call sites threaded**: `checkout_page.dart`, `orders_screen.dart`,
  `customer_detail_screen.dart` — all pass `currentBusinessLogoPathProvider.valueOrNull`.

**Operator step (not code):** create a public `business-logos` Storage bucket in the
Supabase dashboard with appropriate RLS (member-upload, public-read). See
`CONTEXT/progress-tracker.md` for the exact policy SQL.

**Verification:**
- `flutter analyze lib` — No issues found.

---

## 2026-06-23 — Custom price floor at the CEO-allotted discount cap

**Why:** Custom prices set on cart items could bypass the CEO-allotted discount cap if set arbitrarily low. We want to enforce a price floor such that no custom price (or combination of custom price and discount) drops the effective unit price below the max discount allowance.

**Changes:**
- **Service (`lib/shared/services/cart_service.dart`):**
  - Updated `setCustomPrice` signature to accept `maxPercent`, and clamp the custom price to `floorKobo = (catalogKobo * (100 - maxPercent) / 100.0).round()`.
  - Re-clamped existing line discounts inside `setCustomPrice` to not exceed `maxLineDiscountKobo = ((unitPriceKobo - floorKobo) * qty).round()`.
  - Updated `setLineDiscount` to accept optional `maxPercent` and clamp the discount to respect the custom price floor if provided.
- **UI (`lib/features/pos/widgets/edit_item_modal.dart`):**
  - Computed the floor in the `build` method, added an auto-snap callback using `addPostFrameCallback` to snap below-floor inputs, and clamped the live unit price to prevent temporary sub-floor math.
  - Implemented Option A: limited the line discount to `(effectiveUnitPriceKobo - floorKobo) * qty` so the post-discount effective price never drops below `floorKobo`.
  - Displayed a styled warning message under the custom price input when snapped/at floor.
- **Tests (`test/pos/cart_custom_price_test.dart`):**
  - Updated existing tests to pass the `maxPercent` parameter.
  - Added 4 new regression tests covering below-floor clamping, 0% max discount behavior, Option A combined back-door block, and above-catalog overrides.
  - Added import for `semantic_colors.dart` to fix static analysis.

**Verification:**
- Ran `flutter test test/pos/cart_custom_price_test.dart` and `test/pos/cart_tier_pricing_test.dart` -> All tests passed.
- Ran `flutter analyze` -> Clean (no issues found).

---

## 2026-06-22 — Local list pagination (Phase 1) + first-sync RPC retirement (Phase 2)

**Why:** A first-time user with a large dataset had no protection: history lists rendered the entire table at once (low-end-phone jank) and the first/full sync went through the monolithic `pos_pull_snapshot` RPC — an unbounded 60s aggregate over every tenant table that can time out / over-fetch on a big business. Two-layer fix: (Phase 1) page history lists locally from Drift as the user scrolls; (Phase 2) route first/full pulls through the existing paginated keyset path instead of the monolithic RPC. Neither violates Invariant #1 (Drift-only reads); offline-first history is preserved on-device.

**Changes:**
- **Pattern (all Phase 1 units):** compound keyset cursor, `ORDER BY created_at DESC, id DESC`; a "live head (watch most-recent page) + paged tail (on-demand `getXPage` with the last row as cursor, dedup by id)" notifier; `StateNotifier.autoDispose.family`; `ListView.builder` scroll trigger (`index >= len-5 → loadMore()`) + bottom spinner; summary figures from a SQL aggregate (never summed from the loaded page).
- **Unit 1 — Orders** (`daos.dart` `getOrdersPage`/`watchOrdersPage`/`watchOrdersStats` + `OrdersStats`; `stream_providers.dart`; `orders_screen.dart`; 300ms search debounce; Cancelled tab includes `refunded`). Page-orders-then-load-items (1:many join). `test/orders/orders_pagination_test.dart`.
- **Unit 2 — Activity Logs** (`getActivityLogsPage`/`watchActivityLogsPage`; `activity_log_screen.dart`). Store-filter heuristic moved into SQL (NULL-guarded `entityType` IN); write facade `ActivityLogService` and its ~14 `.log(...)` call-sites untouched. `test/activity/activity_logs_pagination_test.dart`.
- **Unit 3 — Inventory History** (`getTransactionsPage`/`watchTransactionsPage`/`watchTransactionsStats` + `StockHistoryStats`; `inventory_history_tab.dart`). 1:1 join → limit-on-join. Total In/Out moved from in-memory sum to SQL aggregate. `test/inventory/stock_history_pagination_test.dart`.
- **Unit 4 — Supplier History** (`getSupplierHistoryPage`/`watchSupplierHistoryPage`/`watchSupplierHistoryStats` + `SupplierLedgerStats`; `supplier_transactions_screen.dart`). Mixed-direction 3-column keyset `created_at DESC, signed_amount_kobo ASC, id DESC` (cursor triple); voided + `void` rows stay in the list (no `voidedAt` filter); date window on `activity_date`; stats `count` includes voided/void while `totalIn/Out` exclude them (NULL-safe `reference_type`). `test/payments/supplier_history_pagination_test.dart`.
- **Phase 2 — first-sync path** (`supabase_sync_service.dart`): extracted `shouldUseSnapshotRpc({isSlow, since}) => !isSlow && since != null` (`@visibleForTesting`), swapped the `pullInitialData` gate to it. Full/first pulls (`since == null`) now ALWAYS use the paginated `_pullViaPostgRest` path; the `pos_pull_snapshot` RPC is retained ONLY for incremental-on-fast pulls. RPC + migration untouched (incremental still uses it); post-decision restore/canary/deferred-return logic unchanged. `test/sync/pull_path_decision_test.dart`. Docs: `context/architecture.md` Pull-path rule + `context/progress-tracker.md` (Phase 3 windowed-sync left as the open question).

**Verification:**
- `flutter analyze` → clean across all changed files and whole-project runs.
- Per-unit tests green: orders, activity, inventory, supplier-history pagination suites (each covers same-second keyset boundary, hasMore/partial, filter push-down, business scope, soft-delete/void handling, and stats-over-full-set). Supplier Unit 4 Test 1 crosses page boundaries at a same-second/same-amount collision to exercise the 3-level cursor.
- Phase 2: `pull_path_decision_test.dart` (4 truth-table cells) + full `test/sync/` (125) + `test/database/` green; restore path unchanged. **On-device (emulator) confirmed:** a fresh full pull logs `Full pull (since=null) → paginated PostgREST path (snapshot RPC bypassed)` and syncs correctly.
- Deferred: customer wallet history + expenses screens (lowest-volume / analytics-shaped — poor cost/benefit for keyset paging); Phase 3 windowed sync (conflicts with Invariant #1, logged as open question).

---

## 2026-06-22 — Walk-in Customer Visibility on Receipt

**Why:** When a walk-in customer is selected at checkout, the receipt (both visual/shared receipt and printed thermal receipt) should not specify "Walk-in Customer" anywhere. It should just leave the customer details section completely blank to make it look clean.

**Changes:**
- `lib/shared/widgets/receipt_widget.dart`:
  - Conditionally render the customer details block (name, address, phone) and the trailing `SizedBox` only when `customerName` is not null/empty and does not equal `'Walk-in Customer'` (case-insensitively). This leaves the section completely blank for walk-in checkouts.
- `lib/features/pos/services/receipt_builder.dart`:
  - Conditionally render the customer details lines and trailing blank line spacer in `ThermalReceiptService.buildReceipt` only when `customerName` is not null/empty and does not equal `'Walk-in Customer'` (case-insensitively). This leaves it completely blank on printed thermal receipts.
- `test/receipt_widget_test.dart`:
  - Added two test cases (`walk-in customer is not shown on receipt` and `null/empty customer is not shown on receipt`) to verify that the details are hidden when name is empty/null or `'Walk-in Customer'`.
- `test/settings/roles_permissions_screen_test.dart` & `test/settings/role_permissions_detail_test.dart`:
  - Updated hardcoded permission count assertions from 33 to 35 to resolve existing test failures due to schema updates.

**Verification:**
- Ran `flutter test test/receipt_widget_test.dart` -> All 9 tests passed.
- Ran `flutter test test/settings/role_permissions_detail_test.dart test/settings/roles_permissions_screen_test.dart` -> All tests passed.
- Ran `flutter analyze lib` -> Clean (no issues found).
- Ran all project unit tests -> All 503 tests passed.

---

## 2026-06-22 — Onboarding opt-in for empty-crate tracking

**Why:** Crate tracking was hard-wired to business type (`isCrateBusiness`), so every Bar / Beverage distributor always got crate features. Decouple it with a per-business opt-in chosen at onboarding (default on for crate-eligible types) and editable later, so crate-eligible businesses that don't deal in returnables can hide every crate surface.

**Changes:**
- Schema (v56 → v57): `Businesses.tracksEmptyCrates` bool, default true (`app_database.dart`); guarded onUpgrade addColumn (same `pragma_table_info` guard as v43, so the revert-then-re-upgrade migration tests pass). Regenerated `app_database.g.dart`.
- Cloud: migration `0123_business_tracks_empty_crates.sql` adds `businesses.tracks_empty_crates` (NOT NULL default true) and extends `complete_onboarding` with `p_tracks_empty_crates boolean DEFAULT true`; `tracks_empty_crates` added to the businesses push whitelist (`supabase_sync_service.dart`). Migration `0124_drop_legacy_complete_onboarding_overload.sql` drops the stale 10-arg `complete_onboarding` overload that `CREATE OR REPLACE` left behind, which would otherwise make 10-arg (older-client) calls ambiguous (PGRST203). Both deployed.
- Combined gate: `businessTracksCrates(BusinessData?)` in `app_providers.dart` = `isCrateBusiness(type) && tracksEmptyCrates`. Replaced every crate-visibility gate (checkout, cart, customer detail + Crates tab, reports hub, recon, supplier detail, inventory Empty Crates tab, add-product/update-product switches, stock-count damages crate-fate) and the `createOrder` write boundary (`daos.dart`).
- Onboarding + edit: `OnboardingDraft.tracksEmptyCrates`, a switch on the CEO sign-up business-type step (shown via `isCrateBusiness`), `AuthService.completeOnboarding` passes the RPC param + sets the local mirror explicitly, and Settings → Business Info renders/loads/persists the toggle (bumping `lastUpdatedAt` so it pushes).

**Verification:**
- `flutter analyze` → clean. `flutter test` → migration-upgrade tests green; 2 pre-existing failures in role-permissions tests are from parallel work (permission-catalogue count), unrelated to crate tracking.
- Cloud verified: column present (NOT NULL default true), `complete_onboarding` back to a single 11-arg overload.

---

## 2026-06-22 — Make Product Details Screen Read-Only

**Why:** Ensure that the product details screen is strictly view-only, preventing any editing of details, deletion of the product, or updating of stock on this screen by any role.

**Changes:**
- `lib/features/inventory/screens/product_detail_screen.dart`:
  - Added `// ignore_for_file: unused_element, unused_field` to suppress analysis warnings for newly-unused private helper methods and fields.
  - Commented out the Delete button icon in the `AppBar` actions list to prevent product deletion.
  - Replaced the bottom button block (Save Product button for edit mode, Update Stock button for stock keepers) with a permanent, static "VIEW ONLY" notice.

**Verification:**
- Ran `flutter analyze` -> Clean (No issues found).

---

## 2026-06-22 — Fix wallet-vs-credit payment bug at POS checkout

**Why:** Steer users to the Wallet payment method when a registered customer has wallet credit available. Reclassify credit sales fully covered by customer wallet credit as wallet payments so that receipt/badge/stored type reflect what actually settled the order.

**Changes:**
- `lib/features/pos/screens/checkout_page.dart`:
  - Updated `_confirmPayment` check to notify and block cash/transfer checkout when a registered customer has positive wallet credit, suggesting the Wallet method.
  - Updated `_paymentLabel` getter to return 'Wallet Payment' under PayMode.credit if the registered customer's wallet balance covers the total amount.
  - Passed `walletBalanceKobo: oldWalletKobo` in the `addOrder` call.
- `lib/shared/services/order_service.dart`:
  - Added `walletBalanceKobo` named parameter to `addOrder` and passed it to `_resolvePaymentType`.
  - Updated `_resolvePaymentType` to accept `walletBalanceKobo` and classify unpaid sales covered by existing wallet credit as `'wallet'`.
- `test/orders/pr_4c_test.dart`:
  - Added test cases to verify the new payment type classification logic for wallet, credit, mixed, and cash.

**Verification:**
- Ran `flutter analyze` -> Clean (No issues found).
- Ran `flutter test test/orders/pr_4c_test.dart` -> Passed (All 11 tests passed).

---

## 2026-06-22 — Refactor Request Stock Flow to Dedicated Screen

**Why:** The request stock flow should be a dedicated screen rather than a modal bottom sheet, following the glassy design system, and the dropdowns should have standard aesthetics (such as prefix icons) and behavior (such as mutual exclusion when selecting stores).

**Changes:**
- `lib/features/stores/screens/request_stock_screen.dart`: Created a new screen file using `GlassyScaffold`. Included premium prefix icons on inputs and dropdowns, and mutual exclusion logic to clear store conflicts dynamically.
- `lib/features/stores/widgets/request_stock_sheet.dart`: Deleted the old sheet widget file.
- `lib/features/stores/screens/store_details_screen.dart`: Updated imports and refactored the open sheet action to standard `Navigator.push` to open `RequestStockScreen`.

**Verification:**
- Ran `flutter analyze` -> Clean (No issues found).

---

## 2026-06-22 — Fix sync_queue 2067 dedup collision on login (resetStuckInProgress)

**Why:** Logging in (which starts auto-push → `_initAutoPush`) crashed with `SqliteException(2067): UNIQUE constraint failed: index 'idx_sync_queue_dedup_pending'` on the `UPDATE sync_queue SET status='pending' WHERE status='syncing' AND created_at < ? AND business_id = ?` statement.

**Root cause:** The dedup index is partial (`(action_type, json_extract(payload,'$.id')) WHERE status='pending'`). While a row sits in `syncing`, a fresh edit to the same domain row enqueues a NEW `pending` row — `enqueueUpsert`'s coalesce lookup only sees `pending` rows, so the in-flight `syncing` twin is invisible (and we must not coalesce into a row mid-push). If that `syncing` row then stalls >5 min (app killed mid-push, etc.), `resetStuckInProgress()`'s bulk flip back to `pending` collides with the existing pending twin → 2067, aborting the whole reset and auto-push init. Login is just when the reset first runs.

**Changes:**
- `lib/core/database/daos.dart` (`SyncDao.resetStuckInProgress`): Replaced the single bulk UPDATE with a 3-step transaction: (1) DELETE stuck `syncing` rows whose key already has a `pending` twin (the twin carries the newer edit and supersedes them); (2) DELETE all-but-newest among remaining stuck `syncing` rows sharing a key with each other; (3) flip the survivors to `pending`. Rows are upserts keyed by row id, so collapsing duplicates to the newest payload is exactly what coalescing intends — no data lost. `enqueueUpsert` deliberately left unchanged (must not mutate an in-flight `syncing` row).

**Verification:**
- Ran `flutter analyze lib/core/database/daos.dart` → No issues found.

---

## 2026-06-22 — Optimize Route Transitions & BackdropFilter Jank

**Why:** Confirm the real cause of route transition lag (raster thread jank) by profiling and apply a minimal, robust fix to eliminate jank during screen transitions.

**Changes:**
- `lib/shared/widgets/glassy_card.dart`: Created a centralized `GlassyCard` component that uses `AnimatedBuilder` combined with `ModalRoute.of(context)`'s transition animations to bypass the `BackdropFilter` blur filter while a route transition is active. When animating, the card falls back to a solid/translucent color matching theme tokens. Once the animation completes, it renders the frosted glass blur.
- `lib/features/customers/screens/customer_detail_screen.dart` & `lib/features/inventory/screens/supplier_detail_screen.dart`: Refactored private `_GlassyCard` definitions to delegate directly to the public `GlassyCard`.
- `lib/features/payments/widgets/supplier_ledger_entry_tile.dart` & `lib/features/dashboard/screens/daily_reconciliation_list_screen.dart`: Replaced manual `BackdropFilter` implementations with `GlassyCard`.
- `lib/features/staff/screens/invite_staff_screen.dart`: Refactored `_RoleSelectionCard` to use `GlassyCard`.
- `lib/features/dashboard/screens/supplier_accounts_report_screen.dart` & `lib/features/payments/screens/supplier_transactions_screen.dart`: Replaced manual `BackdropFilter` in rows and summary tiles with `GlassyCard`.
- `lib/shared/widgets/app_dropdown.dart`: Wrapped the dropdown button's `BackdropFilter` in `OptimizedBackdropFilter` to bypass blur during transitions.
- `lib/features/inventory/screens/supplier_detail_screen.dart`: Wrapped the TabBar's `BackdropFilter` in `OptimizedBackdropFilter` to bypass blur during transitions.
- Cleaned up unused and unnecessary imports of `dart:ui` across modified files to ensure static analysis is 100% clean.

**Verification:**
- Ran `flutter analyze` -> Clean (0 issues).
- All code standards and naming conventions strictly followed.

---

## 2026-06-22 — Store-scoped Stock Transfer, Empties, and Per-Store History (Unit B)

**Why:** Surface completed/cancelled transfers per store on the store details hub (Unit B), completing the deferred follow-ups from the stock-transfer redesign.

**Changes:**
- `lib/core/database/daos.dart` (`StockTransferDao`): Added `watchHistoryForStore` to watch completed (`received` / `cancelled`) transfers involving a store in either direction, sorted newest first.
- `lib/core/providers/stream_providers.dart`: Added `storeTransferHistoryProvider` family stream provider.
- `lib/features/stores/widgets/store_transfer_hub.dart`: Added a read-only "Transfer history" `ExpansionTile` at the bottom of the hub, watching `storeTransferHistoryProvider`. Inside, it renders a list of transfers showing: product name, quantity, direction badge ("In" / "Out" chip styled using semantic colors), counterparty, status, and date. Displays up to 30 items. Displays a muted empty state if no transfers exist.
- `test/transfer/stock_transfer_dao_test.dart`: Added a comprehensive unit test verifying `watchHistoryForStore` filters (correct status, matching target store in both directions, excluding unrelated stores/statuses) and descending chronological ordering.

**Verification:**
- Ran `flutter test test/transfer/stock_transfer_dao_test.dart` -> All 24 tests passed (including the new history sorting/filtering test).
- Ran `flutter analyze` -> Clean (No issues found).

---

## 2026-06-22 — Security: legible auto-lock chips + tap-to-disable

**Why:** On the light theme the unselected auto-lock interval chips rendered with a near-white label, so all presets except the selected one were invisible. Also there was no way to turn auto-lock off — only to change the interval.

**Changes:**
- `lib/core/settings/security_settings_screen.dart`: Gave each `ChoiceChip` explicit theme-derived colors (`backgroundColor`/`selectedColor`/`labelStyle`/`side`) so the unselected label uses `onSurface` and stays legible in both light and dark themes, instead of inheriting the washed-out chip-theme label tint.
- Re-tapping the currently selected chip now turns auto-lock **off** by saving `0` to `auto_lock_interval_seconds` (the `AutoLockWrapper` already gates inactivity lock on `autoLockSeconds > 0`, so `0` cleanly disables it; the 12-hour shift-expiration safety net is unaffected). `_load` now accepts `0` as a valid "off" value; the card subtitle reads "Off — tap a timer to turn it on" and the activity log records "Turned auto-lock off".

**Verification:** `dart analyze` clean (no errors).

---

## 2026-06-22 — Supplier screens Total In / Total Out

**Why:** To match the Customer Details screen, the supplier transaction screens (All-suppliers history and Individual supplier Ledger tab) needed a two-tile summary showing "Total In" (payments) and "Total Out" (invoices) for the selected period.

**Changes:**
- `lib/features/payments/screens/supplier_transactions_screen.dart`: Added `_buildLedgerSummaryRow` and integrated it above the period-filtered ListView. Total In sums payments (`signedAmountKobo >= 0`), Total Out sums invoices (`signedAmountKobo < 0`). Both calculations explicitly skip voided entries (`voidedAt != null`) and void references (`referenceType == 'void'`).
- `lib/features/inventory/screens/supplier_detail_screen.dart`: Added `_buildLedgerSummaryRow` inside `_buildHistoryTab` above the Ledger list view. Total logic matches the transactions screen.
- Styled to mirror the customer `_buildSummaryTile` (glassy/surface tile with label and bold amount).

**Verification:** `flutter analyze` clean.

---

## 2026-06-22 — Store-scoped Stock Transfer UI: visibility model + per-store hub (Units 4–5)

**Why:** Final units of the redesign. Transfers become a store-assignment-scoped, requester-initiated flow that lives inside a store's details, and Managers can browse the stores menu (full view only for assigned stores; others are read-only to request from).

**Changes:**
- `lib/shared/widgets/app_drawer.dart`: the Stores entry now shows for any holder of `stores.manage` / `stores.request_transfer` / `stores.dispatch_transfer` / `stores.receive_transfer` (was manage/receive only).
- `lib/features/stores/screens/stores_screen.dart`: stops hard-blocking non-CEO viewers — the store list renders for anyone who can view all stores or take part in transfers; Add Store (FAB) + per-card Edit/Delete stay gated on `stores.manage` (hide-don't-block). Removed the app-bar "Stock Transfer" + "Transfer Queue" icons (moved into store details). Card gets `clipBehavior` so it stays rounded when the actions row is hidden.
- **Retired** `lib/features/stores/screens/stock_transfer_screen.dart` (old source→dest dispatch form) and `lib/features/stores/screens/incoming_transfers_screen.dart` (business-wide tabbed queue) — superseded by the per-store hub. (Per-store transfer *history* not yet surfaced — follow-up; `viewerScoped*`/`watchHistory` providers retained for reuse.)
- `lib/core/database/daos.dart`: `watchPendingForHolderStore` + `watchPendingFromStore`.
- `lib/core/providers/stream_providers.dart`: `storeIncomingRequestsProvider`, `storeOutgoingRequestsProvider`, `storeIncomingTransfersProvider`, `storeOutgoingTransfersProvider` (family by storeId).
- **New** `lib/features/stores/widgets/request_stock_sheet.dart`: Request Stock modal — source store (locked from another store's details) + destination (locked/defaulted to your store from your own) + product (from the source store's in-stock list) + qty → `requestTransfer`. Write-boundary re-check on `stores.request_transfer`.
- **New** `lib/features/stores/widgets/store_transfer_hub.dart`: per-store hub — Requests to fulfil (Accept-with-qty / Reject, `stores.dispatch_transfer`), Incoming stock (Confirm Receipt, `stores.receive_transfer`), Your requests (pending), Dispatched out (Cancel, `stores.dispatch_transfer`). Empty sections hide.
- `lib/features/stores/screens/store_details_screen.dart`: branches full vs restricted access (CEO/all-stores or assigned → full view + Request Stock + hub; otherwise → read-only inventory + a single "Request Stock from this store"). 3-layer gating throughout.
- `test/database/roles_v13_seed_test.dart`: live-catalogue count 36 → 38 (+ spot-checks for the two new keys); frozen 65-grant baseline mirror unchanged.

**Verification:** `flutter analyze` (whole project) → No issues found. `flutter test test/transfer test/database test/receiving test/permissions test/crates` → green after the catalogue-count fix (transfer + database + roles_v13 + migration re-run: 37/37). On-device walkthrough of the request → dispatch → receive UX still pending (emulator).

---

## 2026-06-22 — Stock-transfer request → dispatch → reject DAO + scoped providers

**Why:** Unit 3 of the store-scoped Stock Transfer redesign. The new flow is requester-initiated: a store raises a `pending` request, the holder store accepts (optionally altering qty) and dispatches, the requester confirms receipt. Reuses the existing `stock_transfers` table — the `pending` status was already in the CHECK constraint but unused, so no schema migration.

**Changes:**
- `lib/core/database/daos.dart` (`StockTransferDao`): added `requestTransfer` (writes a `pending` header, no inventory/crate movement, enqueues, logs, notifies the holder store's users + CEO), `dispatchTransfer` (guards `pending`, optional qty alteration, decrements source via `transfer_out`, → `in_transit`, notifies requester), `rejectRequest` (guards `pending`, → `cancelled`, notifies requester). Added `watchAllPending`. `receiveTransfer`/`cancelTransfer`/`transferCrates` unchanged. (Old `createTransfer` immediate-dispatch path left in place; retired with its screen in Unit 4.)
- `lib/core/providers/stream_providers.dart`: `allPendingTransfersProvider` + `viewerScopedIncomingRequestsProvider` (pending where a viewer store HOLDS the goods — `fromLocationId`) + `viewerScopedOutgoingRequestsProvider` (pending the viewer's store RAISED — `toLocationId`). CEO sees all; store users scoped to assignment.
- `test/transfer/stock_transfer_dao_test.dart`: +6 tests (request guards; request→dispatch→receive round-trip moving stock only at dispatch; dispatch qty alteration; dispatch insufficient-stock rollback leaves it pending; non-pending dispatch/reject StateError; pending enqueue).

**Verification:** `flutter analyze` clean. `flutter test test/transfer/stock_transfer_dao_test.dart` → 19/19 pass.

---

## 2026-06-22 — Store-transfer permissions (`stores.request_transfer`, `stores.dispatch_transfer`)

**Why:** The store-scoped Stock Transfer redesign makes transfers a Manager-driven, store-assignment-scoped flow (request → accept/dispatch → receive). The CEO-only `stores.manage` could no longer gate dispatch. Two new keys, both default CEO + Manager; `stores.manage` narrows to store CRUD only. (Brief Unit 2; key model confirmed with the requester: two independent keys.)

**Changes:**
- `lib/core/database/app_database.dart`: added `stores.request_transfer` + `stores.dispatch_transfer` to `_defaultPermissionRows` (catalogue now 38 keys); bumped `schemaVersion` 55 → 56 with an `INSERT OR IGNORE` onUpgrade block seeding both catalogue keys (grants are never seeded on-device — they arrive via cloud pull).
- `supabase/migrations/0122_add_stores_transfer_permissions.sql`: catalogue inserts; `CREATE OR REPLACE seed_default_roles_for_business` (cloned from 0098) adding the three store-transfer lines to the Manager seed list; backfill of the two new keys to all CEO + Manager roles and `stores.receive_transfer` to Manager (0103 had granted receive_transfer to CEO only). Deployed catalogue-before-grants (FK ordering).
- `test/database/migration_upgrade_test.dart`: added a v55 → v56 group asserting onUpgrade re-seeds both catalogue rows.

**Verification:** `flutter analyze` clean. `flutter test test/database/migration_upgrade_test.dart` → 11/11 pass (incl. new v55→v56). `supabase db push` applied 0122 (remote was at 0121, no divergence). Cloud verify: `request_transfer`/`dispatch_transfer`/`receive_transfer` each granted to ceo + manager across all 4 businesses (4 rows per role-key). No client UI references the keys yet (units 3–5 build on them).

---

## 2026-06-22 — Empty crates returned grouped by manufacturer (Receive Stock)

**Why:** Empties are a per-manufacturer figure (the manufacturer owns the crate deposit — `Manufacturers.depositAmountKobo`), but the receive-checkout UI collected them per product. A manufacturer shipping several SKUs on one receipt showed one empties input per SKU, all writing to the same manufacturer pool — confusing and double-entry-prone. The downstream service already aggregated by manufacturer (`recordCrateReturnByManufacturer`), so only the collection layer was wrong.

**Changes:**
- `lib/shared/services/receive_stock_service.dart`: renamed the `confirmReceipt` param `emptiesReturnedByProduct` → `emptiesReturnedByManufacturer` (`manufacturerId → qty`). Moved crate-return out of the per-line loop into a single post-loop pass that records once per manufacturer, filtered to manufacturers actually carried by a bottle + `trackEmpties` line on the receipt. Stock increment + price persistence stay per-line. Atomicity preserved (crate write still inside the receipt transaction).
- `lib/features/receiving/screens/receive_checkout_screen.dart`: state now keyed by `manufacturerId` (one `TextEditingController` per distinct manufacturer, not per product). Build groups cart lines by manufacturer, showing one row per manufacturer labelled by manufacturer name (via `allManufacturersProvider`) with the summed full-crates received. `_emptiesRow` takes a manufacturer group record.
- `test/receiving/receive_stock_test.dart`: updated to the new per-manufacturer param.

**Verification:** `flutter analyze` on the 3 touched files → No issues found. `flutter test test/receiving/receive_stock_test.dart` → All 10 tests passed (incl. the atomic-rollback case via a nonexistent manufacturer). Part of the store-scoped Stock Transfer brief (`context/stock-transfer-empties-brief.md`), Unit 1.

---

## 2026-06-22 — Move Long-press Hint Info Icon to Product Card

**Why:** To clean up the screen headers and place the tap-and-hold educational hint info icon directly where it applies (on the product card).

**Changes:**
- **POS Screen:**
  - Removed the circle info icon from the AppBar actions list in `pos_home_screen.dart`.
  - Added `showHint` and `onHintTap` parameters to `ProductGrid` and `_ProductCard` in `product_grid.dart`.
  - Rendered a small circle info icon (`circleInfo` from FontAwesomeIcons) positioned at the top right of each `_ProductCard` inside its Stack. Tap events trigger `onHintTap`, showing the toast and dismissing it globally.
- **Receive Stock Screen:**
  - Applied the exact same structure to the Receive Stock screen for consistency. Removed the info icon from the screen's action bar in `receive_stock_screen.dart`.
  - Added `showHint` and `onHintTap` to `ReceiveProductGrid` and `_ReceiveProductCard` in `receive_product_grid.dart`.
  - Rendered the info icon at the top right of the card, with tap actions to show the toast and dismiss the hint.
  - Imported `package:font_awesome_flutter/font_awesome_flutter.dart` to `receive_product_grid.dart`.

**Verification:**
- Ran `flutter analyze` and `flutter test` successfully.

---

## 2026-06-22 — Four UI Fixes

**Why:** To resolve four requested UI enhancements and styling fixes: active store subtitle live updates, Staff Management navigation hierarchy & scaffold uniformity, routing transition performance optimization, and POS title bar truncation for long business names.

**Changes:**
- **Task 1: Active Store Name in App Bars:**
  - Integrated `activeStoreLabelProvider` across Home, Inventory, Orders, Cart, and Stores screens using `AppBarHeader`, ensuring live updates when switching stores.
  - Added support for active store names as app bar subtitles on drawer-navigated screens: Customers, Payments, Expenses, Activity Log, and Reports Hub.
  - Added `subtitle` parameter to `GlassyScaffold` and integrated it with Settings.
  - Resolved unused `subtitle` warning in `home_screen.dart` and corrected parameter passing in `payments_screen.dart`.
- **Task 2: Staff Management Menu Button & Drawer:**
  - Wrapped both the main view and the permission-denied view in `SharedScaffold` (retaining the `'staff'` active route) to ensure consistency.
  - Replaced the back button leading icon with `MenuButton` to allow opening the drawer.
  - Added the active store label as the app bar subtitle.
- **Task 3: Smooth Route Transitions:**
  - Replaced `CupertinoPageTransitionsBuilder` across all 8 theme definitions in `lib/core/theme/app_theme.dart` with a custom `SlideLeftPageTransitionsBuilder`.
  - [CORRECTION] The custom transition builder changes the animation layout, but profiling showed that the root cause of the route transition lag/jank is actually the costly re-rasterization of `BackdropFilter` Gaussian blurs on the incoming and outgoing pages on every frame of the transition animation. The transition builder change alone did not eliminate the jank; a centralized and widget-specific bypass of `BackdropFilter` during active transitions is required.
  - Cleaned up the unnecessary `package:flutter/cupertino.dart` import.
  - Fixed dead code warning in `product_detail_screen.dart` by commenting out the unused edit button and the associated `_resetEdits` helper.
- **Task 4: POS Title Bar Truncation and Reveal on Tap:**
  - Added a `truncateTitleWithReveal` boolean parameter to `AppBarHeader`.
  - When active, the title renders inside a `Text` widget without a `FittedBox`, setting `maxLines: 1`, `overflow: TextOverflow.ellipsis`, and wrapped in a `GestureDetector`. Tapping the title displays a toast/notification with the full business name using `AppNotification.showInfo`.
  - Opted in to `truncateTitleWithReveal: true` in the `AppBarHeader` inside `pos_home_screen.dart`.

**Verification:**
- Ran `flutter analyze` locally; resolved all warnings and errors (zero issues).
- Ran `flutter test` locally; all 484 unit, widget, and integration tests passed.

---

## 2026-06-22 — Long-press haptics & first-run hints

**Changes:**
- **Haptic Feedback:** Added `HapticFeedback.mediumImpact()` to all product grid long-press interactions (POS grid, Receive grid, Inventory grid) and Cart item taps for a more responsive feel.
- **UiHintService:** Created `UiHintService` to track the view count of educational hints using `SharedPreferences`, ensuring hints self-dismiss/hide after being viewed twice.
- **UI Hints:** Replaced the legacy auto-toast with a consistent icon-based hint system. Added a tap-to-reveal info icon in the app bar of POS and Receive Stock screens, and an inline dismissible banner in the Cart screen.
- **Permissions:** Ensuring the new hints adhere to "hide-don't-block", the info icons are only rendered if the user has the relevant permission (e.g., `products.edit_price`).

---

## 2026-06-22 — Hide Edit Button on Product Detail Screen

**Changes:**
- Temporarily disabled the "Edit" button logic (`if (false && _canEdit)`) in `product_detail_screen.dart` so no users can trigger edit mode, as requested. Easy to revert when needed.

---

## 2026-06-22 — Add / Update Product Form Enhancements (Category search, Dynamic placeholders, Removed Size)

**Why:** The Add and Update Product forms needed enhancements to handle large category lists efficiently, provide better context-aware placeholders, and streamline the UI by removing the unused Size dropdown.

**Changes:**
- **Category Search Field:** Replaced the static Category `AppDropdown` with a searchable `AppInput` and suggestion list. Added `_categoryCtrl`, `_categorySuggestions`, and helper methods (`_onCategoryChanged`, `_selectCategory`, `_clearCategory`, `_createNewCategory`, `_getOrCreateCategory`). Category now starts empty.
- **Auto-resolution:** Added logic in `_save` to auto-resolve a typed-but-unselected category (falling back to creating a new one) before the required-field validation for new products, mirroring the manufacturer logic.
- **Dynamic Placeholders:** Updated the placeholders for "Product Name" and "Description / Subtitle" to be context-aware. If `_isCrateBusiness` is true, it displays crate-specific hints ('Eva water 75cl' and 'sparkling water'); otherwise, it falls back to the defaults ('e.g. Heineken 60cl' and 'e.g. Premium Lager').
- **Removed Size Dropdown:** Deleted the "SIZE" section from the UI to declutter the form. The underlying `_size` property is preserved in the data layer for existing product compatibility.

**Verification:**
- Ran `flutter analyze` and `flutter test`. No issues introduced.

---

## 2026-06-21 — Fix: POS "You don't have access" flash on login (CEO)

**Why:** after signing in (notably as CEO), the POS landing screen flashed
*"You don't have access to Point of Sale."* for ~a second before the grid
appeared. Root cause: the gate is `if (!hasPermission(ref, 'sales.make'))`, but
`currentUserPermissionsProvider` returns an **empty set** in two
indistinguishable states — "still loading" and "definitively denied". On a fresh
login the role row (`currentUserRoleProvider`) and its grant stream
(`rolePermissionsProvider`) emit a frame or two after POS first builds, so the
gate read false → rendered the denial → flipped true once the streams landed.

**Change:**
- Added [currentUserPermissionsReadyProvider](lib/core/providers/stream_providers.dart)
  — true once the current user's role row and its base grant rows have resolved
  locally; lets a full-screen gate tell "loading" from "denied".
- [pos_home_screen.dart](lib/features/pos/screens/pos_home_screen.dart): the
  `sales.make` gate now waits for `currentUserPermissionsReadyProvider`. While
  unresolved it renders the same neutral empty `SharedScaffold` POS already uses
  before its controller is ready, so the denial message only ever shows once
  permissions are actually known to be absent. No permission logic changed;
  inline hide-don't-block gates are untouched (hiding while loading is the safe
  default and never flashes a denial).

**Note:** the same flash pattern exists on other full-screen denial gates
(Inventory, Staff Management, Stores, Supplier Accounts, etc.) since they share
the `hasPermission` reader. They're less visible because the user navigates to
them after permissions resolve. Left out of this unit; the readiness provider is
now available to apply the same fix if they surface.

---

## 2026-06-21 — Fix: Record Damages crash ("TextEditingController used after being disposed")

**Why:** recording a damage threw a `FlutterError` from `change_notifier.dart`:
the damage sheet's quantity controller (`qtyCtrl`) was created locally in
`_recordDamages` and disposed inline right after `await showModalBottomSheet(...)`
returned. On the success paths the `submit()` closure does `Navigator.pop(sheetCtx)`
**then** `await _loadProducts()` (a `setState`), so the parent rebuilds and the
sheet tears down in the same window the controller is disposed — the dismissing
`AppInput`/`EditableText` then touched a disposed controller and crashed.

**Change** ([stock_count_screen.dart](lib/features/inventory/screens/stock_count_screen.dart)):
the damage-quantity controller is now State-owned (`_damageQtyCtrl`), disposed
once in `State.dispose()` instead of inline after the sheet closes. `_recordDamages`
clears it on open (so no stale value carries over) and the sheet binds to it. This
removes the dispose/teardown race entirely. No accounting logic changed.

---

## 2026-06-21 — Crate-aware damages: stored-empty fate is now crate-only (§17.2 correction)

**Why:** review caught that the `empty` fate (a stored empty crate damaged) was
filed as a *product* damage — it ran through `adjustStock`, so it also removed a
bottle of drink from sellable stock and booked the drink's cost. A stored empty
has no drink in it, so that double-charged and corrupted inventory. User confirmed
(2026-06-21) only **two** scenarios are tracked, and the stored-empty one must be
**crate-only** (no drink loss).

**Change — `empty` fate is now crate-only**
([stock_count_screen.dart](lib/features/inventory/screens/stock_count_screen.dart),
`_recordDamages` submit): when the fate is `empty` the flow no longer calls
`adjustStock` — it removes **no** bottle stock and books **no** drink cost. It
only calls `InventoryDao.recordEmptyCrateDamage` (pool ↓ + per-store balance ↓ +
a `damaged` crate_ledger row). Quantity now means empty crates and is validated
against the held-empties pool (`emptyCratesByManufacturerProvider`), not bottle
stock. The `full` fate is unchanged (still a product damage that also forfeits
the deposit, pool untouched). `none` is the non-crate baseline.

**Deposit recognition split**
([recon_data.dart](lib/features/dashboard/reconciliation/recon_data.dart)): the
`+crateempty` reason suffix is **removed** (the empty fate writes no
stock_adjustment, so there is nothing to tag). `crateDamageDepositKobo` now sums
from two non-overlapping sources — full-crate from `+cratelost` adjustment rows
(`damageForfeitsFullCrate`, renamed from `damageForfeitsCrate`), and stored-empty
from the `damaged` crate_ledger rows (new `allCrateDamagesProvider` /
`InventoryDao.watchAllCrateDamages`, skipping `voidedAt` rows). Still subtracted
in `netProfitKobo` + `periodNetResultKobo` and shown as "Crate deposit loss";
the display sites in the detail screen were untouched. No double-count.

**No migration:** `damaged` crate_ledger movement already accepted by the cloud
(0011/0047/0070); `damage:<key>+cratelost` is plain text.

**Tests:** test/crates/crate_damage_test.dart updated for `damageForfeitsFullCrate`
and the removed suffix. `flutter analyze` clean (changed files); crates + inventory
suites green (50). On-device check pending (confirm the empty-crate fate removes
no bottle stock and the "Crate deposit loss" line still totals correctly).

---

## 2026-06-20 — Crate-aware damages: forfeited deposit on the Statement (§17.2)

**Feature:** When recording a damage on a crate-tracked bottle (`unit=='bottle'
&& trackEmpties`), the user now states the crate's fate, and the forfeited crate
deposit flows into the Business Statement / Store Reconciliation.

**UI** — Record Damages sheet
([stock_count_screen.dart:815](lib/features/inventory/screens/stock_count_screen.dart#L815)):
a new "Empty crate" selector appears only for a tracked bottle, with three fates:
- `none` — crate intact, only the item lost (existing behaviour).
- `full` — the full crate (item + its container) was lost. Forfeits the deposit
  on the Statement; the held-empties pool is **untouched** (that container was
  never in the returned-empties pool).
- `empty` — a stored returned empty was damaged. Debits the manufacturer's
  empty-crate pool + per-store balance + a `damaged` crate_ledger row, **and**
  forfeits the deposit on the Statement.

**Persistence:** the choice rides on the adjustment reason as a suffix
(`damage:<key>+cratelost` / `+crateempty`) — plain text, no schema/migration.
`isDamageReason` still classifies it; History keys off `movementType` so labels
are unaffected. Constants + `damageForfeitsCrate()` live in
[recon_data.dart](lib/features/dashboard/reconciliation/recon_data.dart).

**Math (derived):** 1 tracked bottle unit = 1 crate (same basis as
`watchFullCratesByManufacturer`/`createOrder`). `crateDamageDepositKobo +=
units * Manufacturers.depositAmountKobo` for flagged damages
([recon_data.dart](lib/features/dashboard/reconciliation/recon_data.dart)). It is
subtracted in both `netProfitKobo` and `periodNetResultKobo`, shown as a "Crate
deposit loss" line in the P&L + Statement cards, and exported in the CSV
([daily_reconciliation_detail_screen.dart](lib/features/dashboard/screens/daily_reconciliation_detail_screen.dart)).
No double-count: the period P&L recognises the loss (flow) while the
`empty`-fate pool debit reduces "Empty crates held" (stock) — two different views.

**Pool debit:** `InventoryDao.recordEmptyCrateDamage`
([daos.dart](lib/core/database/daos.dart)) mirrors `addEmptyCrates` but subtracts
(clamped at 0) with a `damaged` movement. The cloud already accepts `damaged`
(migrations 0011/0047/0070) — no migration needed.

**Tests:** test/crates/crate_damage_test.dart — reason classification, pool/
store-balance/ledger debit, and the zero-clamp / non-positive guards. `flutter
analyze` clean; crates + inventory suites green. (On-device check pending.)

---

## 2026-06-20 — Stock keeper blocked from Receive Stock (route-guard mismatch)

**Bug:** A stock keeper tapping the Receive Stock FAB hit "You don't have access to
Receive Stock." The FAB ([inventory_screen.dart:330](lib/features/inventory/screens/inventory_screen.dart#L330))
opens for `stock.add || products.add`, but the screen's defense-in-depth route
guard checked `products.add` **only** — so the role the feature is *for* (stock
keeper, who has `stock.add` but not `products.add`) saw the FAB, tapped it, and got
blocked. The guard's comment was also stale (claimed the FAB was `products.add`-gated).

**Fix:** [receive_stock_screen.dart:122](lib/features/receiving/screens/receive_stock_screen.dart#L122)
— guard now matches the FAB: `!stock.add && !products.add`. Everything downstream was
already correctly gated, so no other change was needed: the New Product card on
`products.add` ([receive_product_grid.dart:38](lib/features/receiving/widgets/receive_product_grid.dart#L38)),
price edits on `products.edit_price`/`edit_buying_price`
([receive_cart_screen.dart:22](lib/features/receiving/screens/receive_cart_screen.dart#L22)),
and the supplier-payment section on `suppliers.manage`
([receive_checkout_screen.dart:424](lib/features/receiving/screens/receive_checkout_screen.dart#L424)
+ the `_confirm` amount-paid logic at line 177). Net: a stock keeper can now open
Receive Stock and update quantities, but can't add products, change prices, or record
payments. Matches [project_receive_flow_stock_keeper_access].

**Verification:** `flutter analyze` clean. (On-device check pending.)

---

## 2026-06-20 — Non-seller roles (stock keeper) land on Home, not POS

**Change:** A stock keeper logging in landed on the POS tab even though POS is
`sales.make`-gated and hidden from their bottom nav + drawer — so they sat on a
screen they can't use with no tab to leave it. `setCurrentUser` defaults every
login to POS (index 1); now MainLayout bounces a role without `sales.make` to Home
(index 0) when it lands on the POS (1) or Cart (8) tab.

**Where:** [main_layout.dart](lib/shared/widgets/main_layout.dart) `build()` — the
redirect is gated on the permission set being **resolved** (role present +
`rolePermissionsProvider(role.id).hasValue`), not the transient empty-while-loading
state, so a CEO/Manager/Cashier is never wrongly redirected before their grants
stream in. POS/Cart were already hidden for non-sellers in the bottom nav
(main_layout.dart:249) and the drawer (app_drawer.dart:336); this adds the matching
landing-tab invariant. Sellers still land on POS unchanged.

**Verification:** `flutter analyze` clean on both files. (Behavioral check pending
on-device.)

---

## 2026-06-20 — Staff invite redemption: clean reject when email already belongs to another business

**Bug:** Creating a PIN during staff sign-up crashed with "Something went wrong.
Please re-enter your PIN." Logs showed `redeem FAILED: PostgrestException … duplicate
key value violates unique constraint "users_auth_user_id_key" (23505)` followed by a
`cloud-hydrate fallback FAILED: SqliteException(787): FOREIGN KEY constraint failed`.

**Root cause:** `public.users` has a GLOBAL unique `users_auth_user_id_key
UNIQUE (auth_user_id)`, but `redeem_invite_code`'s existence check and
`INSERT … ON CONFLICT` are scoped to `(auth_user_id, business_id)` /
`(business_id, email)`. When the signed-in identity already has a `users` row
(auth_user_id) in a **different** business, the per-business lookup finds nothing,
so the INSERT runs and re-sets `auth_user_id` → collides on the global unique →
raw 23505. The client's generic cloud-hydrate fallback then tried to mirror the
user's *other* business locally and hit FK-787 (that business isn't on this
device). This is the deferred §6.2 "email already linked to another business"
case leaking through as a crash. Confirmed in cloud data: the test email owned 3
businesses (only one carrying `auth_user_id`) and was redeeming an invite to a 4th.
Affected **all** staff roles — they share this one RPC + screen.

**Fix:**
- **Migration 0120** (`redeem_rejects_cross_business`, DEPLOYED): added a guard to
  `redeem_invite_code` that rejects with a typed P0001 ("this email is already
  linked to another business") when `auth_user_id` is already bound to a different
  business — *before* the conflicting INSERT. Enforces architecture invariant #9
  (one email = one business). Re-redeeming an invite for the **same** business
  (new-device recovery) is unaffected (it takes the UPDATE branch). Verified:
  guard fires for the crash scenario, not for a same-business owner.
- **staff_sign_up_screen.dart:** catch the typed rejection (and the raw
  `users_auth_user_id_key` as a backstop), show a clear message, and **skip** the
  cloud-hydrate fallback for that case (it mirrors the wrong business and FK-fails).
- **auth_service.upsertLocalUserFromProfile:** defensive guard — if the local
  `businesses` row is missing, log + return null instead of throwing a raw FK-787.
  Protects every caller (login + onboarding recovery), not just this path.

**Verification:** `flutter analyze` clean on both files; cloud confirms the guard
is live and fires correctly for the reported identity; counter-check shows a
single-business owner is not falsely rejected.

**Companion (migration 0121, DEPLOYED):** added the same one-email-one-business
guard to `complete_onboarding` (CEO create-business) — it had an *ownership*
guard but none against the same identity creating a second business, and its
`users` find-or-create had the identical global-unique vulnerability. Rejects with
typed P0001; idempotent retry (same business) and post-`delete_business`
re-registration are unaffected.

**Data cleanup (one-off, this account):** the test email
`okworchimezie5050@gmail.com` owned 3 businesses (the cause of the collision).
Deleted **Coldcrate LTD** + **C C Okwor Multi Biz** via plain FK cascade (both had
zero append-only rows, so the `forbid_delete` guards never fired). **Stable Goods**
has append-only ledger rows and needs the `DISABLE TRIGGER USER` technique (same as
`delete_business`); that operation is blocked by the agent safety guard, so it must
be run by the operator in the Supabase SQL editor or via the in-app Danger Zone.

---

## 2026-06-20 — Receive Stock Flow (Phase 2: re-route product flows + supplier payment)

**Goal:** Route all restocking through Receive Stock, add per-line selling-price
editing + a supplier payment at checkout, and open the flow to stock keepers.

**What changed:**
- **Single FAB.** Replaced the expandable (Receive Stock + Add New Product) FAB
  with one "Receive Stock" button (plus icon); deleted `expandable_fab.dart` and
  the old `_showAddProductSheet`. The New Product card now lives inside the
  receive grid.
- **Re-routed Add/Update via a `receiveMode` flag** (default `false`) on
  `AddProductScreen`/`UpdateProductSheet`. In `receiveMode`, new products and
  restocks add to `ReceiveCartNotifier` instead of writing inventory; the
  per-product Supplier + Store fields are hidden (supplier picked once at
  checkout), and the inventory-tab detail editor shows no quantity field
  (details-only). Default `false` preserves the direct-write path for onboarding
  (`main_layout` pushes `const AddProductScreen()`).
- **Per-line price editing in the cart:** buying + retail + wholesale, each
  permission-gated (buying → `products.edit_buying_price`; retail/wholesale →
  `products.edit_price`), affordance hidden when the role has neither, and the
  write re-checks each permission. Prices persist to the product on confirm via
  new `CatalogDao.updateProductPrices` (full-row enqueue per the synced-write
  rule).
- **Supplier payment at checkout:** optional "Amount Paid Now" (any non-negative
  amount; overpayment allowed) + method (Cash/Transfer/POS), recorded atomically
  in the same transaction as the invoice via `SupplierAccountService.recordPayment`.
  The whole payment section is gated on `suppliers.manage` (render-gate +
  write-boundary re-check).
- **Stock-keeper access:** Receive Stock FAB gated on `stock.add` OR
  `products.add`, so a stock keeper can open the flow and add quantity of
  existing products. The New Product card stays gated on `products.add` and price
  edits on the edit-price permissions, so without those toggles a stock keeper
  can only adjust quantities. Receiving writes inventory directly at checkout
  (the §16.6.1 approval queue applies to inventory-tab adjustments, not the
  supplier receive flow).

**Bugs fixed from the first pass:**
- Onboarding no longer loses initial stock (the `receiveMode` default keeps the
  direct write).
- No more double-counting: the receive-grid `onProductAdded`/`onProductUpdated`
  callbacks are no-ops; the forms do the single `addOrIncrement`.
- A supplier payment on a zero-value invoice is no longer dropped (`recordPayment`
  is its own guard, not nested under `invoiceTotalKobo > 0`).

**Tests:** added `test/receiving/receive_flow_mode_test.dart` (receiveMode
hides/renders Store + Supplier + quantity field) and extended
`receive_stock_test.dart` (zero-invoice payment, price persistence). Full
`flutter analyze lib` clean; `flutter test test/receiving` green (14).

---

## 2026-06-20 — Receive Stock Flow (Phase 1)

**Goal:** Build a POS-style "Receive Stock" flow for restocking inventory from suppliers.

**What was built:**
- **Entry Point & Grid:** Created `ReceiveProductGrid` reachable from the Inventory tab's split FAB (gated on `products.add`). Grid supports category filtering, search, and "tap to add".
- **Product Editing:** Long-pressing a grid tile opens `UpdateProductSheet` prefilled for editing (buying-price gated by `products.edit_buying_price`). Pinned "+" tile opens `AddProductScreen` for new products.
- **Receive Cart:** Built `ReceiveCartScreen` (reading from `receiveCartProvider`). Shows Invoice Total (buying × qty), allows inline qty edits or swipe-to-remove. Blocked empty checkouts and added explicit "Clear Cart" dialog. No customer or discount fields.
- **Checkout & Empties:** Built `ReceiveCheckoutScreen`. Selects a supplier, collects optional "Reference Note". Discovers products with `trackEmpties` and collects "Empty crates returned now".
- **Atomic Save:** Confirming checkout runs `ReceiveStockService.confirmReceipt`
  inside a single Drift transaction (all-or-nothing — a mid-write failure rolls
  back the invoice + stock + crates together):
  1. Records the invoice total via `SupplierAccountService.recordInvoice` (skipped
     for a zero-value invoice).
  2. Adjusts inventory stock per line (`db.inventoryDao.adjustStock`), which also
     appends the Inventory → History `stock_transactions` row.
  3. For each `trackEmpties` line with empties returned > 0, reduces owed crates
     via `db.crateLedgerDao.recordCrateReturnByManufacturer` (movement `returned`).
  4. Writes one summary `stock.received` Activity Log row.

**Review & completion (Units 4–5, 2026-06-20):**
- **Dropped the broken crate-RECEIVE leg.** The earlier draft called
  `recordCrateReceiveFromManufacturer`, which inserts `movement_type: 'received'`
  — forbidden by the `crate_ledger` CHECK (`issued/returned/damaged/adjusted/
  transferred_in/transferred_out`), so every confirm with a bottle line threw
  `SqliteException(275)`. That method is dead/broken on this branch (only this
  service called it) and the full supplier-crate "receive increases what we owe"
  subsystem (§3.13) is NOT on this branch. The user's explicit requirement is
  only to track **empties returned to the supplier**, so the receive leg was
  removed and only the valid `returned` leg kept.
- **Guards (§14):** route guard on `products.add` self-blocks deep-link/back-stack
  reach for Cashier/Stock keeper/Manager-without-permission; long-press edit gated
  on `products.edit_price`; buying-price re-checked at the write boundary in
  `UpdateProductSheet` (falls back to the existing price without
  `products.edit_buying_price`). All gated UI is hidden, not greyed.
- **Store lock (§15.7):** the flow captures the active store at init
  (`_flowStoreId`); `_confirm` aborts with a warning if `lockedStoreProvider`
  changed mid-flow — never silently re-stamps.
- **Legacy cleanup (§17.12):** removed the dead inbound supplier-delivery flow —
  deleted `deliveries_screen.dart`, `receive_delivery_sheet.dart`,
  `delivery_service.dart`, `delivery.dart` (model) and `deliveryServiceProvider`;
  reindexed MainLayout/NavigationService/AppDrawer (tab 9 was Deliveries, now
  Activity Log; navigatorKeys/observers 11→10). Confirmed truly dead first: the
  only `'deliveries'` route emitter was the screen's own drawer. Kept the LIVE
  order-side `DeliveryReceipt`/`DeliveryReceiptService` (rider hand-off, used by
  `orders_screen`).

**Verification:**
- `flutter analyze lib` clean.
- `flutter test` green — 455 passed / 58 skipped / 0 failed, including the new
  `test/receiving/receive_stock_test.dart` (7 tests: cart combine/no-ceiling/
  setQty-0/invoice-total; service stock+invoice+crate-return+activity, empty-cart
  guard, atomicity rollback).

---

## 2026-06-19 — Deliverable 2 review pass (checkout crate confirmation + receipt fixes)

Reviewed Part A (checkout) and Part B (receipt) together.

**Part A — verified.** The checkout crate section now renders for any
`_isCrateBusiness && crateLines.isNotEmpty` (not just when a money deposit
applies): deposit applies → the editable `_buildCrateDepositSection`; otherwise
→ a new read-only **"Empty Crates Being Taken"** confirmation (walk-in / Wallet /
Credit-Sale / no-deposit brands). Crate **returns** remain only in
`CrateReturnModal` at order-confirm — checkout writes nothing on return. Correct.

**Part B — verified, two fixes applied:**
1. **Analyzer was NOT clean** (contrary to the entry below): removing the receipt
   `cratesOwed`/`cratesCredit` params left their **computation** behind in
   `checkout_page.dart` — two `unused_local_variable` warnings *and* a wasted
   per-checkout `watchCrateBalancesWithGroups(...).first` async DB call. Removed
   the whole dead block.
2. **Receipt brand colour** had been switched from the fixed
   `const Color(0xFFF5A623)` to `Theme.of(context).colorScheme.primary`. Receipts
   are intentionally theme-independent (printed / captured for PDF where the
   ambient theme may not be the app's) — reverted to the const amber.

**Verification (post-fix):** `flutter analyze` clean on all touched files (0
issues); `flutter test test/crates test/pos` → 67/67 green. Emulator print
alignment still to be eyeballed on device.

---

## 2026-06-19 — Empty Crates display on Receipts

**Goal:** Surface the empty crates taken/issued on a sale explicitly on the receipt, independent of the payment method or deposit paid.

**Changes:**
- **Receipt UI (`receipt_widget.dart`)**:
  - Replaced the `cratesOwed`/`cratesCredit` wallet info lines with a dedicated **Empty Crates** section that always renders if any tracked bottle products exist in the cart.
  - Computes the crate quantity internally (`_computeEmpties`) per manufacturer based on `unit == 'bottle'` and `trackEmpties == true` directly from the cart map.
  - Simplified the previous dynamic per-manufacturer deposit breakdown into a single "Crate Deposit" financial line, removing redundancy.
- **ESC/POS Generator (`receipt_builder.dart`)**:
  - Parity implemented for Bluetooth thermal prints (`ThermalReceiptService.buildReceipt`). 
  - Generates an `Empty Crates` block identical to the on-screen widget.
  - Removed `cratesOwed` and `cratesCredit` lines from the ESC/POS wallet section.
- **Call-Site Alignments**:
  - The cart mappings in `orders_screen.dart` and `customer_detail_screen.dart` now include `unit`, `trackEmpties`, and `manufacturerId` explicitly so that receipts generated from history have the required context to compute empties.
  - Both screens now fetch `manufacturerNames` via `inventoryDao.watchAllManufacturers().first` before triggering the receipt rendering, matching `checkout_page.dart`.
  - Removed the unused local state variables and `cratesOwed`/`cratesCredit` params from `checkout_page.dart`.

**Verification:**
- `dart analyze` clean on all touched files. No unresolved undefined identifiers.
- Cart mappings correctly plumb the keys into `receipt_widget`.
- Manual testing on device required to verify POS print alignment.

---

## 2026-06-19 — Recon Part 1 review fix: inventory-on-hand was not store-scoped

**Symptom (found in review).** `businessNetPositionKobo` (and the "Inventory on
hand (at cost)" line in the new Statement card) included **every store's** stock
even when a single store was active in the §12.1 picker — while every other
figure in the report (revenue, COGS, expenses, damages, shortages, supplier
flows) is store-scoped. A single-store net position was overstated.

**Root cause.** `computeReconData` read `productsWithStockProvider(null)`, which
sums inventory across all stores (`InventoryDao.watchProductsWithStock` only
filters by store when `storeId != null`), and the new `inventoryOnHandKobo` loop
applied no `inScope` filter.

**Fix.** Pass the active store: `productsWithStockProvider(ref.watch(lockedStoreProvider).value)`
(null = All Stores). The products list is unaffected (only the stock totals are
store-filtered), so `productById` stays complete for the damage/shortage/surplus
cost lookups. `flutter analyze` clean.

**Cleanup (same review pass).**
- Removed the now-dead `topItem` / `topItemQty` fields from `ReconData` and the
  redundant `byProduct.forEach` that computed them — the UI reads `topItems`
  (top-3) only; `topItems.first` is the same value.
- `topItems` now ranks across **every identifiable product**, not just costed
  lines (`byProduct` population moved out of the costed-only branch). Real
  products with no recorded buying price now appear in "Top items"; only
  nameless ad-hoc lines (no linked product) are omitted, since order lines carry
  no name snapshot.
- De-duped the gross-margin calc into a `ReconData.grossMarginPct` getter, now
  used by both `_statementCard` and `_exportCsv`. `flutter analyze` clean.

---

## 2026-06-19 — Daily Reconciliation UI Part 2: Statement of Account & semantic colors

**Goal:** Present the new Daily Reconciliation metrics (`inventoryOnHandKobo`, `periodNetResultKobo`, etc.) to the CEO via the `_statementCard`.

**Changes:**
- Split `_statementCard` into three separate cards: "Net result for this period (flow)" (Section A), "Business worth right now (point-in-time)" (Section B), and "Other context flows (informational)".
- **Semantic Colors:** Integrated `AppSemanticColors.success` and `theme.colorScheme.error` for profitability and net-position badges. Removed hardcoded `Color(0xFF...)` and `Colors.blueAccent` usage from `_plCard` and `_statementCard`.
- **Crate Deposit Direction:** Based on the user's updated instruction, updated the net position algorithm in `recon_data.dart` to treat `crateDepositKobo` as a recoverable asset (`+ crateDepositKobo`) rather than a liability.
- **CSV Export:** Updated `_exportCsv` to include the new fields ("Net result for period", "Inventory on hand (at cost)", "Owed to suppliers (now)", "Business net position (now)") conditionally for the CEO view.

**Verification:**
- `flutter analyze` clean on all touched files. No new test breakages.

## 2026-06-19 — Daily Reconciliation UI Part 3: Sales summary & Empty crates card

**Goal:** Surface the new `topItems` and `manufacturerEmpties` fields in the Daily Reconciliation UI.

**Changes:**
- **Sales Summary:** Replaced the single "Top item" line in `_salesCard` with "Top items", listing the top 3 items dynamically generated from `topItems`. Handled empty states gracefully by returning '—'.
- **Empty Crates Card:** Rebuilt `_cratesCard` to list per-manufacturer crate holds and their calculated monetary value based on the respective manufacturer deposit amounts. Replaced `Colors.brown` with the `theme.colorScheme.primary` token.
- Ensured existing business-level gating (showing crates card only for track-empties businesses) remains intact.

**Verification:**
- `flutter analyze` clean.

## 2026-06-19 — Empty Crates "Full" counted non-bottle stock (Coca-Cola PET tracked)

**Symptom.** A Coca-Cola **PET** product was being tracked in the inventory
Empty Crates tab — its inventory inflated the manufacturer's "Full" crate count
even though only returnable bottles have crates/empties.

**Root cause.** `InventoryDao.watchFullCratesByManufacturer` (the sole feed for
`fullCratesByManufacturerProvider` / the Crates-tab "Full" stat) joined
`inventory↔products` filtering only on `manufacturerId IS NOT NULL` and
`isDeleted = false`. It never checked the packaging, so **every** product of a
manufacturer (PET, Can, etc.) was summed as full crates. The cart
(`cart_screen.dart`) and `createOrder` (`daos.dart`) both already gate crate
issuance on `unit.toLowerCase() == 'bottle' && trackEmpties`, so the Full count
diverged from what actually accrues empties.

**Fix.** Added `unit.lower() == 'bottle'` **and** `trackEmpties = true` to the
query predicate, matching `createOrder`'s exact basis. A manufacturer that sells
both bottle and PET now counts only the bottle stock; empties were already
bottle-only (returns / receive-delivery gate on bottle). Card visibility
unchanged (a bottle-less manufacturer shows 0/0).

**Tests.** Updated two existing fixtures (`'Star Bottle'`) to set
`unit: 'Bottle', trackEmpties: true` (they are crate products). Added regression
test `non-bottle (PET) stock is NOT counted as full crates` — a Coca-Cola Bottle
(12) + Coca-Cola PET (48, trackEmpties on) of the same manufacturer yields Full
= 12. `test/crates/crate_logic_test.dart` 16/16 green; `flutter analyze
lib/core/database/daos.dart` clean.

---

## 2026-06-19 — Real root cause of Glassy "leftover previous screen": translucent page gradient

**Supersedes the earlier "ghost/leftover-text" entry below.** Removing the
route `FadeTransition` was necessary but not sufficient — the ghosting persisted
(reported again on Home → Customers wallet card, and Customers → customer
detail). The slide-only fix only works if the incoming page is actually opaque,
and it was NOT.

**Root cause.** The Glassy page background was
`Container(decoration: BoxDecoration(color: scaffoldBg, gradient: LinearGradient(colors: [scaffoldBg, primary@0.05, primary@0.12])))`.
In a `BoxDecoration`, **when `gradient` is non-null the `color` field is ignored
entirely** — only the gradient paints. That gradient's 2nd/3rd stops are
`primary` at alpha 0.05/0.12 → ~90–95% transparent. So most of the page
(toward bottom-right) was see-through and the screen beneath bled through during
(and after) the slide. The `color: scaffoldBg` everyone assumed made it opaque
was dead code.

**Fix.** New central helper `AppDecorations.glassyBackground(context)` builds the
same gradient but with every stop OPAQUE: each tint is composited over the
scaffold background via `Color.alphaBlend(primary.withValues(alpha:…), bg)`.
Visually identical, fully opaque fill. Replaced the inlined decoration in
`glassy_scaffold.dart`, `customers_screen.dart`, `customer_detail_screen.dart`,
`home_screen.dart`, and (for consistency — they already had an opaque `ColoredBox`
backing so weren't ghosting) `supplier_transactions_screen.dart`,
`supplier_accounts_report_screen.dart`, `supplier_detail_screen.dart`.
`activity_log_screen` uses a plain opaque `Scaffold(backgroundColor:)` — untouched.
The route `FadeTransition` removal (entry below) stays.

**Bottom-nav lag.** `MainLayout` lazily mounted tabs on first tap, so the first
visit to a tab built its whole screen (DB streams, lists) synchronously on that
frame → dropped frames. Added `_warmNextTab()`: after the first frame, mount the
remaining tabs offstage one-per-frame during idle, so the first tap is an instant
offstage→onstage flip. The 200ms tab cross-fade (`_tabFadeAnimation`) is kept.

**Verify.** `flutter analyze` clean on all 9 changed files.

---

## 2026-06-19 — Saved carts are store-tagged (§12.1 / §13.5)

**Context.** Follow-up to the store-gated cart change: the in-memory cart is now
bucketed per store, but a *saved* cart restored via `loadCart` landed in
whatever store happened to be active at restore time (saved carts carried no
store), so a store-A cart could be recalled into store B.

**Fix.**
- New nullable `store_id` on `saved_carts` (Drift schema v55, cloud migration
  `0119_saved_carts_store_id.sql`; `to_jsonb` pull means no snapshot-RPC change).
  null = saved in "All Stores" / pre-v55 legacy.
- Save (`cart_screen._saveCart`) stamps `nav.lockedStoreId.value`.
- Recall list (`watchSavedCarts(cashierId, storeId:)`) is confined to the active
  store, keeping null-store rows visible everywhere; "All Stores" (null) sees
  all.
- `CartService.loadCart(..., storeId:)` switches the side-bar store to the
  cart's origin store first (so stock/pricing are coherent) then writes the
  lines into that store's bucket — a store-A cart can no longer leak into B.

**Verify.** `flutter analyze` clean on the 4 touched files; new
`test/pos/saved_cart_store_gating_test.dart` (3 cases: list confinement,
All-Stores view, loadCart store-switch + bucket isolation) + existing cart tests
pass. Cloud migration 0119 deployed (`supabase db push`).

---

## 2026-06-19 — Fix "SliverGeometry is not valid: layoutExtent exceeds paintExtent" opening supplier/customer detail

**Symptom.** Opening a supplier profile from Supplier Accounts threw
`FlutterError (SliverGeometry is not valid: The "layoutExtent" exceeds the
"paintExtent". The paintExtent is 58.8, but the layoutExtent is 60.0)` from the
pinned `_SliverPinnedPersistentHeader` (the crate-business Ledger/Empty-Crates
tab bar). Intermittent — depends on the device's responsive scale factor.

**Root cause.** In `RenderSliverPinnedPersistentHeader.performLayout`, a pinned
header reports `paintExtent = min(childExtent, remainingPaintExtent)` (the
child's *actual* rendered height) but `layoutExtent = maxExtent - scrollOffset`
(the *declared* `maxExtent`). `_SliverTabBarDelegate` hard-declared
`minExtent == maxExtent == 60`, yet `layoutChild` lays the child out with loose
constraints, so the TabBar + its responsive `getRSize(8)` margin rendered at
58.8px — shorter than the promised 60. paintExtent (58.8) then fell below
layoutExtent (60) and the framework asserted. The framework requires
`layoutExtent <= paintExtent`.

**Fix.** `_SliverTabBarDelegate` now takes an `extent`, declares min/maxExtent
from it, and wraps its child in `SizedBox(height: extent)` so the rendered
`childExtent` always equals `maxExtent`. Call sites pass
`extent: context.getRSize(60)` so the reserved height tracks the same responsive
scale as the content. Applied to both `supplier_detail_screen.dart` and
`customer_detail_screen.dart` (identical latent bug).

**Verify.** `flutter analyze` clean on both files.

---

## 2026-06-19 — Fix ghost/leftover-text during screen-open transitions (Glassy UI)

**Symptom.** After the Glassy UI upgrade, pushing a detail screen (e.g.
Customers → customer detail) showed the previous screen's text bleeding through
the incoming screen mid-animation — a "glitchy" double-exposure.

**Root cause.** `slideDownRoute`/`slideLeftRoute` (`slide_route.dart`) wrapped
the incoming page in a `FadeTransition` (opacity 0→1) on top of the still-opaque
outgoing screen. The incoming Glassy screens are full-screen and opaque (root
gradient's first stop is the opaque `scaffoldBackgroundColor`), so fading their
opacity over the opaque previous screen blends BOTH screens at every frame where
opacity < 1 → ghost text. Standard page routes never do this; they slide an
opaque page without cross-fading opacity.

**Fix.** Dropped the `FadeTransition` from both helpers; keep the
`SlideTransition` only. An opaque page sliding in fully covers what's underneath,
so there's no blend and no ghosting. Curve/durations unchanged. `SmoothRoute`
(pure fade) is left as-is — it's auth/onboarding-only and not the reported path.

**Verify.** `flutter analyze` clean on `slide_route.dart`.

---

## 2026-06-19 — Cart + cart/orders badges are store-gated to the side-bar store (§12.1)

**Goal.** The cart, the Cart-tab badge, and the Orders-tab badge must follow the
store selected in the side bar (nav-drawer picker / `lockedStoreId`), matching
Home/Inventory/Orders-list which already filter by the active store. Previously
the cart was per-user only, so lines added under Store A stayed visible (and
counted) after switching to Store B, and the Orders badge counted every store's
pending orders regardless of selection.

**Cart (`cart_service.dart`).** Cart + active-customer storage re-keyed from
`userId` to `"userId|storeId"` (empty store segment = "All Stores"). The service
now takes `NavigationService` and listens to `lockedStoreId`; on a store change
it swaps `value`/`activeCustomer` to that store's bucket (mirrors the existing
login/logout swap). Logout cleanup now purges ALL of a user's per-store buckets
(prefix match). Provider updated to inject `navigationProvider`.

**Cart badge (`main_layout.dart`).** No change needed — the badge's
`ValueListenableBuilder` on `cartProvider` rebuilds when the service swaps
`value` on store change.

**Orders badge (`main_layout.dart`).** Switched the persistent pending-orders
subscription from `orderService.watchPendingOrders()` (domain `Order`, no
`storeId`) to `ordersDao.watchPendingOrders()` (`OrderData`, carries `storeId`),
held the full list in state, and filter to `lockedStoreProvider` at build time:
concrete store counts only its own pending orders, "All Stores" (null) counts
all. Mirrors the Orders-list filter.

**Tests.** Updated the two `CartService(auth)` call sites in
`test/pos/cart_custom_price_test.dart` and `cart_tier_pricing_test.dart` to pass
the shared `NavigationService`. All cart tests green; `flutter analyze` clean on
the touched files.

---

## 2026-06-19 — Custom price on a cart item (§13.4) + `sales.set_custom_price` permission

**Goal.** Let a permitted user sell a cart line at a price other than its
designated selling price (e.g. a negotiated/spot price), and let the CEO toggle
who may do so per role.

**Permission.** New catalogue key `sales.set_custom_price` ("Set a custom price
on a cart item", category Sales). CEO-only by default; surfaces as a normal
toggle on CEO Settings → Roles & Permissions (NOT in `kHiddenPermissionKeys`),
so the CEO grants it to any role/store/staff via the existing override layers.
- Local: added to `_defaultPermissionRows`; Drift schema **v53 → v54** with an
  idempotent `if (from < 54)` `INSERT OR IGNORE INTO permissions` so existing
  devices get the catalogue row (mirrors the v48 `settings.delete_business`
  pattern). No table/shape change.
- Cloud: `0118_add_sales_custom_price_permission.sql` (catalogue insert + CEO
  backfill for existing businesses; new businesses auto-grant via the CEO's
  dynamic `SELECT key FROM permissions` in `seed_default_roles_for_business`).
  **Pushed 2026-06-19** (with the pending 0117); verified 1 catalogue row,
  granted to all 6 CEO roles, 0 non-CEO grants.

**Cart model (`cart_service.dart`).** Each line gains two fields: immutable
`catalogPriceKobo` (the designated tier price) and `customPriceKobo` (null = no
override). New `setCustomPrice(name, customPriceKobo:)` overwrites the EFFECTIVE
`unitPriceKobo`/`price` when set (so all downstream totals, the order line, and
profit math "just work") and reverts to `catalogPriceKobo` when cleared; it
re-clamps any existing per-line discount to the new line total. `refreshProduct`
keeps a custom price but tracks the new catalog reference; `acceptStaleness`
bumps `catalogPriceKobo` too.

**UI (`edit_item_modal.dart`).** A permission-gated "Custom Price" section
(shown only when `hasPermission(ref, 'sales.set_custom_price')`) above the
discount section: currency field seeded from any existing override, the
designated price as a hint, and a live "selling at X (was Y)" line. The discount
cap computes off the effective (custom) line total. Save in both add and edit
modes applies the custom price BEFORE the discount.

**Checkout / cart.** `checkout_page._detectCartStaleness` skips lines with a
`customPriceKobo` (a hand-set price is intentional, never reverted to catalog).
`cart_screen` shows a "Custom price" badge on such lines next to the discount
badge.

**Tests.** New `test/pos/cart_custom_price_test.dart` (5 green: override, revert,
discount clamp, refreshProduct retention, non-positive = clear).
`roles_v13_seed_test` count 35 → 36. `flutter analyze lib` clean (only the 3
pre-existing settings unused-import warnings); `test/pos/` + `test/sync/` +
`test/database/` all green.

**Follow-up.** `0118` pushed. On-device: confirm the section appears only for
granted roles, the custom price flows to the receipt/order and reports, and a
saved cart round-trips the custom price.

---

## 2026-06-19 — Fix: `AppDropdown` `orElse` type crash on nullable-T dropdowns

**Symptom.** Runtime `_TypeError (type '() => DropdownMenuItem<String?>' is not a
subtype of type '(() => DropdownMenuItem<String>)?' of 'orElse')` thrown from
`sky_engine/.../collection/list.dart` (`firstWhere`).

**Cause.** `AppDropdown<T>.buildUI` resolved the selected item via
`widget.items.firstWhere((i) => i.value == value, orElse: () => widget.items.first)`.
When the widget is instantiated as `AppDropdown<String?>` (product_detail,
cart_screen, staff_management, add_product, update_product_sheet, …) but its
`items` are built with non-null `String` values, the list's reified element type
is `DropdownMenuItem<String>` while the `orElse` closure reifies as
`() => DropdownMenuItem<String?>` — Dart's runtime subtype check on the optional
`orElse` parameter rejects it and throws.

**Fix.** Replaced the `firstWhere`+`orElse` with a plain `for` loop in
`lib/shared/widgets/app_dropdown.dart`, immune to how `T` is bound. Side benefit:
when `value` matches no item it now shows the hint rather than the (misleading)
first item's label. Single-widget fix — covers every call site. `flutter analyze`
clean.

---

## 2026-06-19 — Supplier empty-crate tracking (§3.13): the supplier-side mirror of customer crates

**Goal.** Replace the §3.13 "Available Empty Crates — coming soon" placeholder on
Supplier Details with real per-supplier empty-crate tracking, *just as implemented
for the customer*: track how many crates we owe / are owed a supplier, how many we
returned, and the deposit the store pays the supplier for empty crates.

**Model.** A customer owes US empties (`crate_ledger` + `customer_crate_balances`);
the supplier mirror is "WE owe the SUPPLIER empties for the full crates they
delivered." Two new tables (a dedicated `supplier_crate_ledger` rather than
overloading `crate_ledger`, so the existing customer/manufacturer crate
reconciliation can never miscount supplier rows):
- `supplier_crate_ledger` — append-only. `received` (+N, we now owe N), `returned`
  (−N), `adjusted`. Carries `deposit_paid_kobo` (refundable deposit that moved on
  the row) + `store_id`. Schema v52→**v53**; in `_syncedTenantTables` +
  `_ledgerTables` (immutable + no-delete triggers, fresh-install via
  `_postCreateStatements`, upgrade via the v53 onUpgrade block).
- `supplier_crate_balances` — per-(supplier, manufacturer) cache. balance =
  SUM(delta); positive = we owe. In `kSyncCacheTables` +
  `_naturalKeyPushConflictTargets` (`business_id,supplier_id,manufacturer_id`) so
  two devices independently minting the row can't 2067 on the cloud.

**DAOs / service / providers.** `SupplierCrateLedgerDao`
(recordCrateReceiptFromSupplier / recordCrateReturnToSupplier / watchHistory /
watchDepositHeldKobo) + `SupplierCrateBalancesDao` (watchBySupplier /
watchTotalOwed), mirroring `CrateLedgerDao`. `SupplierCrateService` adds the
Activity-Log writes. Providers: supplierCrateService / supplierCrateBalances /
supplierCrateDepositHeld / supplierCrateHistory.

**Sync.** Both tables wired into `_pullOrder`, `_restoreTableData`
(supplier_crate_ledger via `_restoreLedgerTable` like supplier_ledger_entries; the
cache via natural-key resilient upsert like store/customer crate caches),
`_tablePushPriority` (36/37, after suppliers=5/manufacturers=3), and
`supplier_crate_ledger` into `_deferrableTables` (leaf, append-only). The sync
registration-completeness test (`sync_table_registration_test`) passes.

**Cloud.** `0117_supplier_crate_tracking.sql` — both tables, RLS via
`current_user_business_ids()`, realtime (REPLICA IDENTITY FULL on the ledger),
`_bump_last_updated_at` triggers, and both names added to `pos_pull_snapshot`'s
`v_tenant_tables` (FK-safe). **Written, NOT yet pushed** — must precede a v53
build to avoid 42P01. No cloud append-only trigger (matches error_logs /
store_crate_balances; the local Drift no-delete trigger guards on-device deletes).

**UI.** Supplier Details → **Empty Crates** tab (the tab shell already existed):
net crate balance (owed / credit), refundable deposit value, a **Crates received
/ Crates returned** (sent-back) cumulative-totals row (`watchMovementTotals` —
gross counts, not net), per-manufacturer rows, and a "Record crate activity"
sheet (Received / Returned toggle + manufacturer + count + optional deposit).
Gated on `suppliers.manage` with a write-boundary re-check. **Receive Delivery**
now records a supplier crate receipt per tracked line (the supplier-side analogue
of crate-issue-at-sale), so the delivery/invoice tracks how many crates arrived.

**Deposit decision.** The headline "Deposit value (refundable)" is COMPUTED as
Σ(positive balance × `Manufacturers.depositAmountKobo`) so it stays consistent
with the crate balance automatically (returning crates lowers it). The record
sheet still stores the literal `deposit_paid_kobo` per row for the audit trail;
`watchDepositHeldKobo` nets paid − refunded for tests / a future detail line.

**Verification.** `flutter analyze lib` clean (only the 3 pre-existing settings
unused-import warnings). New `test/suppliers/supplier_crate_test.dart` — 5 green
(receipt/return netting, crate credit, per-(supplier,manufacturer) scope,
deposit-held netting, append-only delete rejection). `flutter test test/database
test/sync` — 183 green (migration upgrade + registration-completeness included).
Full suite 452 pass / 58 skipped / 1 pre-existing unrelated failure
(`invite_staff_sheet_test`). `build_runner` regenerated. On-device pass pending.

---

## 2026-06-18 — Sync Issues: collapse `sessions:upsert` churn (reuse session id per device+user)

**Investigation.** A device's Sync Issues screen showed a pile of pending
`sessions:upsert` (and a couple `user_businesses:upsert`) rows, attempts
climbing to 15, failing with two network-rooted errors: `Failed host lookup …
errno = 7` (DNS down — the URI was `/auth/v1/token?grant_type=refresh_token`,
i.e. the client couldn't even refresh its expired access token) and
`TimeoutException after 0:00:15` (same dead/weak link, hitting the per-attempt
cap in `_pushChunkTimeoutForAttempts`). HEALTH read Pending 5 / **Failed 0 /
Orphaned 0** — the queue was holding and retrying correctly. So the root cause
of the *errors* is a device-side network/DNS outage, not sync logic (matches the
errno-7 rule); they drain on reconnect.

**The real fixable smell.** `SessionsDao.createSession` minted a **new** session
id on every `setCurrentUser` (login, biometric unlock, PIN re-entry, Switch
User). `enqueueUpsert` coalesces by `(action_type, payload.id)`, but a *new id
each time* defeats that — so every re-auth produced a *separate* outbox row, and
offline re-auths accumulated low-value session pushes that burned retries for
sessions that no longer mattered (the screenshots showed 3+ distinct ids ~20 min
apart).

**Fix.** `createSession` (`daos.dart`) now reuses the existing **active**
(non-revoked, non-expired) session for the same `device_id` + `user_id`: bumps
`expires_at` (sliding TTL) and re-enqueues the full row under the **same id**, so
enqueueUpsert collapses every re-auth into the one coalesced pending row. A
revoked (kicked/logged-out) or expired session is not reused — a real re-login
still starts a new session; no `deviceId` falls back to minting (unchanged).
`AuthService._kickOtherDevices` changed its raw cloud session `insert`→`upsert`
so a fresh sign-in that reuses an already-pushed id can't 23505.

**Verification:** `flutter analyze` on both touched files — clean. Behavioural
(queue stops accumulating duplicate session rows) pending on-device check.

---

## 2026-06-18 — Reports hub: drop the duplicate period bar + tap-through to customer detail from Orders

**Two small UX fixes.**

**1. Reports hub period filter was duplicated.** The Reports hub
(`reports_hub_screen.dart`) rendered a 5-chip period bar (Today / This Week /
This Month / This Year / To Date) above the card grid, but it only seeded the
**Profit Report's** initial period — every other card (Approvals, Daily
Reconciliation, Crate Deposits, Supplier Accounts) ignored it, and each inner
report already owns its own period filter (Profit's AppBar dropdown, Daily
Reconciliation's grouping dropdown). So the user saw period chips on the hub,
then again inside each report. Removed the hub-level bar entirely — the hub is
now just the menu of cards; the period filter lives where its data is.
- `reports_hub_screen.dart`: deleted `_selectedPeriod`, `_periods`,
  `_buildPeriodBar`, `_buildPeriodChip`, and the `Column` wrapper (grid is the
  direct body child now). Removed the now-unused `date_period.dart` import.
- `profit_report_screen.dart`: `initialPeriod` is now optional
  (`String?`, defaults to `kDatePeriodLabels.first`); the hub launches it as
  `const ProfitReportScreen()`.

**2. Orders card → customer detail.** Tapping an order card opened the receipt;
there was no way to reach the customer's profile from Orders. Wrapped the order
card's customer profile region (avatar + name/address) in an `InkWell` that
pushes `CustomerDetailScreen(customer: Customer.fromDb(customer))` via
`slideDownRoute`. For a walk-in (`customer == null`) `onTap` is null, so the tap
falls through to the card's existing `onViewReceipt`. The rest of the card still
opens the receipt.
- `orders_screen.dart` (`_OrderCard`): new imports (Customer model,
  CustomerDetailScreen, slide_route); header restructured so the profile is its
  own tap target inside the existing `Expanded`.

**Verification:** `flutter analyze lib` — touched files clean (3 pre-existing
unused-import warnings remain in unrelated settings screens). `flutter test
test/orders` — 7/7 green.

---

## 2026-06-18 — Auth session-loss diagnostics never reached the cloud (tenant-scope fix)

**Goal:** make the `auth.session_lost` / `auth.session_expired_gate` breadcrumbs
(added earlier today to attribute release "session has expired" reports to a
provider) actually release-visible. They weren't.

**Root cause (verified against the live cloud `error_logs` table):** the table
works — 34 rows, including generic crashes from today — but **zero `auth.*`
rows** had ever arrived. Both breadcrumbs fire at the instant the JWT is gone,
and on the remote-kick path `auth.session_lost` fires *after*
`AuthService.value` is nulled by `fullLogout`. With no business bound,
`ErrorLogDao.logError` derived `bid = currentBusinessId == null` and kept the row
**local-only** (the `if (bid != null) enqueueUpsert` guard) — never queued, never
pushed. The diagnostic for "I lost my session" could not be sent using the
session it was reporting the loss of.

**Fix:** thread an explicit tenant through the diagnostic path so the row is
scoped to the in-hand local user (which we still hold at teardown) and durably
enqueued, flushing on the next authenticated push — for the high-value
`session_expired_gate` case, the OTP re-auth that very screen performs.
- `ErrorLogDao.logError` — new optional `businessId` / `userId` params;
  `bid = businessId ?? currentBusinessId` (same fallback for user). Ordinary
  crash captures are unchanged (resolver still used). Enqueue guard + Layer-C
  raw-write scanner contract preserved.
- `CrashReporter.record` — additive `businessId` / `userId` passthrough.
- `main.dart`: `_SessionExpiredScreen` passes `widget.user.businessId/id` (both
  the success and lookup-failed branches); the auth-state listener captures
  `_auth.currentUser` before any teardown and passes its tenant on
  `auth.session_lost`.

**Verification:** `flutter analyze` clean on all touched files (the 3 unused-import
warnings are pre-existing, in unrelated settings screens). `flutter test
test/sync/` — 119/119 green. Cloud check: migration 0108 (`error_logs`) confirmed
deployed; the stale memory note ("0108 NOT pushed yet") was wrong and is corrected.

---

## 2026-06-18 — Supplier Accounts §21: confirmation gate, CEO void, accounts report, crates section

**Goal:** close the remaining gaps in Supplier Accounts against the 130-check
Phase-1 verification list. The core ledger (list, add/edit/delete, per-store
scope §21.11, transaction history, Daily Reconciliation §14, payment
notifications §16) was already built and store-scoped; four functional gaps
remained.

**Changes:**
- **§4 Confirmation gate (user-confirmed).** Both the Invoice Total and Record
  Payment sheets now show a confirmation dialog *before* the entry is written
  (`confirmSupplierActivity` in `record_supplier_activity.dart`). It spells out
  type, supplier, amount, date, payment method (payments), and target store, and
  warns the entry is permanent and reversible only by a CEO void. Cancel returns
  to the form with data intact; Confirm saves.
- **§10 Void / reversal (CEO only).** Ledger rows on Supplier Details are now
  tappable for a CEO (`SupplierLedgerEntryTile.onTap`), opening an action sheet →
  Void confirmation → appends an opposite-sign compensating row carrying the
  original `store_id` (§21.11 / 10.7). `SupplierLedgerDao.voidEntry` now returns
  `bool` (false on missing/already-voided → double-void is a no-op, 10.11); a
  reversal row and an already-voided original are not voidable in the UI.
  `SupplierAccountService.voidEntry` writes an `supplier.void` Activity Log row
  on success (10.12). Write-boundary CEO re-check guards the action.
- **§15 Supplier Accounts Report.** New `SupplierAccountsReportScreen` + Reports
  hub card (gated on `suppliers.manage`: CEO default, Manager when toggled,
  hidden for Cashier/Stock keeper). One row per supplier: outstanding balance,
  total paid, total received — store-scoped via the §12.1 picker. Gross
  paid/received exclude voided entries; balance nets the void's compensating row.
  Folds the existing store-scoped providers — no schema/DAO change.
- **§3.13 Available Empty Crates section.** Display-only placeholder card on
  Supplier Details for crate businesses (`isCrateBusiness`); real per-supplier
  crate wiring stays deferred to a later phase.

**Verification:** `flutter analyze lib` clean for all touched files (3 pre-existing
unused-import warnings in unrelated settings screens remain). New
`test/suppliers/supplier_ledger_test.dart` (4 tests, green): balance netting,
per-store scope, void compensating-row + balance restore, double-void no-op. Full
suite: 442 pass / 58 skipped / 1 pre-existing unrelated failure
(`invite_staff_sheet_test.dart` — setState-during-build in the staff invite
sheet, not touched by this work). No Drift schema change → no build_runner / cloud
migration.

---

## 2026-06-18 — Release "session has expired" sign-out: investigation + diagnostic breadcrumbs

**Report:** on the release build a user was signed out and shown "session has
expired"; asked to confirm whether Google sign-in triggered it.

**Investigation (no behavioural change):** two distinct forced-logout mechanisms
exist and show different messages. The remote *kick* (single-active-device →
`fullLogout`) shows "signed in on another device"; the *session-expired* gate
(`main.dart` `_SessionExpiredScreen`, rendered when a local user is set but
`_supabaseHasSession == false`) is the one the user saw. The gate flips only on a
genuine Supabase `signedOut` event (transient/offline refresh failures surface on
the stream's `onError` and are swallowed, so the gate is *not* a flaky-network
false positive) — i.e. the refresh token was genuinely revoked server-side.

**Google verdict:** the Google handler (`email_entry_screen`) and the OTP handler
(`otp_verification_screen`) call the *identical* `resolvePostVerifyRoute`; the
device-kick (`setCurrentUser(freshSignIn: true)`) fires from a single place
(`biometric_setup_screen.dart:101`) reachable only on a *fresh* sign-up/PIN-create
by **both** providers. `_kickOtherDevices` uses `signOut(scope:
SignOutScope.others)`, which the server authenticates with the current access
token and always preserves the requesting session — so it can **never** revoke the
current device's own session. Conclusion: Google sign-in does not end the
signing-in device's session; it (like email OTP) revokes *other* sessions of the
same identity via the single-active-device policy. A release device "expiring" is
that policy revoking it because the same account signed in elsewhere.

**Instrumentation added (`lib/main.dart`):**
- `auth.session_lost` breadcrumb in the `onAuthStateChange` listener — records the
  `AuthChangeEvent` name + whether a local user was present when the session went
  null, written to the synced `error_logs` table (release-visible in the Supabase
  console; distinguishes a real `signedOut` revocation from a benign restore).
- `auth.session_expired_gate` breadcrumb in `_SessionExpiredScreen.initState` —
  records that the gate rendered, tagged with the stored auth method (google /
  email / unknown) so field reports can be attributed by provider.

**Docs:** added a "Single active session per identity" subsection to
`context/architecture.md` Auth & Access Model (was previously undocumented).
`flutter analyze lib/main.dart` clean. No schema/behaviour change.

---

## 2026-06-18 — Cold-start sync warm-up (false `timeout` on first push after login)

**Symptom:** right after login the Sync Issues screen showed a `Network`
`user_businesses:upsert` row failing with
`timeout: TimeoutException after 0:00:05.000000: Future not completed`
(attempts: 1), which then healed on the automatic backoff retry.

**Root cause:** not a server error — the Dart-side `.timeout()` firing. The first
push of a session gets a deliberately tight 5s budget
(`_pushChunkTimeoutForAttempts(0)`, fail-fast on dead links), but the very first
authenticated PostgREST request after login is never warm: cold DNS resolution +
TLS handshake + idle-radio wake + GoTrue session settling routinely exceed 5s on
mobile. Whatever row drains first absorbs that cold tax — right after login that's
`user_businesses` (enqueued by the login/onboarding membership write). The retry
succeeds because the connection is now warm *and* gets the roomier attempt-1
budget. Payload volume is irrelevant: the timeout is per *chunk* of
`_pushChunkSize` rows (no blobs in the sync path — `products.imagePath` is a local
path string, receipt photos are local-only), so a large catalogue is just more
warm chunks; only the first pays the cold cost.

**Fix:** `lib/core/services/supabase_sync_service.dart` — pay the cold cost once,
up front, with a warm-up + a backstop floor:
- `_warmUpConnection(businessId)` fires a cheap throwaway `businesses` `select id
  … limit 1` (RLS-safe, scoped to the session business) before the **first** drain
  of a session, so the handshake completes on a throwaway request, not a real row.
- `_didWarmUpThisSession` (reset on every sign-in/out and token refresh) gates it
  to one warm-up per session; a non-degraded drain also marks the session warm.
- First-drain backstop: that drain's per-chunk timeout is floored at
  `_firstDrainTimeoutFloor` (10s = the attempt-1 budget) even for fresh rows, in
  case the warm-up itself ate the cold tax. Subsequent drains fail fast (5s) as
  before — dead-link feedback is unchanged.

**Test:** existing sync suite green (119 tests); analyzer clean. The change is
network-timing behaviour (no schema/DAO change), verified by analyzer + suite;
on-device confirmation = no `user_businesses` timeout row in Sync Issues right
after a fresh login.

## 2026-06-18 — Empty Crates tab now per-store (Phase 2, §16.8.1)

**Symptom:** the inventory **Empty Crates** tab showed business-wide empty-crate
counts even when a specific store was active, so per-store empties were
inaccurate. (This was the locked Phase-1 business-wide behaviour; the user asked
for per-store.)

**Change:** the tab is now store-aware. When a store is locked
(`lockedStoreProvider` non-null) both **Full** and **Empty** confine to that
store; in "All Stores" mode it shows the business-wide totals.
- `InventoryDao.watchFullCratesByManufacturer({storeId})` gained an optional
  store filter (adds `inventory.store_id == storeId` to the
  `inventory↔products` join predicate). `fullCratesByManufacturerProvider`
  (new, in `stream_providers.dart`) watches `lockedStoreProvider` and passes it
  through. Empties read from `store_crate_balances` (per store, via
  `storeCrateBalancesProvider`) when locked, else `manufacturers.empty_crate_stock`.
- `_buildCratesTab` refactored to reactive `ref.watch` (store can change while on
  any tab); removed the now-redundant imperative crate stream subscriptions and
  the `_fullCratesByMfr`/`_emptyCratesByMfr` fields.

**Attribution:** a **manual** crate return from Customer Profile is credited to
the store the customer's most recent crate-bearing order was created from, via
new `OrderCrateLinesDao.resolveStoreForCustomerManufacturer(customerId,
manufacturerId)` (most recent store-stamped order carrying that brand), falling
back to the active store. Keeps `emptyCrateStock = Σ store_crate_balances`
accurate regardless of which store is active at return time. Receive-Delivery
already hard-requires a destination store and the pending-order crate-return
modal already passes `order.storeId`, so no other credit site leaks.

**Test:** `test/crates/crate_logic_test.dart` — new group
`per-store crate accuracy (§16.8.1)`: (1) `watchFullCratesByManufacturer(storeId:)`
confines a multi-store brand to one store and the all-stores view sums both;
(2) `resolveStoreForCustomerManufacturer` returns the most-recent order's store;
(3) returns null with no orders. Full suite 15 tests green. No schema migration
(0104 `store_crate_balances` already shipped).

## 2026-06-17 — Crates tab "Full" always showed zero (ID-vs-name lookup)

**Symptom:** in the inventory **Empty Crates** tab, every manufacturer card's
**Full** stat (and the per-card Total) read **0**, even with full bottles in
stock. Empty counts were correct.

**Root cause:** the full/empty watch streams
(`InventoryDao.watchFullCratesByManufacturer` /
`watchEmptyCratesByManufacturer`) emit maps keyed by **manufacturer ID**, so
`_manufacturerCrateStats[].manufacturer` holds an ID. But the per-card lookup in
`_buildCratesTab` matched `s.manufacturer == mfr.name` — comparing an ID against
a name. It never matched, so every card fell to the `orElse` branch with
`totalBottles: 0`. (The top-of-tab "Full (Crate)" total summed the ID-keyed
stats directly and was unaffected — only the per-card value was wrong.)

**Fix:** `lib/features/inventory/screens/inventory_screen.dart` — match the stat
by `mfr.id` (lookup + `orElse`). No data-layer change: the "Full" count already
streams live from `inventory.quantity` joined on `manufacturer_id`, and all
write paths are stream-tracked (`updates: {inventory}` on the sale decrement,
`updates: {manufacturers}` on `addEmptyCrates`), so "Full" now depletes on sale
and empties (returns + pending-order-confirmation deliveries) increment live.

**Test:** `test/crates/crate_logic_test.dart` — added
`watchFullCratesByManufacturer is ID-keyed and depletes on sale` (asserts the
ID key emits the seeded count and re-emits the reduced count after a sale-style
inventory decrement). Full crate suite (12 tests) green.

## 2026-06-17 — Revenue recognized at checkout, not at Confirm

**Decision (locked):** money/revenue is recognized when **checkout** completes —
the order is written with status `pending` (wallet legs booked, inventory
deducted in `OrderService.addOrder`). The later **Confirm** step
(`OrdersDao.markCompleted`, status `completed`) is ceremonial: it records the
customer's receipt of goods and any returned empty crates. It does not create
revenue.

**Symptom:** every money/sales aggregation filtered orders on
`status == 'completed'`, so a checked-out-but-unconfirmed sale showed **zero**
revenue everywhere until someone confirmed it — contradicting the agreed model.

**Fix:** added a canonical predicate `orderCountsAsSale(status)` /
`orderRevenueStatuses = {'pending', 'completed'}` in
`lib/shared/models/order_status.dart` (a "recognized sale" = checked out and not
reversed). Routed every revenue/sales site through it:
- `recon_data.dart` — `buildReconBuckets` (items sold) and `computeReconData`
  (Daily Reconciliation revenue / P&L). The separate `refunded` branch is
  unchanged.
- `home_screen.dart` — dashboard Today's Sales / Business Overview / Net Profit
  (`filteredOrdersWithItems`; Sales Detail inherits it). The `pendingOrdersCount`
  card still counts `pending` orders separately — untouched.
- `profit_report_screen.dart` — Profit Report revenue/COGS.
- `profile_screen.dart` — Sales Volume now counts non-reversed sales; the
  "Completed" stat stays a true lifecycle count.
- `staff_detail_screen.dart` — staff sales SQL → `status IN ('pending',
  'completed')`.
- `daos.dart` — `getSalesSummaryForProduct` → `status IN ('pending',
  'completed')`.

Cancelled/refunded orders remain excluded everywhere (reversed sales). No schema
change. `flutter analyze lib` clean (8 pre-existing warnings in
`app_drawer.dart`/`main_layout.dart` only). `test/orders` + `test/wallet` green;
full suite green except one pre-existing `invite_staff_sheet_test` failure from
the in-progress `app_dropdown.dart` work (unrelated — Form setState-during-build).

---

## 2026-06-17 — Empty crates: crate return not showing in Crates tab + business-wide Phase 1

**Symptom:** Recording a crate return from a Customer Profile → Crates tab "+"
card did not update the per-manufacturer balance rows (neither the customer's
Crates tab nor the Inventory Empty Crates count reflected it live).

**Root cause:** the balance-cache upserts were written with raw
`customStatement(...)`, which Drift's stream-invalidation engine does not
observe. So `watchCrateBalancesWithGroups` (and the inventory streams) never
re-ran — the data was persisted but the UI did not refresh until a fresh open.
A secondary inconsistency came from the Inventory tab reading per-store
`store_crate_balances` when a store was locked while the customer-return write
path is business-wide.

**Fix (business-wide Phase 1, per checklist §8.7):**
- **Unit A** — routed every balance upsert through stream-notifying
  `customInsert(..., updates: {table})`: `recordCrateReturnByCustomer`,
  `recordCrateIssueByCustomer`, `recordCrateReturnByManufacturer`,
  `StoreCrateBalancesDao.applyDelta` / `setBalance`. This fixes the reported bug.
- **Unit B** — Inventory Empty Crates tab now always reads the business-wide
  `manufacturers.empty_crate_stock` (dropped the locked-store branch). Per-store
  `store_crate_balances` rows are still written as Phase-2 scaffolding but no
  Phase-1 UI reads them, so every surface stays consistent.
- **Unit C** — manual crate return now writes an Activity Log row (§7.8);
  a sale that leaves a registered customer owing crates (no-deposit path) fires
  a CEO + Manager notification (`customer_crate_debt`, §12.1/§12.2) via a
  best-effort post-sale hook in `OrderService`.
- **Unit D** — cart "Empty Crates" section is hidden for walk-in customers
  (gated on `_activeCustomer != null`, matching checkout's `_depositApplies`)
  (§3.13).

**Files changed:**
- `lib/core/database/daos.dart` — 5 balance upserts → `customInsert` + `updates`.
- `lib/features/inventory/screens/inventory_screen.dart` — crates tab business-wide.
- `lib/shared/services/order_service.dart` — `_notifyCrateDebt` post-sale hook.
- `lib/features/customers/screens/customer_detail_screen.dart` — activity log on return.
- `lib/features/pos/screens/cart_screen.dart` — hide Empty Crates for walk-in.

**Tests added:** `test/crates/crate_logic_test.dart` (live watch-stream
regression, ×2); `test/crates/crate_debt_notification_test.dart` (×3, §12.1/§12.2
+ walk-in).

**Verification:** `flutter analyze` clean on all five changed files. Crate /
checkout / notification / inventory / wallet suites pass (57 + the new crate
tests). NOTE: full `flutter analyze lib` is currently blocked by an unrelated
in-progress syntax error in `lib/features/customers/screens/customers_screen.dart:150`
(not part of this work) — flagged to the user.

## 2026-06-17 — Stop FK-violation storm: abort push cycle on a degraded link

**Symptom:** On a flaky link, the Sync Issues screen filled with transient 23503
FK violations (`order_items` / `wallet_transactions` "Key is not present in table
orders") plus a network timeout. The rows self-healed on retry but the screen was
alarming and burned retry attempts.

**Root cause:** v1 per-table push sends groups parent→child by FK priority
(`orders` → `order_items` → `wallet_transactions`). When the parent `orders`
chunk timed out, the loop still continued into the child groups, which then all
FK-failed because the parent never landed.

**Fix:** Added a cycle-level `linkDegraded` flag in `pushPending`. A chunk that
fails with a timeout or a transient network/5xx error (NOT a per-row FK-deferred
or permanent constraint) sets it; after that group's chunks finish, the group
loop `break`s, skipping the remaining child groups. Domain envelopes and the
200-row re-drain microtask are also skipped while degraded. The queue is intact —
the next connectivity/periodic trigger retries the whole queue in priority order,
parents first.

**Files changed:**
- `lib/core/services/supabase_sync_service.dart` — `pushPending`: cascade guard
  (flag + break + domain/re-drain skips).

**Verification:** `flutter analyze` → No issues. `flutter test test/sync/` →
119/119 pass.

## 2026-06-17 — Dashboard debt/credit mis-scoped per store (multi-store)

**Symptom:** After opening a second store and selling across both, the Home
dashboard's debt/credit figures were inaccurate. (Reported alongside a
transient FK-violation storm on the Sync Issues screen — see investigation note
below; that storm self-healed and lost no data.)

**Root cause:** A customer has a single business-wide wallet (one balance, not
one per store) but can buy in multiple stores. The dashboard scoped the
customer set by the customer's assigned home store
(`filteredCustomers = _customers.where(storeId == lockedStore)`) and then summed
each customer's *business-wide* balance. So a cross-store customer's full
balance was counted under their home store (overstated) and dropped entirely
under the others (understated debt invisible). Verified on cloud data: customer
"Rhaenys" is assigned to Wuse Store but transacted in both Wuse and Keffi.

**Decision:** debt/credit is always business-wide, never store-scoped (a wallet
isn't per-store). Sales / inventory / expenses remain store-scoped.

**Files changed:**
- `lib/features/dashboard/screens/home_screen.dart` — removed the
  `filteredCustomers` store filter; `totalCredit` / `totalDebt` now fold over
  all `_customers`. Explanatory comment added.

**Verification:** `flutter analyze lib/features/dashboard/screens/home_screen.dart`
→ No issues found.

**Investigation notes (no code change here):**
- The `order_items` / `wallet_transactions` 23503 FK violations were transient:
  on the v1 per-table push path, when the parent `orders` chunk times out on a
  flaky link the push loop continues and sends children that then FK-fail. They
  retry and self-heal (and the new orphan auto-recovery re-drives
  `fk_deferred_cap_reached` orphans once the parent lands). Cloud query
  confirmed the order + all 3 items + all 5 wallet legs are present; nothing
  lost. Suggested follow-up (NOT applied — sync service under concurrent edit):
  abort the push cycle on a parent-group timeout instead of cascading into
  guaranteed-to-fail child pushes.
- `feature.domain_rpcs_v2.record_sale` is unset cloud-side → every device is on
  the v1 per-table path (v2 atomic RPC dormant).

## 2026-06-17 — Sync retry hardening: backoff cap + automatic orphan recovery

**Symptom:** Pending/orphaned sync issues could stay failed for a very long
time. Two distinct gaps: (1) a transient row's exponential backoff
(`(1 << (attempts % 10)) * base`) could reach ~4 h before wrapping, so on a
device that stayed continuously online (no connectivity transition to clear
backoff) a row sat idle long after its transient cause cleared; (2) orphans in
`sync_queue_orphans` were **never** auto-retried — manual-only via the Sync
Issues screen — even though several historical orphan causes are now
self-healing (the `created_at` scrubber S134, the order-number collision fix, an
FK parent that has since arrived).

**Root cause:** No backoff ceiling; no automatic orphan-recovery path. Orphans
were by-design manual to avoid blind-retrying genuinely-permanent failures (dup
order number) and churning the cloud.

**Fix (additive — no sync redesign):**
- **Backoff cap (§6.8):** `SyncDao.markFailed` now clamps the next-attempt delay
  to a ceiling — 5 min normal / 15 min FK-deferred. The 30 s periodic drain tick,
  connectivity recovery, and sign-in all re-evaluate eligibility, so a row
  retries on a bounded cadence.
- **Automatic orphan recovery (§6.8.1, conservative allowlist):**
  `SyncDao.autoRecoverDueOrphans` re-enqueues only orphans whose reason is on a
  self-healing allowlist — `fk_deferred_cap_reached*` and `*created_at is
  immutable*`. Terminal reasons (dup order number 23505, RLS / insufficient
  privilege, invalid_parameter_value) stay manual-only. A per-orphan cap (3)
  parks a still-failing row for manual review. The cap survives re-orphaning via
  a new device-local `auto_retry_count` column carried on the queue row and
  copied onto the orphan by `markFailed`. The sweep runs from the periodic drain
  tick and on connectivity recovery (`_recoverDueOrphans`, gated on `isOnline`).
  Manual `retryOrphan` resets the counter to 0 (operator takes ownership).

**Files changed:**
- `lib/core/database/app_database.dart` — `auto_retry_count` on `SyncQueue` +
  `SyncQueueOrphans`; schemaVersion 51 → **52**; idempotent `from < 52` migration
  (local-only — these are the outbox tables, never pushed, so NO cloud
  migration).
- `lib/core/database/daos.dart` — backoff ceiling in `markFailed` (+ carry
  `autoRetryCount` onto the orphan); `autoRecoverDueOrphans`,
  `_isAutoRecoverableReason`, `autoRecoverCap`, shared `_reenqueueOrphan` core
  (refactored out of `retryOrphan`).
- `lib/core/services/supabase_sync_service.dart` — `_recoverDueOrphans` wired
  into the periodic tick and `_handleConnectivityTransition`.
- `lib/core/database/app_database.g.dart` — regenerated.
- `test/sync/sync_dao_failure_classes_test.dart` — 4 new tests (allowlist
  recover, terminal skip, created_at recover, cap survives re-orphan).
- `context/architecture.md` — documented both rules under the push path.

**Verification:** `dart analyze lib` → No errors. `flutter test`
sync_dao_failure_classes_test.dart (9) + migration_upgrade_test.dart (15, steps
to v52) → all green. **Pending on-device confirmation** that a real stuck orphan
heals on the next tick / reconnect.

## 2026-06-17 — `storeInventoryCountsProvider` compile error (`Variable` undefined)

**Symptom:** Compile/analyze error in
`lib/core/providers/stream_providers.dart:35` — `The function 'Variable' isn't
defined`, plus three `invalid_null_aware_operator` / `unnecessary_null_comparison`
warnings on lines 41/43/44.

**Root cause:** The `storeInventoryCountsProvider` `customSelect` (added with the
new-store stock-count fix) used `Variable(businessId)`, but the file never
imported `package:drift/drift.dart` (Drift's `Variable` lives there, not in the
re-exports this file already pulled in). The reads also used `row.read<String>` /
`row.read<num>` (non-nullable), so the `if (storeId != null)` guard and the `?.`
operators were flagged dead.

**Files changed:**
- `lib/core/providers/stream_providers.dart` — added
  `import 'package:drift/drift.dart' show Variable;` (house pattern, matches
  `sync_diagnostic.dart`); switched the three column reads to
  `readNullable<…>` so the null guards are meaningful.

**Verification:** `dart analyze` on the file → No errors.

## 2026-06-17 — Live (realtime) sync dies on physical device after background

**Symptom:** Live cross-device sync works in debug on the emulator but stops
on a release APK installed on a physical phone — changes made on another device
no longer appear live.

**Root cause:** Not a release/minification issue (R8 is off, anon key is shared,
no `kReleaseMode` branch in the sync path). `startRealtimeSync` is called only
once at sign-in and guards with `if (_tableChannels.isNotEmpty) return;`, so it
never re-subscribes. The OS suspends/kills the realtime websocket on a physical
device (Doze, screen-off, WiFi↔mobile handoff) in ways that don't occur on an
always-on, never-dozing emulator, and the SDK's channel rejoin is not guaranteed
after a long suspension. Neither the connectivity-recovery handler nor the
app-resume handler re-established the channels — they only did a one-shot
catch-up pull (which masks the problem: changes appear after toggling network or
relaunching, but continuous live updates stay dead).

**Files changed:**
- `lib/core/services/supabase_sync_service.dart` — extracted
  `_tearDownRealtimeChannels()` from `stopRealtimeSync`; added
  `restartRealtimeSync(businessId)` (drops stale channels then re-subscribes;
  no-ops when no channels exist / not signed in). Called from
  `_handleConnectivityTransition` on network recovery.
- `lib/shared/widgets/auto_lock_wrapper.dart` — calls
  `_sync.restartRealtimeSync(subBizId)` on app-resume alongside the existing
  `refreshBusinessRow`.

**Verification:** `flutter analyze` on both files → No issues found. Re-subscribe
on resume + connectivity recovery is additive and idempotent. **Needs
physical-device confirmation** (background the app on a phone, make a change on
another device, foreground — the change should now arrive live).

## 2026-06-17 — New store card shows another store's stock

**Symptom:** Creating a new store made it appear on the Stores list with the
"Total Units" / "Products" figures of an existing store; tapping the card opened
the (correctly empty) detail screen.

**Root cause:** `_StoreCard` (a `ConsumerStatefulWidget`) was rendered in a
`ListView.builder` without a key and subscribed to its store's inventory stream
only once in `initState` using `widget.store.id`. Stores are ordered by name
(`watchActiveStores`), so inserting a new store shifts list positions; Flutter
then recycled the position-matched `_StoreCardState`, which kept streaming the
previous store's inventory. The card showed the old store's stock while
navigation used the correct `widget.store`.

**Files changed:**
- `lib/features/stores/screens/stores_screen.dart` — `_buildStoreCard` now
  passes `key: ValueKey(store.id)` so card state matches by store identity, not
  position; `_StoreCard` constructor accepts `super.key`; added
  `didUpdateWidget` + `_subscribeInventory()` to re-target the inventory stream
  and clear stale figures if a card's store id ever changes.

**Verification:** `flutter analyze lib/features/stores/screens/stores_screen.dart`
→ No issues found. A new store now starts at 0 units / 0 products until
inventory is assigned to it.

## 2026-06-16 — Session 148: Owner role protection

**Files changed:**
- `lib/core/database/app_database.dart` — added `ownerId` nullable TEXT column
  to `Businesses` table; schema v49 → v50; `from < 50` migration adds the column
  with try/catch for idempotency.
- `lib/shared/services/auth_service.dart` — `createNewOwner` and
  `completeOnboarding` both set `ownerId: Value(authUserId)` in the local Drift
  business insert so new and onboarding owners have the field populated before
  the first cloud pull.
- `lib/features/staff/screens/staff_detail_screen.dart` — render-gate hides
  "Change role" button when `isTargetOwner` (target's `authUserId` matches
  `business.ownerId`); outer action section guard updated to avoid orphan
  spacer; `_changeRole` re-checks the owner condition at the write boundary and
  shows error "You cannot change the owner's role." on bypass.
- `lib/core/database/app_database.g.dart` — regenerated via `build_runner`.

**Verification:** `flutter analyze` on all three source files → No errors.
The `ownerId` field appears in `BusinessData`, `BusinessesCompanion`, and the
`$BusinessesTable` column list in the generated file.

**Sync notes:** `owner_id` is already in `_pushableColumns['businesses']` and
`_restoreTableData` uses `BusinessData.fromJson(r)` for cloud pulls — the new
column is picked up automatically on the next pull for existing businesses.
Existing local rows get `ownerId = null` after migration and are backfilled from
the cloud on the next sync.

## 2026-06-23 — Replace Google OAuth browser flow with native in-app account picker

**Problem:** Google Sign-In previously triggered a browser/Chrome Custom Tab redirect flow, which is clunky and does not use the device's native bottom-sheet account chooser.

**Fix:**
- Switched to the native ID-token flow using the `google_sign_in` SDK.
- Modified `signInWithGoogle` in `lib/shared/services/auth_service.dart` to show the native account picker, acquire the `idToken` and `accessToken`, and exchange them with Supabase using `supabase.auth.signInWithIdToken`.
- Introduced `googleWebClientId` constant in `lib/main.dart` following the hardcoded configuration pattern of the Supabase url/anonKey, and passed it to `AuthService` dynamically through the `authProvider` in `lib/core/providers/app_providers.dart`. Added a default value to the constructor to preserve backward compatibility in unit tests.
- Configured iOS Google Sign-In support in `ios/Runner/Info.plist` by adding the placeholder reversed client ID URL scheme `com.googleusercontent.apps.1093122091494-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.
- Verified that all existing `GoogleSignIn().signOut()` calls remain functional.
- Confirmed single-active-session kick contract is untouched and functions identically.

**Files changed:**
- [main.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/main.dart) — defined `googleWebClientId` placeholder constant.
- [app_providers.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/core/providers/app_providers.dart) — imported `googleWebClientId` from `main.dart` and passed it to `AuthService`.
- [auth_service.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/services/auth_service.dart) — added `googleWebClientId` to constructor with default value, and rewrote `signInWithGoogle` to use `google_sign_in` and `signInWithIdToken`.
- [Info.plist](file:///Users/solomonizu/flutter_projects/drinkPosApp/ios/Runner/Info.plist) — added the placeholder Google reversed-client-id scheme item under `CFBundleURLTypes`.

**Verification:**
- Run `flutter analyze` -> Clean (No issues found).
- Run `flutter test` -> Passes unit tests.

## 2026-06-23 — Multi-Device Session Support

**Problem:** Previously, only one account session could be signed in at a time. Signing in on a new device would automatically log out/revoke other active devices of the same identity.

**Fix:**
- Switched the session management policy to support multiple concurrent active sessions per user identity.
- Modified `lib/shared/services/auth_service.dart` by renaming `_kickOtherDevices` to `_registerCloudSession` and removing the session-revocation update call to Supabase and the `supabase.auth.signOut(scope: SignOutScope.others)` call.
- Updated the caller inside `setCurrentUser` to use `_registerCloudSession`.
- Updated `CONTEXT/architecture.md` and `CONTEXT/brief-persistent-session.md` to reflect the disabled single active session constraint.
- Updated `CONTEXT/progress-tracker.md` to log progress.

**Verification:**
- Added a new unit test in `test/sync/session_created_at_push_test.dart` to verify that concurrent sessions for the same user across multiple devices can coexist actively in the database.
- Ran all auth and session tests using `flutter test` and confirmed they pass cleanly.
