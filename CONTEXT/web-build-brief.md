# Reebaplus POS — Web (Chrome) Build & Responsive Redesign Brief

**Audience:** the developer implementing the web target.
**Status:** handoff brief. Read this top to bottom before writing any code.
**Goal in one sentence:** make the existing Flutter POS run correctly in a desktop
Chrome browser, and redesign the UI so every screen is laid out properly for
**desktop**, **tablet**, and **mobile** widths — with the sidebar **always
visible** on desktop.

---

## 0. Read these first (non-negotiable)

This is a mature, spec-driven codebase (149+ sessions). You do **not** get to
invent patterns. Before touching anything, read, in order:

1. `context/project-overview.md` — what the product does
2. `context/architecture.md` — stack, storage model, **Invariants** section
3. `context/ui-context.md` — the design-token system (this is your styling bible)
4. `context/code-standards.md` — naming, widget rules, module boundaries
5. `context/ai-workflow-rules.md` — how work is scoped and delivered
6. `context/progress-tracker.md` — current state; **update it after every unit**

Then read `CLAUDE.md` at the repo root.

**Two house rules that will bite you:**
- This team runs on an **emulator / `flutter run`**, never `flutter build apk`.
  For this task you run **`flutter run -d chrome`**.
- **Never `git checkout` a dirty file** — the repo carries large uncommitted
  trees. To undo, re-edit or stash. Do not run `dart format` globally (house
  style is old dartfmt, unenforced).

---

## 1. What you must NOT change

The web target is **additive**. You are changing *layout* and *platform
plumbing*, not business logic.

- **Do not** change the Drift schema, migrations, DAOs, or sync engine
  (`lib/core/services/`, `lib/core/database/`). The one exception is the
  database *connection factory* (§4.1) — and even there you add a web branch,
  you do not rewrite the existing native one.
- **Do not** touch the **Invariants** in `architecture.md`. Local-first,
  outbox-only writes, append-only ledgers, RLS tenancy, PIN-never-leaves-device,
  permissions-from-data — all still hold on web.
- **Do not** hardcode colours, radii, font sizes, or pixel spacing. Everything
  routes through the token system in `ui-context.md`
  (`Theme.of(context).colorScheme.*`, `AppRadius.*`, `context.getRSize(n)`,
  `Theme.of(context).textTheme.*`, `AppSemanticColors`). The redesign reuses
  these tokens — it does not introduce new raw values.
- **Do not** branch on hard-coded role names. Gating stays
  `ref.watch(permissionsProvider).can(...)` / `hasPermission(ref, '...')`,
  hide-don't-block.
- **Do not** remove the bottom navigation bar. On phone widths it stays. You are
  *adding* a sidebar for wider widths, not replacing the mobile pattern.

---

## 2. The two halves of this job

This task is **two separate workstreams**. Do them in this order and verify each
before moving on (per `ai-workflow-rules.md`: one unit at a time).

**Workstream A — Make it run on web at all (platform plumbing).**
Until this is done, `flutter run -d chrome` will white-screen or crash on
startup. This is pure infrastructure, no UI.

**Workstream B — Responsive UI redesign (desktop / tablet / mobile).**
Only start this once the app actually boots and you can log in on Chrome.

---

## 3. Breakpoints (single source of truth)

The breakpoints already exist in `lib/core/utils/responsive.dart` and are
**canonical** — use them everywhere, do not invent new numbers:

```dart
context.isPhone    // width < 600
context.isTablet   // 600 <= width < 1024
context.isDesktop  // width >= 1024
```

| Form factor | Width      | Navigation                          | Content density               |
|-------------|------------|-------------------------------------|-------------------------------|
| Mobile      | `< 600`    | Bottom nav bar + slide-in drawer    | Single column, as today       |
| Tablet      | `600–1023` | **Collapsed rail** (icons only), tappable to expand | 2-column where it helps |
| Desktop     | `>= 1024`  | **Persistent expanded sidebar (always visible)** | Multi-pane, max content width |

> ⚠️ Note on `getRSize`: it scales off a 375px baseline and is **clamped to
> 1.5×**. That is correct for *type and spacing within a component*, but it does
> **not** create desktop layouts — left alone, a desktop browser just renders a
> giant phone. The redesign's job is to change *layout structure* per breakpoint
> (panes, grids, the sidebar), while still using `getRSize` for in-component
> spacing. Do not try to "fix" desktop by raising the 1.5× cap.

Build a small shared helper widget so screens don't each re-implement the
branching, e.g. `ResponsiveScaffold` / a `ResponsiveLayout(mobile:, tablet:,
desktop:)` builder in `lib/shared/widgets/`. One helper, reused — not a
per-screen `if (context.isDesktop)` ladder copy-pasted 40 times.

