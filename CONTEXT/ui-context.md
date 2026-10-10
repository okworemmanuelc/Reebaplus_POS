# UI Context — Reebaplus POS Design System

Source of truth for design tokens, components, and layout patterns. Every
colour, radius, spacing, and gradient used in the app maps to a token below.
**Never hardcode a hex value, radius, pixel size, or raw palette constant —
reference the access path.** If a decision is not covered here, ask before
inventing one.

---

## Theme system (read this first)

The app ships **5 selectable design systems** via `ThemeController`
(`lib/core/theme/theme_notifier.dart`): **Blue Classic (default)**, Amber,
Purple Violet, Green Forest, Black & White — each with a light and dark
variant. Blue Classic carries the designer's exact colour sheet (PRD #346,
first comment; #349).

Widget code must **never** reference a raw palette constant (`blueMain`,
`amberPrimary`, `alBg`, `fixedDanger`, etc.) directly. Always resolve through
one of these access paths:

| What you need | Access path | Follows the scheme? |
|---|---|---|
| Background, surface, primary, secondary, error, text, on-primary | `Theme.of(context).colorScheme.*` | Yes |
| Scaffold bg, divider, card colour | `Theme.of(context).scaffoldBackgroundColor` / `.dividerColor` / `.cardColor` | Yes |
| Success, warning, info (legacy per-scheme status) | `Theme.of(context).extension<AppSemanticColors>()!.success` / `.warning` / `.info` | Yes |
| Primary tint, glow, link hover, background fade, card fill, muted-on-Surface-2, shadows, scrim | `Theme.of(context).extension<AppSchemeColors>()!.*` (`lib/core/theme/scheme_colors.dart`) | Yes |
| Tags, status pills, stock badges, pale icon tiles, Credit/Debt boxes, product-tile tints | `Theme.of(context).extension<AppFixedColors>()!.*` (`lib/core/theme/fixed_colors.dart`) | **No — identical in all 5 schemes** |

This file documents the **Blue Classic** palette as the concrete hex
reference. The scheme-following access paths resolve to different hex values
under the other four themes — the access path is the contract, not the hex
value. `AppFixedColors` is the exception: its values are the same in every
scheme (only light vs dark differ).

