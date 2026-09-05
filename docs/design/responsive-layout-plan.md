# Responsive Layout Plan — short viewports (landscape phones) and tablets

Status: proposed, not started
Author: design investigation, 2026-09-05
Scope: `lib/core/utils/responsive.dart` + every screen in `lib/`
Related: `context/ui-context.md`, ADR to be written in Phase 0

---

## 1. The defect

`lib/core/utils/responsive.dart` scales the entire design system off screen
**width** only:

```dart
const double _kBaseWidth = 375.0;
double _scaleFactor(double screenWidth) =>
    (screenWidth / _kBaseWidth).clamp(0.8, 1.5);
```

Four entry points share that one curve — the free functions `rFontSize`,
`rSize`, and the `getRFontSize` / `getRSize` methods on the `ResponsiveHelper`
extension (via its private `_scale` getter). `AppFAB` calls the free `rSize`;
almost everything else calls the extension. All four must change together.

On a Pixel-class phone:

| orientation | width | height | scale |
|---|---|---|---|
| portrait | 412 | 915 | 1.10 |
| landscape | 915 | 412 | **1.50** (clamped) |

Rotating inflates every vertical gap, icon, chip, and font by **1.37×** at the
exact moment vertical space drops by **2.2×**. The design system does not merely
fail to adapt to landscape — it actively makes it worse. Combined, vertical
demand rises ~1.37× into ~0.45× the space: roughly **3× oversubscribed**.

### The observed symptom

POS home overflows by 134px in landscape. `_buildPos` in
`lib/features/pos/screens/pos_home_screen.dart` (lines 253–322) stacks three
fixed-height children above an `Expanded` product grid:

| band | composition at scale 1.50 | height |
|---|---|---|
| `_buildHeader` | `getRSize(16)` padding ×2 = 48 + `AppDropdown` ~48 | ~96dp |
| `_buildSearchField` | `getRSize(12)` bottom pad = 18 + `AppInput` ~52 | ~70dp |
| `CategoryFilterBar` | `getRSize(38)` = 57 + margins `getRSize(8)`/`getRSize(16)` = 36 | ~93dp |
| **total fixed chrome** | | **~259dp** |

The body has ~245dp (412 − 24 status − 68 app bar − ~68 nav + gesture inset).
The `Expanded` collapses to zero and the fixed children spill by the difference.

Note the `AppDropdown` (~48dp) and `AppInput` (~52dp) heights are *not* scaled —
they come from `inputDecorationTheme.contentPadding:
EdgeInsets.symmetric(horizontal: 16, vertical: 16)`, hardcoded in
`lib/core/theme/app_theme.dart` and repeated across all 10 theme variants. They
are a fixed ~100dp floor under the chrome that no scale change can touch. This
matters in Phase 0.

### Why call-site fixes are not viable

**2,622 `getRSize(` + 674 `getRFontSize(` call sites across 96 files.** Any plan
that edits call sites is a plan that never finishes. The seam is one function.

### Secondary defects

**Breakpoints misclassify a landscape phone as a tablet.**
`isTablet => screenWidth >= 600` (`responsive.dart:51`) is true at 915dp wide.
That drives:
- `crossAxisCount: context.isTablet ? 3 : 2` — `inventory_screen.dart:2265`
- the `availableWidth / 180` column math — `product_grid.dart:105-109`
  (4 columns of `getRSize(210)` = 315dp-tall cards inside a 245dp viewport)
- layout options stripped from the POS view picker — `view_selector_sheet.dart:66`
- the 480dp auth content cap dropped — `branded_auth_background.dart:62`,
  `auth_background.dart:68`

**iPads flip navigation mode on rotate.** `isDesktop => screenWidth >= 1024`
means a 10.9" iPad is a *tablet* in portrait (820dp wide → bottom nav) and a
*desktop* in landscape (1180dp wide → 280dp side rail, `main_layout.dart:286`).
Rotating the device swaps the entire navigation chrome. Pre-existing, unreported.

**Nothing in the app is orientation-aware.** No `OrientationBuilder` anywhere.
Rotation is explicitly permitted on both platforms — `Info.plist` lists both
landscape orientations, and `AndroidManifest.xml:38` declares
`configChanges="orientation|...|screenSize"`.

**No rendered-UI tests exist.** `test/golden/` holds DAO fixtures, not widget
goldens. There is no harness that would have caught this and none that will
catch a regression.

---

## 2. Design principles

