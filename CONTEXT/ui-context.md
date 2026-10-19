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
| Under POS | POS has no FAB since #384: its scan button sits beside the search field in the frozen band. |

### `AppNotification`

Use for all success, error, info, and warning feedback messages. Never use a
raw `SnackBar`. Success variant uses `Colors.green.shade600` (`#43A047`) to
match `AppButton`'s success gradient.

**Placement (#384).** The card starts `AppNotification.topOffset(context)`
under the top safe-area edge: the tallest top bar the app draws
(`max(68, max(getRSize(44), 48) + getRSize(16))`) plus `getRSize(8)`, so it
never covers a screen's title, store name or bell. A screen's top bar must not
be taller than that. The card lives in the Overlay of the context that raised
it (each MainLayout tab has its own), so it always shows on the tab in view.

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
Home (#374: `ScreenHeader` + `HeaderBell`, `StatCard` + `StatusPill`,
`IconTile`, `SectionHeader`) and Inventory → Manufacturers (#389:
`SectionHeader` + `SettingsRow` per manufacturer, 720dp cap) so far.

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
| `ProductTile` (`StockLevel`) | `product_tile.dart` | POS / Receive Stock / Request Stock grid tile: photo first, else category tint + keyword icon; name, size·pack, price (optional since #380 — Request Stock passes none and the stock pill sits at the start), stock pill; cart-count badge and primary border; out of stock dims and ignores taps. Optional `inCartLabel` (#384) replaces the badge text (POS sells fractions: "1.5"). Optional `tappableWhenOut` (#394, default false): an out-of-stock tile keeps tap and hold, is not dimmed and has no overlay; the danger pill stays (Receive Stock restocks empty products). |
| `categoryVisual()` / `CategoryVisual` | `category_visual.dart` | The pure tile rule: keyword → icon + colour (stout/malt/beer·lager/water/energy/soft drink·soda·juice/wine·spirit), else a stable code-unit-sum hash into the fixed palette; null/blank → neutral + box. Unit-tested. |
| `CategoryChip` | `category_chip.dart` | Category filter chip with a dot coloured by `categoryVisual`; null category = "All". |
| `CartLine`, `QuantityStepper` | `cart_line.dart` | Cart line card: icon tile, name, "qty × price", total, size·pack, stepper (− becomes a red delete at the last unit). Caller resolves the icon (the Cart uses `categoryVisual`, #385). Optional `badges` (tags under "qty × price") and `originalTotalLabel` (the pre-discount total, struck through above the total), both #385, default to none. `onIncrement` / `onDecrement` are optional (#394): with both null the line draws no stepper (the receive cart edits quantities in its sheet). |
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
- **Request Stock (#380)** flies to its "Review request" bar: `FlyTargetId.stockRequest`.
- **Receive Stock (#394)** flies to its "Review Items (N)" bar:
  `FlyTargetId.receiveCart`. The bar only exists once the receipt has a line,
  and a flight resolves its target at launch, so the tile launches the flight
  in a post-frame callback after the add (the first add flies too; the add
  itself never waits). Request Stock launches synchronously and so skips the
  flight on its first add (follow-up).
- **A new destination**: add a `FlyTargetId` value, wrap its button in a
  `FlyTarget` with that id, and call `flyToTarget(context, target: thatId)`
  after the add (post-frame if the target appears with that add).

**Text weights for parts.** `AppTextStyles` (`app_theme.dart`) gained
`boldStyle(base)` (700), `semiBoldStyle(base)` (600), `mediumStyle(base)` (500),
`regularStyle(base)` (400) and `extraBoldStyle(base)` (800) — the PRD #346
decision 2 roles at a chosen base size, scaled with `getRFontSize` — so parts
never build a raw `TextStyle`.

**Fixed colours.** `AppFixedColors.onSolid` (white, both brightnesses) is the
text on a solid fixed pill (PRO).

**Coach hint banner (`lib/shared/widgets/coach_hint_banner.dart`, #380).** The pale `primaryTint` "tap to add, tap and hold to choose a quantity" banner over a product grid, with a 48dp ✕. One per screen; the caller owns showing and retiring it (`UiHintService`). Request Stock, POS (#384) and Receive Stock (#394) use it.

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
- `cart_panel.dart` — `CartPanel` (its own `RepaintBoundary`; solid `colorScheme.surface`, left hairline, and `AppSchemeColors.panelShadow` on the slide-in panel only — the fixed panel sits flat beside POS, #385), `CartPanelCloseButton` (the ✕ as a square outlined button — hairline border on Surface, 48dp target — placed at the end of the hosted Cart screen's own header via `CartScreen.onClosePanel`, so there is no extra strip and the status-bar padding is applied once) and `CartPanelScrim`. Widths: slide-in = 60% of the screen, max 460; fixed = 30%, 360–440 — plus the right system inset, which the panel's Surface runs under.
- `view_cart_bar.dart` — `ViewCartBar` (count badge, "N items · customer", the Cart screen's Total, chevron). Moves into the shared parts in #352 PR 2.

**System insets (#352 phone check).** The frame respects the side insets (a landscape navigation bar on the right, a display cutout on the left): the rail owns the left inset, the fixed cart panel owns the right one while it shows, and otherwise the content area is padded clear of it (and the inset is removed from the screens' MediaQuery so they never add it again). The bottom bar, the rail and the View Cart bar respect the bottom inset. **Bottom inset rule (#377):** the frame reads the tabs' MediaQuery *inside* its Scaffold body, so a screen sees exactly what that Scaffold gives it — under the bottom bar no bottom inset and no keyboard inset (the bar pads itself by the inset, the Scaffold's resize owns the keyboard). Never rebuild a tab's MediaQuery from `MainLayout`'s own context: that re-adds both, and a bottom `SafeArea` then draws a band the height of the system nav above the bar. `MainLayout` also wraps the tabs in `BottomBarInsetScope` while the bar shows (a nav tab's root, under 600dp), and `deviceBottomPadding` returns 0 inside it, so a tab root, a sheet opened on the tab's navigator and the in-tab drawer never add the inset again. A pushed screen (the bar hides), a drawer-only tab (no bar), the side rail (600dp+, the screen owns the bottom inset) and anything on the root navigator still get the raw inset.

**Visible nav items (5):** Home, Stock (`Gates.viewInventory`), POS + Cart (`Gates.makeSale`), Orders (pending-orders badge for the active store). Cart shows the cart-line count badge.

- **Bottom bar** (under 600): solid Surface, hairline top border, `topBarShadow`. **Only POS is raised**: a primary-gradient circle in a Surface ring with a glow, white icon, ExtraBold primary "POS" label. Selected = filled primary icon + primary label (600); idle = outlined icon + muted label. Shown only on the 5 nav-tab roots (hidden on drawer destinations and pushed pages, as before). Sideways **and** under 600dp wide it slides away on scroll (#258); at 600dp+ there is no bar to slide.
- **Rail** (600+, `context.navRailWidth` = `getRSize(80)` clamped 72–96, plus the left system inset): solid Surface, 1px `dividerColor` line on its right. Menu (☰, `AppIcons.menu`) on top — it opens the drawer and is the first-run tour's `SpotlightTargetId.menuButton` at this size — then the same five items. POS = raised primary-gradient tile with glow, white icon, primary label. Selected = filled primary icon + primary label, **no pill**; idle = outlined + muted. Always shown at 600dp+ (also on drawer destinations and pushed pages, like the old desktop sidebar), so the menu is always reachable. Under 440dp of height (after insets) it compacts — smaller POS tile, tighter padding, items spread evenly — so a sideways phone fits the menu and all five items; it scrolls rather than clips if a window is ever shorter. Labels never ellipsize: a label too wide for the rail scales down (`FittedBox`).
- **Drawer** pops over the screen at **every** size (the permanent 280dp desktop drawer is gone). Under 600dp each screen's own Scaffold declares it (`SharedScaffold` & co.) and the screen's `MenuButton` opens it; at 600dp+ MainLayout's Scaffold declares it so it covers the rail too, and screens pass `drawer: null` and drop their own menu button (`context.isRailLayout ? null : const MenuButton()`). Selected drawer item = solid primary-gradient bar (`primaryButtonGradient`) with a white filled icon, white label and a chevron. Permission hiding unchanged.
- **Cart panel** hosts the **Cart screen** (restyled in #385, see below), in its own Navigator — checkout and the receipt open inside the panel through the Cart tab's own code. Back first unwinds the panel's pushed pages, then closes a slide-in panel. Leaving POS closes the slide-in panel; the fixed panel stays wanted. The Cart tab itself still exists at every size (rail Cart = Cart tab, same as the bar).
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
- **Quick actions** (#362, PRD #270): a "Quick actions" `SectionHeader` (the "Performance Overview" style) over fixed-size tiles (`kHomeQuickActionTileWidth` = 104 base): flat `AppDecorations.card`, a 44 `IconTile` with an explicit fixed pair (tint + filled icon), label DM Sans 600 at 12, up to 2 lines. Tiles share a height, line up from the left and are never stretched; the row scrolls sideways only when they do not fit. It sits between the period header and the cards at every size (upright: under the pills; rail layout: under the "Performance Overview" line), is held back during the first load and omitted, heading included, when no tile is visible. Tiles, in order, and their pairs: Add Expense `danger` + `bill`; Stock Transfer `info` + `transfer` (only with 2+ non-van stores; opens Request Stock with the locked store as "Deliver to", or neither end fixed under All Stores); Take Stock `purple` + `auditCheck`; Record Payment `green` + `payments` (#362 PR 4; shown when at least one payment side is available); Receive Stock `warning` + `receiving` — **always last** (owner, 2026-10-10). Five tiles scroll sideways on an upright phone and fit sideways at 844×390 ("Stock Transfer" / "Record Payment" wrap to 2 lines there). Which tiles show, and the Record Payment sides, are decided only by `resolveQuickActions` (`lib/features/dashboard/quick_actions.dart`), citing Gate Registry entries.
- **Record Payment chooser** (`lib/features/dashboard/widgets/record_payment_chooser.dart`, #362 PR 4): only when both sides are available. A modal sheet on the Home tab's navigator: handle, "Record Payment" (`screenTitleStyle`), muted SemiBold "Who is paying?", then one flat `AppDecorations.card` option per side (≥ 48dp, whole card taps): 44 `IconTile` + title Bold 15 + subtitle Regular 12 muted + chevron — "Customer paid us" / "Reduces what they owe" (`green`, `user`), "We paid a supplier" / "Reduces what you owe" (`danger`, `supplier`). It returns the side and Home opens that form: `CustomerPaymentSheet` titled "Record Payment" with its picker, or the supplier `RecordPaymentSheet` in its supplier-picker mode, unchanged. One side skips the chooser.

### POS (`pos_home_screen.dart` + `pos/widgets/`, #384)

One scroll view (PRD #239): top bar (pinned upright, floats away sideways) → tier row (scrolls away) → frozen band (pinned) → coach hint → grid. The page sits on `AppDecorations.pageBackground`.
- **Top bar** (`PosTopBar`, `pos_header_parts.dart`): solid Surface `AppBar` + hairline + `topBarShadow` with `ScreenHeader` — POS tile (`AppIcons.pos`), "Point of Sale", the store POS sells from (the controller's store, else `activeStoreLabelProvider`), then the view selector (grid / list, kept from before) and the live bell (`PosLiveBell`, a copy of Home's); the menu button (48dp) only under 600dp. Height `posTopBarHeight`: Home's rule, but the 68dp shrinks with the scale on a short sideways phone.
- **Tier row** (kept, not in the mockups): Retailer / Wholesaler (`AppDropdown`, CEO/Manager only, as before), manufacturer filter, and the Quick Sale button (`PosQuickSaleButton`: 48dp `primaryTint` square, bolt).
- **Frozen band**: page-fade colour; a Surface-filled search field with the scan button beside it — a square primary-gradient button under 600dp, a "Scan Barcode" pill at 600dp+ (`PosBarcodeScanButton.shape`); hidden with nothing to scan into (All Stores placeholder). Under it `CategoryFilterBar`: the shared `CategoryChip`s in a horizontal scroll, "All" first, "Uncategorized" last (Receive Stock shares the bar).
- **Grid**: `ProductTile` per product (subtitle = description · size · unit, price for the active tier, stock pill — amber at ≤ 5, `kPosLowStockAt` — count badge with the cart line's quantity). Gutter 16, gap 12, cell height `posTileExtent` (grows with the text scale). Columns: `ProductGrid.columnsFor(grid width, preference)` — under 380dp at most 2; 380–600 the view selector's choice (default 2); over 600 at least width / 170 (`kPosTileMinWidth`): 4 at 800dp upright beside the rail, 4 beside the fixed cart panel at 1280dp, 4 sideways at 844dp. The list view is a row card (`_PosProductListRow`) from the same data.
- **All Stores placeholder**: neutral `IconTile` (store), the same text, a 48dp "Select store" text button.
- **Short screen** (`posShortHeight`: screen height minus top/bottom system insets under `kPosShortHeight` = 480dp — a sideways phone; a measured height, not `isShortViewport`, and the keyboard never flips it): no separate tier row; one frozen row = search (flexes) + tier picker (`kPosShortTierWidth` 128) + manufacturer picker (`kPosShortManufacturerWidth` 150) + Quick Sale square + scan **square**; tile art drops from 60 to 20 (base) so a full row of tiles shows on first view at 844×390 with insets, View Cart bar included. Upright phones, tablets and wide screens are unchanged.

### Cart (`lib/features/pos/screens/cart_screen.dart` + `lib/features/pos/widgets/cart/cart_parts.dart`, #385)

The Cart tab (under 600dp, and the rail's Cart item) and the cart panel draw the same screen (`tablet-cart-panel-*.png`, `wide-pos-cart-*.png`; no phone mockup — the phone tab is the panel design at full width). **Restyle only: every money, crate, deposit and discount figure comes from the unchanged `_quote`.**
- **Top bar** (`CartTopBar`): solid Surface bar (hairline + `topBarShadow`) with `ScreenHeader` — primary cart tile, "Cart", primary "N items" (cart lines, the same count as the nav badge and the View Cart bar); then the bell (Cart tab only — in the panel POS's header beside it carries one), the red-tint **Clear** pill (`AppFixedColors.danger*`, only with lines; today's animated clear, no confirm step) and, in the panel, the square ✕. The menu button (48dp) leads under 600dp. The title is a plain one-line `Text`: **never a `FittedBox` in a header** (it shrank "Cart" to a dot in the tablet panel, #385), and the panel header carries no bell, so the title always has room. The panel header is the `FlyTarget(FlyTargetId.cart, priority: 1)`.
- **Customer card** (`CartCustomerCard`, fixed above the scroll so it is never squeezed out, #255): 40 `IconTile` (info, user), name Bold 15 (wraps to 2 lines rather than being cut short), balance SemiBold 12 — "Bal: ₦X clear / credit" in `AppFixedColors.green`, "overdue" in `danger` — and a Surface-2 "Change" button (48dp) that opens today's picker.
- **Lines** show in the order they were added and never move when a quantity changes (the old sort by quantity made a line jump to the top mid-edit; checkout still lists them largest first): the shared `CartLine` — category tile (`categoryVisual` of the line's category), name (`productDisplayName` without the unit), "qty × price" (whole quantities drop ".0"), net line total in primary with the gross struck through when discounted, "Custom price" / "−10%" badges, detail "subtitle · unit", stepper (+ is clamped to the line's stock cap by `CartService.updateQty`; − at the last unit is the red bin, which removes the line with the 5s Undo). Tap opens Edit Item. Keys `cartLineKey(...)`.
- **Under the lines, in this order**: Subtotal row; the amber `CrateValueMissingCard` (`warningTint` / `warningOutline`, same gate as before); the `EmptyCratesCard` (warning crate tile, "N going out", the per-brand rows and "Required Deposit"; still registered customers only); the `CartDiscountRow` (green tag tile, "Discount", green "−₦X"; only when a line has a discount).
- **Footer** (`CartFooter`): "Total" Bold 18 + the primary ExtraBold 26 figure (subtotal − discounts; the deposit is still captured at checkout), Save Cart and Recall (`CartOutlineButton`: side by side when both labels fit whole in half the width, else stacked — never ellipsized), and the gradient "Proceed to Checkout" `AppButton`. It is **pinned** under the scrolling lines (Surface + hairline) when the space below the customer card is at least `getRSize(440)` (measured with a `LayoutBuilder`, not a viewport predicate); otherwise (a phone sideways, the keyboard up) it scrolls at the end of the list. Bottom padding is `deviceBottomPadding`.
- **Empty**: neutral 64 `IconTile` (cart-add), "Cart is empty", outlined Recall.

### Customer payment sheet (`lib/features/customers/widgets/customer_payment_sheet.dart`, #362 PR 3)

The one form for "a customer paid us": the customer page's Add Credit and Home's Record Payment (title and submit "Record Payment", #362 PR 4). `CustomerPaymentSheet.show(context, {customer, title, submitLabel})`, opened on the caller's navigator (so inside the frame the Scaffold's resize owns the keyboard; the bottom padding is `deviceBottomPadding` only). One shrink-wrapped `CustomScrollView`, capped at 90% of the screen height, so it scrolls at 360dp @1.3 and at 844×390 with the keyboard up.
- **Header**: hairline handle, title in `screenTitleStyle` ("Add Credit" by default), primary SemiBold subtitle ("Choose the customer who paid" / "Add credit for ‹name›").
- **Picker** (no customer given): `AppInput` search ("Search name or phone", matches name, or phone ignoring spaces) over flat `AppDecorations.card` rows — 40 `IconTile` (info, `AppIcons.user`), name Bold 15 (2 lines), phone Regular 12 muted, chevron; whole card taps, ≥ 48dp. No walk-in, no deleted customers. Empty: neutral `IconTile` + "No customers yet" (none at all) or "No customers match".
- **Form**: the chosen customer as a card (44 `IconTile`, name, phone, balance line Bold 14 — `AppFixedColors.danger` "Owes ₦X", `green` "Has ₦X credit", muted "Nothing owed"; "Change" text button only when picked in the sheet), a full-width secondary "Pay full ₦X" `AppButton` (48dp) only when owing, then Amount (`AppInput`, starts empty), "Payment method" as two side-by-side cards (Cash / Bank Transfer; selected = primary border, `primaryTint` fill, filled primary icon), Note (optional) and the primary submit `AppButton`.

### Checkout + sales sheets (`checkout_page.dart`, `lib/features/pos/widgets/sales_parts.dart`, #393)

**Restyle only: every Checkout figure, default and validation is pinned by `test/pos/checkout_money_test.dart`.**
- **Pushed sales screens** (Checkout, the scan page): `SalesTopBar` — solid Surface bar, hairline, `topBarShadow`, `ScreenHeader` with a 48dp back / close (`SalesBackButton`). Checkout's title is "Checkout" with the live payable total as the subtitle ("Receipt" after Confirm). The page body is `pageBackground`; the form and the receipt are capped at `kSettingsMaxContentWidth` (720) and centred (in the cart panel they fill it).
- **Checkout form**: `SectionHeader` per section; Order Summary is one flat card (category `IconTile` per line, as the Cart; Subtotal / Discount / Crate Deposit muted rows; Total Bold 16 + ExtraBold 20 primary). Crate rows: warning crate `IconTile`, name, "N crates · Full ₦X · No deposit/Part/Full", amount in primary, edit icon; the whole row (≥ 48dp) opens the deposit sheet. Warnings are `SalesNotice` (warning tint for missing crate value, danger for the debt limit). Payment choices are `SalesChoiceCard`s (selected = primary border + `primaryTint`, filled icon; ≥ 48dp): Cash / Transfer + Pay with Credit side by side (same height), Cash + Transfer tenders, Register as Credit Sale (subtitle + round check), Add credit balance to receipt (checkbox icon). Balances: `AppFixedColors.green` credit, `danger` debt. Confirm Payment stays at the end of the scroll.
- **Sheets** (Edit Item, the scan sheets, camera, deposit, Cart pickers): Surface with the theme's 20dp top corners (`salesSheetDecoration`), no hand-drawn shadow; `SalesSheetHeader` = handle, optional 44 `IconTile`, title in `screenTitleStyle`, primary SemiBold subtitle, trailing 48dp ✕. Rows are flat `AppDecorations.card`s with a 40 `IconTile`, ≥ 48dp, whole card taps. Steppers are `SalesStepButton` (48dp pale-primary squares, the Cart line look). The New-barcode options are the shared `SettingsRow`. Fixed-height sheets use `sheetMaxHeight`, never `getRHeight`.
- **Dialogs**: theme surface and radius; Quick Sale caps at 560 (`kQuickSaleMaxWidth`) with a warning bolt `IconTile`; buttons are `AppButton`s at full height (no `small`).
- **Scan page**: the viewfinder stays dark (`colorScheme.scrim`) under the Surface bar; the torch is a 48dp icon button (primary when on).

### Orders (`orders_screen.dart`, `lib/features/orders/widgets/orders_parts.dart`, #393 PR 2)

- **Top bar**: `OrdersTopBar` — the Home / POS recipe (Surface, hairline, `topBarShadow`, `ScreenHeader` + live bell; menu only under 600dp). The tab bar is a Surface band with a hairline, primary label + 3dp indicator, full width.
- **Tab bodies** sit on the page fade and are capped at `kSettingsMaxContentWidth` (720), centred, 16 gutter (`ordersCapPadding`): the summary figures card (`OrdersSummaryStrip`: ExtraBold figure over a SemiBold muted label, hairlines between), the search `AppInput` (+ period `AppDropdown` on Completed / Cancelled), then the cards.
- **Order card**: flat `AppDecorations.card` with a 4dp status stripe (primary pending, green completed, info refunded, danger cancelled); customer row (40 `IconTile`, name Bold 15, address) that opens Customer Detail; rider button (48dp) or `OrderStatusPill`; order number in `monoStyle`; payment `TagPill`; item lines; money block (Total ExtraBold primary, Paid, debt `TagPill`, discount in fixed green) only with `Gates.seeOrderMoney`; Refund / Confirm `AppButton`s at 48dp.
- **Sheets / dialogs**: the receipt sheet and crate return sheet use Surface with the 20dp top corners and `sheetMaxHeight`; crate rows are cards with an `AppInput` count; Credit / Cash are 48dp choice cards. Crate Return Approval uses the same top bar, cards and 48dp tinted Approve / Reject.

### Request Stock (`lib/features/stores/screens/request_stock_screen.dart`, #380)

A pushed screen (GlassyScaffold title bar). One `CustomScrollView`: the two store pickers side by side ("Request from store" / "Deliver to store"; a fixed end is a locked field), a search field, the coach hint, then `RequestProductGrid` — `ProductTile`s for the **source store's in-stock products** only, columns = width / 170 (2–6), cell height `getRSize(220)`, no price, "N in stock" pill (warning at or under the product's `lowStockThreshold`), the requested quantity as the badge. Empty states centre in the remaining space (no source yet / source has nothing in stock / no search match). Under it, while the list is not empty and the keyboard is down, a Surface footer with the primary "N items · Review request" button (`deviceBottomPadding` below it); it is the fly-to target. The review sheet lists lines as cards (category `IconTile`, name up to 2 lines, "‹store› has N", red ✕ remove, `QuantityStepper` — at 1 the minus is remove), then "N products · M units" and "Send request" → a confirm dialog. Hold on a tile opens a quantity sheet (autofocused number field). With the keyboard up the scroll view ends at the keyboard's top edge (pinned by `request_stock_keyboard_test.dart`).

### Inventory (`lib/features/inventory/screens/inventory_screen.dart` + `widgets/inventory_parts.dart`, #392 PR 1)

- **Top bar** (`InventoryTopBar`): Home's solid Surface bar (hairline + `topBarShadow`, height `inventoryTopBarHeight` = Home's rule) with `ScreenHeader` — inventory tile, "Inventory", the active store; actions are 48dp `InventoryBarAction`s (search toggle on Products, Daily Stock Count behind `Gates.dailyStockCount`) and `InventoryLiveBell` (`HeaderBell`). Menu (48dp) only under 600dp. The other Inventory screens reuse this bar in later PRs.
- **Width**: list and form content caps at `kInventoryMaxContentWidth` (720, fixed — the settings cap) and centres via `inventoryGutter(context, measuredWidth)` (`LayoutBuilder` / `SliverLayoutBuilder`, never a viewport predicate). Detail screens (Product, Supplier, Manufacturer) will cap at a fixed 960 and pair header cards side by side at ≥ 900 measured. Sheets keep Material 3's 640.
- **Figure cards** (`InventoryFigureCard`): 32 `IconTile` + ExtraBold 20 figure on one line, SemiBold 12 muted label under it; 2dp primary border when its filter is on. The summary row (Total SKUs `info`, Low Stock `warning`, Out of Stock `danger`, Total Crates `green`, Near Expiry `warning`) shares one row when each card gets `getRSize(104)`, else scrolls sideways at `getRSize(112)`. Empty Crates and History use the same card, display only.
- **Tab bar**: Surface band, hairline under it (reserved on top of the 48dp floor), Bold/SemiBold 14 labels, primary underline; labels start at the content column's edge.
- **Products**: `AppInput` search; Category + Manufacturer `AppDropdown`s (not `CategoryFilterBar` — Inventory filters by category id incl. Uncategorized) and a 48dp `primaryTint` tag square (Manage categories); `CoachHintBanner` for hold-to-edit; `InventoryProductRow` cards — photo, else `categoryVisual` tile, name Bold 15 (2 lines), subtitle, stock `TagPill` (In Stock green / Low Stock warning / Out of Stock danger) + expiry `TagPill`, ExtraBold stock figure and unit; the card edge takes `warningOutline` / `dangerOutline` when low / out.
- **Suppliers**: secondary "Add Supplier" `AppButton`, then a `SettingsRow` per supplier (bank tile, contacts subtitle).
- **Empty Crates**: two figure cards, `SectionHeader` "Bottle manufacturers", flat card per brand (44 `IconTile`, name, crate value, warning `TagPill` "⚠ N short", chevron, Full / Empty / Total row in primary / warning / green ExtraBold 18).
- **History**: `InventoryPeriodChip` stadiums (48dp), Stock In / Out figure cards, the table as one flat card (Surface header, hairline-separated rows, movement badges in fixed tones).
- **Sheets** (Manage Categories, Add Manufacturer): theme sheet (no own Surface), `useSafeArea`, `InventorySheetHeader` (handle, `screenTitleStyle` title, optional primary subtitle); category rows are flat cards with the category tile and 48dp rename / delete; dialogs are `scrollable`.
- **Add Product** (`add_product_screen.dart`, #392 PR 2): `pageBackground`; `InventoryTopBar` (tag tile "Add Product", inventory tile "Add Stock" for an existing product) with a 48dp back `IconButton` (`AppIcons.arrowBack`, `maybePop`); body capped at 720 via `inventoryGutter`. Fields sit in `InventoryFormCard`s (fast layout: Name → Unit, then a "More details" card with a 48dp toggle; classic layout: notice / details, then Quantity + Store). Labels `InventoryFieldLabel`, hints `InventoryFieldHelper`, banners `InventoryNotice` (tone + 48dp ✕), suggestions `InventorySuggestionList` / 48dp `InventorySuggestionTile`, ✕ clears `InventoryFieldClear` (48dp), expiry `InventoryDateField` (AppInput shape, 48dp, "Clear date"), checkboxes `InventoryCheckRow`. The save button is `InventoryFormFooter` (Surface + top hairline, button capped at 720, `deviceBottomPadding`) in `bottomNavigationBar` — it stays under the keyboard, the body resizes. Dialogs are `scrollable`.
- **Update Product sheet** (`update_product_sheet.dart`): keeps its own Surface (both callers pass a transparent sheet background), theme sheet shape, `sheetMaxHeight(0.92)`, `deviceBottomPadding` INSIDE the Surface under the save button; header = 44 `IconTile` + 48dp photo button with an edit badge + `screenTitleStyle` title + primary subtitle; fields use the same form parts. Width = M3 sheet default 640.
- **Photo field** (`product_photo_field.dart`): theme input fill box, 48dp `primaryTint` "Add photo" / "Change photo" pill, 48dp "Remove photo" in fixed danger. Catalogue note: `AppIcon` + Medium 12.

- **Detail screens** (Supplier Detail, Manufacturer; `widgets/supplier_parts.dart`, #392 PR 4): `InventoryTopBar` (48dp back, live bell or edit/delete) over `pageBackground`; the body sits in `InventoryDetailColumn` (fixed 960, centred, top bar stays full width). Header figures use `InventoryDetailHeaderCards`: side by side (equal width, regular `StatCard`) when the MEASURED width is >= 900, stacked below with slim one-row figures (`InventoryDetailStatCard(compact: true)`) so a sideways phone keeps room for the tabs. Tabs: `InventoryDetailTabBar` (Surface band + hairline, `tabBarExtent` 48 + `tabBarChromeExtent` 1). List rows: `InventoryDetailRowCard` (40 `IconTile`, Bold 15 title, muted subtitle, trailing figure/pill, optional footer buttons); actions on the Supplier Crates tab are `SettingsRow`s; Total In / Out are `SupplierTotalTile`s (FittedBox, a money figure never ellipsises). Fixed colours only (`AppFixedColors` green / danger / warning). The supplier ledger rows (`SupplierLedgerEntryTile`) and payment sheets belong to `lib/features/payments/` (batch B).
- **Crate sheets and the keyboard** (buy, damaged, count, value change, Add Manufacturer, catalogue report, Supplier record-crates / float / entry options): theme sheet (no own Surface, no `backgroundColor: transparent`), `useSafeArea: true`, `CrateSheetFrame` (keyed, scrolling, `InventorySheetHeader`, bottom = 24 + `deviceBottomPadding` + `inventorySheetKeyboardLift`), `CrateRecordBox` for "This is what will be recorded" (primary tint, warning tone for a loss/short), `CrateSheetActions` (Cancel + confirm). A modal sheet is NOT resized by `MainLayout`'s Scaffold, so any sheet with a text box adds `inventorySheetKeyboardLift` itself. Inputs use the theme fill (not `cardColor`, which equals the light sheet's Surface). Any `AlertDialog` is `scrollable: true`.

- **Product Detail** (`product_detail_screen.dart`, #392 PR 3): `pageBackground`; `InventoryTopBar` ("Product Details", 48dp back `IconButton`, 48dp delete in fixed danger behind `products.delete`); content caps at a fixed **960** (`kDetailMaxContentWidth`, `detailGutter`, measured) — the batch-wide detail rule. Identity card (72 photo or `IconTile`, name `AppInput` ExtraBold 20, stock `TagPill`) full width; below it a `DetailPair`: Stock & Info on the left, Pricing / Sales Summary / Sales Target / Last Delivery stacked on the right when the measured width is >= 900 (`kDetailSideBySideWidth`), else one column in the same order. Rows are `DetailInfoRow` (40 `IconTile` by tone, SemiBold 13 muted label, Bold 14 value capped at 45% of the row, trailing control) in a `DetailCard`, hairline `DetailDivider`s, 48dp floor; inline price / text boxes are a themed 48dp box. Expiry badge is a `TagPill`. The Delete dialog is `scrollable`. Update Stock sheet is unconnected dead code (owner decision) — untouched.
- **Stock Count** (`stock_count_screen.dart`, #392 PR 3): `pageBackground`; `InventoryTopBar` ("Daily Stock Count", store name as subtitle, back, Record Damages + History `InventoryBarAction`s); list content caps at the settings 720 (`inventoryGutter`); PRODUCT / SYSTEM / ACTUAL / DIFF labels over flat `AppDecorations.card` rows (name Bold 14, system SemiBold, 84-wide 48dp `AppInput` count box, diff in fixed green / danger; card edge `dangerOutline` when short, green when over). `AppFAB` "Save Count" unchanged, with 80dp scroll clearance. Sheets (Review Count, Record Damages, Count History, a day's counts): theme sheet shape on their own Surface (transparent route background), `InventorySheetHeader`, **one scrolling list** (header + chips + rows) with only the Back / Confirm buttons pinned, so an empty-count review sheet never overflows sideways; Record Damages scrolls in `sheetMaxHeight(0.92)` with `deviceBottomPadding` inside; chips are `TagPill`s; history rows are 48dp+ flat cards with an `IconTile`.

### Customers (`lib/features/customers/`, #395, PRD #346 Wave 2 A)

Local parts in `lib/features/customers/widgets/customer_parts.dart`. **Restyle only: every figure, gate and write path is unchanged.**
- **Top bar** (`CustomerTopBar`, height `customerTopBarHeight` = CEO Settings' rule): solid Surface + hairline + `topBarShadow`, `ScreenHeader` — customers tile, "Customers", the active store; the live bell (`CustomerLiveBell`, a copy of Home's); the 48dp `MenuButton` only under 600dp (also when Home's Credits card pushes the screen, as before). No scroll-reactive colour.
- **List**: one `CustomerListRow` per registered customer (the walk-in is never listed) — flat `AppDecorations.card`, the whole card taps (≥ 48dp): 44 `infoTint` tile with the initial, name Bold 15 (2 lines), address Regular 12 muted (2 lines, "N/A" kept), the tier as a dense info `TagPill` ("RETAILER" / "WHOLESALER"), then "Credits Balance" over the figure (Bold 16, `AppFixedColors.green`, `danger` below zero; `creditBalancesKoboProvider`, deposits excluded). The locked store scopes the list. Empty: neutral `IconTile` + "No customers found.". Add Customer stays the `AppFAB`.
- **Wide**: list and form screens cap at `kSettingsMaxContentWidth` (720) and centre; the gutter is at least `getRSize(16)`. 800×1280 beside the rail is effectively full width; 1280×800 = 720 centred.
- **Add / Edit Customer sheets**: the sheet draws its own Surface with the theme's sheet shape (`customerSheetShape`) inside the 0.9 `DraggableScrollableSheet` (snaps 0.5 / 0.9 kept); hairline handle (`CustomerSheetHandle`), then a `ScreenHeader` (user-add / edit tile, title, primary subtitle; Edit adds its 48dp back arrow and stays non-dismissible). Fields are `AppInput` / `AppDropdown` with an even `getRSize(16)` gap. `CustomerFormSheetLayout` pins the header and Save when the sheet is at least `getRSize(340)` tall, otherwise everything scrolls as one list (sideways with the keyboard up). Material caps a sheet at 640dp wide, centred.

**Customer Detail (#395 PR 2)** — same parts file. **Restyle only: every figure, gate and write handler unchanged.**
- **Top bar**: `CustomerTopBar` + `ScreenHeader` (user tile, "Customer Profile", "Account Details"), 48dp back, Delete as a 48dp `AppFixedColors.danger` icon (same `Gates.deleteCustomer` + walk-in guard), then `CustomerLiveBell`. No scroll-reactive tint.
- **Width**: every sliver and the tab bar cap at a fixed `kCustomerDetailMaxContentWidth` (960), centred (`customerDetailGutter`, measured). The profile and credits cards sit side by side when the measured content width is >= 900 (`CustomerHeaderSliver`, a `SliverLayoutBuilder`), else stack. The body is a `SafeArea(top/bottom: false)` so the sideways system bar is cleared.
- **Profile card** (`CustomerProfileCard`): 60 gradient initials tile, name ExtraBold 18, tier `TagPill` (Wholesaler green / Retailer warning), muted phone / address / "Since" lines, 48dp edit pencil (`Gates.editCustomer`).
- **Credits card** (`CustomerCreditsCard`): wallet `IconTile` + "Credits Balance", the figure ExtraBold 28 (`danger` below zero), the Period `AppDropdown`, "Debt Limit" in a neutral box, "Deposit Held" in an `infoTint` box (only when not 0), then Add Credit (primary) / Set Limit (outline) / Refund Cash (outline), each >= 48dp behind its gate.
- **Tabs**: `TabBar` stays in `TabbedSliverScaffold` (#245): Surface band, hairline, Bold 13 primary label, primary indicator. **Credits**: Total In (green) / Total Out (danger) `CustomerFigureCard`s behind `seeWalletTotals`, rows are flat `CustomerDetailRow` cards (green arrow-down in, danger arrow-up out; 48dp void button). **Orders**: receipt `IconTile`, "#ORD…" Bold, date, total, status `TagPill` (completed green, cancelled / refunded danger, else warning); a row opens the receipt. **Crates**: "Record crate return" is a `SettingsRow` (`Gates.recordCrateReturn`); balance rows are box `IconTile` + name + `TagPill` (owed info, credit green, clear neutral).
- **Sheets** (Refund Cash / Refund Deposit, Set Debt Limit, Record Crate Return, via `showCustomerSheet`): theme Surface and shape, `CustomerSheetFrame` (handle, `screenTitleStyle` title, primary subtitle, one shrink-wrapped scroll capped at 90% of the screen height, `deviceBottomPadding`), `AppInput` fields, primary `AppButton`; refund methods are four `CustomerOptionCard`s in a 2x2 grid. Currency labels use `activeCurrencySymbol`. The receipt sheet changed its frame only. Dialogs: theme dialog, `AppInput` reason, `AppFixedColors.danger` action.

### Receive Stock (`lib/features/receiving/screens/receive_stock_screen.dart` + `receiving/widgets/`, #394)

A pushed screen (Inventory's FAB, Home's quick action) on `AppDecorations.pageBackground`. **Restyle only: the receive gate (`stock.add || products.add`), the direct inventory write, the FIFO batch, the supplier rule and the uncosted warning are untouched.**
- **Top bar** (`ReceiveTopBar`, `receive_parts.dart`, a copy of the CEO Settings / POS bar): solid Surface + hairline + `topBarShadow`, `ScreenHeader` — receiving tile (`AppIcons.receiving`), "Receive Stock", the active store label (whose stock the "Current" counts show: the locked store, or All Stores' aggregate), a 48dp back arrow exactly when the route implies one, and the search toggle (48dp, search ↔ close). Height `receiveTopBarHeight` (POS's rule).
- **One `CustomScrollView`** (PRD #239): the search field (only while toggled on, autofocus; opening it scrolls to the top so it is in view) → `CategoryFilterBar` (POS's, reused) → the shared `CoachHintBanner` "Tap and hold a product to edit it." (only with `Gates.editProductPrice`, same `UiHintService` key) → the grid. On a sideways phone the chips and hint scroll away; a whole tile row then fits above the bar. A chosen category deleted by sync falls back to "All".
- **Grid** (`ReceiveProductGrid`, a sliver): the New Product cell first (only with `Gates.addProduct`; card frame with a primary border, pale primary add `IconTile`, "New Product"), then a `ProductTile` per product — name, subtitle = size · unit (the crate size and unit, as before), pill "Current: N" or a red "No stock", **no price**, the receipt quantity as the badge, `tappableWhenOut: true`. Tap adds one and flies; hold re-checks `editProductPrice` and opens `UpdateProductSheet` (receive mode). Columns = `(grid width incl. gutters / 170).clamp(2, 6)`: 2 on phones (was 3), 4 sideways at 844 and upright at 800 beside the rail, 6 at 1280. Cell height `receiveTileExtent` (grows with the text scale; the art shrinks under 480dp of height). Tile keys `receiveProductTileKey(id)`.
- **Footer**: while the receipt has lines, a Surface + hairline bar with the gradient "Review Items (N)" `AppButton` (`deviceBottomPadding` below, side insets cleared) — the fly-to target — opening the receive cart.

### Receive cart, Edit Receive Item, Receive Checkout (`lib/features/receiving/`, #394 PR 2)

**Restyle only: every figure comes from the unchanged `ReceiveCartNotifier`; `_confirm` / `confirmReceipt`, the supplier-required rule (#334), the crate maps (#210) and the uncosted disclosure (#199) are untouched.** Content caps at `kReceiveMaxContentWidth` (720, the batch-wide list / form cap, centred with a `getRSize(16)` minimum gutter via `receiveSidePadding`); bars span the screen. Sheets cap at `kReceiveSheetMaxWidth` (640).
- **Receive cart** (`receive_cart_screen.dart`): `ReceiveTopBar` — cart tile, "Receive Stock Cart", primary "N items" (lines), the red-tint **Clear** pill (`ReceiveClearButton`, a tighter copy of the Cart's so the title stays whole at 390dp) which still asks "Clear Cart" first and goes back after. Lines are `CartLine` **without a stepper**: category tile (`categoryVisual` of the line's in-memory `categoryId`), name, "qty × cost", line total, a "Cost: ₦X" `TagPill`, detail "unit · Ret: ₦X • Whls: ₦Y"; tap opens Edit, swipe left removes (danger background). Footer "Invoice Total:" + primary ExtraBold figure and the gradient "Continue (N items)" — pinned (Surface + hairline) when the body is at least `getRSize(440)` tall, else the last list item (sideways phone). Empty: neutral 64 `IconTile`, same two texts. Keys `receiveCartLineKey(id)`, `ReceiveKeys.*`.
- **Edit Receive Item sheet** (`edit_receive_item_modal.dart`): handle, 44 primary-tint `IconTile`, "Edit Quantity & Prices" (`screenTitleStyle`), the product name in primary, 48dp ✕; a card with the − (danger tint) / quantity (ExtraBold 28, autofocus) / + (green tint) buttons, each 52 (≥ 48dp); "UPDATE PRICES" group header; the three `AppInput`s with their gates (`editBuyingPrice`, `editProductPrice`); the inline uncosted line in `AppFixedColors.warning`; "Total Cost" in a `primaryTint` box; Remove (danger) + Save Changes. Scrolls, capped at 90% of the screen height.
- **Receive Checkout** (`receive_checkout_screen.dart`): `ReceiveTopBar` — invoice tile, "Invoice". One scroll: Invoice Total as a `StatCard` (info, invoice icon, figure, "N units • M products"); the `UncostedReceiveWarning` (warning tint + outline card, warning `IconTile`, same three lines); group headers with today's wording ("STOCKING INTO *", "SUPPLIER *" / "SUPPLIER (optional)", "DATE RECEIVED", "PAYMENT", "ITEMS", "CRATES WITH THIS DELIVERY"); store `AppDropdown`; supplier and date `_TapField`s (Surface + hairline, ≥ 48dp; the supplier clear ✕ is a 48dp `IconButton`); note; Amount Paid Now + payment method as `AppDropdown` (Cash / Transfer / POS; only with a supplier and `manageSuppliers`); items card; one crate row per manufacturer (warning crate `IconTile`, name, "N drinks on this delivery", Full crates in / Empty crates back). "Confirm Receipt" is a pinned Surface + hairline footer (was `Scaffold.bottomSheet`) with `deviceBottomPadding`. The confirm dialog keeps its text.
- **Supplier picker**: `DraggableScrollableSheet` (0.7 / 0.4 / 0.9) — handle, search (autofocus), "Add Supplier" outline (only with `manageSuppliers`), suppliers as cards (40 info `IconTile` supplier, name Bold 15, whole card taps ≥ 48dp), "No suppliers found"; list bottom padding `deviceBottomPadding`.

### Expenses (`lib/features/expenses/`, #412, PRD #346 Wave 2 B)

Local parts in `lib/features/expenses/widgets/expense_parts.dart`. **Restyle only: every figure, gate and write path is unchanged.**
- **Top bar** (`ExpenseTopBar`, height `expenseTopBarHeight`): solid Surface + hairline + `topBarShadow`, `ScreenHeader` (expenses tile, "Expenses", the active store), the live bell, the 48dp `MenuButton` only under 600dp. Add Expense uses the same bar with a 48dp back arrow ("Record Expense" / "Edit Expense", "Log operating costs").
- **Wide**: list and form cap at the raw `kSettingsMaxContentWidth` (720), centred through per-sliver side gutters (`expenseGutter`); the tab bar band spans the width, its tabs cap at 720. No scroll view is given a height (PRD #239); structure stays `TabbedSliverScaffold` + `TabSliverView`, rows keep `kExpenseRowKeyPrefix`.
- **Cards**: flat `AppDecorations.card` (`ExpenseCardShell`). Total + period `AppDropdown`; Monthly Budget with a fixed-colour bar (`green`, `danger` when over; edit pencil 48dp, CEO only); pending block `warningTint` / `warningOutline` (`Gates.approveExpenses`); expense rows have a danger-tone category `IconTile`, a `TagPill` status (approved green, rejected danger, pending warning) and the three-dot menu (edit / delete rules unchanged).
- **Stats**: Annual Projection, vs-budget, top staff and Category Breakdown are flat cards. Breakdown palette keeps its order on the fixed set: red `danger`, amber `warning`, emerald `greenDot`, blue `info`, purple `purple`, pink `neutralIcon`.
- **Pop-ups**: Monthly budget and Reject use `AppInput` inside `AlertDialog(scrollable: true)`; Delete is a theme dialog with a danger action.
- **Add Expense form**: `AppInput` / `AppDropdown` fields, `ActionChip` category suggestions, the receipt picker as a tappable card (danger outline until attached, green after), danger `AppButton` footer with `deviceBottomPadding`.

### Supplier Accounts (`lib/features/payments/`, #411, PRD #346 Wave 2 B)

Local parts in `widgets/payments_parts.dart`. **Restyle only: every figure, gate, balance sign and write path is unchanged.**
- **Top bar** (`PaymentsTopBar`, Home's height rule): solid Surface + hairline + `topBarShadow`, `ScreenHeader` (payments tile "Supplier Accounts", or receipt tile "Transaction History" with a 48dp back arrow), the live bell, the 48dp `MenuButton` only under 600dp. Never changes on scroll.
- **Width**: list screens cap at the raw 720 (`paymentsGutter`, measured, minimum gutter `getRSize(16)`). 800 beside the rail is nearly full width; 1280 is 720 centred.
- **Supplier Accounts**: `SettingsRow` "Transaction history", `SectionHeader` "Suppliers" with "Balances for: store", then a `PaymentsSupplierRow` per supplier (44 bank tile, Bold 15 name, muted contacts, balance Bold 13 in fixed danger "Owed" / green "Credit" / muted "Settled"). Add Supplier stays the `AppFAB`.
- **Transaction History**: period `AppDropdown` (long ranges behind `Gates.seeExtendedDateRanges`), Total In / Out `PaymentsFigureCard`s (FittedBox figures), `SupplierLedgerEntryTile` rows (flat card, 40 `IconTile` green / danger / neutral for a void, Bold 15 name, SemiBold 12 subtitle, ExtraBold 15 signed figure; a void is faded and struck through).
- **Sheets**: supplier form and Record Invoice / Payment keep the draggable sheet (tap-out kept) on their own Surface with the theme shape; `PaymentsFormSheetLayout` pins header and button when the sheet is at least `getRSize(340)` tall, else scrolls everything; the button lifts by `paymentsSheetKeyboardLift` plus `deviceBottomPadding`. The chooser is a theme sheet (`PaymentsChooserFrame`) with two `SettingsRow`s. The confirm dialog is the theme dialog.

### Settings pages, Profile and Staff Settings (`lib/core/settings/settings_page_parts.dart`, `lib/features/profile/`, #442, PRD #346 Wave 2 C)

Pages behind CEO Settings follow the CEO Settings menu (no mockups). **Restyle only.**
- **Top bar** (`SettingsPageBar`, height rule of Home): solid Surface + hairline + `topBarShadow`, `ScreenHeader`, a 48dp back arrow when the route can pop. Never changes on scroll.
- **Width**: list and form pages cap at the raw `kSettingsMaxContentWidth` (720, `settingsGutter`, measured, minimum `getRSize(16)`); the top bar spans the full width. Sheets cap at 640.
- **Rows and cards**: `SettingsRow` for navigation rows, `SettingsCard` (= `AppDecorations.card`) + `SettingsControlRow` (48 `IconTile`, Bold 16 title, Regular 13 muted subtitle, optional trailing control) for toggles and info.
- **Profile**: header card (avatar initials in the avatar colour, ExtraBold 20 name, role tag, pills), stat cards (40 `IconTile` in fixed green / purple / primary), `Account Details` card (48dp rows). `profile_ui.dart` is shared with Staff Detail.
- **Business Info / Appearance / Display / Receipt printer** (PR 2): `SectionHeader` (group) over a `SettingsCard`; fields are `AppInput` / `AppDropdown`, switches are Bold 15 title + Regular 13 muted subtitle rows, Save is a full-width `AppButton`. Appearance cards keep their keys; Display and Appearance mark the active choice with a 2dp outline.
- **Security / Subscription / Activity Logs access / Activity Logs / Delete Business** (PR 3): toggles and info are `SettingsCard` + `SettingsControlRow`; the Subscription status is a fixed-tone `TagPill`; Activity Logs is a drawer root (`MenuButton` + `NotificationBell`, 720 list cap, `IconTile` + `TagPill` log cards); Delete Business is a danger-tint banner over a danger `AppButton`.
- **Edit Profile** (`EditProfileSheet.show`): theme sheet, `ScreenHeader`, `AppInput`, 8 hex swatches (48dp targets), `AppButton`; scrolls above the keyboard.
### Staff (`lib/features/staff/`, #440, PRD #346 Wave 2 C)

Local parts in `widgets/staff_parts.dart`. **Restyle only: every gate, write path, confirmation and wording is unchanged.**
- **Top bar** (`StaffTopBar`, CEO Settings' height rule): solid Surface + hairline + `topBarShadow`, `ScreenHeader` (staff tile; Staff Management keeps its 48dp `MenuButton` only off the rail and a `TabBar` under the header; pushed screens get a 48dp back arrow). No bell (the screens never had one). Never changes on scroll.
- **Width**: Staff Management and Invite Staff cap at the raw `kSettingsMaxContentWidth` (720, `staffGutter`, minimum gutter `getRSize(16)`); Staff Detail caps at a raw 960 (`kStaffDetailMaxContentWidth`) and puts the header card and Account Details side by side once the measured column is 900 or more. Sheets use Material's 640.
- **Staff Management**: `AppInput` search (+ `AppDropdown` store filter, side by side when the column is 420 or more, else stacked), `StaffListRow` flat cards (44 initial tile, Bold 15 name, muted email / phone / address, role `TagPill` via `staffRoleTone` CEO warning / Manager info / Cashier green / rest neutral, "You" and "Suspended" pills, last login, chevron only when tappable; faded rows for suspended or a Manager viewing a CEO / Manager), "SUSPENDED" as a group `SectionHeader`. Invites: `StaffInviteCard` (mono code, role tag, three meta lines, danger Revoke).
- **Staff Detail**: `StaffHeaderCard` (60 gradient initials tile, ExtraBold name, role / Active-Suspended / store pills), `StaffStatGrid` (measured 2 / 3 / 5 columns, fixed-colour `IconTile`s, FittedBox figures), `StaffInfoCard` (Account Details rows, the store row and Permission access still tap), `AppButton` actions behind their own gates. Pop-ups are the theme dialog; the driver-balance pop-up's name box is an `AppInput` in a `scrollable: true` dialog. The Assigned stores sheet is a theme sheet with `StaffSheetFrame`.
- **Invite Staff**: `AppInput` / `AppDropdown` form, `StaffRoleOptionCard`s (selected = primary border on `primaryTint`), the generated code in a `primaryTint` card in `monoStyle`.

### Roles & permissions (`lib/core/settings/roles_permissions_screen.dart`, `role_permissions_detail_screen.dart`, `lib/features/staff/screens/staff_permissions_screen.dart`, #440 part 2)

Local parts in `lib/features/staff/widgets/permission_parts.dart`. **Restyle only.**
- **Page**: `PermissionPage` = soft fade + `StaffTopBar` (`ScreenHeader`, 48dp back) + side-inset safe body; all three screens cap at the raw 720 (`StaffColumn`). No-access and load-error text are `PermissionMessage` with the same words.
- **Roles & Permissions**: intro line, then one `SettingsRow` per role in tier order (CEO, Manager, Cashier, Stock keeper), `IconTile` toned by role, subtitle "N of M permissions" / "All M permissions".
- **Role detail / Staff permissions**: group `SectionHeader` over a flat `PermissionToggleCard` of `SwitchListTile`s (>= 48dp, hairline between). A child whose parent is off is locked off and says `Requires "…"`; an override says "Overridden — … default is on/off" in Bold primary. Role detail adds the Business / Store pill toggle (`PermissionScopeToggle`, primary gradient on the selected segment), the Manager-only "Allow viewing other stores" card, the discount slider card under Sales and the expense-approval `AppInput` card under Expenses; Store scope has the store picker card (`AppDropdown`) and Restore store defaults. Dialogs are the theme dialog with a fixed-danger action.

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
| Header | Business tile (business logo from `currentBusinessLogoPathProvider`, else the primary-gradient initial; taps open Profile), business name (800), primary "Tap logo to open profile", lock in a bordered Surface-2 square — **no ✕** (#388): the drawer pops over at every size, so tapping outside it, the back button / gesture or a swipe closes it, and the business name gets the freed width; person's name (700); `TagPill`s — PRO `solidInfo` / FREE TRIAL `warning` (same `badgeLabel` rule), role `info`; "Terminal 01" in `monoStyle` |
| Sync banner | `DrawerSyncBanner`: `warningTint` fill + `warningOutline` border + `warning` icon while records wait; `danger*` once something failed. Same signals, gate (`Gates.viewSyncIssues`) and tap (Sync Issues); hidden when nothing is waiting |
| Store picker | `DrawerStoreRow`: card, filled primary store icon, "Store" over the name, up/down chevron (`AppIcons.unfoldMore`); shown only with 2+ stores |
| Items | `DrawerNavTile`: idle = outlined muted icon + Medium label; selected = `primaryButtonGradient` bar, white filled icon, Bold white label, chevron (every size). Hairline between the main and admin groups |
| Footer | Pinned under the list with a hairline above: the compact Display card (moon `IconTile` info, CEO / role still resolving only) and a full-width Log Out outlined in `AppFixedColors.danger` |
| Short windows | Under 560dp of height (after insets, measured from the drawer's own constraints) the header scrolls with the list; the footer stays pinned |
| Bottom inset | The footer adds `deviceBottomPadding` minus however far the drawer stops short of the screen's bottom (under 600dp on a tab root the drawer ends at the bottom bar, which already clears the inset) |
| Nav list | Permission-gated; items not permitted to the current role are omitted entirely (hide-don't-block) |

### Dashboard reports (`lib/features/dashboard/screens/` + `widgets/report_parts.dart`, #413 PR 1)

**Restyle only: every figure comes from the unchanged `recon_data.dart` / `report_revenue.dart`; gates (`profitReportEntry`, `seeReportCostPrices`, `crateDepositsReport`, `supplierAccountsReport`, `viewApprovals`, `dailyReconciliation`) are untouched.**
- **Top bar** (`ReportTopBar`, height `reportTopBarHeight` = CEO Settings' rule): solid Surface + hairline + `topBarShadow`, `ScreenHeader` with a 48dp `ReportBackButton` (`maybePop`), the report's tile, title, the active store (Sales Detail: the period) and 48dp `ReportBarAction`s (Export CSV). No scroll-reactive colour.
- **Width**: list screens (hub, Sales Detail, Profit, Crate Deposits, Supplier Accounts) cap at the raw 720 (`reportGutter`, measured, minimum `getRSize(16)`); the top bar stays full width.
- **Parts**: `ReportCard` (flat `AppDecorations.card`), `ReportHeadlineCard` (40 `IconTile`, muted label, ExtraBold 28 figure in a `FittedBox`, `ReportChip` wrap), `ReportValueRow` (label | value, value scales down, never ellipsises), `ReportHubCard` (48 `IconTile`, Bold 16 title, pending badge in `AppFixedColors.warning` or chevron; keys `reportCardKey`, `report-card-badge-<title>`), `ReportEmpty`.
- **Colours**: profit / income in `AppFixedColors.green`, loss / owed in `danger`, refunded in `warning`. Never `Colors.*`.

**Daily Reconciliation (#413 PR 2):** list = `ReportTopBar` + period `AppDropdown` + flat day cards (`StatusPill` danger for Mismatch, `ChangedSinceReviewBadge`), 720 cap. Detail = raw 960 (`kReconDetailMaxWidth`), cards stacked below 900 measured width and in two columns (first half left, rest right) from 900; the reviewed banner and the breakdown stay full width. Card icons/figures use `AppFixedColors` (info, green, danger, warning); `ChangedSinceReviewBadge` is a warning `TagPill`. Figures and the card set stay exactly as `recon_data.dart` yields them (Hard Rule #8).

**Stock Approvals (#413 PR 3):** `ReportTopBar` + 720 cap. Each request (Quick Sale, crate deposit or refund, stock add/remove) is a flat card: surface fill, hairline, soft shadow, 40 `IconTile` (danger remove, green add, info Quick Sale and refund, purple deposit), Bold 15 title, PENDING `TagPill`, ExtraBold amount in the same fixed colour, `ExpansionTile` details, `AppButton` Reject (outline) + Approve / Confirm (success). The reject-reason pop-up and the crate amount box use `AppInput`; the pop-up is `AlertDialog(scrollable: true)`.

### Bottom sheets

| Property | Value |
|---|---|
| Top corner radius | `AppRadius.xl` (20px) default; `AppRadius.xxl` (28px) for Notifications modal |
| Handle bar | 40×4px, radius `AppRadius.hairline` (2px) |
| `useSafeArea` | `true` — but this does **not** inset the bottom. Footer content must add `context.deviceBottomPadding` explicitly. |
| Tall / scrollable sheets | Use `DraggableScrollableSheet`. Notifications: `initialChildSize 0.5`, `minChildSize 0.5`, `maxChildSize 0.9` |

### Dialogs

Centered overlay. Corner radius 16–20px (`AppRadius.lg` to `AppRadius.xl`).

**Keyboard rule (owner phone check, #402):** a pop-up that holds a text box (`AppInput`, `TextField`, `TextFormField`) must scroll — `AlertDialog(scrollable: true, …)`, or a `Dialog` whose body is a `SingleChildScrollView`. With the keyboard up a pop-up gets about half the screen; unscrollable content squeezes the text box into a "BOTTOM OVERFLOWED" stripe. `test/utils/dialog_keyboard_scroll_ban_test.dart` scans `lib/` and fails on any pop-up that breaks this. A restyle that makes a pop-up taller (e.g. swapping a plain `TextField` for `AppInput`) also adds a keyboard-open widget test at 360×640 and 390×844 with text at 1.15 — set the keyboard on `tester.view.viewInsets` (the harness's own `viewInsets` only reaches the screen, not a pop-up on the root navigator).

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

### Subscription states (`lib/features/subscription/`, #414)

Full-screen states, not list screens: `SubscriptionStateFrame` = Scaffold + `AppDecorations.pageBackground` (no blurred photo), `SafeArea`, content centred at the raw `kSettingsMaxContentWidth` (720), hero centred in the free space and the actions under it; scrolls when short. **Locked**: 88 danger `IconTile` (lock), ExtraBold 26 title, Regular 15 muted body, SemiBold danger "Your free trial ended on …" line (trial only), primary Subscribe (opens the unchanged "coming soon" pop-up) and ghost Sign out. **Thank You**: 88 green `IconTile` inside the pulsing ring, ExtraBold 28 title, muted body, flat `AppDecorations.card` plan card (Bold 16 price, Regular 13 muted "Renews …"), primary Continue. Read-only: no write of any kind. Goldens `subscription_locked_*` / `thank_you_subscription_*`.

### Stores (`lib/features/stores/`, `stores_settings_screen.dart`, #441, PRD #346 Wave 2 C)

Local parts in `lib/features/stores/widgets/stores_parts.dart` (shared-part candidates).

- **Top bar** (`StoresTopBar`, height `storesTopBarHeight` = CEO Settings' rule): solid Surface + hairline + `topBarShadow`, `ScreenHeader` — store tile, "Stores", the active store; live bell; the 48dp `MenuButton` only under 600dp. CEO Settings > Stores uses the same bar with a 48dp back arrow (`maybePop`) and no subtitle.
- **List**: one flat `AppDecorations.card` per store, capped at the raw `kSettingsMaxContentWidth` (720) and centred (`storesSliver`). The top row (44 `IconTile`, name Bold 15 up to 2 lines, muted location up to 2 lines, chevron) opens Store Details; under it a hairline, "Total Units" (info) and "Products" (green) `StoreFigure`s, then — only with `Gates.manageStores` — 48dp Edit / Delete text actions. Empty: neutral `IconTile` + "No Stores Yet". No access: the same centred sentence as before. The list clears the Add Store `AppFAB` with 88 + `deviceBottomPadding`.
- **Sheets** (`StoreSheetFrame`, `showStoresSheet`): the theme sheet shape on its own Surface, capped at 640; hairline handle, 44 `IconTile` + `screenTitleStyle` title (+ optional muted subtitle), then fields; one shrink-wrapped scroll view capped at 90% of the screen height with `deviceBottomPadding` below, so it scrolls with the keyboard up. Fields are `AppInput`; the Country picker is `StoresAutocompleteField` (label over `AppInput`, 48dp option rows). The Delete dialog is `scrollable` and its stock warning is a `StoresNotice`.
- **CEO Settings > Stores**: 720 cap; a flat card per location (name + address `AppInput`, 48dp "Save changes"), 48dp outlined "Add a store" / "Add a van", a `SectionHeader` "Vans" with the muted explainer. Compact on purpose: the 800x600 test surface must show "Add a van" without scrolling.

- **Store Details** (`store_details_screen.dart`, #441 PR 2): `StoresTopBar` + `ScreenHeader` with a 48dp back arrow (store name, location or "Main Storage"); one column capped at a raw 960. Header: Store Value `StatCard` (info, figure, "Total Units" pill) and three `StoreStatTile`s (Products, Low Stock, Customers — the last taps); stacked below 900 measured width (tiles 2 or 3 across), side by side from 900. Then the Inventory card (`StoresExpansionTile`, open by default; rows name Bold 14 + `TagPill` "N units", danger at or under the low-stock threshold), "Request Stock" secondary `AppButton` (`requestStoreTransfer`), "Quick Actions" with a `SettingsRow`, and the Transfer hub. Browse-only viewers get the info `StoresNotice`, the Inventory card and "Request Stock from this store".
- **Transfer hub** (`store_transfer_hub.dart`): "Stock Transfers" `SectionHeader`; group `SectionHeader`s (uppercase) per section; one flat card per transfer (40 `IconTile`, name · units Bold 14, muted subtitle) with 48dp `AppButton`s (primary Accept & Dispatch / Confirm Receipt, danger Reject / Cancel Transfer; side by side while each has 340dp, else stacked); "Transfer history" collapsible with IN / OUT `TagPill`s and the status in danger when cancelled. The Dispatch dialog is a `scrollable` `AlertDialog` that owns its controllers.


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