**Which one for a tint?** (PRD #346 decision 6) Tags and tinted icon tiles use
`AppFixedColors` — e.g. a pale icon tile on a Home stat card or settings row is
`infoTint` with an `info` icon in every scheme. The scheme still drives primary
buttons, active nav (a filled primary icon + primary label; since the PRD
#346 addendum the rail has no pale pill, #352), prices, the screen-title icon
tile (a solid primary gradient, not a tint) and focus outlines.

---

## Colour palette (Blue Classic — default)

"System" values live in `lib/core/theme/colors.dart`; "project" values were
added by #349 from the designer colour sheet.

### Surfaces and text

| Semantic token | Access path | Light | Dark | Usage |
|---|---|---|---|---|
| Background | `scaffoldBackgroundColor` | `#F8FAFC` | `#090D14` | Screen background (top of the fade) |
| Background fade | `AppSchemeColors.backgroundFade` | `#EEF3FD` | `#0C1526` | Bottom stop of the screen background fade |
| Surface | `colorScheme.surface` | `#FFFFFF` | `#111827` | Top bars, cart, menu, bottom bar |
| Surface 2 | `inputDecorationTheme.fillColor` / `chipTheme.backgroundColor` (dark: also `cardColor`) | `#F1F5F9` | `#1C2438` | Inputs, grey buttons, steppers |
| Card fill | `AppSchemeColors.cardFill` | `#FFFFFF` @ 0.90 | `#111827` @ 0.72 | Slightly see-through card fill |
| Border / Divider | `dividerColor` | `#E2E8F0` | `#FFFFFF` @ 0.12 | Borders and dividers |
| Text primary | `colorScheme.onSurface` | `#0F172A` | `#F8FAFC` | Main text |
| Text secondary | `textTheme.bodySmall.color` / `iconTheme.color` | `#64748B` | `#A0AEC0` | Muted text |
| Muted on Surface 2 | `AppSchemeColors.mutedOnSurface2` | `#475569` | `#A0AEC0` | Muted text placed on Surface 2 |

### Brand

| Semantic token | Access path | Light | Dark | Usage |
|---|---|---|---|---|
| Primary | `colorScheme.primary` | `#2563EB` | `#3B82F6` | Prices, totals, subtitles, active items, focus border |
| Secondary | `colorScheme.secondary` | `#60A5FA` | `#60A5FA` | Gradient start on primary buttons/FAB |
| On primary | `colorScheme.onPrimary` | `#FFFFFF` | `#FFFFFF` | Text and icons on the blue gradient (dark was black before #349 — deliberate change) |
| Primary tint | `AppSchemeColors.primaryTint` | `#2563EB` @ 0.12 | `#3B82F6` @ 0.16 | Pale active fills (not the screen-title icon tile, which is the solid primary gradient; the rail's selected item has no pill since #352) |
| Primary glow | `AppSchemeColors.primaryGlow` | `#2563EB` @ 0.30 | `#3B82F6` @ 0.30 | Shadow under primary buttons |
| Link hover | `AppSchemeColors.linkHover` | `#1D4ED8` | `#60A5FA` | Link hover / pressed |
| Error | `colorScheme.error` | `#EF4444` | `#EF4444` | Form errors (per scheme; Amber/Purple/Green/B&W use `#FF3B30`) |
| Success / warning / info | `AppSemanticColors.success` / `.warning` / `.info` | `#30D158` / `#FFB020` / `#3B82F6` | same | Legacy per-scheme status colours; new tags and tiles use `AppFixedColors` |

### Shadows and overlays

| Semantic token | Access path | Light | Dark |
|---|---|---|---|
| Card shadow | `AppSchemeColors.cardShadow` | `#000000` @ 0.05 | `#000000` @ 0.25 |
| Dim behind open menu / cart | `AppSchemeColors.scrim` | `#000000` @ 0.35 | `#000000` @ 0.55 |
| Slide-in panel shadow | `AppSchemeColors.panelShadow` | `#0F172A` @ 0.12 | `#000000` @ 0.50 |
| Top bar shadow | `AppSchemeColors.topBarShadow` | `#0F172A` @ 0.05 | `#000000` @ 0.30 |

The sheet's card shadow geometry (0 0 10px) is not a colour token; it lands
with the flat card style (#351).

### The other four schemes

Amber, Purple Violet, Green Forest and Black & White keep their own system
hexes in `colors.dart`. Their `AppSchemeColors` are built by the same
`AppSchemeColors.derive` as Blue, so the alpha values are identical:

| Token | Rule (every scheme) |
|---|---|
| `primaryTint` | own `colorScheme.primary` @ 0.12 light / 0.16 dark |
| `primaryGlow` | own primary @ 0.30 |
| `cardFill` | own `colorScheme.surface` @ 0.90 light / 0.72 dark |
| `cardShadow`, `scrim` | black at Blue's alphas |
| `panelShadow`, `topBarShadow` | light: own text primary @ 0.12 / 0.05; dark: black @ 0.50 / 0.30 |
| `backgroundFade` | own primary @ 5% (light) / 7% (dark) laid over own background (`AppSchemeColors.fadeFrom`); Blue uses the sheet's exact hexes |
| `linkHover` | one step darker than the light primary, one step lighter than the dark primary (Amber `#B45309` / `#FBBF24`, Purple `#6D28D9` / `#A78BFA`, Green `#166534` / `#4ADE80`, B&W `#000000` / `#FFFFFF`) |
| `mutedOnSurface2` | light: the scheme's 600-step grey (Amber `#4B5563`, Purple/Green `#4B5563`, B&W `#52525B`); dark: the scheme's muted text |

On-primary stays as before outside Blue: B&W dark is black on the near-white
primary; Amber/Purple/Green dark use Material's default (black).

---

## Fixed colour set (`AppFixedColors`)

Identical in **all 5 design systems** (PRD #346 decision 6). One instance per
brightness — `AppFixedColors.light` / `AppFixedColors.dark` — is installed in
every `ThemeData`. Use it for PRO/CEO pills, status pills (Positive / None /
Live / Clear), stock badges, the pale icon tiles (Home stat cards, settings
rows), Credit/Debt boxes and product-tile tints. Access:
`Theme.of(context).extension<AppFixedColors>()!.<token>`.

| Token | Light | Dark | Usage |
|---|---|---|---|
| `danger` | `#EF4444` | `#EF4444` | Clear, Log Out, remove, count badges |
| `onSolid` | `#FFFFFF` | `#FFFFFF` | Text on a solid fixed pill (PRO), count-badge text (#352) |
| `dangerTint` | `#EF4444` @ 0.10 | `#EF4444` @ 0.14 | Pale danger fill |
| `dangerOutline` | `#EF4444` @ 0.35 | `#EF4444` @ 0.45 | Clear button border |
| `warning` | `#FFB020` | `#FFB020` | Crates, pending, low stock |
| `warningTint` | `#FFB020` @ 0.15 | `#FFB020` @ 0.14 | Pale warning fill |
| `warningOutline` | `#FFB020` @ 0.55 | `#FFB020` @ 0.45 | Warning border |
| `green` | `#43A047` | `#30D158` | Green text and icons: balance, discount, profit (darker on white for readability; `#43A047` = `Colors.green.shade600`, the AppButton success colour) |
| `greenDot` | `#30D158` | `#30D158` | Stock is fine |
| `greenTint` | `#30D158` @ 0.15 | `#30D158` @ 0.14 | Pale green fill |
| `info` | `#3B82F6` | `#3B82F6` | Water icons, Roles icon |
| `infoTint` | `#3B82F6` @ 0.12 | `#3B82F6` @ 0.16 | Pale info fill; the fixed icon-tile fill |
| `neutralIcon` | `#0B1220` | `#E2E8F0` | Stout and neutral icon |
| `neutralTile` | `#0B1220` @ 0.08 | `#FFFFFF` @ 0.08 | Stout and neutral tile |
| `maltTile` | `#60A5FA` @ 0.20 | `#60A5FA` @ 0.16 | Malt tile |
| `purple` | `#7C3AED` | `#A78BFA` | Home's Take Stock quick action (#362; not on the designer's sheet, proposed in #362, owner may swap) |
| `purpleTint` | `#F3EEFF` | `#241B3D` | Pale purple tile behind `purple` (opaque, unlike the alpha tints) |

The sheet defines outlines for danger and warning only; there is no green or
info outline token. Base hexes are the `fixed*` constants at the bottom of
`colors.dart` — never reference them from widgets.

---

## Gradients

Never construct a `LinearGradient` inline. Use the helpers and access paths
below.

| Gradient | Stops | Direction | Access |
|---|---|---|---|
| Primary surface gradient | `colorScheme.primary.withValues(alpha:0.8)` → `colorScheme.primary` | top-left → bottom-right | `AppDecorations.primaryGradient(context)` |
| Primary button / FAB | `colorScheme.secondary` → `colorScheme.primary` | top-left → bottom-right | Built into `AppButton` primary variant and `AppFAB` |
| Success button | `Color.lerp(Colors.green.shade600, Colors.white, 0.1)` → `Colors.green.shade600` (`#43A047`, same as `AppFixedColors.light.green`) | top-left → bottom-right | Built into `AppButton` success variant |
| Disabled button | `Colors.grey.shade400` → `Colors.grey.shade500` | top-left → bottom-right | Built into `AppButton` / `AppFAB` disabled state |
| Amber glow line | `transparent` → `colorScheme.primary` → `transparent` | horizontal, 2px height | `AmberGlowLine` widget |

---

## Typography

Fonts are bundled in `assets/google_fonts/` and registered in `pubspec.yaml`
as two real font families — `DMSans` (400, 500, 600, 700, 800) and
`RobotoMono` (400). Nothing is fetched from the network
(`GoogleFonts.config.allowRuntimeFetching = false` in `main.dart` stays as a
guard for any future `google_fonts` call). Because each weight is its own
file in one family, a style that asks for w700 gets the Bold file, never a
synthesised bold of Regular. The family names are the constants
`appFontFamily` / `appMonoFontFamily` in `lib/core/theme/app_theme.dart`;
widgets never write the family name themselves.

| File | Family / weight | Source |
|---|---|---|
| `DMSans-Regular.ttf` | DM Sans 400 | googlefonts/dm-fonts @ `4412393b` (v4.004) |
| `DMSans-Medium.ttf` | DM Sans 500 | same |
| `DMSans-SemiBold.ttf` | DM Sans 600 | same |
| `DMSans-Bold.ttf` | DM Sans 700 | same |
| `DMSans-ExtraBold.ttf` | DM Sans 800 | same (added #349) |
| `RobotoMono-Regular.ttf` | Roboto Mono 400 | googlefonts/RobotoMono @ `111eb14e` (v3.001; added #349) |

### DM Sans weights (PRD #346 decision 2)

| Weight | Used for |
|---|---|
| 400 | Helper text and captions |
| 500 | Typed input, normal drawer items |
| 600 | Blue subtitles, chips, nav labels, "Subtotal"-style labels |
| 700 | Prices, totals, names, card titles, buttons, badges, big figures |
| 800 | Screen titles (base 18), the business name, the "POS" label under the raised button |

**Every theme uses DM Sans (#349).** All 10 builders (5 schemes × light/dark)
return through `AppTheme.withAppFont`, which puts `textTheme`,
`primaryTextTheme` and the component slots that carry their own style (app
bar title/toolbar, chip labels, input hint/label/helper/error, bottom-nav
labels, navigation-bar labels) on `DMSans`. It changes only the family —
size, weight, colour, letter spacing and height stay as each builder sets
them. Text styled with a raw `TextStyle` inherits the family from
`DefaultTextStyle`. The few explicit `fontFamily: 'monospace'` call sites are
left for the `monoStyle` adoption in Wave 2.

### Fonts in tests

`test/flutter_test_config.dart` (#352) loads the bundled DM Sans (all five
weights), Roboto Mono and the Material Symbols Outlined font into every test,
straight from disk and without initialising the test binding, so widget tests
and goldens measure and draw real glyphs. Two known test-only artifacts: text
whose style sets no family at all (e.g. `AppDropdown`'s selected value, a
`DefaultTextStyle` built from a bare `TextStyle`) draws as solid bars, and
`₦` draws as a box because DM Sans has no Naira glyph (a device falls back to
the system font). Pixel goldens live in `test/redesign/goldens/`, never
`test/golden/` (Linux CI).

### Styles outside the `TextTheme`

Defined as a `BuildContext` extension (`AppTextStyles`) in
`lib/core/theme/app_theme.dart`; sizes are already scaled with
`getRFontSize`, colour is unset (inherits from the surroundings).

| Access | Font | Base size | Use |
|---|---|---|---|
| `context.screenTitleStyle` | DM Sans 800 | 18 | Screen titles, business name, the "POS" label |
| `context.monoStyle` | Roboto Mono 400 | 13 | Codes and IDs only (e.g. "Terminal 01") |

### `TextTheme`

All sizes are **base px** scaled at runtime via `context.getRFontSize(base)`.
Do not pass raw `fontSize` values — always wrap in `getRFontSize`.

Access all styles via `Theme.of(context).textTheme.<styleName>`. Never
construct a `TextStyle` with raw `fontSize` or `fontWeight` outside of
`lib/core/theme/app_theme.dart`.

| Style | Base size | Weight | Default colour |
|---|---|---|---|
| `displayLarge` | 32 | 700 | Text primary |
| `displayMedium` | 28 | 700 | Text primary |
| `displaySmall` | 24 | 600 | Text primary |
| `headlineLarge` | 22 | 600 | Text primary |
| `headlineMedium` | 20 | 600 | Text primary |
| `headlineSmall` | 18 | 600 | Text primary |
| `titleLarge` | 16 | 600 | Text primary |
| `titleMedium` | 14 | 600 | Text primary |
| `titleSmall` | 13 | 500 | Text secondary |
| `bodyLarge` | 16 | 400 | Text primary |
| `bodyMedium` | 14 | 400 | Text primary |
| `bodySmall` | 12 | 400 | Text secondary |
| `labelLarge` | 14 | 600 | Text primary |
| `labelMedium` | 12 | 600 | Text primary |
| `labelSmall` | 11 | 500 | Text secondary |

Buttons define their own internal text size and weight — do not override
button label styles from outside the `AppButton` widget.

---

## Border radius scale

All radius values are defined as constants in `lib/core/theme/app_theme.dart`.
Reference them by name — never write a raw `BorderRadius.circular(14)`.

| Token name | Value | Used by |
|---|---|---|
| `AppRadius.hairline` | 2px | Modal handle bar, `AmberGlowLine` |
| `AppRadius.inputAuth` | 10px | Auth / onboarding input fields (`authInputDecoration`) |
| `AppRadius.sm` | 12px | `AppDecorations.primaryGradient` container default |
| `AppRadius.md` | 14px | `AppButton`, `AppInput`, `AppDropdown`, avatar buttons |
| `AppRadius.lg` | 16px | `AppFAB`, legacy `glassCard` |
| `AppRadius.xl` | 20px | Cards (`CardTheme`), chips, `surfaceCard`, most bottom sheets |
| `AppRadius.xxl` | 28px | Notifications modal top corners |

---

## Spacing scale

There are no static spacing constants. All spacing scales from a **375 px
baseline** via `context.getRSize(basePixels)`, clamped to **0.85× (0.84× in
a short viewport) – 1.15×**; type (`getRFontSize`) is clamped to **0.90×–1.15×**.
The 1.15 ceiling (since #372, was 1.50 spacing / 1.35 type) sits just above the
largest phone (430dp / 375 = 1.147), so phones are unaffected and tablets / wide
screens draw at about the mockups' 1× (ADR 0025, "Amendment, #372").

Do not write raw pixel values in `EdgeInsets`, `SizedBox`, or `Gap`. Always
wrap in `context.getRSize(n)`.

| Use case | Base px | Typical call |
|---|---|---|
| Icon-to-label gap | 4 | `getRSize(4)` |
| Tight element gap | 6–8 | `getRSize(6)` / `getRSize(8)` |
| Standard element gap | 12–16 | `getRSize(12)` / `getRSize(16)` |
| Section gap | 20–28 | `getRSize(20)` / `getRSize(28)` |
| Content horizontal padding | 16 | `horizontal: getRSize(16)` |
| Content vertical padding | 16 | `vertical: getRSize(16)` |
| Bottom sheet internal padding | 20–28 | `getRSize(20)` |
| Nav / large spacing | 40–60 | `getRSize(40)` / `getRSize(56)` |

---

## AI / accent variants

No AI feature exists in this project. There is **no AI accent token**.
If one is ever authorised, reuse `AppFixedColors.info` (`#3B82F6`) or
`AppSchemeColors.primaryGlow` before adding a new token. Do not add a speculative
colour token.

---

## Component library

All shared components live in `lib/shared/widgets/` (and
`lib/core/widgets/` for `AppFAB`). Always use these — never reach for a raw
`TextField`, `DropdownButton`, `ElevatedButton`, or `SnackBar`.

### `AppButton` (`app_button.dart`)

| Property | Value |
|---|---|
| Variants | `primary`, `secondary`, `outline`, `danger`, `ghost`, `success` |
| Heights | `xsmall` 32px / `small` 40px / `normal` 54px / `large` 60px |
| Radius | `AppRadius.md` (14px) |
| Primary bg | Secondary → Primary gradient + `primary` @ 0.30 shadow (the `AppSchemeColors.primaryGlow` value) |
| Secondary bg | `colorScheme.primary` @ 12% opacity |
| Success bg | Success button gradient (see Gradients) |
| Danger | `colorScheme.error` text / bg |
| Disabled | Grey gradient @ 70% opacity, non-interactive |

### `AppInput` (`app_input.dart`)

| Property | Value |
|---|---|
| Background | `colorScheme.surface` (filled, no outline) |
| Radius | `AppRadius.md` (14px) |
| Padding | `getRSize(16)` horizontal |
| Label | Above the field, `getRSize(8)` gap |
| Focus border | 2px, `colorScheme.primary` |

### `AppDropdown` (`app_dropdown.dart`)

Same shape language as `AppInput` — radius `AppRadius.md`, filled, label
above. Chevron: `AppIcons.chevronDown`.

### `AppFAB` (`lib/core/widgets/app_fab.dart`)

| Property | Value |
|---|---|
| Layout | Icon + label row |
| Height | 50px |
| Min width | 165px |
| Radius | `AppRadius.lg` (16px) |
| Background | Secondary → Primary gradient + glow shadow |
| `reserveBottomInset` | `true` by default (lifts above the nav bar). Set `false` only on the 5 visible-bar tab roots (Home, POS, Inventory, Orders, Cart). |
| Under POS | The frame's View Cart bar sits below the POS tab (not over it), so POS's FAB rises above it (#352). |

### `AppNotification`

Use for all success, error, info, and warning feedback messages. Never use a
raw `SnackBar`. Success variant uses `Colors.green.shade600` (`#43A047`) to
match `AppButton`'s success gradient.

### `AppDecorations` (`app_decorations.dart`)

| Helper | Returns | Restricted to |
|---|---|---|
| `AppDecorations.pageBackground(context)` | `BoxDecoration` with vertical opaque background fade (`scaffoldBackgroundColor` → `backgroundFade`) | Screen roots |
| `AppDecorations.card(context, {radius})` | `BoxDecoration` flat card (`cardFill`, `dividerColor` border, `cardShadow`) | General use |
| `AppDecorations.primaryGradient(context)` | `BoxDecoration` with primary gradient, radius `AppRadius.sm` | General use |
| `AppDecorations.primaryButtonGradient(context, {radius, shape, glow})` | `BoxDecoration` with the button gradient (`secondary` → `primary`) and `primaryGlow` shadow; `shape: BoxShape.circle` for a round button | The frame's raised POS button (bar + rail), the drawer's selected item, the View Cart bar (#352) |
| `AppDecorations.surfaceCard(context)` | `BoxDecoration` (delegates to `card`) | Legacy callers |
| `AppDecorations.glassCard(context)` | `BoxDecoration` (delegates to `card`) | Legacy callers |
| `AppDecorations.authInputDecoration(context, ...)` | `InputDecoration` with radius `AppRadius.inputAuth` (10px) | Auth / onboarding screens only |

---

## Flat with a soft fade (Global UI Standard)

The app uses the "flat with a soft fade" design standard (PRD #346; issue #351), replacing the earlier Glassy/blur look. When building or upgrading screens, strictly adhere to these visual principles:

1. **Opaque Page Fade**: Every screen body or `Scaffold` wrapper uses `AppDecorations.pageBackground(context)` — a vertical `LinearGradient` from `theme.scaffoldBackgroundColor` (top) to `AppSchemeColors.backgroundFade` (bottom). Both gradient stops are **strictly 100% opaque** so previous screens never show through during route transitions. Never build your own custom page gradient.
2. **Solid Top Bars**: `AppBar`s are always solid `colorScheme.surface`, with `elevation: 0`, `scrolledUnderElevation: 0`, `surfaceTintColor: Colors.transparent`, a 1px hairline bottom divider (`dividerColor`), and a soft `topBarShadow` shadow. AppBars never change color or blur on scroll.
3. **Flat Cards**: Use `AppDecorations.card(context, {radius})` or `GlassyCard`. The card recipe uses:
   - Fill: `AppSchemeColors.cardFill` (slightly see-through: white @ 0.90 light / `#111827` @ 0.72 dark in Blue Classic);
   - Border: `Border.all(color: theme.dividerColor, width: 1)`;
   - Shadow: `BoxShadow(color: AppSchemeColors.cardShadow, blurRadius: 12, offset: Offset(0, 2))`;
   - Radius: `AppSpacing.borderRadiusXL` (20px) default.
4. **No Blur Anywhere**: `BackdropFilter` and `ImageFilter.blur` are banned across `lib/` (enforced by `no_backdrop_blur_ban_test.dart`). The sole allowed exception is `lib/features/auth/widgets/auth_background.dart` on sign-in screens pending the Wave 2 Auth redesign.
5. **Theme-Level Sheets and Dialogs**: Modal sheets and dialogs are styled centrally in `ThemeData`:
   - `bottomSheetTheme`: `backgroundColor = surface`, `surfaceTintColor = transparent`, `modalBarrierColor = scrim` (black @ 0.35 light / 0.55 dark), `shape = RoundedRectangleBorder(top: 24px)`, `dragHandleColor = dividerColor`, `dragHandleSize = 36×4`. (`showDragHandle` is false; existing hand-drawn handles remain until Wave 2).
   - `dialogTheme`: `backgroundColor = surface`, `surfaceTintColor = transparent`, `barrierColor = scrim`, `shape = RoundedRectangleBorder(radius: 20px)`.
6. **Subtle Outlines & Dividers**: Use `theme.dividerColor` for borders and dividers; set `TabBar`'s `dividerColor: Colors.transparent`.
7. **Grid-Like Stats Layouts**: Avoid vertical lists for secondary stats. Refactor into side-by-side expanded grids using `Row` to maximise space efficiency inside cards.
8. **Generous Spacing**: Ensure generous gaps between major components using `context.getRSize()` (e.g., a top margin of `getRSize(24)` below the AppBar).

---

## Responsive Grid & Card Layouts

To prevent **overflow errors** on varying screen sizes (especially inside `GridView` where items have a fixed aspect ratio), follow these rules:

1. **Avoid `Expanded` for text blocks**: Never use `Expanded` or hardcoded flex proportions for areas containing text inside a constrained card. Text scaling (`getRFontSize`) and structural scaling (`getRSize`) may scale at slightly different rates, causing text to overflow a fixed percentage of a card.
2. **Flexible visual areas**: Use `Expanded` on the visual or empty areas (e.g., images, colored headers, top backgrounds) so they fill the *remaining* space dynamically.
3. **Intrinsic height for content**: Let text blocks define their own height. Wrap them in a standard `Padding` or `Container` (without an `Expanded` parent) so they naturally expand as needed, pushing back against the flexible visual area.

### Tap targets never compress

Structural scale compresses hard in a short viewport (`context.isShortViewport`,
e.g. a landscape phone) — padding, gaps, and field heights all shrink. **A tap
target does not.** No control may render below the 48dp Material / WCAG 2.5.5
minimum at any viewport, whatever `getRSize` says.

The trap is a control that does not *look* like one. A field that is `readOnly`
with an `onTap` — a date picker, a value chooser — is tapped anywhere on its
surface, so inspecting its icon tells you nothing; `AppInput` handles this case
for you (`wholeSurfaceTap`). A `readOnly` field with no `onTap` is a display
field, not a control, and correctly compacts to 40dp. When adding a new tappable
surface, ask which part of it the user actually presses before letting it
compress.

`AppDropdown` is the simpler case and its floor is **unconditional** at every
viewport, not just short ones: its whole surface is a `GestureDetector` and
`onChanged` is required, so it is always a control and can never compact. It
measured 43dp in portrait until 2026-09-07 — a reminder that this floor is worth
checking on existing widgets, not only new ones.

Use `kMinInteractiveDimension` (Flutter's own 48.0) rather than a literal, so the
intent reads at the call site.

Full responsive rules — the two-curve scale, `_kComfortableHeight`, and the
form-factor-vs-available-width split — land here in Phase 9; see
`docs/adr/0025-two-curve-responsive-scale.md` and
`docs/design/responsive-layout-plan.md` in the meantime.

## Shared parts (`lib/shared/widgets/redesign/`, #352 PR 2)

The redesign's building blocks. Import the barrel
`package:reebaplus_pos/shared/widgets/redesign/redesign.dart`. Every part takes
**plain data** (strings, numbers, enums, callbacks — never a provider), has
48dp+ tap targets, survives text scale 1.3 at 360dp, and has a light + dark
gallery golden in `test/redesign/goldens/parts_<part>_<theme>.png`. Screens
adopt them in Waves 1 and 2: the frame (View Cart bar), CEO Settings (#369:
`ScreenHeader` in an `AppBar`, `ProfileCard`, `SectionHeader`, `SettingsRow`)
and Home (#374: `ScreenHeader` + `HeaderBell`, `StatCard` + `StatusPill`,
`IconTile`, `SectionHeader`) so far.

**Settings-style lists on wide screens (#369).** A list of cards (settings
rows, a profile card, a search card) caps its content at 720dp
(`kSettingsMaxContentWidth`) and centres it; the top bar still spans the full
width. Under the cap the gutter is `getRSize(16)`, as in the mockup.

| Part | File | Use for |
|---|---|---|
| `ScreenHeader` (+ `HeaderBell`) | `screen_header.dart` | The content of a screen's top bar: gradient icon tile, ExtraBold title, primary subtitle, actions. Put it in an `AppBar` title / sliver header. `HeaderBell(count:, onPressed:)` is a plain bell with a badge; screens may pass the live `NotificationBell` instead. |
| `StatCard` | `stat_card.dart` | Home figure cards: icon tile, muted title + status pill, big figure, one-line subtitle. Optional `onTap`; optional `trailing` widget after the text (#374: Total SKUs' expand chevron); optional `density` (`StatCardDensity.compact`, #374: the landscape mockup's 12 padding / 44 tile / title 13 / figure 22 / subtitle 12 with a `dense` pill) for narrow grid cells. |
| `TagPill`, `StatusPill` | `tag_pill.dart` | PRO / CEO / status words in fixed colours (`TagPillTone`). `StatusPill` adds the mockup's ↑ / ↓ / ⓘ icon per tone. Optional `dense` (#374: 5×2 padding, 9 icon, 11 label) for compact stat cards. Display only. |
| `IconTile` (`IconTileTone`) | `icon_tile.dart` | The pale rounded square with a filled icon (stat cards, settings rows, cart lines). Fixed tone pairs, or explicit colours. |
| `ProductTile` (`StockLevel`) | `product_tile.dart` | POS / Receive Stock grid tile: photo first, else category tint + keyword icon; name, size·pack, price, stock pill; cart-count badge and primary border; out of stock dims and ignores taps. |
| `categoryVisual()` / `CategoryVisual` | `category_visual.dart` | The pure tile rule: keyword → icon + colour (stout/malt/beer·lager/water/energy/soft drink·soda·juice/wine·spirit), else a stable code-unit-sum hash into the fixed palette; null/blank → neutral + box. Unit-tested. |
| `CategoryChip` | `category_chip.dart` | Category filter chip with a dot coloured by `categoryVisual`; null category = "All". |
| `CartLine`, `QuantityStepper` | `cart_line.dart` | Cart line card: icon tile, name, "qty × price", total, size·pack, stepper (− becomes a red delete at the last unit). Caller resolves the icon (today: `productIconFromCodePoint`). |
| `ViewCartBar` | `view_cart_bar.dart` | The gradient "View Cart" bar (count, items · customer, total, chevron). Used by `MainLayout`. |
| `SettingsRow` | `settings_row.dart` | Settings / menu row card: icon tile, title, subtitle, chevron; whole card taps. |
| `ProfileCard` | `profile_card.dart` | Settings profile card: gradient initial tile (or the business `logo`, an optional `ImageProvider` that falls back to the initial if it fails, #369), business name (800), person, tags. |
| `flyToTarget()`, `FlyTarget`, `FlyTargetRegistry` | `fly_to_cart.dart` | The fly-to-cart animation and its landing targets (see below). |
| `SectionHeader` | `section_header.dart` | "Performance Overview · Analytics for the selected period": ExtraBold title, muted subtitle that wraps under it when narrow. `variant: SectionHeaderVariant.group` (#369) = the muted group label over a list of rows (SemiBold 15, `textTheme.bodySmall` colour; 16 above, 10 below in CEO Settings). |

### Fly-to-cart (`fly_to_cart.dart`, #352 PR 3)

`flyToTarget(context, target: FlyTargetId.cart)` flies a 30dp primary circle
with a cart icon from the tapped widget to the cart target **that is showing**:
the bottom-bar Cart item (under 600dp), the rail Cart item (600dp+, panel
closed), or the cart panel's header (fixed panel at 1024dp+, or the slide-in
when open). Targets are widgets wrapped in `FlyTarget(id:, priority:)`;
`FlyTargetRegistry.resolve` picks the highest-priority one that is mounted,
painted (not `Offstage`) and on screen — never a screen coordinate. The
panel header registers at priority 1, the nav Cart item at 0.

- **Feel (unchanged from the old POS particle):** 620ms; position eased with
  `Curves.easeIn`; x straight, y with an upward arc of `−110·sin(π·t)` on the
  raw progress; scale 1 → 0.35; opaque until 82%, then fades out; 0.55 primary
  glow (blur 10, spread 1).
- **Never blocks the add:** no target showing, reduced motion
  (`MediaQuery.disableAnimations`) or no overlay → no flight, silently. It
  draws in the root overlay in its own `OverlayEntry` (owns its controller,
  removes itself on landing), so the source may unmount mid-flight. The
  returned `FlyToCartFlight` can `cancel()`; POS cancels a tile's previous
  flight on a new tap and on dispose, as before.
- **A new destination** (Receive Stock's receiving cart, Wave 2 A): add a
  `FlyTargetId` value, wrap its button in a `FlyTarget` with that id, and call
  `flyToTarget(context, target: thatId)` after the add.

**Text weights for parts.** `AppTextStyles` (`app_theme.dart`) gained
`boldStyle(base)` (700), `semiBoldStyle(base)` (600), `mediumStyle(base)` (500),
`regularStyle(base)` (400) and `extraBoldStyle(base)` (800) — the PRD #346
decision 2 roles at a chosen base size, scaled with `getRFontSize` — so parts
never build a raw `TextStyle`.

**Fixed colours.** `AppFixedColors.onSolid` (white, both brightnesses) is the
text on a solid fixed pill (PRO).

## Layout patterns

### `MainLayout` — the app frame (`lib/shared/widgets/main_layout.dart`, #352)

One root `Scaffold`. What surrounds the tabs depends on the **screen width**
(not the shortest side), read only through `context.isRailLayout` (600dp+) and
`context.isWideLayout` (1024dp+) in `lib/core/utils/responsive.dart`. Other
screens keep using `isPhone` / `isTablet` / `isDesktop` for their own layouts.

| Width | Navigation | Cart on POS |
|---|---|---|
| under 600 | **Bottom bar** (`FrameBottomBar`) | Cart tab; a floating **View Cart** bar under POS opens the Cart tab |
| 600–1023 | **Side rail** (`FrameNavRail`), no bottom bar | **View Cart** opens a **slide-in panel** from the right over a dim (`AppSchemeColors.scrim`); ✕ or tapping the dim closes it |
| 1024+ | Side rail | Cart panel **fixed on the right** of POS (open by default); ✕ hides it and brings back the View Cart bar |

**Shared parts** (`lib/shared/widgets/frame/`):
- `frame_nav.dart` — `FrameNavItem` (one list, built once in MainLayout from the gates, drawn by both the bar and the rail, so items / order / permission hiding / tap behaviour cannot drift), `FrameBottomBar`, `FrameNavRail`. Item keys: `frameNavItemKey(tabIndex)`.
- `cart_panel.dart` — `CartPanel` (solid `colorScheme.surface`, `AppSchemeColors.panelShadow`, left hairline), `CartPanelCloseButton` (the ✕, placed at the end of the hosted Cart screen's own header via `CartScreen.onClosePanel`, so there is no extra strip and the status-bar padding is applied once) and `CartPanelScrim`. Widths: slide-in = 60% of the screen, max 460; fixed = 30%, 360–440 — plus the right system inset, which the panel's Surface runs under.
- `view_cart_bar.dart` — `ViewCartBar` (count badge, "N items · customer", the Cart screen's Total, chevron). Moves into the shared parts in #352 PR 2.

**System insets (#352 phone check).** The frame respects the side insets (a landscape navigation bar on the right, a display cutout on the left): the rail owns the left inset, the fixed cart panel owns the right one while it shows, and otherwise the content area is padded clear of it (and the inset is removed from the screens' MediaQuery so they never add it again). The bottom bar, the rail and the View Cart bar respect the bottom inset. **Bottom inset rule (#377):** the frame reads the tabs' MediaQuery *inside* its Scaffold body, so a screen sees exactly what that Scaffold gives it — under the bottom bar no bottom inset and no keyboard inset (the bar pads itself by the inset, the Scaffold's resize owns the keyboard). Never rebuild a tab's MediaQuery from `MainLayout`'s own context: that re-adds both, and a bottom `SafeArea` then draws a band the height of the system nav above the bar. `MainLayout` also wraps the tabs in `BottomBarInsetScope` while the bar shows (a nav tab's root, under 600dp), and `deviceBottomPadding` returns 0 inside it, so a tab root, a sheet opened on the tab's navigator and the in-tab drawer never add the inset again. A pushed screen (the bar hides), a drawer-only tab (no bar), the side rail (600dp+, the screen owns the bottom inset) and anything on the root navigator still get the raw inset.

**Visible nav items (5):** Home, Stock (`Gates.viewInventory`), POS + Cart (`Gates.makeSale`), Orders (pending-orders badge for the active store). Cart shows the cart-line count badge.

- **Bottom bar** (under 600): solid Surface, hairline top border, `topBarShadow`. **Only POS is raised**: a primary-gradient circle in a Surface ring with a glow, white icon, ExtraBold primary "POS" label. Selected = filled primary icon + primary label (600); idle = outlined icon + muted label. Shown only on the 5 nav-tab roots (hidden on drawer destinations and pushed pages, as before). Sideways **and** under 600dp wide it slides away on scroll (#258); at 600dp+ there is no bar to slide.
- **Rail** (600+, `context.navRailWidth` = `getRSize(80)` clamped 72–96, plus the left system inset): solid Surface, 1px `dividerColor` line on its right. Menu (☰, `AppIcons.menu`) on top — it opens the drawer and is the first-run tour's `SpotlightTargetId.menuButton` at this size — then the same five items. POS = raised primary-gradient tile with glow, white icon, primary label. Selected = filled primary icon + primary label, **no pill**; idle = outlined + muted. Always shown at 600dp+ (also on drawer destinations and pushed pages, like the old desktop sidebar), so the menu is always reachable. Under 440dp of height (after insets) it compacts — smaller POS tile, tighter padding, items spread evenly — so a sideways phone fits the menu and all five items; it scrolls rather than clips if a window is ever shorter. Labels never ellipsize: a label too wide for the rail scales down (`FittedBox`).
- **Drawer** pops over the screen at **every** size (the permanent 280dp desktop drawer is gone). Under 600dp each screen's own Scaffold declares it (`SharedScaffold` & co.) and the screen's `MenuButton` opens it; at 600dp+ MainLayout's Scaffold declares it so it covers the rail too, and screens pass `drawer: null` and drop their own menu button (`context.isRailLayout ? null : const MenuButton()`). Selected drawer item = solid primary-gradient bar (`primaryButtonGradient`) with a white filled icon, white label and a chevron. Permission hiding unchanged.
- **Cart panel** hosts the **existing Cart screen, unchanged**, in its own Navigator — checkout and the receipt open inside the panel through the Cart tab's own code. Back first unwinds the panel's pushed pages, then closes a slide-in panel. Leaving POS closes the slide-in panel; the fixed panel stays wanted. The Cart tab itself still exists at every size (rail Cart = Cart tab, same as the bar).
- **View Cart bar** sits **under** POS (a Column slot, so it never covers the grid or the scan button) on the POS root when the cart has lines, the panel is not showing, and the keyboard is down.

Each tab keeps its own push stack. Tab switches use a 200ms `easeOut` fade.
Only the landing tab is pre-initialised; other tabs initialise on first visit.
The tab stack is keyed so a rotation across 600dp keeps every tab's Navigator.

**Landing tab is per role** (`NavigationService.landingTabForRole`): CEO,
Manager and Stock keeper open on Home; Cashier opens on POS. A session starts on
Home — the neutral default, and the only tab never hidden from a nav bar —
because the role has not resolved from local SQLite at login; MainLayout applies
the role's tab once permissions land, once per session. A root-level back press
falls home to that same landing tab.

**Drawer-accessed destinations (not in the bar/rail):** Customers, Payments,
Expenses, Stores, Suppliers, Staff, Reports, Activity Log, Settings, CEO
Settings — full tab roots on the same per-tab `Navigator` machinery.

### Home (`home_screen.dart` + `dashboard/widgets/home_parts.dart`, #374)

- **Top bar**: solid Surface `AppBar` (hairline + `topBarShadow`, as CEO Settings) with `ScreenHeader` — trending-up tile, business name, active store, live `HeaderBell`; the menu button (48dp) only under 600dp. No scroll-reactive colour.
- **Period + Reports**: a "Today ⌄" outlined pill (calendar icon; a `PopupMenuButton` with the same period list; Custom opens the date range picker) and "Reports" as a `primaryTint` pill with the `AppFixedColors.danger` attention dot. In the rail layout (600dp+: sideways phones, tablets, wide) both sit in the top bar before the bell and "Performance Overview · Analytics for the selected period" (`SectionHeader`) is one line above the cards; on an upright phone they sit in a row under that header. The quick-actions row (#362) goes directly under the header.
- **Cards**: `StatCard` per figure in the order Sales, Profit, Pending, Expenses, Stock Value, Credits, Total SKUs. Columns from the width the cards really get (`homeGridColumns`): 3 at 1024dp+ or sideways at 600dp+, 2 at 600–1023 upright (or sideways 480–599), else 1. Rows share a height (`IntrinsicHeight`); gated or loading cards leave no gap. A cell narrower than `getRSize(kHomeCompactCardBelow)` (310) draws its cards at `StatCardDensity.compact` (and the credits grid card tighter): the sideways 3-column phone and the upright tablet's 2 columns; upright phones and 1280×800 stay regular. Every title must fit beside the widest pill at 844×390 with a 48dp right navigation bar (tested).
- **Trend pills**: neutral flags ("Active"/"No sales", "Attention"/"Clear", "Live") → `TagPillTone.neutral` "!"; positive → `green` ↑; otherwise `danger` ↓ (`homeTrendTone`).
- **Customer Credits**: single column = full card (wallet tile, title, chevron, Credit `infoTint` / Debt `dangerTint` boxes); grid cell = compact title + "Credit and debt", **values kept** (the card opens Customers, which lists per-customer balances, not these totals).
- **Staff Sales**: `SectionHeader` + one flat card, full width under the grid.
- **Quick actions** (#362, PRD #270): a "Quick actions" `SectionHeader` (the "Performance Overview" style) over fixed-size tiles (`kHomeQuickActionTileWidth` = 104 base): flat `AppDecorations.card`, a 44 `IconTile` with an explicit fixed pair (tint + filled icon), label DM Sans 600 at 12, up to 2 lines. Tiles share a height, line up from the left and are never stretched; the row scrolls sideways only when they do not fit. It sits between the period header and the cards at every size (upright: under the pills; rail layout: under the "Performance Overview" line), is held back during the first load and omitted, heading included, when no tile is visible. Tiles and their pairs: Add Expense `danger` + `bill`; Receive Stock `warning` + `receiving`; Take Stock `purple` + `auditCheck` (Stock Transfer `info` + `transfer` and Record Payment `green` + `payments` come in #362 PRs 2 and 4). Which tiles show is decided only by `resolveQuickActions` (`lib/features/dashboard/quick_actions.dart`), citing Gate Registry entries.

### App bar

| Property | Value |
|---|---|
| Height | `kToolbarHeight + 12` (≈ 68px at baseline) |
| Elevation | 0 |
| `surfaceTintColor` | `transparent` |
| Title alignment | Left |
| Bottom edge | 1px divider using `dividerColor` |

### `AppDrawer`

`lib/shared/widgets/app_drawer.dart` reads the providers and gates;
`app_drawer_parts.dart` draws (plain data + callbacks). Restyled to
`phone-drawer-dark.png` / `wide-drawer-*.png` in #368.

| Section | Detail |
|---|---|
| Presentation | A pop-over `Drawer` at every size (#352), solid `colorScheme.surface` |
| Width | `appDrawerWidth`: `getRSize(328)` (the mockups' 328dp, scaled like its content), at most 84% of the screen, plus the left system inset (the Surface runs under a cutout; the content is padded clear of it) |
| Header | Business tile (business logo from `currentBusinessLogoPathProvider`, else the primary-gradient initial; taps open Profile), business name (800), primary "Tap logo to open profile", lock in a bordered Surface-2 square, ✕ (closes); person's name (700); `TagPill`s — PRO `solidInfo` / FREE TRIAL `warning` (same `badgeLabel` rule), role `info`; "Terminal 01" in `monoStyle` |
| Sync banner | `DrawerSyncBanner`: `warningTint` fill + `warningOutline` border + `warning` icon while records wait; `danger*` once something failed. Same signals, gate (`Gates.viewSyncIssues`) and tap (Sync Issues); hidden when nothing is waiting |
| Store picker | `DrawerStoreRow`: card, filled primary store icon, "Store" over the name, up/down chevron (`AppIcons.unfoldMore`); shown only with 2+ stores |
| Items | `DrawerNavTile`: idle = outlined muted icon + Medium label; selected = `primaryButtonGradient` bar, white filled icon, Bold white label, chevron (every size). Hairline between the main and admin groups |
| Footer | Pinned under the list with a hairline above: the compact Display card (moon `IconTile` info, CEO / role still resolving only) and a full-width Log Out outlined in `AppFixedColors.danger` |
| Short windows | Under 560dp of height (after insets, measured from the drawer's own constraints) the header scrolls with the list; the footer stays pinned |
| Bottom inset | The footer adds `deviceBottomPadding` minus however far the drawer stops short of the screen's bottom (under 600dp on a tab root the drawer ends at the bottom bar, which already clears the inset) |
| Nav list | Permission-gated; items not permitted to the current role are omitted entirely (hide-don't-block) |

### Bottom sheets

| Property | Value |
|---|---|
| Top corner radius | `AppRadius.xl` (20px) default; `AppRadius.xxl` (28px) for Notifications modal |
| Handle bar | 40×4px, radius `AppRadius.hairline` (2px) |
| `useSafeArea` | `true` — but this does **not** inset the bottom. Footer content must add `context.deviceBottomPadding` explicitly. |
| Tall / scrollable sheets | Use `DraggableScrollableSheet`. Notifications: `initialChildSize 0.5`, `minChildSize 0.5`, `maxChildSize 0.9` |

### Dialogs

Centered overlay. Corner radius 16–20px (`AppRadius.lg` to `AppRadius.xl`).

### Safe-area rule

Content anchored to the bottom of the screen under `MainLayout` must use
`context.deviceBottomPadding` (accounts for the nav bar only). Above a visible
bottom bar it returns 0 (#377: the bar already clears the system nav), so the
same call is right on a tab root, in a sheet over it, and on a pushed screen. Never use
`MediaQuery.of(context).viewInsets.bottom` or
`MediaQuery.of(context).padding.bottom` inside `MainLayout` — both either
read 0 or double-count the keyboard due to how `MainLayout`'s `Scaffold`
handles insets. See `CLAUDE.md` for the full platform-specific rule.

---

## Brand logo

The official Reebaplus logo (ring mark "R+" with a rising arrow, plus the
"Reebaplus" wordmark) comes in two artworks: **dark** (light-grey R, white
wordmark; for dark themes) and **light** (dark R, black wordmark; for light
themes). The designer's originals live in `assets/branding/` (not bundled).

- **In the app, always use `ReebaplusLogo(height:)`** (`lib/shared/widgets/reebaplus_logo.dart`). It picks the artwork for the current theme. Never reference `assets/images/brand/*` directly (enforced by `test/shared/widgets/reebaplus_logo_test.dart`).
- `lockup: true` adds the wordmark under the mark. Leave it off where the screen already prints the name next to the logo.
- `brightness:` overrides the theme, only for screens drawn before the theme is known (the startup splash follows the device setting).
- **Launcher icon follows the device theme where the OS allows it**: Android light icon on `#BEBFC1`, dark icon on `#040404` (the dark artwork's near-black) via `-night` resources, plus a monochrome layer for Android 13+ themed icons; iOS 18 light / dark / tinted icons.
- Regenerate everything after a logo change: `dart run tool/generate_brand_assets.dart && dart run flutter_launcher_icons`.
- The business's own logo (drawer header, receipts) is separate from the Reebaplus logo.

## Icon library

All UI icons are unified under `AppIcons` (`lib/core/theme/app_icons.dart`), backed by **Material Symbols Outlined (w400)** via `package:material_symbols_icons`.

Widgets must **never** reference an icon set package or icon class directly. Always resolve through `AppIcons`:

| Access | Pattern | When to use |
|---|---|---|
| `AppIcons.<name>` | `Icon(AppIcons.<name>)` or `AppIcon(AppIcons.<name>)` | Default for all UI icons (nav items, buttons, chevrons, status, actions) |
| `AppIcon(icon, filled: true)` | `AppIcon(AppIcons.<name>, filled: true)` | When a filled symbol variant is needed (e.g., active navigation states) |

### Exceptions and compatibility:
- **Google Brand Logo**: `AppIcons.googleBrand` holds a direct `IconData(0xf1a0, fontFamily: 'FontAwesomeBrands', fontPackage: 'font_awesome_flutter')` constant until replaced by an SVG asset in Wave 2 (TODO #346).
- **Saved Codepoints**: Legacy FontAwesome codepoints persisted in the local SQLite database or cart lines (e.g. `kStoredIconBeerMug = 0xf0fc`, `kStoredIconBox = 0xf466`, `kStoredIconBolt = 0xf0e7`, `kStoredIconWineBottle = 0xf72f`) are translated on read to the corresponding `AppIcons` constant via `productIconFromCodePoint` (`lib/shared/utils/product_icon_helper.dart`).