1. **Nothing is removed in landscape.** Every component present in portrait is
   present in landscape. Density drops and layout re-flows — bands become rails —
   but no control is hidden, collapsed behind a menu, or gated on orientation.
   This is the owner's explicit requirement and it governs every phase below.
2. **Typography and spacing are separate curves.** Spacing may compress hard;
   text must stay legible. They are already separate entry points
   (`getRSize` vs `getRFontSize`), so they can diverge without touching a call site.
3. **Width answers horizontal questions, height answers vertical ones.**
   Column counts and content width come from width. Band heights, gaps, and
   whether chrome collapses come from height.
4. **Form factor is `shortestSide`.** A phone in landscape is a phone. A tablet
   is a tablet in both orientations.
5. **Landscape is a re-flow, not a squeeze.** Where a screen has fixed horizontal
   bands stacked vertically, landscape moves them into a vertical rail. Landscape
   has width to spare and no height; the layout should trade one for the other.
6. **Tablets get more content, not bigger content.** Extra space becomes more
   columns, a second pane, a visible detail view — never larger padding.

---

## 3. The scale model

Replace the single width curve with a height-gated form-factor curve, split into
two clamps.

```dart
/// Baseline width for the form-factor scale (iPhone SE / standard Android).
const double _kBaseWidth = 375.0;

/// Height at or above which vertical space is not scarce and the form-factor
/// scale governs alone. Below it, scale is cut proportionally so a short
/// viewport fits the same components at lower density.
const double _kComfortableHeight = 700.0;

double _rawScale(Size size) {
  final formFactor = size.shortestSide / _kBaseWidth;
  final heightFactor = (size.height / _kComfortableHeight).clamp(0.0, 1.0);
  return formFactor * heightFactor;
}

/// Structure: padding, gaps, band heights, icon boxes. Compresses hard.
double _spacingScale(Size size) => _rawScale(size).clamp(0.70, 1.50);

/// Typography. Compresses gently — text must stay legible at any density.
double _fontScale(Size size) => _rawScale(size).clamp(0.90, 1.35);
```

`getRSize` / `rSize` use `_spacingScale`. `getRFontSize` / `rFontSize` use
`_fontScale`. **No call site changes.**

`heightFactor` is clamped to a 1.0 ceiling so it only ever *cuts* — a tall
viewport never boosts the scale beyond what the form factor asked for. That is
what keeps tablets stable across rotation.

### Verified impact

| device | w×h | form | hFactor | spacing | font | today | change |
|---|---|---|---|---|---|---|---|
| iPhone SE (1st) portrait | 320×568 | 0.853 | 0.811 | **0.70** | 0.90 | 0.85 | tighter |
| Android compact portrait | 360×800 | 0.960 | 1.00 | **0.96** | 0.96 | 0.96 | none |
| iPhone 13 mini portrait | 375×812 | 1.000 | 1.00 | **1.00** | 1.00 | 1.00 | none |
| Pixel 7 portrait | 412×915 | 1.099 | 1.00 | **1.10** | 1.10 | 1.10 | none |
| iPhone 15 Pro Max portrait | 430×932 | 1.147 | 1.00 | **1.15** | 1.15 | 1.15 | none |
| **Pixel 7 landscape** | **915×412** | 1.099 | 0.589 | **0.70** | **0.90** | **1.50** | **fixed** |
| **Android compact landscape** | **800×360** | 0.960 | 0.514 | **0.70** | **0.90** | **1.50** | **fixed** |
| iPad 10.9 portrait | 820×1180 | 2.187 | 1.00 | **1.50** | 1.35 | 1.50 | none |
| iPad 10.9 landscape | 1180×820 | 2.187 | 1.00 | **1.50** | 1.35 | 1.50 | none |
| iPad mini portrait | 744×1133 | 1.984 | 1.00 | **1.50** | 1.35 | 1.50 | none |
| iPad mini landscape | 1133×744 | 1.984 | 1.00 | **1.50** | 1.35 | 1.50 | none |
| iPad Pro 12.9 portrait | 1024×1366 | 2.731 | 1.00 | **1.50** | 1.35 | 1.50 | none |
| iPad Pro 12.9 landscape | 1366×1024 | 2.731 | 1.00 | **1.50** | 1.35 | 1.50 | none |

**Every portrait phone is unchanged. Every tablet is unchanged in both
orientations — no jump on rotate. Only landscape phones and the 1st-gen SE
move, and both move in the direction they need.**