---

## 4. Workstream A — Platform plumbing (do this first)

### 4.1 Drift database on web — THE critical blocker

`lib/core/database/app_database.dart` ends with `_openConnection()`, which uses
`NativeDatabase(File(...))` + `path_provider`'s
`getApplicationDocumentsDirectory()`. **None of that exists on web** —
`dart:io`'s `File` and `path_provider` are unsupported, so the app cannot open
its database and will crash on launch.

Drift on web requires the **WASM** path: a `WasmDatabase` backed by
`sqlite3.wasm` + a Drift web worker, persisted via IndexedDB / OPFS.

Do this:
1. Read the official guide: <https://drift.simonbinder.eu/platforms/web/>.
2. Add web assets to `web/`: download the matching `sqlite3.wasm` and
   `drift_worker.js` (versions must match the installed `drift` / `drift_dev`,
   currently `^2.11.0` — confirm against `pubspec.lock`).
3. Split the connection factory using **conditional imports** so native builds
   keep `NativeDatabase` untouched and web gets `WasmDatabase`:
   - `connection/native.dart` — the current `_openConnection()` body.
   - `connection/web.dart` — `WasmDatabase.open(...)` against the wasm asset.
   - `connection/connection.dart` — `export 'native.dart' if (dart.library.js_interop) 'web.dart';`
4. Keep the existing PRAGMA setup where the platform supports it; WASM ignores
   some PRAGMAs — that's expected, don't fight it.

This is the highest-risk item. Get the app to **boot and persist data across a
refresh** in Chrome before doing anything else.

### 4.2 Plugin / package web-compatibility matrix

Audit every plugin. Web-incompatible calls must be guarded behind
`kIsWeb` (from `package:flutter/foundation.dart`) or behind conditional imports
with a no-op/alternative web implementation — **never** let a mobile-only plugin
execute on web.

