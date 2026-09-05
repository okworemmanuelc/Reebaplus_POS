# Two-curve responsive scale model and short-viewport constraints

**Status:** accepted (2026-09-06)

Phase 0 of the responsive overhaul (`docs/design/responsive-layout-plan.md`). Replaces the
single screen-width responsive scaling curve in `lib/core/utils/responsive.dart` with a
height-aware two-curve model, establishes orientation-independent breakpoints, and enforces
compact constraints on shared input widgets in height-constrained viewports.

## Context and Defect

`lib/core/utils/responsive.dart` previously scaled the entire UI (`rSize`, `rFontSize`,
`getRSize`, `getRFontSize`) off screen **width** only:
`(screenWidth / 375.0).clamp(0.8, 1.5)`.

On a standard device (e.g. Pixel 7, 412×915):
- In portrait (width 412): scale was **1.10**.
- In landscape (width 915, height 412): scale jumped to **1.50** (clamped ceiling).

Rotating a phone grew the UI by **~37%** (`1.10 -> 1.50`) at the exact moment vertical
room dropped by **2.2×** (`915dp -> 412dp`), creating a ~3× oversubscription of vertical
space. On POS home, fixed top chrome expanded to ~259dp, completely collapsing the product
grid's `Expanded` container and throwing a 134px layout overflow.

## Decision

### 1. Two-Curve Scale Model

Scale is driven by the orientation-independent form factor (`shortestSide / 375.0`) gated
by vertical comfort:
```dart
double _rawScale(Size size) {
  final formFactor = size.shortestSide / 375.0;
  final heightFactor = (size.height / 700.0).clamp(0.0, 1.0);
  return formFactor * heightFactor;
}
```
Above 700dp height, vertical space is comfortable and form factor governs alone. Below
700dp, scale compresses proportionally.

The single scale curve is split into two specialized curves:
- **Spacing curve (`_calcSpacingScale`):** clamped between `spacingFloor` and `1.50`.
  Structural elements (padding, margins, icon boxes, gaps) can compress aggressively in
  tight viewports down to `0.70` without losing functionality.
- **Typography curve (`_calcFontScale`):** clamped between `0.90` and `1.35`.
  Text below 0.90 scale becomes unreadable on high-density mobile screens. The 1.35 ceiling
  prevents oversized body copy on tablets.

### 2. Conditional Spacing Floor and Ratio-Invariant Deviation

**Deviation from Section 3 of the Plan:**
Section 3 of `responsive-layout-plan.md` originally specified an unconditional 0.70 spacing
floor across all viewports. During implementation, this was changed to a **conditional
floor: 0.85 in comfortable viewports, and 0.70 only when `isShortViewport` (`height < 500dp`).**

**Reasoning:**
Spacing and typography previously shared a single identical curve, maintaining an exact
`1.0` ratio between box size and text size by construction. Splitting into two independent
curves breaks that invariant. Allowing a 0.70 spacing floor on a comfortable-height device
(such as an iPhone SE1 portrait, 320×568) produces 18% smaller boxes containing 5.5% larger
text — a **28% ratio swing** across ~3,300 unreviewed call sites. Holding the spacing floor
at 0.85 when height is comfortable keeps the ratio swing under **6%**, avoiding text truncation
in fixed containers. Only truly short viewports (`height < 500dp`) drop to 0.70 to fit chrome.

### 3. Breakpoints & Tablet Exclusivity

- `isPhone`: `screenShortestSide < 600` (a phone in landscape is still a phone).
- `isDesktop`: `screenWidth >= 1024 && !isShortViewport` (side-rail decision).
- `isTablet`: `screenShortestSide >= 600 && !isDesktop`.

`isTablet` explicitly excludes `isDesktop`. On landscape tablets (e.g. iPad 10.9" 1180×820
and iPad Mini 1133×744), `screenWidth >= 1024` evaluates `isDesktop` to `true`, and `isTablet`
evaluates to `false`. Their classification is **UNCHANGED from today**; harmonizing iPad
landscape rail behavior is deliberately deferred to Phase 7, not overlooked.

### 4. Field Heights Measured, Not Estimated

`AppInput` and `AppDropdown` form a fixed vertical floor under chrome in short viewports.
Measurements under `AppTheme.dark()` at `pixel7Landscape` (915×412):

- **`AppInput`:**
  - In comfortable portrait: **53.0dp**.
  - In short viewport without icons: **40.0dp** (achieved via `isDense: true` and
    fallback `contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 9.5)`).
  - With a decorative icon before constraints: **48.0dp** (Flutter's default
    `prefixIconConstraints` of 48×48 set an immovable floor).
  - With compact constraints (`40×40`) for decorative icons: **40.0dp**.
  - With interactive icons (e.g. clear button / `GestureDetector` / `TextButton`):
    the interactive icon wins, preserving the **48.0dp** minimum tap target.
- **`AppDropdown`:**
  - In comfortable portrait: **43.0dp**.
  - In short viewport: **40.0dp** (achieved via fallback `vertical: 12.5`).
  - *Note:* `AppDropdown` never read the theme; it had a hardcoded `vertical: 14` padding.
    It now falls through from caller padding to compact padding when short, then hardcoded 14.

### 5. Accessibility Drift Under `textScaler 1.3`

When rendered under `textScaler: TextScaler.linear(1.3)` at `pixel7Landscape`:
- `AppInput` drifts from **40.0dp to 46.0dp** (+6.0dp).
- `AppDropdown` drifts from **40.0dp to 44.0dp** (+4.0dp).
- Neither overflows (`tester.takeException()` is null).

This drift gives back most of the 13dp compacting savings under larger system accessibility
type sizes. It serves as empirical evidence that **compacting field padding is only a stopgap;
Phase 2's structural re-flow (rail layout) is required, not optional.**

## Known Edges and Limitations

1. **Hard Cliff at 500dp Height:**
   `isShortViewport` is a binary threshold (`height < 500.0`). While stable for physical
   hardware devices, desktop browser window resizing or Android split-screen modes can
   trigger a abrupt 48dp/40dp step at 499dp vs 500dp.
2. **Logic vs. Layout Verification:**
   The full test suite (1,888 tests) passing cleanly proves that the business logic, Drift
   DAOs, Riverpod state, and calculation layers are regression-free. It **does NOT prove
   screen layout** — this codebase has no rendered widget snapshot or golden test coverage
   for complete screens. Layout verification relies on Phase 0's dedicated viewport harness
   and device emulator inspections.