The font clamp ceiling of 1.35 (down from 1.50) is the one deliberate tablet
change: it stops body text reaching 21px on an iPad while spacing still opens to
1.50. Tablets get more room between things and more columns, not larger type —
principle 6. Flag this in review; it is the only judgement call in the table.

### New breakpoints

```dart
/// Vertical space is scarce — collapse or re-flow chrome, never hide it.
bool get isShortViewport => screenHeight < 500;

/// Form factor, not window size. A landscape phone is a phone.
bool get isPhone  => screenShortestSide < 600;
bool get isTablet => screenShortestSide >= 600 && screenShortestSide < 1024;

/// The 280dp side-rail decision. Width-driven — it is a question about
/// horizontal room — but never in a short window.
bool get isDesktop => screenWidth >= 1024 && !isShortViewport;
```

Leave the raw width comparisons alone where the code genuinely asks about
available width: `product_grid.dart:105` (`availableWidth > 600`) and
`receive_product_grid.dart:45`. A landscape phone really does have 915dp of
width and should show more columns — it just must not also get 315dp-tall cards.

`isDesktop` keeps its width basis, so a 10.9" iPad keeps the side rail in
landscape and loses it in portrait — the standard iPad size-class behaviour, and
the same as today. Making `isDesktop` shortestSide-based would strip the rail
from every iPad below 12.9"; that is a larger product change and is **not**
proposed here.

### The fixed floor under the chrome

Scale alone cannot fix POS, because ~100dp of the chrome does not scale:
`AppDropdown` (~48dp) and `AppInput` (~52dp) get their height from
`inputDecorationTheme.contentPadding: vertical: 16`, hardcoded across all 10
theme variants in `app_theme.dart`.

Do **not** edit the 10 theme sites. Both widgets already accept a
`contentPadding` parameter and already fall through to the theme when it is null
(`app_input.dart:118`, `app_dropdown.dart:255`). Give each a compact default
derived from `isShortViewport` — vertical 16 → 8. Two widget files, ten themes
fixed, no theme churn.

### Does it fit?

POS landscape on a Pixel 7 (915×412), body ≈ 252dp:

| band | at spacing 0.70 + compact inputs | height |
|---|---|---|
| `_buildHeader` | `getRSize(16)`×2 = 22.4 + dropdown 35 | 57.4dp |
| `_buildSearchField` | `getRSize(12)` = 8.4 + input 35 | 43.4dp |
| `CategoryFilterBar` | `getRSize(38)` = 26.6 + margins 16.8 | 43.4dp |
| **chrome** | | **144.2dp** |
| **grid** | | **107.8dp** |

The overflow is gone, but 108dp of grid is one compact row and a peek. **Scale
fixes the crash; it does not fix the screen.** That is what Phase 2's re-flow is
for.

---

## 4. Landscape phone layout: re-flow, not squeeze

Landscape has 915dp of width and 252dp of height. Stacking horizontal bands
vertically is the wrong shape for that viewport regardless of density.

**POS in landscape becomes a filter rail plus grid:**

```
┌──────────────────────────────────────────────────────────┐
│ AppBar                                                    │
├────────────────┬─────────────────────────────────────────┤
│ Retailer     ▾ │                                         │
│ All          ▾ │        product grid                     │
│ [search     ]  │        full 252dp of height             │
│ ⚡ Quick sale  │        ~715dp of width                  │
│ ─────────────  │                                         │
│ All            │                                         │
│ Flavor         │                                         │
│ Water          │                                         │
│ Uncategorized  │                                         │
└────────────────┴─────────────────────────────────────────┘
│ Home   Stock   POS   Orders   Cart                        │
└──────────────────────────────────────────────────────────┘
```

Rail ~200dp. The category chips become a vertical scrolling list. Every control
that exists in portrait exists here — principle 1. The grid gains the full body
height instead of 108dp: **2.3× more usable product area than compression alone.**

The same rail pattern applies to every screen with the header-bands-above-a-list
shape: POS, Receive Stock (`receive_stock_screen.dart:162-200`, identical
structure), Inventory, Orders.

---

## 5. Tablet interface design

Tablets are not scaled-up phones. The extra space becomes panes and columns.

### 5.1 POS — the two-pane sale

The single highest-value tablet change. Today a tablet cashier taps POS → adds
items → switches to the Cart tab → checks out → returns. On a tablet the cart
should simply be visible.

**Landscape (1180×820) — three panes:**

