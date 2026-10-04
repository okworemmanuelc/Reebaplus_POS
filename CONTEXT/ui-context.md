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
buttons, active nav (the active rail item's pale pill is
`AppSchemeColors.primaryTint`), prices, the screen-title icon tile (a solid
primary gradient, not a tint) and focus outlines.

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
| Primary tint | `AppSchemeColors.primaryTint` | `#2563EB` @ 0.12 | `#3B82F6` @ 0.16 | Active rail item and other pale active fills (not the screen-title icon tile, which is the solid primary gradient) |
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
| Drawer header | `scaffoldBackgroundColor` → `roleAccentColor.withValues(alpha:0.3)` | top-left → bottom-right | Built into `AppDrawer` header; `roleAccentColor` is resolved per role inside `AppDrawer` |

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
| `AppRadius.lg` | 16px | `AppFAB`, glass cards (`glassCard`) |
| `AppRadius.xl` | 20px | Cards (`CardTheme`), chips, `surfaceCard`, most bottom sheets |
| `AppRadius.xxl` | 28px | Notifications modal top corners |

---

## Spacing scale

There are no static spacing constants. All spacing scales from a **375 px
baseline** via `context.getRSize(basePixels)`, clamped to **0.8×–1.5×** for
narrow and wide screens.

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

### `AppNotification`

Use for all success, error, info, and warning feedback messages. Never use a
raw `SnackBar`. Success variant uses `Colors.green.shade600` (`#43A047`) to
match `AppButton`'s success gradient.

### `AppDecorations` (`app_decorations.dart`)

| Helper | Returns | Restricted to |
|---|---|---|
| `AppDecorations.primaryGradient(context)` | `BoxDecoration` with primary gradient, radius `AppRadius.sm` | General use |
| `AppDecorations.surfaceCard(context)` | `BoxDecoration` with `colorScheme.surface`, radius `AppRadius.xl` | General use |
| `AppDecorations.glassCard(context)` | Frosted-glass `BoxDecoration` | Auth screens only |
| `AppDecorations.authInputDecoration(context, ...)` | `InputDecoration` with radius `AppRadius.inputAuth` (10px) | Auth / onboarding screens only |

---

## Glassy & Modernistic UI Standard (New Global Standard)

The app is actively migrating to a modern, premium "Glassy" design language. When building or upgrading screens, strictly adhere to these visual principles:

1. **Gradient Backgrounds**: Replaces flat `Scaffold` backgrounds. Wrap the screen's body or the `Scaffold` in a `Container` with a `LinearGradient`:
   `theme.scaffoldBackgroundColor` → `primary.withValues(alpha: 0.05)` → `primary.withValues(alpha: 0.12)`. Set the inner `Scaffold` to `backgroundColor: Colors.transparent`.
2. **Scroll-Reactive AppBars**: `AppBar`s must start transparent and dynamically darken/dim when scrolling. Use a `NotificationListener<ScrollUpdateNotification>` to track scroll offset (`pixels > 10`) and update the `AppBar`'s `backgroundColor` to `theme.colorScheme.surface.withValues(alpha: 0.8)`. Always use `elevation: 0`.
3. **Glassy Cards**: Replace standard flat cards and `AppDecorations.surfaceCard` with a frosted-glass widget (e.g., `_GlassyCard`) leveraging `ClipRRect`, `BackdropFilter(sigmaX: 12, sigmaY: 12)`, and faint borders (`primary.withValues(alpha: 0.05)`). Wrap inner content with `Material(type: MaterialType.transparency)` to preserve `InkWell` ripples.
4. **Subtle Outlines & Dividers**: Minimise harsh dividing lines. Set `TabBar`'s `dividerColor: Colors.transparent` and keep card borders ultra-faint.
5. **Grid-Like Stats Layouts**: Avoid vertical lists for secondary stats. Refactor into side-by-side expanded grids using `Row` to maximise space efficiency inside Glassy containers.
6. **Generous Spacing**: Ensure generous gaps between major components using `context.getRSize()` (e.g., a top margin of `getRSize(24)` below the AppBar).

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

## Layout patterns

### `MainLayout` (`lib/shared/widgets/main_layout.dart`)

One root `Scaffold` with a `BottomNavigationBar` (fixed type). The nav bar
is always present in the widget tree even when hidden — it is never removed,
only replaced with `SizedBox.shrink()` so the layout does not shift.

**Visible bottom-bar tabs (5):** Home, POS, Inventory, Orders, Cart.

**Drawer-accessed destinations (not in the bottom bar):** Customers, Payments,
Expenses, Stores, Suppliers, Staff, Reports, Activity Log, Settings, CEO
Settings. These are full tab roots that use the same per-tab `Navigator` and
fade-transition machinery as the bottom-bar tabs — they simply do not appear
in the bar itself.

Each tab keeps its own push stack. Tab switches use a 200ms `easeOut` fade.
Only the landing tab is pre-initialised; other tabs initialise on first visit.

**Landing tab is per role** (`NavigationService.landingTabForRole`): CEO,
Manager and Stock keeper open on Home; Cashier opens on POS. A session starts on
Home — the neutral default, and the only tab never hidden from a nav bar —
because the role has not resolved from local SQLite at login; MainLayout applies
the role's tab once permissions land, once per session. A root-level back press
falls home to that same landing tab.

### App bar

| Property | Value |
|---|---|
| Height | `kToolbarHeight + 12` (≈ 68px at baseline) |
| Elevation | 0 |
| `surfaceTintColor` | `transparent` |
| Title alignment | Left |
| Bottom edge | 1px divider using `dividerColor` |

### `AppDrawer`

| Section | Detail |
|---|---|
| Header | 56×56px logo avatar (radius `AppRadius.md`), role badge, sync status badge |
| Header background | Gradient: `scaffoldBackgroundColor` → `roleAccentColor @ 30% alpha` |
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
`context.deviceBottomPadding` (accounts for the nav bar only). Never use
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
- **Launcher icon follows the device theme where the OS allows it**: Android light icon on `#BEBFC1`, dark icon on `#000000` via `-night` resources, plus a monochrome layer for Android 13+ themed icons; iOS 18 light / dark / tinted icons.
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