| Package | Web? | Action |
|---|---|---|
| `print_bluetooth_thermal` | ❌ Android only | Guard with `kIsWeb`. On web, thermal printing is unavailable — fall back to **browser print / PDF / share** for receipts. Do not call the plugin on web. |
| `local_auth` (biometrics) | ❌ | Guard with `kIsWeb`. On web, skip biometric setup; PIN-only unlock. The "BiometricSetup" step must no-op cleanly on web. |
| `permission_handler` | ⚠️ mostly no-op on web | Guard; don't request mobile runtime permissions on web. |
| `path_provider` | ❌ no web | Only used by the DB connection (§4.1) — once that's conditional, confirm no other call site runs on web. |
| `image_picker` | ✅ | Works (file input). Verify the picked-image flow. |
| `file_picker` | ✅ | Works. Verify CSV export/import paths. |
| `share_plus` | ✅ (Web Share API / download) | Works; behaviour differs (download fallback). Verify receipt share. |
| `url_launcher` | ✅ | Works. |
| `connectivity_plus` | ✅ | Works (online/offline only; no connection *type* on web — the adaptive chunk sizing will read a coarse value, which is fine). |
| `google_sign_in` | ⚠️ needs web setup | Web uses `google_sign_in_web`; requires a Google **OAuth client ID** in `web/index.html` as a `<meta name="google-signin-client_id">` (or the newer GIS button). Coordinate the client ID with whoever owns the Supabase/Google project. If not ready, gate Google sign-in off on web and keep **email + OTP** as the web auth path. |
| `flutter_secure_storage` | ⚠️ | Has a web implementation but it is **not** OS-keystore-backed (it's WebCrypto over `localStorage`). The **PIN hash and refresh token live here**. Confirm the web backend is acceptable to the team for storing the PIN hash; surface this as a security note (see §6). Do not silently downgrade the security model without flagging it. |
| `supabase_flutter`, `drift`, `flutter_riverpod`, `intl`, `crypto`, `uuid`, `rxdart`, `font_awesome_flutter`, `google_fonts`, `flutter_svg`, `timezone`, `barcode_widget`, `app_links`, `screenshot` | ✅ | Web-supported. Verify each render path once. |
| `esc_pos_utils_plus` | ✅ pure Dart | Builds ESC/POS bytes fine; just no Bluetooth transport on web. |
| `sqlite3_flutter_libs` | native only | Replaced by `sqlite3.wasm` on web (§4.1). |

Run `flutter pub get` after any pubspec change. If a web-specific package is
needed (e.g. `google_sign_in_web` is usually pulled transitively), add it
explicitly only if the build complains.

### 4.3 `web/index.html` and bootstrap

- Confirm `web/index.html`, `web/manifest.json`, `web/favicon.png`, and
  `web/icons/` exist (they do). Update title/theme-colour to Reebaplus branding
  if placeholder.
- DM Sans is **bundled locally** with `allowRuntimeFetching = false` — confirm
  fonts render on web from `assets/google_fonts/` and do **not** trigger a
  network fetch.
- Add the WASM/worker assets from §4.1 to `web/`.
- Verify `main.dart` startup has no `dart:io` reference on the web path (the
  crash handler, secure storage init, etc.). Guard any `Platform.xxx` checks
  with `kIsWeb` first (`Platform` throws on web).

### 4.4 Workstream A acceptance criteria

- `flutter run -d chrome` boots to the Welcome screen with **no console
  exceptions**.
- You can sign in (email + OTP), reach POS, add a product, ring a sale, and the
  data **survives a full browser refresh** (proves Drift WASM persistence).
- No mobile-only plugin executes on web (no thermal/biometric/permission crash).
- `flutter analyze` is clean.

---

## 5. Workstream B — Responsive UI redesign

Only start once Workstream A passes. The redesign is **layout only** — same
features, same providers, same tokens, restructured for width.

### 5.1 The sidebar (the headline requirement)

Today navigation is a `BottomNavigationBar` in
`lib/shared/widgets/main_layout.dart` plus a slide-in `AppDrawer`
(`lib/shared/widgets/app_drawer.dart`). The bottom bar shows 5 tabs (Home, POS,
Inventory/Stock, Orders, Cart); the drawer holds the rest (Customers, Payments,
Expenses, Stores, Suppliers, Staff, Reports, Activity Log, Settings, CEO
Settings).

Redesign `MainLayout` to be width-aware:

- **Desktop (`>= 1024`): a persistent, always-visible expanded sidebar** down the
  left edge. It must show **all** the destinations the current role is permitted
  to see (the 5 bottom-bar items **and** the drawer destinations), merged into
  one scrollable nav list with labels + icons. It is **not** collapsible away —
  it is always on screen. The bottom nav bar is **hidden** at this width.
- **Tablet (`600–1023`): a `NavigationRail`** (icon-only collapsed rail, always
  visible) that the user can expand to show labels. Bottom bar hidden.
- **Mobile (`< 600`): unchanged** — bottom nav bar + the existing slide-in
  drawer via the hamburger.

Hard requirements that must survive the redesign:
- **Permission gating is identical.** A nav item appears only if the role can
  reach it (`hasPermission` / hide-don't-block). The stock keeper still has no
  POS/Cart; the same `tabOrder` permission logic that drives the bottom bar
  drives the sidebar. Drive the bar AND the sidebar from **one** permitted-
  destinations list so they can never desync.
- **The per-tab `Navigator` / `TabNavigator` machinery stays.** Each destination
  keeps its own push stack and the 200ms fade. The sidebar selects a tab index
  exactly like the bottom bar does today (`nav.setIndex(i)`); tapping the active
  destination pops its stack to root (same as the current bottom-bar behaviour).
- **Badges carry over** — pending-orders count and cart count must render on the
  sidebar/rail items too, using the existing `_pendingOrders` /
  `cartProvider` streams.
- **Active store picker** (`lockedStoreProvider`) and the role/sync header that
  live in `AppDrawer` today need a home in the desktop sidebar (e.g. a header
  block at the top of the sidebar). Reuse `AppDrawer`'s existing header widgets;
  don't rebuild them.

### 5.2 Screen-level responsiveness

Every screen must be reviewed. The two failure modes to kill are: (a) content
stretching edge-to-edge across a 1920px monitor as one giant column, and (b)
fixed-width mobile cards overflowing or looking lost in whitespace.

General rules:
- **Cap content width.** On desktop, constrain primary content with a
  `max-width` (e.g. a centered `ConstrainedBox`/`Center` around the body) so text
  columns and forms don't sprawl across an ultra-wide monitor. Full-bleed is for
  grids and tables only.
- **Grids reflow by available width**, not a fixed cross-axis count. POS product
  grid, inventory grid, receive-stock grid, customer cards, etc. should use
  `SliverGridDelegateWithMaxCrossAxisExtent` (target a tile width) so columns
  grow with the window instead of a hardcoded `crossAxisCount`. Honour the
  existing overflow-avoidance rules in `ui-context.md` ("Responsive Grid & Card
  Layouts" — flexible visual area, intrinsic-height text).
- **Use the width you gain.** Key two-pane opportunities on desktop/tablet
  (optional but strongly encouraged where it reduces navigation):
  - **POS:** product grid on the left, **cart pinned as a right-hand pane**
    instead of a separate tab. (Keep the Cart tab for mobile.)
  - **Inventory / Customers / Orders / Suppliers:** master list on the left,
    **detail pane on the right** instead of a full push navigation, on desktop.
  - **Reports / Reconciliation:** wider tables, side-by-side stat grids
    (the "Grid-Like Stats Layouts" standard already in `ui-context.md`).
  These are layout reshapes of existing screens, not new features. If a two-pane
  reshape is large, ship the sidebar + width-capping + reflowing grids first and
  log the two-pane work as a follow-up unit in `progress-tracker.md`.
- **Modals & bottom sheets:** on desktop a full-width bottom sheet looks wrong.
  Render sheets as **centered dialogs / side panels** at tablet+ widths, keep
  bottom sheets on mobile. Wrap the existing sheet content; don't rewrite it.
- **Keep the glassy design language** (`ui-context.md` "Glassy & Modernistic UI
  Standard") — gradient backgrounds via `AppDecorations.glassyBackground`,
  scroll-reactive app bars, glassy cards. The redesign is responsive *and*
  on-brand, not a plain Material rework.

### 5.3 Web input affordances

- **Hover & cursor:** interactive elements should show pointer cursors and hover
  states on web (Flutter gives most of this free via `InkWell`/`MouseRegion`;
  verify custom tap targets).
- **Keyboard:** the POS is keyboard-heavy on desktop. At minimum, search fields
  autofocus where sensible and `Enter` submits forms/dialogs. Full keyboard-
  shortcut design is out of scope unless asked — but don't break tab-order.
- **Scrolling:** ensure long screens scroll with mouse wheel and that no fixed
  footer overlaps content at short window heights.

### 5.4 Workstream B acceptance criteria

- Resizing the Chrome window from ~360px to ~1920px continuously reflows with no
  overflow (yellow/black stripes), no clipped text, no horizontal scrollbar.
- At `>= 1024`, the sidebar is **always visible** and lists every
  permission-allowed destination; the bottom bar is gone.
- At `600–1023`, a navigation rail is visible; bottom bar gone.
- At `< 600`, the app is visually unchanged from today (bottom bar + drawer).
- Permission gating, badges, active-store picker, and per-tab navigation all
  behave exactly as before at every width.
- Tested in Chrome at phone (responsive devtools), tablet, and desktop widths.
- `flutter analyze` clean; `flutter test` green.

---

## 6. Things to surface, not silently decide

Per `ai-workflow-rules.md`, when something is ambiguous you **log it in
`progress-tracker.md` and flag it** — you do not invent product behaviour.
Expect to raise at least these:

1. **PIN hash on web.** `flutter_secure_storage` on web is WebCrypto over
   `localStorage`, not an OS keystore. The architecture says "PINs never leave
   the device" — they still don't, but the at-rest protection is weaker in a
   browser. Confirm the team accepts this for the web target.
2. **Google sign-in on web** needs an OAuth client ID wired into `index.html`.
   If it's not available, ship email+OTP on web and defer Google.
3. **Thermal receipt printing** has no web equivalent. Confirm the web receipt
   path (browser print / PDF / share) is acceptable for v1.
4. **Two-pane reshapes** (POS cart pane, master-detail) — confirm scope: full
   redesign now, or sidebar + reflow now and panes as a fast-follow.

---

## 7. Suggested unit sequence (each is one verifiable increment)

1. Drift WASM connection (conditional import) → app boots & persists on Chrome.
2. Plugin web-guards (`kIsWeb`) → no mobile-only plugin runs on web; login →
   sale works end to end on Chrome.
3. `ResponsiveLayout` helper + breakpoint plumbing (no visual change yet).
4. `MainLayout` sidebar/rail/bottom-bar switch (the headline nav change).
5. Width-capping + grid reflow pass across the high-traffic screens
   (POS, Inventory, Orders, Customers, Reports).
6. Modals → dialogs/side-panels at tablet+.
7. Polish: hover/cursor/keyboard, receipt web fallback, final QA at all widths.

After **each** unit: `flutter analyze` clean, relevant tests green, update
`progress-tracker.md`, and (per house rule) add a dated `BUILD_LOG.md` entry for
any verified fix. Do not start the next unit until the current one is verified
end-to-end on Chrome.

---

## 8. Definition of done

- `flutter run -d chrome` runs the full app: onboarding, login, POS, cart,
  checkout, inventory, receive stock, customers, orders, reports — all usable in
  a desktop browser, with data persisting across refresh.
- Sidebar always visible on desktop; rail on tablet; bottom bar on mobile —
  all permission-gated and badge-accurate.
- No raw tokens introduced; all Invariants intact; sync/schema/DAOs untouched
  except the conditional DB connection.
- `flutter analyze` clean, `flutter test` green, `progress-tracker.md` and
  `BUILD_LOG.md` updated.
- Open questions from §6 logged and answered (or explicitly deferred) before
  sign-off.
</content>
</invoke>