```
┌─────────────────────────────────────────────────────────────────┐
│ AppBar                                                           │
├──────────────┬───────────────────────────────┬─────────────────┤
│ Retailer   ▾ │                               │ Customer      ▾ │
│ All        ▾ │                               ├─────────────────┤
│ [search   ]  │      product grid             │ Star Lager  ×4  │
│ ⚡ Quick sale│      4–5 columns              │ Coke 50cl   ×12 │
│ ───────────  │                               │ Water       ×2  │
│ All          │                               ├─────────────────┤
│ Flavor       │                               │ Subtotal  ₦8,400│
│ Water        │                               │ Deposit   ₦1,200│
│ Uncategorized│                               │ Total     ₦9,600│
│              │                               │ [ Checkout    ] │
├──────────────┴───────────────────────────────┴─────────────────┤
│ Home   Stock   POS   Orders   Cart                              │
└─────────────────────────────────────────────────────────────────┘
   220dp              flex                        380dp
```

**Portrait (820×1180) — two panes:** filters stay as top bands, grid flex, cart
pane 340dp on the right.

**Feasibility — verified, this is an extraction not a rewrite:**
- `CartScreen`'s `cart:` parameter is **dead code**. Grep confirms only
  `widget.onCustomerChanged` is referenced (lines 453, 607); `widget.cart` never
  is. `main_layout.dart:68` already constructs it as
  `CartScreen(cart: [], onCustomerChanged: _voidOnCustomerChanged)`.
- The screen already reads live state from `cartProvider` at line 793.
- `build()` runs 789→1713 with the `Scaffold` boundary at line 995: lines
  789–995 are derivation (subtotal, bottle detection, crate deposits), 995–1713
  are UI.

**Extraction:** split at 995. Lines 789–995 become a `CartTotals` computation
(pure, testable, no widget). Lines 995+ become `CartPane`. `CartScreen` becomes
`Scaffold(appBar: …, body: CartPane())`. POS embeds `CartPane` directly. Delete
the dead `cart:` parameter in the same commit.

The Cart bottom-nav tab stays for phones and remains reachable on tablets — the
pane is additive, principle 1.

### 5.2 List-detail split

Eight screens push a detail route from a list. On a tablet both should be
visible at once.

| list | detail push site |
|---|---|
| Inventory → Product | `inventory_screen.dart:1287` |
| Inventory → Supplier | `inventory_screen.dart:899` |
| Customers → Customer | `customers_screen.dart:296` |
| Orders → Customer | `orders_screen.dart:1658` |
| Payments → Supplier | `payments_screen.dart:263` |
| Staff → Staff member | `staff_management_screen.dart:619` |
| Stores → Store | `stores_screen.dart:982` |
| Drivers → Driver | `drivers_list_screen.dart:99` |

Build one `MasterDetailScaffold` in `lib/shared/widgets/`: on `isTablet ||
isDesktop` it renders master (360–420dp) beside detail with an empty-state
placeholder when nothing is selected; on phone it pushes exactly as today. All
eight sites route through it. One widget, eight screens, and phone behaviour is
untouched by construction.

### 5.3 Checkout — two columns

`checkout_page.dart` is a single tall `SingleChildScrollView` (`_buildCheckoutForm`, line 400) with 38
fixed `getRSize` heights. On a tablet: order summary and crate deposits left,
customer / tender / payment method right. Removes the scroll from the money path
entirely at tablet width.

### 5.4 Dashboard and reports

`home_screen.dart` and the eight report screens use 2-across stat grids. On
tablet go 3–4 across and let charts take real width. Low risk, high polish.

### 5.5 Sheets become dialogs

On tablet a full-width bottom sheet is a 1180dp-wide strip of controls. Above
`isTablet`, present them as centred dialogs capped at 560dp. Affects the sheet
inventory in Phase 6 — one presentation helper, not per-sheet edits.

### 5.6 Auth and onboarding

Already correct: `BrandedAuthBackground` and `AuthBackground` cap content at
480dp when `!context.isPhone`. One change needed — see Phase 1's trap.

---

## 6. Phase order

Each phase is one branch and one PR. Do not entangle phases.

### Phase 0 — the seam `fix/responsive-short-viewport-seam`

1. Rewrite the scale model in `responsive.dart` per §3. All four entry points.
2. Add `isShortViewport`; move `isPhone`/`isTablet` to `shortestSide`; add the
   `!isShortViewport` guard to `isDesktop`.
3. Compact `contentPadding` defaults in `app_input.dart` and `app_dropdown.dart`
   (§3, "fixed floor"). Do **not** touch the 10 theme sites.
