# Responsive Layout Plan — short viewports, compact portrait phones, and tablets

Status: in progress — Phase 0 landed with gaps (see §10); runtime measurement audit added (see §11).
Author: design investigation, 2026-09-05
Audited against implementation: 2026-09-06 (branch `fix/responsive-short-viewport-seam`)
Audited against runtime measurement (PRD #239): 2026-09-18 (issue #242)
Scope: `lib/core/utils/responsive.dart` + every screen in `lib/`. **Not landscape-only**: small portrait phones (such as iPhone SE1 320×568) suffer the exact same content starvation and layout overflows, and sit *above* the plan's 500dp `isShortViewport` threshold (see §11.3).
Related: `context/ui-context.md`, `docs/adr/0025-two-curve-responsive-scale.md`, `docs/adr/0027-tabbed-sliver-scaffold.md`

> **Read §10 and §11 first if you are picking this up.** Phase 0 shipped the scale model
> and it works, but runtime measurement under PRD #239 contradicted five of the plan's
> core assumptions and figures. §11 records the five corrections; §1, §3, and §4 have
> been annotated or corrected in place with pointers to §11.

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
| `_buildHeader` | `getRSize(16)` padding ×2 = 48 + `AppDropdown` ~48 | ~96dp *(correction: ~121dp with 73dp labelled dropdown, see §11.1)* |
| `_buildSearchField` | `getRSize(12)` bottom pad = 18 + `AppInput` ~52 | ~70dp |
| `CategoryFilterBar` | `getRSize(38)` = 57 + margins `getRSize(8)`/`getRSize(16)` = 36 | ~93dp |
| **total fixed chrome** | | **~259dp** *(correction: **~284dp**, see §11.1)* |

The body has ~245dp (412 − 24 status − 68 app bar − ~68 nav + gesture inset).
The `Expanded` collapses to zero and the fixed children spill by the difference.

Note the `AppDropdown` (~48dp) and `AppInput` (~52dp) heights are *not* scaled —
they come from `inputDecorationTheme.contentPadding:
EdgeInsets.symmetric(horizontal: 16, vertical: 16)`, hardcoded in
`lib/core/theme/app_theme.dart` and repeated across all 10 theme variants. They
are a fixed ~100dp floor under the chrome that no scale change can touch. This
matters in Phase 0. *(Correction in §11.1: `AppDropdown` with its stacked label
actually measures 73dp, not ~48dp or ~40dp, because the label stacked above the
field contributes 25dp of unscaled constants. The fixed chrome budget is
correspondingly taller.)*

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
Rotating the device swaps the entire navigation chrome. Pre-existing, unreported
— and **still present after Phase 0**, which deliberately preserved today's
classification. Now owned by Phase 7 (§10, deviation 2).

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
5. **Landscape is a re-flow, not a squeeze.** Where a screen stacks fixed
   horizontal bands, landscape must trade its surplus width for the height it
   lacks — by moving chrome into a rail, or by letting it collapse on scroll.
   §4 holds the open comparison; compression alone is never the answer.
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

/// Structure: padding, gaps, band heights, icon boxes. Compresses hard —
/// but only in a genuinely short viewport. See "conditional floor" below.
double _spacingScale(Size size) {
  final floor = size.height < 500.0 ? 0.70 : 0.85;
  return _rawScale(size).clamp(floor, 1.50);
}

/// Typography. Compresses gently — text must stay legible at any density.
double _fontScale(Size size) => _rawScale(size).clamp(0.90, 1.35);
```

**The conditional spacing floor was added during implementation and is correct.**
This plan originally specified a flat 0.70 floor. That was a latent bug: spacing
and font previously shared one curve, so the box-to-text ratio was 1.0 *by
construction* and text fit its container automatically. Splitting the curves
destroys that invariant. A flat 0.70 floor on a comfortable-height device — the
1st-gen SE at 320×568 — would have shrunk boxes 18% while growing text 5.5%: a
**28% ratio swing across ~3,300 call sites nobody is going to review by hand**,
i.e. silent text truncation. Holding the floor at 0.85 whenever the viewport is
not short keeps the swing under 6%. Only `isShortViewport` drops to 0.70, where
the compression is needed and the screens are being reworked anyway.

`getRSize` / `rSize` use `_spacingScale`. `getRFontSize` / `rFontSize` use
`_fontScale`. **No call site changes.**

`heightFactor` is clamped to a 1.0 ceiling so it only ever *cuts* — a tall
viewport never boosts the scale beyond what the form factor asked for. That is
what keeps tablets stable across rotation.

### Verified impact

| device | w×h | form | hFactor | spacing | font | today | change |
|---|---|---|---|---|---|---|---|
| iPhone SE (1st) portrait | 320×568 | 0.853 | 0.811 | **0.85** | 0.90 | 0.85 | none |
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

**Every portrait phone is unchanged — the 1st-gen SE included, once the
conditional floor is applied. Every tablet is unchanged in both orientations,
so there is no jump on rotate. Landscape phones are the only viewports that
move, and they move exactly where they needed to go.**

Every row above is now asserted by `test/utils/responsive_test.dart` — 26 tests,
one scale assertion and one breakpoint assertion per viewport. The table is
executable, not aspirational.

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
| `_buildHeader` | `getRSize(16)`×2 = 22.4 + dropdown 35 | 57.4dp *(correction: 95.4dp with 73dp labelled dropdown, see §11.1)* |
| `_buildSearchField` | `getRSize(12)` = 8.4 + input 35 | 43.4dp |
| `CategoryFilterBar` | `getRSize(38)` = 26.6 + margins 16.8 | 43.4dp |
| **chrome** | | **144.2dp** *(correction: **182.2dp**, see §11.1)* |
| **grid** | | **107.8dp** *(correction: **~69.8dp**, see §11.1)* |

> **Correction (2026-09-18, §11.1):** The table above calculated dropdown height
> at 35dp (and earlier 48dp). In reality, `AppDropdown` with its stacked label
> measures **73dp** (48dp tap target floor + 25dp unscaled label constants).
> Corrected chrome at rest is **182.2dp**, leaving only **~69.8dp** for the grid.

The overflow is gone, but 108dp of grid is one compact row and a peek. **Scale
fixes the crash; it does not fix the screen.** That is what Phase 2's re-flow is
for.

---

## 4. Landscape phone layout — DECIDED 2026-09-17: Option A, collapsing header

> **Decision (issue #259, PRD #239).** The open question below is settled in
> favour of **Option A, the collapsing header**. The top bar and the
> price-tier / store row scroll away; the search bar and the category chips
> freeze at the top. Shipped in `pos_home_screen.dart` as a single
> `CustomScrollView`.
>
> **What settled it** — and it was not the pixel table below:
>
> 1. **The defect is worse than this section measured.** This section's
>    arithmetic assumed the grid gets `body − chrome` ≈ 90dp. The #241 discovery
>    sweep measured the populated grid at **0.0dp of 463dp** at 800x360, with a
>    21px overflow, and 102px when the catalogue is empty. The grid was not
>    "one clipped row", it was nothing at all, silently — so the choice was not
>    between 82,350dp² and 180,200dp², it was between zero and either.
> 2. **The bars give their height back sideways.** #258 slides the bottom bar
>    away while scrolling and POS's own top bar returns on reverse scroll. That
>    is what makes A viable at the shortest supported viewport, and it did not
>    exist when the table below was drawn.
> 3. **Option B's decisive advantage no longer applies.** B was "every control
>    permanently reachable". Under A as shipped, the search bar and chips are
>    *frozen* — permanently reachable — and the tier row is one reverse scroll
>    away, not behind a menu. B's cost, a column or two of products on a screen
>    where width is the only thing POS has plenty of, is permanent.
>
> **The recorded trade-off, accepted with open eyes:** frozen chrome grows with
> the system font size, which is precisely the `textScaler` argument ADR 0025 §5
> made for the rail. It is real. `pos_home_viewport_test.dart` pins it — a
> complete product card must stay reachable sideways at the app's maximum scale
> (1.3, the clamp in `main.dart`) — so if the frozen band ever grows enough to
> starve the grid again, a test fails rather than a cashier discovering it.
>
> **The implementation risk flagged below did not materialise.** A collapsing
> header inside `AppRefreshWrapper` works; a test pins that overpulling POS
> still descends the spinner. `PinnedHeaderSliver` (Flutter 3.24+) and
> `SliverFloatingHeader` (Flutter 3.27+, so **3.27 is the binding floor** for
> this screen) did the work, so no `NestedScrollView` and no hand-written
> `SliverPersistentHeaderDelegate` with a declared extent were needed — which
> also means there is no declared extent to keep in step with the responsive
> scale.
>
> Everything from here to the end of section 4 is the original open decision,
> kept as the record of how the call was reached.

## 4 (original). Landscape phone layout — an open decision, to be measured in Phase 2

Landscape gives POS 915dp of width and 252dp of body height. With Phase 0's
scale, 40dp fields and the 48dp dropdown tap-target floor in place, the fixed
chrome measures — these figures are asserted, not estimated
(`test/pos/pos_home_screen_overflow_test.dart`):

| band | composition at spacing 0.70, 40dp input, 48dp dropdown | height |
|---|---|---|
| `_buildHeader` | `getRSize(16)`×2 = 22.4 + `AppDropdown` **48** | 70.4dp *(correction: 95.4dp with 73dp labelled dropdown, see §11.1)* |
| `_buildSearchField` | `getRSize(12)` = 8.4 + `AppInput` 40 | 48.4dp |
| `CategoryFilterBar` | `getRSize(38)` = 26.6 + margins 16.8 | 43.4dp |
| **chrome** | | **162.2dp** *(correction: **187.2dp**, see §11.1)* |
| **grid** | 252 − 162.2 | **~90dp** *(correction: **~64.8dp**, see §11.1)* |

> **Correction (2026-09-18, §11.1):** `AppDropdown` **48** only accounted for
> the bare control, omitting the 25dp unscaled label stacked above it. With its
> label, `AppDropdown` measures **73dp**, raising `_buildHeader` to **95.4dp**,
> chrome to **187.2dp**, and reducing grid at rest to **~64.8dp** (one clipped
> row). On 800×360 the populated grid is starved to **0.0dp** (see §11.2).

**Updated 2026-09-07:** chrome was 154.2dp with a 40dp dropdown. Restoring
`AppDropdown`'s 48dp tap target (gap 3) added 8dp to the header band and took
8dp off the grid. The 8dp was deliberately not clawed back from padding — see
gap 3; buying grid pixels with a tap target is exactly the trade principle 1
forbids.

~90dp is one clipped row. **Phase 0 stopped the crash; the screen is still not
usable in landscape.** Two designs are on the table and neither has been
measured on a device.

The 1st-gen-SE landscape case (568×320) is worse and worth naming: chrome is the
same 162.2dp against a much shorter body, leaving **~9.8dp of grid**. It does not
crash — the test pins that — but POS is not usable at 320dp landscape at any
scale. Only the re-flow below fixes it.

### Option A — collapsing header

App bar and the Retailer/All dropdown row scroll away with the grid; search and
category chips pin to the top.

- At rest: grid = 915 × 90 = **82,350dp²**
- Scrolled: app bar (68) + dropdown row (70.4) yield; pinned chrome = 91.8dp
  (search 48.4 + chips 43.4); grid = 915 × 228 = **208,800dp²**

Note the scrolled figure is unchanged by the 48dp dropdown floor — the dropdown
row is precisely what Option A scrolls away, so the 8dp comes back. Only the
at-rest figure moved (89,500 → 82,350), which widens A's at-rest deficit.

### Option B — side rail

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

Rail ~200dp; chips become a vertical list. Grid = 715 × 252 = **180,200dp²**,
constant, with every control permanently visible and no gesture required.

### The honest comparison

| | at rest | after scrolling | controls always visible | columns |
|---|---|---|---|---|
| today | 82,350dp² | 82,350dp² | all | ~5 |
| **A** collapsing | 82,350dp² | **208,800dp²** | search + chips only | ~5 |
| **B** rail | **180,200dp²** | 180,200dp² | **all** | ~3–4 |

**A wins once scrolled (+16% over B) and loses badly at rest (−54%). B is
constant and needs no gesture, but costs ~200dp of width and therefore a column
or two.** A also lets the tier dropdown leave the viewport, which B does not —
so A's advantage is not "keeps more reachable", it is "more pixels once the
cashier scrolls".

Two corrections to earlier drafts of this section, both recorded so the next
reader does not re-derive them:

1. **This plan originally claimed the rail gives "2.3× more usable product
   area". That was wrong** — it divided heights (252/98 = 2.6×) and called the
   result area. The rail costs 200dp of width, so the real at-rest gain is
   **2.0×**, not 2.3×.
2. **A later edit marked the rail "rejected" on the grounds that a collapsing
   header "keeps both permanently reachable" while the rail merely "partitioned
   horizontal space". That reasoning is backwards** — the rail keeps *every*
   control permanently reachable, including the tier dropdown that Option A
   scrolls away. The table above is the accurate basis for the choice.

~~**Neither option is rejected. Phase 2 prototypes both on a real device and picks
on measurement**, per the `prototype` skill. Decide with the owner — the cashier's
actual scroll behaviour during a sale settles this, and no amount of arithmetic
will.~~

**Superseded 2026-09-17 (#259): Option A is decided — see the decision box at the
top of this section.** The owner settled it on the #241 emulator walk, where the
grid turned out to be at zero height rather than one clipped row.

### Implementation risk that must be scoped before choosing A

Option A requires converting POS's body from a `Column` to slivers
(`NestedScrollView` / `SliverAppBar` with `pinned`) — **inside `AppRefreshWrapper`,
which this codebase documents as the single sanctioned `RefreshIndicator`
(`lib/shared/widgets/app_refresh_wrapper.dart`; see the pull-to-refresh
invariant in `CONTEXT.md`).** Nesting a collapsing header inside a
`RefreshIndicator` is a known-awkward Flutter combination and will interact with
`SyncPullBanner`. Option B is a `Row` and carries none of this risk. Weigh that
alongside the pixel counts.

### ADR 0025 contradicted this section — RESOLVED 2026-09-17 (#259)

`docs/adr/0025-two-curve-responsive-scale.md` §5 concluded that "Phase 2's
structural re-flow (**rail layout**) is required, not optional", citing the
`textScaler 1.3` drift that gives back most of the compaction savings. The plan
text meanwhile marked the rail rejected.

**Resolved: ADR 0025 §5 was corrected in #259's PR**, in the same commit as the
fix, per the standing rule that one of the two documents had to give. §5 now
says a structural re-flow is required — which was always its real finding — and
no longer prescribes the rail as the form it must take.

The `textScaler` finding itself stands and is not weakened: a rail's grid height
does not shrink when a user raises their system font size, and Option A's frozen
chrome does. That cost was accepted deliberately and is now pinned by a test
rather than left to be rediscovered (see the decision box above).

### Applicability beyond POS

Whichever wins applies equally to every screen with the
header-bands-above-a-list shape: Receive Stock
(`receive_stock_screen.dart:162-200`, structurally identical), Inventory, and
Orders.

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
   — confirm before claiming a number). **This instruction was wrong and the ADR
   shipped on a colliding number — see §10 gap 3a. The ADR is `0025`. Neither
   0024 nor 0018 was free: both were held by unmerged branches, which a check
   against `docs/adr/` on this branch alone cannot see.** Record the two-curve model, the
   `_kComfortableHeight` gate, the 1.35 font ceiling, and the rejected
   alternatives: orientation lock, and shortestSide-based `isDesktop`.

#### Phase 0 — audited status (2026-09-06)

Commits `183f0a8`, `fdab844`, `4f3fe1b`, `f50ed17`, `78778af`, `928a66d`,
`b580f1a` on `fix/responsive-short-viewport-seam`. `flutter analyze` clean.

| # | deliverable | status |
|---|---|---|
| 1 | two-curve scale model, all four entry points | **done** — plus a correct deviation (§3, conditional floor) |
| 2 | `isShortViewport`, shortestSide breakpoints, `isDesktop` guard | **done** — with one deviation (below) |
| 3 | compact `contentPadding` in `AppInput` / `AppDropdown` | **done, and exceeded** — measured, not estimated |
| 4 | viewport harness + POS-home overflow test | **done 2026-09-07** — `test/pos/pos_home_screen_overflow_test.dart` (5 tests) + `test/helpers/pos_home_harness.dart`; was partial at the 2026-09-06 audit |
| 5 | static ban test | **done 2026-09-07** — broader than planned (bans *all* direct MediaQuery size reads in `lib/`), `skip:` removed, green |
| 6 | ADR | **done** — `docs/adr/0025` (renumbered from a colliding 0024, §10 gap 3a); its two factual errors corrected 2026-09-07 |
| + | 14 of 15 fractional-height sheets → `getRHeight` | not planned for Phase 0; landed anyway |
| + | auth 480dp cap trap | fixed, and more simply than this plan proposed |

**Deviation 1 — conditional spacing floor.** Correct and now folded into §3.

**Deviation 2 — `isTablet` excludes `isDesktop`.** §3 defined `isTablet` as
`shortestSide >= 600 && shortestSide < 1024`; the implementation uses
`shortestSide >= 600 && !isDesktop` so the two predicates cannot disagree.
Consequence, asserted by test: **iPad 10.9 and iPad mini are `isTablet` in
portrait and `isDesktop` in landscape.** That is unchanged from production, so
Phase 0 introduced no regression — but the rotation flip this plan flagged in §1
as a pre-existing defect is **still present** and now belongs to Phase 7.

**Deviation 3 — measured 40dp fields.** `AppInput` and `AppDropdown` were
measured under `AppTheme.dark()` rather than using §3's estimated `vertical: 8`.
`AppInput`: `isDense: true` + `vertical: 9.5`, and 40×40 icon constraints for
*decorative* icons only — an `_isInteractive` check unwraps `Padding`/`SizedBox`/
`Container`/etc. to find a real `IconButton`/`GestureDetector`/`InkWell` and
preserves the 48dp tap target when it finds one. `AppDropdown`: `vertical: 12.5`,
replacing a hardcoded un-themed 14. Good work, and better than what was asked
for — but see the tap-target caveat in §10 gap 3, **fixed 2026-09-07 for
`AppInput` (conditionally) and for `AppDropdown` (unconditionally).**

**Emulator verification.** Landscape POS home renders with no `RenderFlex`
overflow. The grid shows ~1 clipped row. Note the plan text previously recorded
this as "confirming the ~108dp estimate" — with the delivered 40dp fields the
measured figure is **~98dp**; §4 now carries the corrected arithmetic.

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

#### Phase 1 — audited status (2026-09-08)

Branch `fix/responsive-auth-landscape` cut from `fix/responsive-short-viewport-seam`.
`flutter analyze` clean (0 errors, 0 warnings).
Comprehensive test suite `test/auth/auth_landscape_screens_test.dart` (40 tests) +
`test/auth/biometric_setup_screen_test.dart` (3 tests) + full `test/auth/` (83 tests) green.

| # | deliverable | status |
|---|---|---|
| 1 | `biometric_setup_screen.dart` — moved onto `AuthCenteredScroll` | **done** — verified failing before fix (`RenderFlex overflowed by 169 pixels`), passing across all viewports after |
| 2 | `success_dashboard_entry_screen.dart` — moved onto `AuthCenteredScroll` | **done** — centers content, auto-forward timer stored in `Timer` and cancelled on `dispose()` |
| 3 | `coming_soon_screen.dart` — moved onto `AuthCenteredScroll` | **done** — centers content, scrolls cleanly in short viewports |
| 4 | `login_screen.dart` — two columns under `isShortViewport` | **done** — avatar, greeting, email/dots left; `PinKeypad` right; vertical stack preserved in portrait |
| 5 | `create_pin_screen.dart` — two columns under `isShortViewport` | **done** — step label, title, subtitle, dots left; `PinKeypad` right; single-column in portrait |
| 6 | `who_is_working_screen.dart` — grid sizing under `constraints.maxWidth` | **done** — `LayoutBuilder` prevents 5-column blowout inside 480dp cap; 48dp floor enforced |
| 7 | `ceo_sign_up_screen.dart` — compact "Step X of Y" top bar | **done** — collapses back button and `_StepDots` into single row under `isShortViewport` with 48dp back button |
| 8 | Verify-only screens harness verification | **done** — all 7 screens pumped at `pixel7Landscape`, `androidCompactLandscape`, `pixel7Portrait` without overflow |
| + | `AppButton` 48dp floor | **done** — normal (54) and large (60) clamped to `max(kMinInteractiveDimension, ...)` preventing 37.8dp short-viewport compression |
| + | `AccessGrantedScreen` timer leak fix | **done** — `_contentTimer` cancelled on `dispose()` |

**Deviations and Notes:**
- **`AppButton` Tap Target Floor & Small Sizing:** Under short viewports (`isShortViewport == true`, scale factor 0.70), `AppButton`'s height `context.getRSize(54)` previously shrank to 37.8dp. Normal and large heights now clamp at `max(kMinInteractiveDimension, ...)` preserving the 48dp floor. In addition, `xsmall` (32dp) and `small` (40dp) use raw constants instead of riding `context.getRSize` so they do not compress to 22.4dp / 28dp in landscape viewports.
- **Landscape Typography Scaling:** New two-column landscape paths in `LoginScreen` and `CreatePinScreen` use `context.getRFontSize(...)` (11, 12, 13, 15, 18, 20) with tightened vertical padding so all portrait controls (including 'Enter your 6-digit PIN to continue') fit legibly beside the keypad on 360–412dp tall surfaces without vertical scrolling.
- **Bottom insets on auth screens:** Auth screens remain the documented exception to the `deviceBottomPadding` rule: screens like `LoginScreen` use `resizeToAvoidBottomInset: false` and `auth_form_kit.dart` uses `MediaQuery.of(context).viewInsets.bottom` to manage keyboard insets safely.
- **Nothing broken:** Every screen in §2 has been audited and verified via widget tests across `pixel7Landscape`, `androidCompactLandscape`, and `pixel7Portrait` without `RenderFlex` overflow or tap target compression.

### Phase 2 — POS `fix/responsive-pos-landscape`

- **First, settle §4.** Prototype both the collapsing header (A) and the side
  rail (B) in `pos_home_screen.dart` under `isShortViewport` and measure on a
  device. Neither is rejected; §4 carries the arithmetic and the risks. Scope
  Option A's sliver-inside-`AppRefreshWrapper` problem before committing to it.
  Whichever wins, correct the losing document — plan §4 or ADR 0025 §5, which
  currently disagree.
- Write the POS-home landscape overflow test that Phase 0 did not deliver
  (§10, gap 1) **before** restructuring the screen, so the rework has a net.
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

The 15 fractional-height sites are the correct *shape* — they shrink with the
viewport — but several wrap fixed-height headers that do not.

**14 of the 15 were migrated from `MediaQuery...size.height * f` to
`context.getRHeight(f)` in `b580f1a`. That is plumbing only — the values are
identical and none of these are fixed** (§10, gap 6). The line numbers below
still hold; read them as `getRHeight` calls now. Audit each at 412dp:

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

---

## 10. Audit of the Phase 0 implementation (2026-09-06)

Read against branch `fix/responsive-short-viewport-seam` at `b580f1a`.
`flutter analyze`: clean. `flutter test test/utils/`: 31 passed, 1 skipped.

**The scale model is sound and does what it claimed.** Every row of §3's table is
now an executable assertion. The two deviations the implementer made were both
improvements, and ADR 0025 is unusually good — it records measured field heights,
`textScaler` drift, and its own limitations rather than only its decisions.

The gaps below are what a second pair of eyes should act on.

### Gap 1 — the regression test that started all this was never written

Phase 0 item 4 required "a widget test that pumps POS home at `phoneLandscape`
and asserts no overflow… **it must fail on `main` before the fix and pass
after**". `test/helpers/viewports.dart` shipped (13 surfaces, more than the 5
asked for) and is good. But **no test pumps POS home, or any real screen, at any
viewport.** `grep -rn "PosHomeScreen" test/` returns nothing.

Everything asserted is arithmetic on the scale functions plus isolated `AppInput`
/ `AppDropdown` measurements. The 134px overflow that opened this work is
verified only by an emulator eyeball, and **nothing prevents it regressing.** ADR
0025's limitation 2 concedes exactly this.

This is the single most valuable thing to fix, and it is cheap now that the
harness exists. Do it before Phase 2 restructures the screen.

### Gap 2 — the ban test enforces nothing — RESOLVED 2026-09-07

`test/utils/media_query_size_ban_test.dart` previously carried a `skip:`.
The four remaining unmigrated call sites were migrated to `responsive.dart` accessors:
- `who_is_working_screen.dart:289` → `context.screenWidth`
- `cart_screen.dart:1494` → `context.screenWidth`
- `view_selector_sheet.dart:21` → `context.screenWidth`
- `activity_log_screen.dart:190` → `context.screenHeight - kToolbarHeight - 100`

The `skip:` was removed and the static ban test is active and passing cleanly across `lib/`.

### Gap 3 — 40dp tap targets fall below the accessibility floor — FIXED 2026-09-07

ADR 0025 limitation 3 flagged this and it deserved more prominence than a
footnote: in landscape, fields whose **whole surface** is the tap target
presented 40dp, under the 48dp Material / WCAG 2.5.5 minimum. `_isInteractive`
inspects the prefix/suffix icon, so it could not see that the *field itself* has
an `onTap`.

Two ADR errors, both corrected in `0025` §3:

1. **The ADR cited a path that does not exist** —
   `lib/features/inventory/screens/record_supplier_activity.dart`. The file is
   `lib/features/payments/widgets/record_supplier_activity.dart` (2 `readOnly:
   true` + `onTap` date pickers among 6 `AppInput`s, `:436` and `:759`).
2. **The ADR missed a second site** —
   `lib/features/expenses/screens/add_expense_screen.dart:572` (the plan
   previously said 573-577; the `readOnly:` line is 572, the block 570-581) has
   the same `readOnly: true` + `onTap: _pickDate` + decorative `suffixIcon`
   shape and is equally affected. `staff_sign_up_screen.dart` also matched a grep
   for `readOnly: true` but builds raw `TextField`s, so it is **not** affected —
   which is itself ADR limitation 4 in action.

**Those three are the complete affected set**, verified by sweeping all 30 files
that construct an `AppInput`. Every other `onTap:` near an `AppInput` belongs to
a `GestureDetector` suffix icon, which `_isInteractive` already catches.

**What shipped.** The plan proposed "treat `readOnly && onTap != null` as
interactive", which flips only *one* of the two levers that produce 40dp and so
would have left the widget's documented contract false. `AppInput` now derives
`wholeSurfaceTap = readOnly && onTap != null` and closes both:

- it suppresses the compact 40×40 icon constraints, so a decorative icon carries
  its default 48dp floor again — this alone covers all three real sites; and
- it sets `InputDecoration.constraints: minHeight 48` in a short viewport, which
  answers the case no icon inspection ever could: a whole-surface tap target with
  **no icon at all** (the pre-existing test already pins `hNone == 40.0`).

**Correction, verified by probe 2026-09-07: only the second lever is
load-bearing.** This section originally claimed both were, and that "removing
either turns a different assertion red". Disabling `InputDecoration.constraints`
does turn `responsive_test.dart:581` red — 40dp, the no-icon case. Disabling the
icon-constraint suppression leaves **all 32 tests green**, because `minHeight: 48`
already answers the icon case as well. Lever one is kept for coherence — a 48dp
field should not hold a 40dp icon box — but it protects nothing, and the next
reader must not delete lever two believing lever one covers it.

Regression-tested in
`test/utils/responsive_test.dart` (2 new tests): 48dp with and without an icon at
`pixel7Landscape`, 40dp preserved for a `readOnly` field with **no** `onTap` (so
the fix does not leak vertical chrome onto the ~8 display-only `readOnly` fields
in `inventory_screen` / `product_detail_screen`), and 53dp unchanged in portrait.

Cost: 8dp on exactly three fields. Both screens put them inside a `ListView`
(`record_supplier_activity.dart:409`/`:686`, `add_expense_screen.dart:451`), so
there is no overflow risk.

**`AppDropdown` had the same defect — FIXED 2026-09-07.** Its entire surface is
also a tap target (`app_dropdown.dart:232`, `GestureDetector(onTap:
_toggleDropdown)`), and `onChanged` is required and non-nullable, so there is no
disabled state and no configuration in which a compacted height is acceptable.

**It was worse than recorded here, and worse than Phase 0.** The existing test
pinned `AppDropdown` at **43dp in portrait** — a pre-existing breach of the 48dp
floor that predates this whole workstream. Phase 0 took it 43 → 40 in landscape.
So the fix is **unconditional**, not `isShortViewport`-gated like `AppInput`'s:
a `ConstrainedBox(minHeight: kMinInteractiveDimension)` outside the padded,
keyed `Container`, so the hit area, the painted surface and the size
`_openDropdown` measures for the overlay all agree — and a caller-supplied
`contentPadding` cannot breach it either (measured without the floor, a
zero-padding dropdown renders **15.0dp**).

Note this differs from `AppInput` deliberately: an `AppInput` may legitimately be
a *display* field, so its floor is conditional on `readOnly && onTap != null`.
An `AppDropdown` is always a control.

Tests: a dedicated floor test across `pixel7Landscape` / `pixel7Portrait` /
`androidCompactLandscape` plus the padding-override case, and two pre-existing
assertions updated from 43dp/40dp — **they were pinning the defect.** The
`textScaler 1.3` drift test also changes: `AppDropdown` no longer drifts at all
(44 → 48), because the floor now exceeds what scaled text produces. It is the one
field whose height is stable under text scaling.

**Cost, paid not dodged:** +8dp on POS's header band in landscape → chrome
154.2 → **162.2dp**, grid ~98 → **~90dp**; §4's arithmetic is updated. *(Correction
in §11.1: 162.2dp chrome / ~90dp grid still omitted the 25dp stacked label above
AppDropdown; with the 73dp labelled dropdown, chrome is 187.2dp and grid at rest
is ~64.8dp).* The POS-home test budget moved 160 → 165dp for the same reason. On
a 320dp-tall viewport (SE1 landscape) the grid falls to **~9.8dp** — it still does
not crash, and it is frankly unusable, which is Phase 2's case in one number.

### Gap 3a — the ADR shipped on a colliding number

Phase 0 item 6 said "next free number is **0024**; 0018 is absent from
`docs/adr/` — confirm before claiming a number". The confirmation was made
against the working tree, which cannot see other branches. Both numbers were
already taken:

| number | held by | branch |
|---|---|---|
| 0018 | `0018-push-notifications-fcm.md` | `feat/push-notifications-fcm` (unmerged) |
| 0024 | `0024-brand-deposit-rate-fans-out-to-products.md` | `fix/cart-reads-brand-deposit-live` (unmerged, `f73a102`, 2026-08-20) |

`0024-brand-deposit-rate-fans-out-to-products.md` is in **this branch's own
history** — `fix/responsive-short-viewport-seam` contains `f73a102` — and is
already cited by number in `CONTEXT.md:293`, `BUILD_LOG.md:19`, and
`CONTEXT/progress-tracker.md:57/98/111`. The responsive ADR was the newer claim
and moved: **`docs/adr/0025-two-curve-responsive-scale.md`**, with all 11
references in this plan updated.

**The durable rule:** an ADR number is free only if no *branch* holds it. Check
with `git branch -a` + `git ls-tree`, not `ls docs/adr/`.

Note this branch containing `f73a102` also means it is **not** cut from `main` —
worth checking for scope entanglement before the Phase 0 PR (see Housekeeping).

### Gap 4 — ADR 0025 and plan §4 give opposite Phase 2 instructions

ADR §5 concludes the **rail** is "required, not optional"; the plan text had
marked the rail **rejected**. §4 now presents both as open with the arithmetic.
One of the two documents must be corrected in the Phase 2 PR.

### Gap 5 — "full test suite passing cleanly" is not reproducible — RESOLVED 2026-09-07

ADR 0025 limitation 2 states the full suite of 1,888 tests passes cleanly. A full
`flutter test` run on this branch gives **1888 passed, ~130 skipped, 1 failed**:

    test/van_sales/van_returns_test.dart:
      sync › a return enqueues its event, the moved cursor and the ledger credit

**This is not a responsive regression.** The test passes in isolation
(`flutter test test/van_sales/van_returns_test.dart` → 26/26), touches no layout
code, and fails only in a full-suite run — order-dependent state pollution,
almost certainly pre-existing. Filed separately as **#228** (`test(van_sales): van_returns_test flakes intermittently in full-suite run`),
and ADR 0025 limitation 2 updated to cite the issue.

### Gap 6 — migrating the fractional sheets did not fix them

`b580f1a` moved 14 of 15 `MediaQuery...size.height * f` sites to
`context.getRHeight(f)`. That is a real plumbing win and it makes the ban test
reachable. **It changes no behaviour** — `getRHeight(f)` is `screenHeight * f`.

So `crate_return_modal.dart:453`, flagged in §6 as "almost certainly broken", is
now `context.getRHeight(0.25)` and still resolves to **103dp on a landscape
phone**. Phase 6 still owns every one of these.

**Confirmed in the field, 2026-09-06.** The receipt printer picker overflowed by
59px in landscape — the first of these to be reported by a user rather than
predicted here. All four call sites capped the sheet at `getRHeight(0.5)`:
a 206dp ceiling on a 915x412 phone, under content whose minimum is ~265dp.

The measurement that generalises: **a sheet's chrome does not compress with the
viewport.** The picker's refresh `IconButton` and its paper-size
`SegmentedButton` are both pinned at the 48dp tap-target floor, and Phase 0's
own fields bottom out at 40dp, so intrinsic sheet height is near-constant across
orientations while `screenHeight * f` collapses by 2.2x on rotation. A fraction
is the wrong shape of answer for a vertical cap.

Shipped 2026-09-07 (`responsive.dart`):

    double sheetMaxHeight(double fraction) => screenHeight *
        (isShortViewport && fraction < 0.90 ? 0.90 : fraction);

Plus the widget-level half, which is what actually makes a sheet safe: every
branch of `PrinterPicker` is now `Flexible` + `SingleChildScrollView`, so it
cannot overflow *whatever* cap it is handed. Regression-tested against the old
206dp ceiling in `test/widgets/printer_picker_overflow_test.dart` (14 tests,
4 viewports); reverting either half turns it red.

**Remaining offenders — 10 sites still on a bare fraction:**

| site | fraction | landscape (412dp) result |
|---|---|---|
| `crate_return_modal.dart:453` | 0.25 | 103dp |
| `crate_return_modal.dart:393` | 0.9 | 370dp — already above the floor |
| `manage_categories_sheet.dart:91` | 0.5 | 206dp |
| `stores_screen.dart:802` | 0.6 | 247dp |
| `cart_screen.dart:289` | 0.7 | 288dp |
| `cart_screen.dart:464` | 0.85 | 350dp |
| `customer_detail_screen.dart:1080` | 0.85 | 350dp |
| `orders_screen.dart:1032` | 0.85 | 350dp |
| `van_sale_receipt_sheet.dart:61` | 0.85 | 350dp |
| `update_product_sheet.dart:750` | 0.92 | 379dp — already above the floor |

Note the `height:` sites (not `maxHeight:`) are the dangerous ones — they pin an
exact height rather than a ceiling, so `sheetMaxHeight` is not a drop-in there;
each needs its content checked for a scrollable escape first. Phase 6 owns the
migration; the three at 0.5-0.6 are the ones most likely to be reported next.

### Housekeeping

`598c2fc` (sheet migration) was reverted by `02ec949` and re-applied verbatim as
`b580f1a`; the only difference between the two is one comment word
("Retained" → "Kept"). Net effect nil — worth squashing before the PR so the
history reads cleanly.

**Scope entanglement — RESOLVED 2026-09-07, by `main` moving.** The branch was
cut before `f73a102` (`fix/cart-reads-brand-deposit-live`, and its ADR 0024)
reached `main`, which is what produced the number collision in gap 3a. That
commit has since merged as **#223**, so `f73a102` is now an ancestor of
`origin/main` and no longer a foreign commit here. Verified 2026-09-07:
`git rev-list --count origin/main..HEAD` = **12**, all `*(responsive)` /
`feat(ui)` commits, and `HEAD..origin/main` = **0** — the branch is current with
`origin/main` and needs no rebase. Note the *local* `main` ref is stale (45
commits behind); measure against `origin/main`, not `main`.

### Recommended order from here

1. ~~Write the POS-home landscape overflow test (gap 1).~~ **DONE** —
   `test/pos/pos_home_screen_overflow_test.dart` (5 tests) +
   `test/helpers/pos_home_harness.dart`.
2. ~~Fix the two ADR errors and the `readOnly`+`onTap` tap target (gaps 3,
   2 of 2).~~ **DONE 2026-09-07** — plus a third ADR error found on the way: the
   number collision (gap 3a), so the ADR is now `0025`. `AppDropdown` carried the
   same defect — worse, in fact: 43dp in *portrait*, predating Phase 0 — and was
   fixed the same day with an unconditional floor. See gap 3.
3. ~~File the flaky van-returns test separately (gap 5); correct the ADR claim.~~ **DONE 2026-09-07** — filed as **#228**, ADR 0025 limitation 2 updated.
4. ~~Migrate the four remaining MediaQuery sites and un-`skip` the ban test (gap 2).~~ **DONE 2026-09-07** — all 4 sites migrated, `media_query_size_ban_test.dart` active and passing.
4b. ~~Move the three tightest sheet caps (0.5-0.6) onto `sheetMaxHeight` (gap 6)~~ — **DONE 2026-09-07** — `manage_categories_sheet.dart` (0.5), `stores_screen.dart` (0.6), and `crate_return_modal.dart` (0.25/0.9) migrated.
5. Squash the revert churn, then open the Phase 0 PR.
6. Phase 1 (auth) — unblocked and independent of the §4 decision.
7. Phase 2 — prototype both §4 options, measure, decide, reconcile the documents.

---

## 11. Audit against runtime measurement — PRD #239 (2026-09-18)

Audited against runtime measurements from PRD #239, the #241 discovery pass,
and implementation of the early slices (#240, #243, #245, #246, #256, #257,
#258, #259).

This section records the five places where real device and harness measurement
contradicted the assumptions, figures, and scope of this plan, so future work
does not re-derive the same findings or act on figures known to be invalid.

### 11.1 Correction 1 — The dropdown field measures 73dp with its label, not ~40dp / 48dp

The plan repeatedly recorded `AppDropdown` as ~40dp (or 48dp after Phase 0 gap 3
enforced the tap-target floor). Earlier work compacted the internal padding of
the field itself, but completely overlooked the label stacked above it.

In `lib/shared/widgets/app_dropdown.dart`, a labelled dropdown stacks a text
label above the control with unscaled vertical constants:
- Label text height (`titleSmall` / 13sp with line metrics ≈ 17dp)
- Gap between label and input (`context.getRSize(8)` ≈ 8dp)
- Control body (floored at `kMinInteractiveDimension` = 48dp)

Combined, a dropdown field measures **73dp** with its label.

**Impact on fixed chrome budgets:**
Wherever the plan calculated chrome heights using ~40dp or 48dp, the arithmetic
was wrong by at least 25dp per dropdown:
- **POS (`_buildHeader`):** 22.4dp padding + 73dp dropdown = **95.4dp** (not
  70.4dp). Chrome at rest is **187.2dp** (not 162.2dp), leaving only **~64.8dp**
  at rest on Pixel 7 landscape (915×412), and **negative space** on 800×360.
- **Inventory (filter row):** On an 800×360 landscape phone, the filter row
  alone measures **92.6dp** (two dropdowns side by side), which is taller than
  the entire 75.6dp vertical space given to the tab content area. There is
  negative space (−17.0dp). No amount of padding tightening can fix this while
  the stacked label remains.

The plan's arithmetic in §1, §3, and §4 has been annotated and corrected in place
to reflect the real 73dp measurement.

### 11.2 Correction 2 — Scroll-away headers charge the body in a tabbed scroller

The mechanism by which a tabbed scroller charges its body for headers that scroll
away was completely absent from this plan, despite being the primary structural
root cause on five major screens (Inventory, Orders, Customer Detail, Supplier
Detail, Driver Profile).

**The mechanism:**
Under Flutter's `NestedScrollView`, the inner tab body is rendered by
`RenderSliverFillRemainingWithScrollable`. This render object sizes the body box
at rest to:
```
bodyHeight = viewportMainAxisExtent - precedingScrollExtent
```
Because the scroll-away header slivers precede the tab body in the outer sliver
tree, their *entire* height (`precedingScrollExtent`) is subtracted from the
body viewport *at rest*. The body is not sized to the viewport minus the pinned
tab bar; it is sized minus **all** header slivers. The body area only expands
back once the user scrolls the header offstage.

**Consequences on-screen:**
- On **Inventory** (summary cards + store banner + tab bar taking ~264dp), the
  body at 800×360 was left with **95.6dp**. Subtracting the 92.6dp filter band
  left the product list with **exactly 0.0dp of height**.
- On **Expenses** (#256), the list was squeezed to **1.8dp of 1,137dp**.
- On **Customer Detail** (#245) and **Supplier Detail** (#246), tall profile
  headers and credit cards caused 27px and 51px bottom overflows and squeezed
  ledger lists to under 55dp.

**The architectural resolution:**
The plan assumed call-site padding tweaks could fit these screens. Instead,
`TabbedSliverScaffold` (ADR 0027, #243) was built to replace hand-rolled
`NestedScrollView`s. It pairs `SliverOverlapAbsorber` and `SliverOverlapInjector`
and turns each tab into an independent `CustomScrollView` whose filter bands are
slivers alongside the list items, rather than fixed box bands over an
`Expanded`.

### 11.3 Correction 3 — Scope is not landscape-only (small portrait phones and the gating trap)

The plan was titled and framed exclusively around short viewports (landscape
phones) and tablets. This scope definition was fundamentally too narrow.

**Small portrait phones fail identically:**
A budget phone in portrait — specifically the iPhone SE 1st-generation baseline
(320×568 portrait) — suffers the exact same content starvation and layout
overflows as a landscape phone:
- Inventory overflowed by 19px in portrait with only 163.5dp left for content.
- Expenses overflowed 135px and 181px horizontally on narrow cards at 320dp.
- Supplier Detail overflowed 51px on the right of its balance card.

**The gating trap:**
At 320×568 portrait, `screenHeight` is **568.0dp**. This is comfortably *above*
the plan's `isShortViewport` threshold (`screenHeight < 500.0`).
Consequently:
- Any responsive fix gated on `context.isShortViewport` evaluates to `false` on a
  320×568 portrait phone.
- Any fix gated on `orientation == Orientation.landscape` likewise never runs in
  portrait.

Gated fixes leave small portrait phones broken.

**The correction:**
Responsive structural fixes must be **unconditional** — screens must be
structured as a single scrollable surface (`CustomScrollView` or
`TabbedSliverScaffold`) across all viewports, without orientation branches or
`isShortViewport` layout gates. The scope statement at the head of this plan has
been amended accordingly.

### 11.4 Correction 4 — Presumed screen inventory in later phases is unverified and superseded

The plan's later phases (Phase 4, Phase 5, Phase 8) presumed that nearly every
screen in the app would need individual responsive rework. That assumption was
speculative.

**The runtime discovery pass (#241):**
Issue #241 implemented a runtime overflow detection hook (`OverflowRouteReporter`)
and executed a discovery sweep across ~70 screens in empty and populated states at
800×360, paired with an exhaustive device emulator walk by the product owner.

**The findings:**
Most screens in the app are completely unaffected by rotation or compact viewports.
The defect clustered strictly on screens sharing two structural anti-patterns:
1. Fixed box headers stacked above an `Expanded` body inside a non-scrolling
   `Column` (POS #259, Expenses #256, Cart #255).
2. Tabbed bodies with fixed box filter strips inside a `NestedScrollView`
   (Inventory #243, Customer Detail #245, Supplier Detail #246).

The exhaustive lists in Phase 4, Phase 5, and Phase 8 are superseded by the
verified defect list in PRD #239. Effort is directed to measured defects rather
than speculative screen-by-screen churn.

### 11.5 Correction 5 — "Write the regression test" superseded by the two-assertion invariant

The plan's outstanding item in §6 (Phase 0 item 4) and §10 (Gap 1) called for
writing a regression test asserting "no overflow" on POS home.

**Why "no overflow" is insufficient:**
Measurement on real devices and in the test harness revealed that on populated
screens, **content starvation is silent**:
- When the catalogue has products, the list or grid collapses to 0.0dp, renders
  nothing, and throws **no exception at all** (`tester.takeException()` returns
  `null`).
- The red `RenderFlex` overflow band appears **only when the catalogue is
  empty** (because the empty state placeholder has a fixed intrinsic height
  that refuses to compress to zero).

An overflow-only assertion passes a screen whose content has been crushed to zero
height.

**The two-assertion invariant:**
Responsive viewport tests that validate visible content rows or cards enforce the
two-assertion invariant codified in `test/helpers/screen_harness.dart`:
1. `expectNoOverflow`: no `RenderFlex` overflow at paint time.
2. `expectContentRowVisible`: at least one complete, hit-testable content row (or
   product card, order row, credit ledger entry) is visible in the viewport.

Empty-state tests in the customer, POS, expenses, and inventory suites use targeted
empty-state assertions rather than expecting content rows, while the report-card
badge test uses its badge-specific assertion instead of `expectContentRowVisible`.

### 11.6 Blocking contradiction: Sales screen landscape treatment (Plan §4 vs ADR 0025 §5)

Plan §4 and ADR 0025 §5 gave diametrically opposite instructions for the
landscape treatment of the sales screen (POS):
- **ADR 0025 §5** concluded that "Phase 2's structural re-flow (**rail layout**)
  is required, not optional", citing `textScaler 1.3` drift.
- **Plan §4** marked the side rail rejected on the grounds that a collapsing
  header keeps controls reachable and saves horizontal width.

This contradiction remains an active, unresolved design blocker that halts work on the
sales screen until resolved through prototyping and measurement on real devices.

### 11.7 Harness gaps found by #255 — the bottom bar is 24dp short, and a clipped row still counts

Found while reproducing the empty-Cart band (#255), which the #241 sweep had
called unaffected. The harness still gets the verdict wrong in two ways:

1. **The bottom bar stand-in omits the bottom inset.** `pumpScreen` renders the
   bar as a bare `SizedBox(height: 56)`, but the Scaffold still strips the 24dp
   bottom inset (`kRealisticPhoneInsets`) from the body. MainLayout's real bar
   is Material's `BottomNavigationBar`, which is `56 + viewPadding.bottom` tall.
   So every harness screen is handed 24dp the phone does not have. Measured on
   the empty Cart at 800x360: 14.6dp spare with the 56dp bar, a 9.4px overflow
   with the real 80dp one. Test fonts draw lines shorter than a device font,
   which covers the rest of the 15px seen on the emulator.
   Correcting the default turns four existing tests red: Inventory's empty
   first-run state at 800x360, POS grid density at 568x320, and Supplier
   Detail's tab scroll-retention and swipe tests. Each belongs to its own slice,
   so #255 left the default alone and passes the real height
   (`kBottomNavBodyHeight + kRealisticPhoneInsets.bottom`) from its own suite.
2. **`visibleRowCount` measures a row against the whole screen, not the scroll
   view that clips it.** A row whose centre is inside the scroll view but whose
   lower part is clipped behind the bottom bar still counts as "complete". At
   800x360 it counted a partly clipped Recall button and a partly clipped cart
   line at rest. Suites that care assert the target's rect sits wholly inside
   its scroll surface after scrolling to it, as Supplier Detail (#246) and Cart
   (#255) do.

Until both are fixed in `test/helpers/screen_harness.dart`, a green harness run
is weaker evidence than it looks. Do not treat a sweep's "unaffected" as a
device verdict.
