# Brief — Data Analytics (Reports hub → Analytics hub)

You are a junior implementer. This brief is written so you do **not** plan from scratch:
every unit tells you which files to open (with line anchors), the exact steps, the pattern to
copy, and how to verify. **One unit per prompt.** Implement the unit, verify it end to end,
update docs, then stop. Do not build ahead. If a step says "[BLOCKED]" or "open question",
stop and log it — do not invent behaviour (`ai-workflow-rules.md` §Handling Missing
Requirements).

The codebase already contains a near-identical worked example for everything here:
`lib/features/dashboard/reconciliation/recon_data.dart` (aggregation) +
`lib/features/dashboard/screens/daily_reconciliation_*` (UI). When in doubt, copy those.

---

## ⚙️ How to run this brief (execution protocol — READ THIS FIRST, EVERY TIME)

You were pointed at this file and told a single unit number (e.g. "work on Unit 3"). That
unit is your **entire job**. Obey these rules:

1. **Scope lock — do ONLY your unit.**
   - Implement exactly the unit you were given. Do not start the next unit. Do not "while I'm
     here" fix unrelated code, rename things, reformat, upgrade other screens, or touch files
     your unit's steps don't name.
   - If you notice a bug or improvement outside your unit, **do not fix it** — add a one-line
     note under "Open Questions / Observations" in `context/progress-tracker.md` and move on
     (`ai-workflow-rules.md`: "Do not refactor code unrelated to the current unit").
   - If your unit depends on a previous unit that isn't done, **stop and say so** — do not
     build the missing prerequisite yourself.

2. **Read only what your unit needs (keep context lean).** In this order, read:
   `§0` (reading list), `§2` (current state), `§3` (decisions), `§5` (Templates A–F), and
   **your unit's entry in `§6`**. Then open only the files those sections name (with the line
   anchors given). **Do not crawl the repo** or read other units' files.

3. **Copy the templates — do not invent structure.** Every unit maps to Template A–F in `§5`
   and to the worked example in `recon_data.dart`. If you find yourself designing an approach
   from scratch, you've missed a template — re-read `§5`.

4. **Respect the gates.**
   - Schema/cloud lands and is verified **before** the UI that consumes it (Unit 1 before all
     UI). Never combine a migration with the UI that reads it.
   - If your unit is marked ⚠ "needs Qn resolved" or **[BLOCKED]** and the answer is not yet
     recorded in `context/progress-tracker.md`, **stop and report the blocker** — do not pick
     an answer yourself.

5. **Definition of done = `§8`.** Before reporting complete, run `flutter analyze` (zero
   errors / zero new warnings) and `flutter test` (green, including any test your unit adds).
   Update `BUILD_LOG.md` (dated entry) and `context/progress-tracker.md` in the **same** unit.

6. **Report back tersely.** Return ONLY: (a) files changed, (b) `flutter analyze` result,
   (c) `flutter test` result, (d) anything you logged as an observation/blocker. **Do not**
   paste code or write a long summary — the orchestrator reads the diff itself.

7. **Do not commit or push** unless explicitly told to. Leave the working tree for review.

> Orchestrator note (for the human/driver): run **one fresh agent per unit** so context stays
> small; verify `analyze`/`test` and the diff yourself before moving on (executor self-reports
> are not trusted — see memory `feedback_verify_executor_output`). Aggregator units 3/5/7 are
> independent and may run in parallel git worktrees; UI units 4/6/8 all edit
> `analytics_hub_screen.dart` and must run serially.

---

## 0. Read first (mandatory, in order)

1. `context/project-overview.md`
2. `context/architecture.md` — re-read the **Invariants** section before *every* unit.
3. `context/ui-context.md` — Glassy standard + responsive-grid rules.
4. `context/code-standards.md` — kobo money math, tokens-not-raw-values, module boundaries.
5. `context/ai-workflow-rules.md` — scoping, "when to split", "handling missing requirements".
6. `context/progress-tracker.md`

Hard-won invariants you must not break (saved memory):

- **`project_revenue_recognized_at_checkout`** — revenue counts at **checkout** (order
  `status == 'pending'`), not at Confirm (`completed`). Use `orderCountsAsSale(status)` /
  `orderRevenueStatuses` from `lib/shared/models/order_status.dart`. **Never** filter on
  `== 'completed'`. `refunded`/`cancelled` never count. Every metric obeys this.
