# UI Context — Reebaplus POS Design System

Source of truth for design tokens, components, and layout patterns. Every
colour, radius, spacing, and gradient used in the app maps to a token below.
**Never hardcode a hex value, radius, pixel size, or raw palette constant —
reference the access path.** If a decision is not covered here, ask before
inventing one.

---

## Theme system (read this first)

The app ships **5 selectable design systems** via `ThemeController`
(`lib/core/theme/theme_notifier.dart`): Blue Classic, **Amber (default,
Reebaplus brand)**, Purple Violet, Green Forest, Black & White — each with a
light and dark variant.

Widget code must **never** reference a raw palette constant (`amberPrimary`,
`alBg`, `adSurface`, etc.) directly. Always resolve through one of these
three access paths:

| What you need | Access path |
|---|---|
| Background, surface, primary, secondary, error, text | `Theme.of(context).colorScheme.*` |
| Scaffold bg, divider, card colour | `Theme.of(context).scaffoldBackgroundColor` / `.dividerColor` / `.cardColor` |
| Success, warning, info | `Theme.of(context).extension<AppSemanticColors>()!.success` / `.warning` / `.info` |

This file documents the **Amber** palette as the concrete hex reference.
The same semantic access paths resolve to different hex values under the other
four themes — the access path is the contract, not the hex value.

---

## Colour palette (Amber — default)

| Semantic token | Access path | Light hex | Dark hex | Usage |
|---|---|---|---|---|
| Background | `scaffoldBackgroundColor` | `#F4F6FA` | `#080C12` | App/screen background |
| Surface | `colorScheme.surface` | `#FFFFFF` | `#0E1420` | Cards, app bar, bottom sheets |
| Surface 2 | `cardColor` (dark) / `colorScheme.surfaceContainerHighest` (light) | `#EDF0F5` | `#141B28` | Chips, secondary cards |
| Border / Divider | `dividerColor` | `rgba(0,0,0,0.07)` | `rgba(255,255,255,0.06)` | Dividers, outlines, app-bar bottom border |
| Text primary | `colorScheme.onSurface` | `#0E1420` | `#E8EEF6` | Headings, body text |
| Text secondary | `colorScheme.onSurfaceVariant` | `#4B5563` | `#6B7A90` | Subtext, captions, `bodySmall` / `labelSmall` |
| Primary (brand) | `colorScheme.primary` | `#D97706` | `#F5A623` | Primary buttons, active nav, FAB, focus border |
| Secondary | `colorScheme.secondary` | `#FF7A00` | `#FF7A00` | Gradient end on primary buttons/FAB |
| Primary container | `colorScheme.primaryContainer` | `primary @ 12% opacity` | `primary @ 12% opacity` | Secondary button background |
| Error / Danger | `colorScheme.error` | `#FF3B30` | `#FF3B30` | Error states, danger button text/bg |
| Success | `AppSemanticColors.success` | `#30D158` | `#30D158` | Status badges, banners, notification success |
| Success button | `AppSemanticColors.successButton` | `#43A047` | `#43A047` | `AppButton` / `AppFAB` success-variant gradient base |
| Warning | `AppSemanticColors.warning` | `#FFB020` | `#FFB020` | Warning badges, banners |
| Info | `AppSemanticColors.info` | `#3B82F6` | `#3B82F6` | Info badges, banners |
| Glow | `AppSemanticColors.glow` | `rgba(245,166,35,0.35)` | `rgba(245,166,35,0.35)` | Box-shadow glow on primary buttons/FAB |

> The other four themes (Blue Classic, Purple Violet, Green Forest, Black &
> White) define their own light/dark palette constants in
> `lib/core/theme/colors.dart`. Do not copy their hex values into widget code.
> The access paths above resolve to the active theme automatically.

---

## Gradients

Never construct a `LinearGradient` inline. Use the helpers and access paths
below.

| Gradient | Stops | Direction | Access |
|---|---|---|---|
| Primary surface gradient | `colorScheme.primary.withValues(alpha:0.8)` → `colorScheme.primary` | top-left → bottom-right | `AppDecorations.primaryGradient(context)` |
| Primary button / FAB | `colorScheme.secondary` → `colorScheme.primary` | top-left → bottom-right | Built into `AppButton` primary variant and `AppFAB` |
| Success button | `Color.lerp(AppSemanticColors.successButton, Colors.white, 0.1)` → `AppSemanticColors.successButton` | top-left → bottom-right | Built into `AppButton` / `AppFAB` success variant |
| Disabled button | `Colors.grey.shade400` → `Colors.grey.shade500` | top-left → bottom-right | Built into `AppButton` / `AppFAB` disabled state |
| Amber glow line | `transparent` → `colorScheme.primary` → `transparent` | horizontal, 2px height | `AmberGlowLine` widget |
| Drawer header | `scaffoldBackgroundColor` → `roleAccentColor.withValues(alpha:0.3)` | top-left → bottom-right | Built into `AppDrawer` header; `roleAccentColor` is resolved per role inside `AppDrawer` |

---

## Typography

Font: **DM Sans**, bundled locally in `assets/google_fonts/` (weights 400,
500, 600, 700) via the `google_fonts` package with
`allowRuntimeFetching = false`. It never falls back to a network fetch.

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
If one is ever authorised, reuse `AppSemanticColors.info` (`#3B82F6`) or
`AppSemanticColors.glow` before adding a new token. Do not add a speculative
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
| Primary bg | Secondary → Primary gradient + `AppSemanticColors.glow` shadow |
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
above. Chevron: `FontAwesomeIcons.chevronDown`.

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
raw `SnackBar`. Success variant uses `AppSemanticColors.successButton` to
match `AppButton`'s success gradient.

### `AppDecorations` (`app_decorations.dart`)

| Helper | Returns | Restricted to |
|---|---|---|
| `AppDecorations.primaryGradient(context)` | `BoxDecoration` with primary gradient, radius `AppRadius.sm` | General use |
| `AppDecorations.surfaceCard(context)` | `BoxDecoration` with `colorScheme.surface`, radius `AppRadius.xl` | General use |
| `AppDecorations.glassCard(context)` | Frosted-glass `BoxDecoration` | Auth screens only |
| `AppDecorations.authInputDecoration(context, ...)` | `InputDecoration` with radius `AppRadius.inputAuth` (10px) | Auth / onboarding screens only |

---

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

## Icon library

| Library | Import | When to use |
|---|---|---|
| `font_awesome_flutter` | `FontAwesomeIcons.*` | **Default for all UI icons** — nav items, buttons, chevrons, status icons, action icons |
| Material `Icons` | `Icons.*` | Only for system icons where no FontAwesome equivalent is wired up |
| `cupertino_icons` | — | Bundled dependency only; not used directly in app UI |

Always choose `FontAwesomeIcons` first. Fall back to `Icons` only when
necessary, and note the fallback in a comment.