4. Build the test harness this repo has never had: `test/helpers/viewports.dart`
   with the named surfaces from the §3 table. Add a widget test that pumps POS
   home at `phoneLandscape` and asserts no overflow. **It must fail on `main`
   before the fix and pass after** — demonstrate both.
5. Add a static ban test modelled on `test/providers/mirror_notifier_ban_test.dart`
   (read it first; it is the house pattern, alongside
   `business_scoped_stream_ban_test.dart` and `gate_static_ban_test.dart`).
   Ban new `MediaQuery.of(context).size.height *` literals outside an allowlist
   of the 15 existing sites. If a reliable regex for "unscrollable Column under a
   body" is not achievable, ship only the height-literal ban and say so — do not
   ship a flaky test.
6. Write the ADR (next free number is **0024**; 0018 is absent from `docs/adr/`
   — confirm before claiming a number). Record the two-curve model, the
   `_kComfortableHeight` gate, the 1.35 font ceiling, and the rejected
   alternatives: orientation lock, and shortestSide-based `isDesktop`.

**Stop after Phase 0 and hand back for an emulator rotation check.** This phase
moves every screen at once; it earns a review of its own.

### Phase 1 — onboarding and auth `fix/responsive-auth-landscape`

A landscape user cannot get *into* the app. `AuthFormShell` / `AuthCenteredScroll`
(`auth_form_kit.dart`) already do the right thing — `LayoutBuilder` +
`SingleChildScrollView` + `minHeight` — and use raw sizes rather than `getRSize`,
so kit-based screens already survive. Fix the ones that are not on the kit:

1. `biometric_setup_screen.dart` — **hard break.** Bare centred `Column`, no
   scroll view at all (line 110ff): step indicator 56 + icon 80 + title + body +
   two buttons inside a ~313dp box. Move onto `AuthCenteredScroll`.
2. `success_dashboard_entry_screen.dart:43` — same unscrolled-`Column` shape.
3. `coming_soon_screen.dart:34` — same.
4. `login_screen.dart` — the most-used screen in the app. Uses `getRSize`
   heavily, sets `resizeToAvoidBottomInset: false` (line 591), and `PinKeypad`'s
   four rows of 64×64 keys need ~320dp in a ~369dp landscape viewport. It
   scrolls, but a scrolling PIN pad is a bad daily login. Under `isShortViewport`
   lay it out as two columns — avatar, greeting and dots left, keypad right.
5. `create_pin_screen.dart` — same keypad treatment; already scrolls.
6. `who_is_working_screen.dart:313` — staff `GridView` computes
   `childAspectRatio` from width. Recheck against a 412dp-tall viewport.
7. `ceo_sign_up_screen.dart:762` — `_buildTopBar` (logo + 56dp
   `OnboardingStepIndicator`) is fixed above an `Expanded` step body. Under
   `isShortViewport` collapse the indicator to a compact "Step 3 of 7" line —
   same information, one row.
8. Verify only, with the harness: `email_entry_screen`, `otp_verification_screen`,
   `existing_account_screen`, `no_account_found_screen`, `staff_sign_up_screen`,
   `welcome_screen`, `access_granted_screen`.

**Trap.** After Phase 0's breakpoint change a landscape phone becomes
`isPhone == true` and therefore *loses* the 480dp content cap at
`branded_auth_background.dart:62` and `auth_background.dart:68` — auth content
would stretch to 915dp. Change both conditions to
`!context.isPhone || context.isShortViewport`.

### Phase 2 — POS `fix/responsive-pos-landscape`

- Implement the §4 landscape rail in `pos_home_screen.dart` under
  `isShortViewport`. Portrait keeps today's bands.
- `category_filter_bar.dart` — horizontal chip strip in portrait, vertical list
  in the rail. Halve the `getRSize(8)` / `getRSize(16)` margins in short viewports.
- `product_grid.dart:110-116` — the aspect ratio pins card height at
  `getRSize(210)`. In a short viewport target ~150dp base and default to the
  compact list layout.
- `view_selector_sheet.dart:66` — after Phase 0, confirm a landscape phone still
  gets the full option set (it is now `isPhone`, so it should).
- `pos_barcode_scan_button.dart` uses `reserveBottomInset: false` because the
  bottom nav lifts the FAB. Confirm that still holds in landscape.

### Phase 3 — money path `fix/responsive-checkout-landscape`