- **`project_business_scoping_invariant`** — never raw-`select` a business table. You only
  read through the existing `all*Provider`s (already business-scoped). No new DB queries
  needed for Phase 1.
- **`project_store_lock_dual_mechanism`** — `lockedStoreProvider.value` (`null` = All Stores)
  is THE active store. Scope via it. **Do not** add per-screen store dropdowns.
- **`project_permission_key_cloud_fk_deploy`** — a NEW permission key must exist in the cloud
  `permissions` catalogue **before** any `role_permissions` grant referencing it syncs.
  Local on-device seeds the **catalogue key only** (grants always arrive from the cloud pull
  — see Unit 1). Deploy the cloud migration first.
- **`project_permission_enforcement_leaks`** — analytics is read-only, so each gated surface
  needs a **render-gate** (hide-don't-block) on the correct key, never a role slug.
- **`reference_currency_app_wide`** — money via `formatCurrency(kobo)` /
  `activeCurrencySymbol`, never hardcode `₦`.
- **`feedback_role_tier_ordering`** — staff/roles ordered by `roleRank` (CEO→Manager→Cashier
  →Stock keeper), never alphabetical.
- **`feedback_no_apk_build`** — never `flutter build apk`; use `flutter run` on the emulator.
- **`feedback_never_git_checkout_uncommitted`** — never `git checkout` a dirty file; never
  run `dart format` (house style is old dartfmt, unenforced).
- **`feedback_log_working_fixes`** — after each verified unit, add a dated `BUILD_LOG.md`
  entry and update `context/progress-tracker.md` in the same step.
- **`feedback_supabase_push_authorized`** — you may run `supabase db push` (respect deploy
  ordering); don't ask each time.

---

## 1. Feature definition

Add a **Data Analytics** card to the Business Reports hub
(`lib/features/dashboard/screens/reports_hub_screen.dart`). Tapping it pushes a new
**Analytics hub** screen: a scrollable, store-scoped (`lockedStoreProvider`), period-scoped
set of read-only insight cards grouped into sections. Every metric is derived from data the
POS already collects. **Analytics never writes business data.**

Two phases. Phase 1 = highest-impact metrics off data already collected. Phase 2 = derived/
combined metrics. Phase 2 items needing data the POS does **not** capture are flagged
**[BLOCKED]** and gated behind an open question in §7.

---

## 2. Current state (mapped — do not re-derive)

**Reports hub** — `lib/features/dashboard/screens/reports_hub_screen.dart`:
- Cards live in a `GridView.count(crossAxisCount: 2)` (line ~164), each built by
  `_buildReportCard(context, title:, subtitle:, icon:, color:, onTap:, badgeCount:)`
  (line ~180).
- Gating uses `isManagerOrAbove(ref)` (line ~30), `hasPermission(ref, '<key>')` (e.g. line
  ~96/110), `businessTracksCrates(ref.watch(currentBusinessProvider))` (line ~33).
- Navigation: `Navigator.push(context, slideDownRoute(const SomeReportScreen()))`.

**The reference aggregator** — `lib/features/dashboard/reconciliation/recon_data.dart`:
- `ReconData computeReconData(WidgetRef ref, {DateTime? start, DateTime? endExclusive,
  required bool isCeo})` (line ~360). It **synchronously `ref.watch`es** the provider list
  below, then folds one pass over orders. **This is the exact pattern you copy.**
  ```dart
  final orders      = ref.watch(allOrdersProvider).valueOrNull ?? const [];
  final expenses    = ref.watch(allExpensesProvider).valueOrNull ?? const [];
  final adjustments = ref.watch(allStockAdjustmentsProvider).valueOrNull ?? const [];
  final activeStoreId = ref.watch(lockedStoreProvider).value;
  final productsWS  = ref.watch(productsWithStockProvider(activeStoreId)).valueOrNull ?? const [];
  final users       = ref.watch(usersByBusinessProvider).valueOrNull ?? const {}; // id → user
  final manufacturers = ref.watch(allManufacturersProvider).valueOrNull ?? const [];
  final inScope = reconStoreFilter(ref);     // (String? storeId) => bool, honours lockedStore
  bool inSpan(DateTime t) => (start == null || !t.isBefore(start)) &&
                             (endExclusive == null || t.isBefore(endExclusive));
  ```
- The fold (lines ~415–470) already computes, store+span+`orderCountsAsSale`-scoped:
  per-product units (`byProduct` → `topItems`), per-staff revenue (`byStaff` →
  `bestStaff`/`bestStaffKobo`), revenue, COGS (`i.item.quantity * i.item.buyingPriceKobo`),
  `uncostedItems` (lines with `buyingPriceKobo <= 0`). **Read this fold before writing any
  unit — most metrics are a 5-line variation of it.**

**Row shapes** (`lib/core/database/daos.dart`):
- `OrderWithItems` (line ~2683): `.order` (`OrderData`: `status, totalAmountKobo, staffId,
  storeId, customerId, paymentType, amountPaidKobo, createdAt`), `.items`
  (`List<OrderItemDataWithProductData>`), `.customer` (`CustomerData?`).
- `OrderItemDataWithProductData` (line ~2691): `.item` (`OrderItemData`: `quantity,
  unitPriceKobo, buyingPriceKobo, totalKobo, productId, storeId`), `.product`
  (`ProductData?` — null for Quick Sale), `.displayName` (safe label for both).
- `ProductData`: `id, name, category, buyingPriceKobo, retailerPriceKobo, manufacturerId`.

**Period** — `lib/core/utils/date_period.dart`:
- `(DateTime?, DateTime?) dateRangeForLabel(String label)` → `(start, null)` (open-ended end).
- Labels list (line ~74): `'Today', 'This Week', 'This Month', 'This Year'` (+ `datePeriodFromLabel`
  also accepts `'This Quarter'`, `'All time'`). Use these strings verbatim as the period state.

**Timezone bucketing** — copy `getSalesSummaryForProduct` in `daos.dart` (line ~2431): it
loads `businesses.timezone`, `tz.getLocation(...)` with UTC fallback, and buckets
`order.createdAt.toUtc()` against tz day boundaries. Reuse this for hour/day/season.

**Gating helpers** (`lib/core/providers/stream_providers.dart`):
- `bool hasPermission(WidgetRef ref, String key)` (line ~1529) → membership in
  `currentUserPermissionsProvider`.
- `bool isManagerOrAbove(WidgetRef ref)` (line ~1538) → fails closed while role resolves.
- `activeStoreLabelProvider` (line ~1679) → the store subtitle string.

**UI shell** — `lib/shared/widgets/glassy_scaffold.dart`:
`GlassyScaffold({required String title, String? subtitle, required Widget body,
List<Widget>? actions, PreferredSizeWidget? bottom, bool centerTitle})`. It already paints the
glassy gradient + scroll-reactive AppBar. **Model the Analytics hub screen on a sibling pushed
report screen** — `lib/features/dashboard/screens/supplier_accounts_report_screen.dart` and
`crate_deposits_report_screen.dart` are the closest templates (pushed, glassy, period-scoped).

**Surfaces to migrate (don't duplicate):**
- "Best performing staff" → `_buildStaffSalesSection` in
  `dashboard/screens/home_screen.dart` (line ~821). The canonical ranked view moves to the
  Analytics hub (Unit 6).
- "Best selling item" → `topItems` shown in `daily_reconciliation_detail_screen.dart`
  (line ~152). Full ranked view moves to the Analytics hub (Unit 4).

**No chart package is in `pubspec.yaml`.** Do **not** add one. Bars are plain `Container`s
with a fractional width — see Template E.

---

## 3. Architecture decisions (locked)

1. **No new tables, no new synced columns, no new DB queries for Phase 1.** Everything is
   derived from the existing `all*Provider`s. If a unit seems to need a new column → it is a
   [BLOCKED] Phase-2 item; log it, don't add it.
2. **Aggregation = a `*_data.dart` file, never in `build`.** Each section gets ONE
   `compute*Analytics(ref, {start, endExclusive})` free function (Template A) that watches the
   providers and delegates to a pure `aggregate*` (Template A.2) for unit-testing.
3. **One pass per section, many cards off it.** Mirror `recon_data`: compute once per (store,
   period), drive every card in the section from the returned record.
4. **Uniform store + period scope.** Store: `lockedStoreProvider` via `reconStoreFilter(ref)`.
   Period: one `analyticsPeriodProvider` (a `String` label) at the hub top → `dateRangeForLabel`.
5. **Explicit empty state.** A metric with no qualifying rows renders "Not enough data yet"
   (Template E `EmptyMetric`), never a bare 0. Uncosted lines are excluded from margin and
   surfaced as a caveat (count them like `recon_data.uncostedItems`).
6. **Money/cost gating.** Margin/profit cards additionally render-gate on
   `reports.see_profit`; buying-price figures on `reports.see_cost_prices`. A Manager without
   them still sees units/revenue.

---

## 4. Metric → data-source map

### Phase 1
| Metric | Source | Computation |
|---|---|---|
| Best / least selling product | order_items × products | Σ `quantity` per `productId`; rank desc/asc |
| Most / least profitable product | order_items × products | Σ `quantity*(unitPriceKobo−buyingPriceKobo)`; exclude uncosted |
| Best performing staff *(migrate)* | orders | Σ revenue per `staffId`; `roleRank` order |
| Best selling item *(migrate)* | order_items | full ranked best-selling list |
| Best / worst store | orders by `storeId` | Σ revenue per store; rank (ignores store lock) |
| Sales by hour of day | orders `createdAt` (tz) | bucket 0–23; Σ revenue + count |
| Sales by day of week | orders `createdAt` (tz) | bucket Mon–Sun |
| Best / least selling season | orders `createdAt` (tz) | bucket by season — **Q1** |

### Phase 2
| Metric | Source | Notes |
|---|---|---|
| Best performing manager | orders × users(role=Manager) | staff agg filtered to Manager `roleRank` |
| Best customer by spend | orders by `customerId` | Σ revenue per customer |
| Avg spend / visit | orders | Σ revenue ÷ order count |
| Avg items / visit | order_items ÷ orders | Σ qty ÷ order count |
| Sales / staff / hour | orders + worked window | **Q2** (no clock-in; proxy) |
| Avg transaction time | — | **[BLOCKED] Q3** (no cart-start timestamp) |
| Cancel/reversal rate | orders status | count(cancelled+refunded) ÷ count(all) |
| Refund frequency | orders/refunds | count refunds in span |
| Voids/refunds per staff | orders/ledger voids by `staffId` | per-staff reversal counts |
| Margin per store after costs | orders+items+expenses by store | (rev−COGS−expenses)÷rev |
| Margin by category | order_items × products.category | per-category (rev−COGS) |
| Expense % of revenue | expenses ÷ revenue | approved expenses ÷ recognized revenue |
| Cross-store same-period | orders by store | side-by-side table |
| Stores falling behind | orders by store | delta vs top / prior period |
| Inventory turnover | sales velocity + stock | units sold ÷ avg stock |
| Excess/aging stock | inventory + last-sold | low velocity / old last-sale |
| Lost to expiry/spoilage | damages + expiry | damages now; expiry **Q4** |
| Unexplained shrinkage | daily-count variance | reuse recon shortage value |
| Customer return frequency | orders by customer | repeat-order rate |
| Customers gone quiet | orders by customer | last-order > threshold (**Q6**) |
| Frequently short/damaged | damages by product | rank by damage units |
| Order→receive lead time | supplier receipts | **[BLOCKED] Q5** (no PO placed time) |
| Stock transferred between stores | stock_transfers | Σ received qty per pair |
| New customers / period | customers `createdAt` | count new in span |

---

## 5. Shared patterns (copy these — every unit references them by letter)

### Template A — section aggregator file (`lib/features/dashboard/analytics/<section>_analytics.dart`)
**A.1 — pure aggregator (unit-testable, no Riverpod):**
```dart
// Pure: takes already-fetched lists, returns the record. NO ref, NO providers.
ProductAnalytics aggregateProductAnalytics({
  required List<OrderWithItems> orders,
  required bool Function(String? storeId) inScope,
  required bool Function(DateTime t) inSpan,
}) {
  final byUnits = <String, ({String name, int qty})>{};
  final byMargin = <String, ({String name, int marginKobo})>{};
  var uncostedItems = 0;
  for (final o in orders) {
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) continue;
    for (final li in o.items) {
      if (!inScope(li.item.storeId)) continue;
      final p = li.product;
      if (p == null) continue;                       // Quick Sale — no SKU to rank
      final units = (byUnits[p.id]?.qty ?? 0) + li.item.quantity;
      byUnits[p.id] = (name: p.name, qty: units);
      if (li.item.buyingPriceKobo <= 0) { uncostedItems += li.item.quantity; continue; }
      final margin = (byMargin[p.id]?.marginKobo ?? 0) +
          li.item.quantity * (li.item.unitPriceKobo - li.item.buyingPriceKobo);
      byMargin[p.id] = (name: p.name, marginKobo: margin);
    }
  }
  final unitsRanked = byUnits.entries
      .map((e) => (id: e.key, name: e.value.name, qty: e.value.qty)).toList()
    ..sort((a, b) => b.qty != a.qty ? b.qty.compareTo(a.qty) : a.name.compareTo(b.name));
  final marginRanked = byMargin.entries
      .map((e) => (id: e.key, name: e.value.name, marginKobo: e.value.marginKobo)).toList()
    ..sort((a, b) => b.marginKobo != a.marginKobo
        ? b.marginKobo.compareTo(a.marginKobo) : a.name.compareTo(b.name));
  return ProductAnalytics(
    unitsRanked: unitsRanked, marginRanked: marginRanked, uncostedItems: uncostedItems);
}
```
**Strategy notes:** kobo `int` only; deterministic tie-break by name so tests are stable;
exclude `product == null`; count (don't drop) uncosted for the caveat.

**A.2 — Riverpod wrapper (mirrors `computeReconData`'s provider-watch shape):**
```dart
ProductAnalytics computeProductAnalytics(
  WidgetRef ref, {DateTime? start, DateTime? endExclusive}) {
  final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
  final inScope = reconStoreFilter(ref);
  bool inSpan(DateTime t) => (start == null || !t.isBefore(start)) &&
                             (endExclusive == null || t.isBefore(endExclusive));
  return aggregateProductAnalytics(orders: orders, inScope: inScope, inSpan: inSpan);
}
```
Define the result class (`ProductAnalytics`) in the same file with `final` fields and a
`const` constructor (one class per concern; see `ReconData` at `recon_data.dart:246`).

### Template B — period state provider (define once, Unit 2)
In a new `lib/features/dashboard/analytics/analytics_providers.dart`:
```dart
// Default 'This Month' — same vocabulary as date_period.dart labels.
final analyticsPeriodProvider = StateProvider<String>((ref) => 'This Month');
```
Sections resolve bounds with: `final (start, end) = dateRangeForLabel(ref.watch(analyticsPeriodProvider));`

### Template C — section consumed in the hub screen `build`
Mirror `daily_reconciliation_detail_screen.dart:41` (calls `computeReconData(ref, …)` directly
in build). Aggregation is a synchronous fold over already-watched providers, so calling it in
`build` is the established pattern here (it is NOT a network/DB call). Keep the call one line;
all layout stays in widgets.
```dart
final (start, end) = dateRangeForLabel(ref.watch(analyticsPeriodProvider));
final data = computeProductAnalytics(ref, start: start, endExclusive: end);
```

### Template D — render-gate (hide-don't-block)
```dart
if (hasPermission(ref, 'reports.see_analytics')) ...[ /* card */ ],
// margin/cost figures inside a visible card:
if (hasPermission(ref, 'reports.see_profit')) Text(formatCurrency(marginKobo)),
```

### Template E — metric card + bar row widgets (glassy, tokens only)
Reuse `GlassyCard` (see `lib/shared/widgets/` — the same one `customer_detail_screen` uses).
Title via `context.titleMedium`/`bodyMedium`; spacing via `context.getRSize(n)`; radius
`AppRadius.*`; money via `formatCurrency`. A bar row is a fractional-width `Container`:
```dart
// value/maxValue in [0,1]; no chart package.
Stack(children: [
  Container(height: context.getRSize(10),
    decoration: BoxDecoration(color: theme.dividerColor,
      borderRadius: BorderRadius.circular(AppRadius.hairline))),
  FractionallySizedBox(widthFactor: (value / maxValue).clamp(0.0, 1.0),
    child: Container(height: context.getRSize(10),
      decoration: BoxDecoration(color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(AppRadius.hairline)))),
]);
```
`EmptyMetric` = a centered `bodySmall` "Not enough data yet" inside the `GlassyCard`.

### Template F — aggregator unit test (`test/dashboard/<section>_analytics_test.dart`)
Test the **pure A.1 function** with hand-built rows — no DB, no ProviderContainer. Build
`OrderWithItems(OrderData(...), [OrderItemDataWithProductData(OrderItemData(...),
ProductData(...))], null)`. Construct Drift data classes directly (all fields are plain).
Assert: rank order, tie-break by name, `orderCountsAsSale` excludes refunded/cancelled,
`inSpan` excludes out-of-window, `inScope` excludes other stores, `uncostedItems` counts
`buyingPriceKobo <= 0`, Quick-Sale (`product == null`) lines are skipped. Mirror the structure
of an existing pagination test (e.g. `test/orders/orders_pagination_test.dart`) for harness
boilerplate.

---

## 6. Units (the prompts — one at a time)

> Every unit ends with: `flutter analyze` zero errors/new warnings → `flutter test` green →
> `BUILD_LOG.md` dated entry + `progress-tracker.md` updated → emulator walkthrough
> (`flutter run`). Schema/cloud lands and verifies BEFORE the UI that consumes it.

### Phase 1

#### Unit 1 — Permission key `reports.see_analytics` (schema + cloud; NO UI)
**Goal:** the key exists in the local catalogue and the cloud catalogue, with CEO + Manager
grants seeded in the cloud (grants reach devices via pull — never seeded on-device).

**Local steps (`lib/core/database/app_database.dart`):**
1. In `_defaultPermissionRows` (line ~4062), under the `// Reports` block (after
   `reports.see_expenses`, line ~4101) add:
   `['reports.see_analytics', 'See data analytics', 'Reports'],`
2. Bump `schemaVersion` 57 → **58** (line ~1784).
3. After the `if (from < 57)` block (ends ~line 3810), add — copying the v54 shape verbatim:
   ```dart
   if (from < 58) {
     // v58: add reports.see_analytics — gates the Data Analytics hub. CEO +
     // Manager by default; grants arrive from the cloud pull (backfill in
     // supabase/migrations/0125_add_reports_analytics_permission.sql). Catalogue
     // key only locally — grants are never seeded on-device. Idempotent (key PK).
     await customStatement(
       "INSERT OR IGNORE INTO permissions (key, description, category) "
       "VALUES ('reports.see_analytics', 'See data analytics', 'Reports')",
     );
   }
   ```
4. Regenerate Drift: `dart run build_runner build --delete-conflicting-outputs`. Commit the
   `*.g.dart` changes (do not hand-edit them).

**Cloud steps:** create `supabase/migrations/0125_add_reports_analytics_permission.sql` by
**cloning `0122_add_stores_transfer_permissions.sql`** and editing:
- Pass 1 (catalog): insert one row
  `('reports.see_analytics', 'See data analytics', 'Reports')`.
- Pass 2 (`CREATE OR REPLACE seed_default_roles_for_business`): the CEO block already grants
  every key via `SELECT key FROM permissions` (unchanged). Add ONE Manager line:
  `(p_business_id, v_mgr, 'reports.see_analytics'),`. Leave Cashier/Stock-keeper untouched.
- Pass 3 (backfill existing businesses): one `INSERT … SELECT business_id, id,
  'reports.see_analytics', now() FROM public.roles WHERE slug IN ('ceo','manager')
  ON CONFLICT DO NOTHING`.
- Keep the `REVOKE/GRANT EXECUTE` lines and the verification comment block; edit them for the
  new key.
Then `supabase db push` (authorized). Run the verification SQL: catalogue has the key; CEO +
Manager rows exist for every business.

**Done check:** migration-upgrade test green (the existing schema-ladder test must still pass
through v58); cloud verified. No UI yet. `BUILD_LOG` + tracker updated.

#### Unit 2 — Analytics entry card + hub scaffold + period bar (UI only)
**Goal:** a "Data Analytics" card on the Reports hub opens an empty, glassy, store/period-
scoped Analytics hub.

**Steps:**
1. `analytics_providers.dart` — add Template B (`analyticsPeriodProvider`).
2. New `lib/features/dashboard/screens/analytics_hub_screen.dart`. **Open
   `supplier_accounts_report_screen.dart` and copy its scaffold skeleton** (pushed glassy
   report screen with period scoping). Title "Data Analytics"; subtitle =
   `ref.watch(activeStoreLabelProvider)`. Body = a top **period selector row** + three
   `Text` section headers ("Products", "Staff & Stores", "Timing") each over a placeholder
   `GlassyCard` reading "Coming up".
3. Period selector: a row of `ChoiceChip`s or an `AppDropdown` over the labels
   `['Today','This Week','This Month','This Year']`; on change set
   `ref.read(analyticsPeriodProvider.notifier).state = label`. (Reference the dropdown handler
   in `daily_reconciliation_list_screen.dart:65`.)
4. Reports hub — `reports_hub_screen.dart`: import the new screen; add to the `cards` list,
   placed after Daily Reconciliation:
   ```dart
   if (isMgrUp && hasPermission(ref, 'reports.see_analytics'))
     _buildReportCard(context,
       title: 'Data Analytics', subtitle: 'Trends · top performers',
       icon: FontAwesomeIcons.chartLine.data, color: Colors.deepPurple,
       onTap: () => Navigator.push(context,
           slideDownRoute(const AnalyticsHubScreen()))),
   ```
**Done check:** card visible to CEO/Manager only; navigates; switching store updates the
subtitle; switching period rebuilds (verify via a temporary debugPrint, then remove). No data.

#### Unit 3 — Product analytics aggregator (logic + test; NO UI)
**Steps:** create `lib/features/dashboard/analytics/product_analytics.dart` with Template A
(A.1 `aggregateProductAnalytics`, A.2 `computeProductAnalytics`, and the `ProductAnalytics`
result class). Then `test/dashboard/product_analytics_test.dart` per Template F covering:
best/least by units, most/least by margin, uncosted excluded+counted, refunded/cancelled
excluded, store scope, span scope, Quick-Sale skipped, tie-break by name.
**Done check:** new test green; no UI yet.

#### Unit 4 — Product analytics UI
**Steps:** in `analytics_hub_screen.dart`, replace the "Products" placeholder with four cards
off `computeProductAnalytics(ref, …)` (Template C): Best selling, Least selling, Most
profitable, Least profitable (Template E bar rows; show top 5 each). Margin/cost figures
wrapped in `if (hasPermission(ref,'reports.see_profit'))` and cost detail in
`if (hasPermission(ref,'reports.see_cost_prices'))` (Template D). If `uncostedItems > 0`, show
a `bodySmall` caveat "N items have no buying price and are excluded from profit." Empty →
`EmptyMetric`. This is the migrated "Best selling item" full view.
**Done check:** numbers match a hand-check against Daily Reconciliation `topItems` for the
same store+period; Manager-without-profit sees units only.

#### Unit 5 — Staff & store analytics aggregator (logic + test)
**Steps:** `lib/features/dashboard/analytics/staff_store_analytics.dart`, Template A. A.1
`aggregateStaffStoreAnalytics` folds per-`staffId` revenue and per-`storeId` revenue (copy the
`byStaff` block at `recon_data.dart:448`). A.2 wrapper also watches `usersByBusinessProvider`
(id→user, for names + `roleRank`) and passes the name/rank resolver in. **Note:** staff ranking
honours the active store (`inScope`); **store ranking ignores the store lock** (it ranks across
all stores — pass an always-true scope for that fold). `null` staffId → "Unassigned".
Order staff output by revenue desc, then `roleRank` for ties. Test per Template F.
**Done check:** test green.

#### Unit 6 — Staff & store analytics UI
**Steps:** "Staff & Stores" section: a staff leaderboard card (revenue bars, `roleRank`-aware)
and Best store / Worst store cards. This is the migrated "Best performing staff" canonical
view. Leave `home_screen._buildStaffSalesSection` as the dashboard summary (do not delete);
add a one-line code comment there pointing to the hub as the full view.
**Done check:** leaderboard matches the home summary for the same period; ordering by tier on ties.

#### Unit 7 — Timing analytics aggregator (logic + test)  ⚠ needs **Q1** resolved first
**Steps:** `lib/features/dashboard/analytics/timing_analytics.dart`. A.2 wrapper loads the
business timezone (copy the `tz` block from `daos.dart:2431`); A.1 buckets recognized sales by
hour-of-day (0–23), day-of-week (Mon–Sun), and **season per Q1** using the tz-localized
`createdAt`. Return three `List<int>` revenue arrays + counts. Test bucketing across a tz
boundary and DST safety (Template F; build orders at known UTC instants).
**Done check:** test green; **do not start until Q1 is answered in `progress-tracker.md`.**

#### Unit 8 — Timing analytics UI
**Steps:** "Timing" section: hour-of-day bar row (24 bars), day-of-week bar row (7 bars) via
Template E, and a Best/Least season card. Highlight the peak bucket with
`theme.colorScheme.primary` and a label ("Busiest: 6–7pm — staff up").
**Done check:** peak visually matches the data; empty period → `EmptyMetric`.

### Phase 2 (each follows the Unit 3 + Unit 4 pair template exactly)

> For each: build the `*_analytics.dart` aggregator (Template A) + test (Template F) as one
> unit, then the UI section as the next unit. Gate margin/cost cards per §3.6. Same store/
> period scoping. Do not combine the aggregator and UI in one prompt.

- **Unit 9 — Operations** (`operations_analytics.dart` + UI): cancel/reversal rate
  (`count(status in {cancelled,refunded}) / count(all in span+scope)`), refund frequency,
  voids/refunds per `staffId`, cancel rate per store. Orders + ledger voids only.
- **Unit 10 — Margin & cost** (`margin_analytics.dart` + UI): margin per store after expenses
  (rev−COGS−approved expenses, per store; reuse the expenses fold at `recon_data.dart:484`),
  margin by `products.category`, expense % of revenue, cross-store same-period table, "stores
  falling behind by how much" (delta vs top store). **Whole section render-gated on
  `reports.see_profit`.**
- **Unit 11 — Customers** (`customer_analytics.dart` + UI): best customer by spend (group by
  `o.order.customerId`, name via `o.customer`), avg spend/visit, avg items/visit, return
  frequency, customers gone quiet (last-order older than **Q6** threshold), new customers in
  span (needs `customers.createdAt` via the existing customers provider). Q6 must be resolved.
- **Unit 12 — Inventory** (`inventory_analytics.dart` + UI): turnover (units sold ÷ avg
  stock from `productsWithStockProvider`), excess/aging stock (low velocity / old last-sale),
  unexplained shrinkage (reuse the daily-count shortage value already computed in
  `recon_data.dart` — read how it derives shortage, lines ~529+), frequently short/damaged
  products (rank `isDamageReason` adjustments by units), stock transferred between stores
  (`stock_transfers` where `status == 'received'`, Σ qty per from→to pair). Expiry portion
  pending **Q4**.
- **Unit 13 — Manager + per-staff-per-hour:** best performing manager = reuse Unit 5
  aggregator filtered to Manager `roleRank`; sales-per-staff-per-hour only after **Q2**
  resolves the worked-hours source (build it with the agreed proxy + a visible caveat).

**[BLOCKED] — do NOT build until the open question is answered in `progress-tracker.md`:**
avg transaction time + cross-store transaction speed (**Q3**); order→receive lead time (**Q5**);
the expiry-specific portion of Unit 12 (**Q4**).

---

## 7. Open questions (resolve in `progress-tracker.md` before the dependent unit)

- **Q1 (blocks Unit 7) — season model.** (a) calendar quarters; (b) Nigerian wet/dry
  (Apr–Oct / Nov–Mar); (c) custom. **Recommend (b)**, configurable later.
- **Q2 (blocks Unit 13) — worked-hours source.** No clock-in exists. **Recommend** first→last
  order timestamp per staff per day as the active window, with a stated caveat. Or defer.
- **Q3 ([BLOCKED]) — transaction duration.** Only `orders.createdAt` (commit time) is stored;
  no cart-open timestamp → not derivable. Needs new capture; out of scope until product decides.
- **Q4 — expiry write-off.** Products carry expiry, but no expiry write-off event distinct
  from a damage. Damage-based loss buildable now; expiry figure needs a write-off action.
- **Q5 ([BLOCKED]) — PO placed timestamp.** Receipts store receive date but no order-placed
  event → lead time has no start. Out of scope until a placement event exists.
- **Q6 (blocks Unit 11) — "gone quiet" threshold** (30 / 60 / 90 days).

---

## 8. Definition of done (every unit)
1. Works end to end in scope; store + period switching rebuilds correctly.
2. No invariant violated — confirm `orderCountsAsSale`, business-scoping, no direct Supabase
   call, no new table/column, render-gate on the right key.
3. `code-standards.md`: kobo-int money, tokens not raw values, `GlassyCard`/`GlassyScaffold`,
   `ConsumerWidget` first, correct import order, one class per file.
4. `flutter analyze` zero errors / zero new warnings; `flutter test` green (new aggregator
   tests included).
5. `BUILD_LOG.md` dated entry + `context/progress-tracker.md` updated in the same step.
6. Emulator walkthrough (`flutter run`, never `build apk`).
