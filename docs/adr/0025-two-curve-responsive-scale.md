# Two-curve responsive scale model and short-viewport constraints

**Status:** accepted (2026-09-06); limitation 3 resolved 2026-09-07

**Renumbered 0024 → 0025 on 2026-09-07.** This ADR originally claimed 0024, which
was already taken by `0024-brand-deposit-rate-fans-out-to-products.md` (commit
`f73a102`, 2026-08-20) — a decision already cited by number in `CONTEXT.md`,
`BUILD_LOG.md`, and `CONTEXT/progress-tracker.md`. Neither ADR had reached `main`,
so the newer one moved. `0018-push-notifications-fcm.md` also exists on an
unmerged branch, so 0018 is **not** free either — check every branch, not just
`main`, before claiming a number.

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
a structural re-flow is required, not optional.**

> **Corrected 2026-09-17 (issue #259, PRD #239).** This paragraph originally read
> "Phase 2's structural re-flow (**rail layout**) is required, not optional",
> naming the rail as the form the re-flow had to take. That went further than the
> evidence: the `textScaler` drift above shows a re-flow is needed, not which
> re-flow. It also contradicted `docs/design/responsive-layout-plan.md` §4, which
> left the choice open, and the two documents could not both be right.
>
> **POS shipped the collapsing header instead** — the top bar and price-tier row
> scroll away, the search bar and category chips freeze at the top — decided on
> the #241 discovery findings, where the populated product grid measured **0.0dp
> of 463dp** at 800x360 rather than the ~90dp this ADR's arithmetic assumed.
>
> The drift finding is unchanged and was the strongest argument *against* the
> choice that was made: frozen chrome grows with the system font size, where a
> rail's grid height would not. That cost was accepted knowingly and is pinned by
> `test/pos/pos_home_viewport_test.dart`, which requires a complete product card
> to stay reachable sideways at the app's maximum scale — the 1.3 clamp in
> `main.dart`, which is also the ceiling measured above. The scale model in this
> ADR is untouched.

## Known Edges and Limitations

1. **Hard Cliff at 500dp Height:**
   `isShortViewport` is a binary threshold (`height < 500.0`). While stable for physical
   hardware devices, desktop browser window resizing or Android split-screen modes can
   trigger a abrupt 48dp/40dp step at 499dp vs 500dp.
2. **Logic vs. Layout Verification:**
   The full test suite (1,911 tests passing cleanly; 1 pre-existing order-dependent
   flake in `test/van_sales/van_returns_test.dart` filed separately as #228) proves
   that the business logic, Drift DAOs, Riverpod state, and calculation layers are
   regression-free. It **does NOT prove screen layout** — this codebase has no rendered
   widget snapshot or golden test coverage for complete screens. Layout verification
   relies on Phase 0's dedicated viewport harness and device emulator inspections.
3. **Whole-Surface Tap Targets Reduced to 40dp in Landscape — RESOLVED 2026-09-07:**
   Fields whose entire surface is the tap target — `AppInput` with `readOnly: true` **and**
   an `onTap` — presented a 40dp tap target in landscape, under the 48dp Material /
   WCAG 2.5.5 minimum. `_isInteractive` inspects the prefix/suffix icon, so it could not
   see that the *field itself* was the control.

   **This entry originally carried two factual errors, corrected here.**
   - It cited `lib/features/inventory/screens/record_supplier_activity.dart`. **That file
     does not exist.** The real file is
     `lib/features/payments/widgets/record_supplier_activity.dart` (Date Received `:436`,
     Date Paid `:759`).
   - It missed a second affected site:
     `lib/features/expenses/screens/add_expense_screen.dart:572` (Date), the same
     `readOnly: true` + `onTap: _pickDate` + decorative calendar `suffixIcon` shape.

   Those three call sites are the **complete** affected set — verified by sweeping all 30
   files that construct an `AppInput`. Every other `onTap:` near an `AppInput` belongs to a
   `GestureDetector` suffix icon, which `_isInteractive` already catches.
   `staff_sign_up_screen.dart` matches a `readOnly` grep but builds a raw `TextField`, so it
   is unaffected — limitation 4 in action.

   **The fix.** `AppInput` derives `wholeSurfaceTap = readOnly && onTap != null` and closes
   both of the levers that produce 40dp:
   - it suppresses the compact 40×40 icon constraints, so a decorative icon carries its
     default 48dp floor again (this alone covers all three real sites); and
   - it sets `InputDecoration.constraints: minHeight 48` in a short viewport, which answers
     the case no icon inspection ever could — a whole-surface tap target with no icon at all.

   **Only the second lever is load-bearing.** Verified by probe, 2026-09-07: disabling
   `InputDecoration.constraints` turns `responsive_test.dart:581` red (40dp, no-icon case),
   but disabling the icon-constraint suppression leaves all 32 tests green — `minHeight: 48`
   already carries the icon case too. The first lever is kept as coherence, not protection:
   a 48dp field should not hold a 40dp icon box. It is **not** a second line of defence, and
   a future reader must not treat it as one. Regression-tested at `pixel7Landscape` in
   `test/utils/responsive_test.dart`. A `readOnly` field **without** an `onTap` is a display
   field, not a control, and still compacts to 40dp — the fix costs 8dp on exactly three
   fields, both of whose screens scroll (`ListView`).

   **`AppDropdown` — also fixed, 2026-09-07, and unconditionally.** Its entire surface is a
   tap target (`app_dropdown.dart:232`) and `onChanged` is required and non-nullable, so it
   has no disabled state and no legitimate compacted form. It measured **43dp in portrait**
   before this workstream began — a breach that predates Phase 0 — and Phase 0 took it to
   40dp in landscape. It now carries a `ConstrainedBox(minHeight: kMinInteractiveDimension)`
   outside the padded, keyed `Container`, at **every** viewport, which a caller-supplied
   `contentPadding` cannot override.

   The asymmetry with `AppInput` is deliberate: an `AppInput` can be a display field, so its
   floor is conditional; an `AppDropdown` is always a control.

   Two pre-existing assertions in `responsive_test.dart` were updated from 43dp and 40dp —
   **they were pinning the defect** — and `AppDropdown` now shows zero drift under
   `textScaler 1.3` (was 44dp) because the floor exceeds what scaled text produces.

   **The cost is real and was paid, not dodged.** POS's landscape chrome moved
   154.2 → 162.2dp and its grid ~98 → ~90dp; the screen's test budget moved 160 → 165dp.
   At 320dp height (SE1 landscape) the grid falls to ~9.8dp — no crash, but unusable, which
   is the strongest single argument for §5's conclusion that Phase 2's re-flow is required
   rather than optional.
4. **Auth Screens Bypass AppInput:**
   The auth and onboarding screens construct raw `TextField` widgets styled with
   `AppDecorations.authInputDecoration` rather than using `AppInput`. Consequently, Phase 0's
   compact padding and icon constraints do not reach them. Phase 1 (auth landscape adaptation)
   must not assume `AppDecorations` or raw `TextField`s are compacted by Phase 0.