`cart_screen.dart` → `checkout_page.dart` → `receipt_widget.dart`. A sale cannot
currently be *completed* in landscape. `checkout_page.dart` scrolls, so the risk
is its pinned footers and the `size.height * 0.5` sheet at line 1548.
`cart_screen.dart:219` and `:394` use `* 0.7` / `* 0.85` fixed-height sheets
whose internal headers do not shrink — check both at 412dp.

### Phase 4 — remaining bottom-nav roots `fix/responsive-tabs-landscape`

`inventory_screen.dart` (including the `isTablet ? 3 : 2` grid at 2265),
`orders_screen.dart`, `receive_stock_screen.dart` (identical
header-bands-above-`Expanded` shape as POS, and no scroll on the fixed part),
`home_screen.dart`.

### Phase 5 — reports and detail screens

`reports_hub`, `profit_report`, `sales_detail`, `daily_reconciliation_detail`,
`daily_reconciliation_list`, `crate_deposits_report`, `supplier_accounts_report`,
`stock_approvals`.

### Phase 6 — sheets and modals

The 15 `size.height * <fraction>` sites are the correct *shape* — they shrink
with the viewport — but several wrap fixed-height headers that do not. Audit each
at 412dp:

`crate_return_modal.dart:453` (`* 0.25` = 98dp — almost certainly broken),
`crate_return_modal.dart:393`, `manage_categories_sheet.dart:91`,
`update_product_sheet.dart:750`, `customer_detail_screen.dart:1080` and `:1257`,
`orders_screen.dart:1032` and `:1288`, `stores_screen.dart:802`,
`checkout_page.dart:1548`, `cart_screen.dart:219` and `:394`,
`van_sale_receipt_sheet.dart:61`, `van_receipt_view.dart:234`.

Plus `edit_item_modal`, `quick_sale_modal`, `notifications_modal`,
`store_picker_sheet`, `pin_dialog`, `printer_picker`.

Add the §5.5 tablet dialog presentation in the same phase.

### Phase 7 — tablet panes `feat/tablet-two-pane`

Depends on Phases 0–4. §5.1 POS two-pane (including the `CartPane` extraction
and deleting the dead `cart:` parameter), then §5.2 `MasterDetailScaffold` across
the eight list-detail sites, then §5.3 checkout columns and §5.4 report grids.

Largest phase — split into three PRs if the diff runs long.

### Phase 8 — long tail

Settings (12 screens), staff, stores, customers, expenses, payments, van sales
(11 screens), sync, diagnostics, subscription, profile.

### Phase 9 — document the system

- `context/ui-context.md` — new "Short viewports and tablets" section under
  "Responsive Grid & Card Layouts": the two-curve scale, `_kComfortableHeight`,
  the `isShortViewport` breakpoint, the form-factor-vs-available-width rule, the
  six principles from §2, and the rule that fixed chrome above an `Expanded` must
  re-flow or collapse — never be hidden.
- `context/progress-tracker.md` and `BUILD_LOG.md` entries per phase.

---

## 7. Verification, every phase

- `flutter analyze` clean.
- The Phase 0 harness green at all named surfaces for every screen the phase
  touched.
- `flutter run` on the emulator, rotate to landscape, walk the phase's screens.
  Before/after screenshots. **Never `flutter build apk`.**
- Report honestly. If a screen is left broken, name it and say why.

---

## 8. Constraints for whoever implements this

- Read `context/project-overview.md`, `architecture.md`, `ui-context.md`,
  `code-standards.md`, `ai-workflow-rules.md`, `progress-tracker.md` first —
  `CLAUDE.md` requires it before any architectural work.
- Never `git checkout` a file to discard changes; the tree carries large
  uncommitted work. Re-edit or stash. Do not run `dart format`.
- No AI attribution in commits or PRs — no `Co-Authored-By` trailer.
- Never hardcode a hex, radius, or raw pixel value. Use the access paths in
  `ui-context.md`.
- Bottom-anchored content uses `context.deviceBottomPadding`. Never
  `deviceBottomInset`, never raw `MediaQuery...padding.bottom` — see the doc
  comments in `responsive.dart`, they explain the double-inset trap.
- The user edits files mid-session. Re-verify file state before editing.

---

## 9. Decision already made

Locking phones to portrait was considered and **rejected by the owner.** Phones
stay rotatable; the requirement is that a rotated phone shows *all* the same
components at lower density. That is principle 1 and it is not negotiable in
review — no phase may resolve a fit problem by hiding a control.
