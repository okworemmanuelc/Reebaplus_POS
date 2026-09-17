# Reebaplus POS — Codebase Map

A browsable reference for the app. Every entry here was read out of the code, not guessed. Jump to any screen in any order.

> **Terminology note:** the first time a Flutter or Dart word appears, it is defined in one plain sentence. If you hit a word you don't recognise, check the [Glossary](#glossary).

---

## Table of contents

**Part A — Understanding the app**
- [A1. What this app is](#a1-what-this-app-is)
- [A2. State management: what the app actually uses](#a2-state-management-what-the-app-actually-uses)
- [A3. Navigation: three layers](#a3-navigation-three-layers)
- [A4. Folder structure](#a4-folder-structure)
- [A5. The data layer (offline-first)](#a5-the-data-layer-offline-first)
- [A6. Permissions: the Gate system](#a6-permissions-the-gate-system)
- [A7. Theming and shared shells](#a7-theming-and-shared-shells)
- [A8. JS-to-Flutter concept bridge](#a8-js-to-flutter-concept-bridge)
- [Glossary](#glossary)

**Part B — Screen reference**
- [B1. App shell and root routing](#b1-app-shell-and-root-routing)
- [B2. Auth and onboarding](#b2-auth-and-onboarding)
- [B3. POS, cart and checkout](#b3-pos-cart-and-checkout)
- [B4. Orders](#b4-orders)
- [B5. Inventory](#b5-inventory)
- [B6. Receiving stock](#b6-receiving-stock)
- [B7. Dashboard and reports](#b7-dashboard-and-reports)
- [B8. Customers](#b8-customers)
- [B9. Expenses](#b9-expenses)
- [B10. Suppliers and payments](#b10-suppliers-and-payments)
- [B11. Van sales](#b11-van-sales)
- [B12. Staff](#b12-staff)
- [B13. Stores and transfers](#b13-stores-and-transfers)
- [B14. Settings](#b14-settings)
- [B15. Sync, diagnostics and subscription](#b15-sync-diagnostics-and-subscription)
- [B16. Shared widgets you will see everywhere](#b16-shared-widgets-you-will-see-everywhere)

**Part C — Reading the code critically**
- [C1. Non-idiomatic patterns in this codebase](#c1-non-idiomatic-patterns-in-this-codebase)

**Companion:** [LEARNING_ROADMAP.md](LEARNING_ROADMAP.md) — the suggested order to learn this material.

---

# Part A — Understanding the app

## A1. What this app is

Reebaplus POS is an **offline-first point-of-sale app** for drink retailers and similar shops in Nigeria. It runs on Android (shipped to Play Store as `com.reebaplus.pos`), and the same business data also has a separate web client in another repo.

Three facts shape almost every design decision in the code:

1. **It works with no internet.** Every read comes from a local SQLite database on the phone. Writes go to SQLite first, then get pushed to the cloud later by a background queue. The app never blocks on the network to open.
2. **It is multi-tenant and multi-user.** One phone can be a shared till used by several staff. Every row of data belongs to a `businessId`, and what you can see or do depends on your role.
3. **It tracks money precisely.** All money is stored as integer **kobo** (1/100 of a Naira), never floating-point Naira, so rounding can't lose money.

Scale, for context: ~295 Dart files under `lib/`, 66 database tables, 48 database accessors, 258 test files.

---

## A2. State management: what the app actually uses

> **State** = data your app holds in memory that, when it changes, should update the screen.

The headline answer is **Riverpod**. But being honest about this codebase: it uses **four** state mechanisms side by side, and knowing which is which will save you a lot of confusion.

### 1. Riverpod (the primary system)

Riverpod is a package that stores state in global objects called **providers**, which widgets subscribe to. The package is `flutter_riverpod`.

The whole app is wrapped in a `ProviderScope` in [main.dart:117](../lib/main.dart#L117) — that's the container that holds every provider's value.

Widgets that want to use providers extend `ConsumerWidget` or `ConsumerStatefulWidget` instead of the plain `StatelessWidget`/`StatefulWidget`. That gives them a `ref` object with three methods:

| Call | What it does | JS analogy |
|---|---|---|
| `ref.watch(p)` | Subscribe. When `p` changes, this widget rebuilds. | `useSelector` / subscribing to a store |
| `ref.read(p)` | Read once, no subscription. Use inside callbacks like `onPressed`. | `store.getState()` |
| `ref.listen(p, cb)` | Run a side effect on change without rebuilding. | `useEffect` on a dependency |

Providers live in two files, and they are big:
- [lib/core/providers/app_providers.dart](../lib/core/providers/app_providers.dart) — ~60 providers: services, the database handle, the auth service, the cart.
- [lib/core/providers/stream_providers.dart](../lib/core/providers/stream_providers.dart) — 113 providers, mostly live database queries (2,317 lines).

**The most important custom rule in this codebase:** business-scoped data must use the helpers in [business_scoped_stream.dart](../lib/core/providers/business_scoped_stream.dart) (`businessScopedStream`, `businessScopedStreamFamily`, `businessScopedStreamAutoDispose`) — never a raw `StreamProvider`. A raw one can be built before a user is logged in and then read another tenant's data or crash. There is a test that fails the build if you use a raw one.

### 2. `ChangeNotifier` services

> **ChangeNotifier** = a plain Dart object that can shout "I changed!" to anyone listening.

Several long-lived services are `ChangeNotifier`s exposed through Riverpod's `ChangeNotifierProvider`:

- `AuthService` ([lib/shared/services/auth_service.dart](../lib/shared/services/auth_service.dart)) — who is logged in
- `CartService` ([lib/shared/services/cart_service.dart](../lib/shared/services/cart_service.dart)) — the POS cart
- `ThemeController`, `NotificationService`, `ActivityLogService`, `CustomerService`, `SupplierService`

### 3. `ValueNotifier` + a singleton

`NavigationService` ([lib/shared/services/navigation_service.dart](../lib/shared/services/navigation_service.dart)) is a hand-rolled singleton holding `ValueNotifier`s (`currentIndex`, `lockedStoreId`, `currentTabCanPop`). A `ValueNotifier` is a ChangeNotifier that holds exactly one value.

Because these sit outside Riverpod, the codebase has a bridge called `mirrorNotifier<T>` ([mirror_notifier.dart](../lib/core/providers/mirror_notifier.dart)) that exposes a notifier's value as a Riverpod provider — that's what `lockedStoreProvider` and `currentIndexProvider` are.

> ⚠️ There's a rule attached: never return a service-owned notifier from a `ChangeNotifierProvider`, because Riverpod would dispose an object the service still owns. Use `mirrorNotifier` instead. A test enforces this.

### 4. `setState` (local widget state)

`setState` is Flutter's built-in "this one widget's data changed, rebuild it". It's used heavily for form fields, expanded/collapsed toggles, and loading flags — e.g. 47 calls in `staff_sign_up_screen.dart`.

### How to tell which one you're looking at

| You see… | It is… |
|---|---|
| `ref.watch(...)` | Riverpod |
| `setState(() => ...)` | Local widget state |
| `ListenableBuilder` / `ValueListenableBuilder` | A ChangeNotifier/ValueNotifier |
| `nav.currentIndex.value = 2` | The NavigationService singleton |

---

## A3. Navigation: three layers

There is **no route table and no URL routing** in this app (no `go_router`, no named routes map). Navigation happens on three layers.

### Layer 1 — The root router decides which "world" you're in

[`_HomeRouter`](../lib/main.dart#L632) in [main.dart](../lib/main.dart) is a `ConsumerWidget` whose `_resolve()` method is a priority-ordered chain of `if` statements. It picks exactly one root screen based on app state:

```
_resolve() checks, in this order:
  user == null?
    ├─ still reading storage        → _BrandedSplash
    ├─ no device user               → WelcomeScreen
    └─ otherwise (incl. locked)     → LoginScreen (PIN)
  no Supabase session?              → _SessionExpiredScreen
  local business query not resolved?→ _BrandedSplash
  a pending post-login route?       → SuccessDashboardEntryScreen / AccessGrantedScreen
  subscription locked?              → SubscriptionLockedScreen
  just subscribed?                  → ThankYouSubscriptionScreen
  user is a driver?                 → DriverTerminalScreen
  otherwise                         → MainLayout
```

The result is wrapped in an `AnimatedSwitcher` so swaps fade rather than snap.

> This is why a driver never sees the shop: they get a completely different screen, not a hidden-widgets version of the normal one.

### Layer 2 — MainLayout: 10 tabs, each with its own navigator

[`MainLayout`](../lib/shared/widgets/main_layout.dart) is the logged-in shell. It holds **10 tabs**, each wrapped in its own `TabNavigator` (its own independent navigation stack):

| Index | Screen | Index | Screen |
|---|---|---|---|
| 0 | `HomeScreen` (dashboard) | 5 | `PaymentsScreen` (suppliers) |
| 1 | `PosHomeScreen` | 6 | `ExpensesScreen` |
| 2 | `InventoryScreen` | 7 | `StoresScreen` |
| 3 | `OrdersScreen` | 8 | `CartScreen` |
| 4 | `CustomersScreen` | 9 | `ActivityLogScreen` |

Key behaviours:
- Tabs are kept alive with `Offstage` (rendered but hidden) rather than destroyed, so switching tabs doesn't lose scroll position or reload data.
- Only the landing tab builds at startup; the rest are warmed **one per frame** by `_warmNextTab()` so cold start stays fast.
- The bottom bar shows only 5 of the 10 tabs (Home, Stock, POS, Orders, Cart), and Stock/POS/Cart are hidden entirely if your role lacks the permission.
- Pushing a detail screen inside a tab **hides the bottom bar**, tracked by `_TabPopObserver`.

The other 5 tabs are reached from the drawer (side menu).

### Layer 3 — Imperative pushes

Inside a tab, screens navigate the classic Flutter way:

```dart
Navigator.of(context).push(
  MaterialPageRoute(builder: (_) => ProductDetailScreen(product: p)),
);
```

Modals use `showModalBottomSheet(...)` and dialogs use `showDialog(...)`.

The drawer ([app_drawer.dart](../lib/shared/widgets/app_drawer.dart)) does both: `_navigateTo()` switches tabs via `nav.setIndex(n)`, while `_pushRoute()` pushes a full screen.

---

## A4. Folder structure

```
lib/
├── main.dart                  App entry, bootstrap, root router
├── core/                      App-wide infrastructure
│   ├── database/              Drift (SQLite) schema + 48 DAOs
│   ├── providers/             Riverpod providers (app + stream)
│   ├── permissions/           The Gate registry
│   ├── theme/                 Colours, typography, 5 accent themes
│   ├── services/              Sync, crash reporting, images
│   ├── settings/              CEO settings screens
│   ├── utils/                 Formatting, responsive helpers
│   └── widgets/               FABs, badges
├── shared/                    Reusable across features
│   ├── widgets/               MainLayout, AppDrawer, scaffolds, buttons
│   ├── services/              AuthService, CartService, PrinterService…
│   └── utils/
└── features/                  One folder per business domain
    ├── auth/  pos/  inventory/  receiving/  orders/  customers/
    ├── van_sales/  dashboard/  staff/  stores/  payments/
    ├── expenses/  sync/  profile/  subscription/  settings/  diagnostics/
```

Inside a feature you'll typically see `screens/`, `widgets/`, and sometimes `data/`, `services/`, `state/`, `controllers/`.

**Where to look for a thing:**

| Looking for… | Go to |
|---|---|
| A screen | `lib/features/<domain>/screens/` |
| A database query | `lib/core/database/daos_*.dart` |
| A live data provider | `lib/core/providers/stream_providers.dart` |
| A permission check | `lib/core/permissions/gate_registry.dart` |
| A colour or text style | `lib/core/theme/` |

---

## A5. The data layer (offline-first)

This is the part most different from a typical web app, so it's worth understanding early.

### Local database: Drift

**Drift** is a type-safe SQLite wrapper for Dart. You declare tables as Dart classes and Drift generates the query code.

- Schema: [lib/core/database/app_database.dart](../lib/core/database/app_database.dart) — 66 tables, currently **schema version 81**.
- Generated code: `app_database.g.dart` — **never edit this by hand**; it's regenerated by `build_runner`.
- Queries live in **DAOs** (Data Access Objects) split by domain: `daos_orders.dart`, `daos_inventory.dart`, `daos_van_sales.dart`, etc.

A DAO method usually returns either a `Future` (one-shot read) or a `Stream` (live — re-emits whenever the underlying table changes). The `Stream` ones are what make the UI update automatically after a write.

### Cloud: Supabase

Supabase (hosted Postgres + auth) is initialised in [main.dart:88](../lib/main.dart#L88). Notably it's started **without `await`** — fire-and-forget — so a slow network never delays app startup. Screens that need it await a shared `supabaseReady` future.

### The sync loop

Writes don't go straight to the cloud. The pattern is:

```
User action → write to SQLite → append a row to the sync_queue (outbox)
                                        ↓
                     background push, retried with backoff
                                        ↓
                                    Supabase
                                        ↓
                  pull (+ realtime) → write back into SQLite → UI updates
```

Failures are visible to the user rather than silent — that's what the [Sync Issues screen](#sync-issues) is for.

### Money

All money columns are integer **kobo** and named `..._kobo`. Format for display with `formatCurrency()` from `lib/core/utils/number_format.dart` — never hardcode `₦`, because the currency symbol is a business setting.

---

## A6. Permissions: the Gate system

Rather than scattering `if (user.role == 'ceo')` checks, this app has a **named gate registry** at [lib/core/permissions/gate_registry.dart](../lib/core/permissions/gate_registry.dart) (~50 gates).

```dart
Gates.makeSale.allows(ref)      // → bool, can this user sell?
Guarded.screen(                  // → full-screen guard for a route
  gate: Gates.makeSale,
  builder: _buildPos,
)
```

`Guarded.screen` does something subtle and worth copying: it **waits for permissions to resolve** before deciding, so a user who *is* allowed never sees "no access" flash while their grants load.

Roles are tiered: CEO (0) → Manager (1) → Cashier (2) → Stock keeper (3), plus Driver (4). Display order always follows tier, never alphabetical.

The house rule (referred to in comments as "hard rule #7") is **hide what the role can't use** — so gates control whether nav items and tabs even exist, not just whether buttons are disabled.

---

## A7. Theming and shared shells

- **5 accent themes** (blue, purple, amber, green, black/white) × light/dark, all defined in [app_theme.dart](../lib/core/theme/app_theme.dart) (1,819 lines). The CEO picks the business accent; it syncs to every device.
- Font is DM Sans, bundled locally — network font fetching is disabled so the app works offline.
- OS font scaling is capped at 1.3× in [main.dart](../lib/main.dart#L400) so accessibility settings can't break dense POS layouts.

Three scaffold wrappers you'll see constantly (a **Scaffold** is Flutter's standard page skeleton — app bar, body, FAB, drawer):

| Wrapper | Use | File |
|---|---|---|
| `SharedScaffold` | Tab-root screens; auto-attaches the drawer + menu button | [shared_scaffold.dart](../lib/shared/widgets/shared_scaffold.dart) |
| `GlassyScaffold` | Settings/hub pages; gradient background, scroll-reactive app bar | [glassy_scaffold.dart](../lib/shared/widgets/glassy_scaffold.dart) |
| `Scaffold` | Plain Flutter, for pushed detail pages | Flutter SDK |

> ⚠️ Gotcha recorded in the codebase: `BoxDecoration.color` is ignored when a `gradient` is set. Use `AppDecorations.glassyBackground(context)` for page backgrounds.

---

## A8. JS-to-Flutter concept bridge

Grounded in what this codebase actually uses.

| You know (JS/React) | Here it's | Where to see it |
|---|---|---|
| Component | **Widget** | Every `class X extends StatelessWidget` |
| JSX return | **`build()` method** returning a widget tree | Every screen |
| Function component (no state) | `StatelessWidget` | [coming_soon_screen.dart](../lib/features/auth/screens/coming_soon_screen.dart) |
| Component with `useState` | `StatefulWidget` + `setState` | [pos_home_screen.dart](../lib/features/pos/screens/pos_home_screen.dart) |
| Component reading a store | `ConsumerWidget` + `ref.watch` | [payments_screen.dart](../lib/features/payments/screens/payments_screen.dart) |
| `npm` / `package.json` | `pub` / `pubspec.yaml` | [pubspec.yaml](../pubspec.yaml) |
| `node_modules` | `.dart_tool/` + pub cache | — |
| `Promise` | **`Future`** | `Future<void> _save() async {...}` |
| `async/await` | `async/await` (same) | Everywhere |
| `Promise.then().catch()` | `.then().catchError()` | [main.dart:92](../lib/main.dart#L92) |
| `Observable` / event stream | **`Stream`** | `watchPendingOrders()` |
| `useEffect(fn, [])` | `initState()` | Any `ConsumerState` |
| `useEffect` cleanup | `dispose()` | Any `ConsumerState` |
| Redux store / Zustand | **Riverpod provider** | `lib/core/providers/` |
| `useSelector` | `ref.watch` | Everywhere |
| `useEffect` on state change | `ref.listen` | [main.dart:350](../lib/main.dart#L350) |
| Context provider at root | `ProviderScope` | [main.dart:117](../lib/main.dart#L117) |
| `react-router` | `Navigator` + `MaterialPageRoute` | Everywhere |
| Route guard / middleware | `Guarded.screen(gate: ...)` | [guarded.dart](../lib/core/permissions/guarded.dart) |
| CSS / styled-components | `ThemeData`, `TextStyle`, `BoxDecoration` | `lib/core/theme/` |
| CSS media query | `context.isDesktop`, `getRSize()` | `lib/core/utils/responsive.dart` |
| `localStorage` | `shared_preferences` | View prefs, UI hints |
| Encrypted storage | `flutter_secure_storage` | `SecureStorageService` |
| IndexedDB / SQLite | **Drift** | `lib/core/database/` |
| Prisma / TypeORM | **Drift DAOs** | `daos_*.dart` |
| `null` checks / `?.` | **Sound null safety**: `String?`, `?.`, `??`, `!` | Everywhere |
| `undefined` | Doesn't exist — only `null` | — |
| `const` object | `const` widget (compile-time, cached) | `const SizedBox(height: 16)` |
| Hot Module Replacement | **Hot reload** (`r`) / **hot restart** (`R`) | — |
| `console.log` | `debugPrint()` | — |
| Error boundary | `ErrorWidget.builder` + `CrashReporter` | [main.dart:68](../lib/main.dart#L68) |

**Three Dart things with no clean JS analogue:**

1. **Named + required parameters.** `AppButton(text: 'Save', onPressed: _save)` — order doesn't matter, and `required` is compile-time enforced.
2. **`const` constructors.** A `const` widget is built once and reused forever. That's why you see `const` everywhere — it's a real performance tool, not style.
3. **Everything is a widget.** Padding is a widget (`Padding`), centring is a widget (`Center`), even spacing is a widget (`SizedBox`). There is no stylesheet layer.

---

## Glossary

Defined once, in the order you'll likely meet them.

- **Widget** — the basic UI building block; every visual thing is one.
- **`build()`** — the method returning a widget's UI; called on every rebuild.
- **`BuildContext`** — a handle to a widget's position in the tree; used to look up theme, navigator, screen size.
- **StatelessWidget** — a widget with no changing data of its own.
- **StatefulWidget** — a widget with data that changes; its data lives in a companion `State` class.
- **`setState()`** — tells Flutter "my data changed, rebuild me".
- **`initState()` / `dispose()`** — run once when a stateful widget is created / destroyed.
- **Provider (Riverpod)** — a globally readable, subscribable piece of state.
- **`ref`** — the object giving a widget access to providers.
- **`AsyncValue`** — Riverpod's wrapper for async data: `loading`, `data`, or `error`.
- **`Future`** — a value that arrives later (a Promise).
- **`Stream`** — a sequence of values over time (an Observable).
- **`StreamSubscription`** — an active listener on a Stream; must be cancelled in `dispose()`.
- **Scaffold** — the standard page skeleton (app bar, body, FAB, drawer).
- **`Navigator`** — the stack that pushes/pops screens.
- **`MaterialPageRoute`** — one screen on that stack, with a platform transition.
- **Sliver** — a scrollable region that can do fancy things (collapsing headers, sticky tab bars).
- **DAO** — Data Access Object; a class holding queries for a group of tables.
- **Drift** — the SQLite library; generates `.g.dart` files.
- **kobo** — 1/100 Naira; all money is stored as integer kobo.
- **Gate** — a named permission check (`Gates.makeSale`).
- **Hot reload** — inject code changes into the running app, keeping state.
- **Hot restart** — restart from `main()`, losing state.

---

# Part B — Screen reference

**How to read an entry:** *Purpose* is one line on what the user does here. *Widget tree* shows meaningful structure only, not every widget. *State* is what data the screen holds or watches. *Functions* are the screen's own methods in plain English. *Navigation* is in/out. *Notes* flags anything worth knowing, including code that works but isn't how a Flutter developer would normally write it.

---

## B1. App shell and root routing

### main.dart — bootstrap
**File:** [lib/main.dart](../lib/main.dart) (778 lines)

**Purpose:** Starts the app: crash handling, database, Supabase, theme, then hands off to the root router.

**Startup order** (`_bootstrap()`, line 62) — the order matters:
1. `runZonedGuarded` wraps everything so uncaught async errors are logged, not fatal.
2. `CrashReporter.install()` + replace Flutter's red error box with a friendly `ErrorFallback`.
3. Initialise timezones.
4. Disable Google Fonts network fetching (offline safety).
5. `wipeLegacyDatabaseIfPresent()` — **must** run before anything touches the database.
6. Start Supabase **without awaiting** (fire-and-forget).
7. Warm the SQLite file with `SELECT 1`, 5-second timeout.
8. If the schema self-audit found unhealable drift → boot `SchemaErrorScreen` and stop.
9. Load theme, migrate old auth data to encrypted storage.
10. `runApp(ProviderScope(child: ReebaplusPosApp()))`.

**`_ReebaplusPosAppState` functions:**
- `_checkDeviceUser()` — reads the saved device user; also counts staff on this device to decide whether cold start goes to the PIN screen or the staff picker.
- `_subscribeToSupabaseAuth()` — watches for the cloud session appearing/disappearing; logs a breadcrumb when a session is lost.
- `_onAuthChanged()` / `_onDeviceUserChanged()` — regenerate the navigator key so the whole route stack resets on login/logout.
- `_handleSelfRemoved()` — runs the full offboarding when an admin removes you from another device.
- A 60-second timer refreshes subscription badges and re-pulls the business row.

**Notes:** The Supabase anon key is hardcoded at line 91. That's **intentional and safe** — it's a client-public key protected by row-level security, not a secret.

---

### `_HomeRouter` — the root router
**File:** [lib/main.dart:632](../lib/main.dart#L632)

**Purpose:** Decides which single screen represents the app's current state.

**Widget tree:** `AnimatedSwitcher` → `KeyedSubtree` → whichever screen `_resolve()` returned.

**Functions:** `_resolve()` — the priority chain documented in [A3](#a3-navigation-three-layers).

**Notes:** Good example of **state-driven routing** — no route strings, just data deciding what renders. Also note the deliberate rule in the comments: the app **never** blocks opening on a network pull.

---

### MainLayout — the logged-in shell
**File:** [lib/shared/widgets/main_layout.dart](../lib/shared/widgets/main_layout.dart) (517 lines)

**Purpose:** The tabbed shell holding all 10 main screens plus the bottom navigation bar.

**Widget tree:**
```
PopScope (intercepts the Android back button)
└── ValueListenableBuilder<int>  (rebuilds on tab change)
    └── Scaffold
        ├── body: Stack
        │   ├── 10 × Offstage → TickerMode → TabNavigator(rootScreen)
        │   └── Positioned.fill → SyncPullBanner
        ├── drawer / side rail: AppDrawer  (a Row on desktop widths)
        └── bottomNavigationBar: BottomNavigationBar (5 visible items)
```

**State:** 10 navigator keys; `_initializedTabs` (which tabs have mounted); `_pendingOrders` from a manual stream subscription; watches `lockedStoreProvider`, `selectableStoresProvider`, `Gates.makeSale`, `Gates.viewInventory`.

**Functions:**
- `_warmNextTab()` — mounts one not-yet-built tab per frame after first paint, so the first tap on any tab is instant.
- `_onTabIndexChanged()` — drives the fade animation between tabs.
- `_getActiveRoute(index)` — maps tab index to the route name the drawer highlights.
- `_TabPopObserver` — counts only `PageRoute`s (not popups) so opening a dropdown doesn't flicker the bottom bar away.

**Navigation:** Rendered by `_HomeRouter`. Every tab screen lives inside it.

**Notes:**
- Two defensive redirects run inside `build()` via `addPostFrameCallback`: default the active store, and bounce a non-seller off the POS/Cart tabs. Scheduling to post-frame is correct (you must not mutate state during a build) — but doing state correction inside `build()` at all is a smell; this logic would normally sit in a controller.
- `_pendingOrdersSub` is a **manual `StreamSubscription`** where a `StreamProvider` would be more idiomatic. See [C1](#c1-non-idiomatic-patterns-in-this-codebase).

---

### AppDrawer — the side menu
**File:** [lib/shared/widgets/app_drawer.dart](../lib/shared/widgets/app_drawer.dart) (906 lines)

**Purpose:** The side menu: profile header, permission-filtered navigation, and log out.

**Widget tree:** `Drawer` (phone) or plain `Container` (desktop rail) → `Column` → `_buildHeader` (avatar, name, role tag, subscription badge, store picker) + `Expanded(_buildNavList)`.

**Every item is gated.** The full list, with its gate:

| Item | Gate | Action |
|---|---|---|
| Dashboard | — | tab 0 |
| Point of Sale | `makeSale` | tab 1 |
| Stock | `viewInventory` | tab 2 |
| Orders | — | tab 3 |
| Customers | `viewCustomers` | tab 4 |
| Staff | `manageStaff` | push `StaffManagementScreen` |
| Supplier accounts | `manageSuppliers` | tab 5 |
| Expenses | `viewExpenses` | tab 6 |
| Stores | `viewStores` | tab 7 |
| Van sales | `vanManage` | push `VanSalesHubScreen` |
| Activity logs | `viewActivityLogs` | tab 9 |
| Settings | `manageSettings` | push `SettingsScreen` |
| Sync issues | `viewSyncIssues` | push `SyncIssuesScreen` |
| Display | — | push `ThemeSettingsScreen` |

**Functions:**
- `_pushRoute(context, ref, screen)` — closes the drawer then pushes; on desktop it pushes into the active tab's navigator instead.
- `_navigateTo(context, ref, route)` — switches tabs by name.
- Logout — confirms, and warns differently if you're the sole user (data will be erased).

**Notes:** `ref.watch` (not `read`) on the auth provider is deliberate — the drawer can still be mounted mid-logout, and watching lets it rebuild before its business-scoped streams throw.

---

## B2. Auth and onboarding

The auth flow has two entry paths and they're worth seeing as a map:

```
Fresh install → WelcomeScreen
                 ├── "Create a business" → CeoSignUpScreen (9 steps) ──┐
                 └── "Sign in"           → EmailEntryScreen            │
                                              ↓ (OTP)                  │
                                          OtpVerificationScreen        │
                                              ↓ decides route          │
              ┌───────────────┬───────────────┼──────────────┐         │
        ExistingAccount   NoAccountFound   LoginScreen   CreatePin ←───┘
                                                              ↓
                                                    BiometricSetupScreen
                                                              ↓
                              AccessGranted / SuccessDashboardEntry → MainLayout

Returning device → LoginScreen (PIN) — another staff member uses "Not you? Switch account"
```

---

### WelcomeScreen
**Purpose:** First screen on a fresh install or after full logout; branded entry with the main call-to-actions.
**File:** [lib/features/auth/screens/welcome_screen.dart](../lib/features/auth/screens/welcome_screen.dart) (233 lines)

**Widget tree:** `Scaffold` → `BrandedAuthBackground` → `SafeArea` → `Column` → `_WelcomeLogo`, headline `Text`, two `AppButton`s, `_SignInLink`, `_SmallPrint`.

**State:** `StatefulWidget` with an `AnimationController` for the entrance fade. No providers.

**Functions:**
- `_push(Widget page)` — pushes a page with a fade transition.
- `_SmallPrint._openPlaceholder(context, title)` — opens `ComingSoonScreen` for Terms / Privacy.

**Navigation:** From `_HomeRouter` when no device user exists. Leads to `CeoSignUpScreen`, `StaffSignUpScreen`, `EmailEntryScreen`.

**Notes:** Clean and idiomatic — small private widgets (`_SignInLink`, `_WelcomeLogo`), animation properly disposed. Good first screen to read.

---

### EmailEntryScreen
**Purpose:** Collects an email address and decides where the user goes next.
**File:** [lib/features/auth/screens/email_entry_screen.dart](../lib/features/auth/screens/email_entry_screen.dart) (534 lines)

**Widget tree:** `BrandedAuthBackground` → `AuthFormShell` → email `AppInput` → `AuthErrorText` → `AppButton` → Google sign-in button.

**State:** `_emailController`, `_isValid`, `_loading`, `_error`. Reads `authProvider`, `databaseProvider`.

**Functions:**
- `_checkDeviceAuthenticatedUsers()` — on load, checks whether this device already has signed-in users (offers a shortcut to PIN).
- `_validateEmail()` — live format check driving the button's enabled state.
- `_signInWithGoogle()` — full Google OAuth flow via Supabase.
- `_submit()` — sends the OTP and routes onward.
- `_goToPinDirectly()` — skips to PIN for a known device user.

**Navigation:** From `WelcomeScreen`. Leads to `OtpVerificationScreen`, or straight to `LoginScreen`.

---

### OtpVerificationScreen
**Purpose:** Six-digit email code entry that establishes the cloud session.
**File:** [lib/features/auth/screens/otp_verification_screen.dart](../lib/features/auth/screens/otp_verification_screen.dart) (426 lines)

**Widget tree:** `BrandedAuthBackground` → `AuthCenteredScroll` → title/subtitle with masked email → `OtpBoxRow` (6 boxes driven by one hidden field) → resend countdown → `AppButton`.

**State:** OTP text, `_resendSeconds`, lockout countdown, `_loading`, `_error`. Reads `authProvider`.

**Functions:**
- `_submit()` — verifies the code, then decides the post-verify route (`ExistingAccountRoute`, `NoAccountFoundRoute`, `LoginRoute`, `CreatePinRoute` — see [auth_post_verify_route.dart](../lib/features/auth/auth_post_verify_route.dart)).
- `_resend()` — resends, restarts the timer.
- `_checkLockoutStatus()` / `_startLockoutTimer()` — enforces attempt lockout.
- `_startResendTimer()` — 60-second resend cooldown.
- `_maskEmail(email)` — renders `j••••@gmail.com`.

**Navigation:** From `EmailEntryScreen` or the session-expired screen. Leads to four possible destinations.

**Notes:** The route decision is extracted into a separate pure file — a nice pattern, since branching logic can then be unit-tested without a live Supabase session.

---

### LoginScreen — PIN entry
**Purpose:** The PIN unlock screen for a returning user, with biometrics.
**File:** [lib/features/auth/screens/login_screen.dart](../lib/features/auth/screens/login_screen.dart) (1,095 lines)

**Widget tree:** `BrandedAuthBackground` → `Column` → avatar + name header → `PinDots` (in a `ValueListenableBuilder`) → `_PinPad` (with biometric key bottom-left) → "Forgot PIN" / "Switch user" links. `_SuccessOverlay` covers the screen on success.

**State:** PIN held in a `ValueNotifier` (not `setState`) so the dots update at full frame rate; `_lockoutSeconds`, `_biometricAvailable`, `_isLoading`. Watches `userRoleProvider`.

**Functions:**
- `_initUserAndLockoutState()` — loads the target user and any active lockout.
- `_checkBiometricAvailability()` / `_triggerBiometrics()` — fingerprint/face unlock.
- `_onDigit(digit)` / `_onBackspace()` — build the PIN buffer; auto-submits at 6 digits.
- `_submit()` — verifies the PIN, handles failed-attempt lockout.
- `_enterApp(user)` — refuses a suspended member, then sets the current user and starts login sync.
- `_switchToEmail()` / `_forgotPin()` — escape hatches.
- `_showUserPicker(users)` — bottom sheet when two device users share the same PIN.
- `didChangeAppLifecycleState` — re-checks whether the business was deleted when the app resumes.

**Navigation:** From `_HomeRouter` (cold start, the drawer lock button, auto-lock) or the email screen's "Login with PIN" link. On success, `MainLayout`.

**Notes:** The `ValueNotifier`-for-PIN-dots choice is a deliberate, well-reasoned optimisation. At 1,095 lines with 6 private classes, though, this file would normally be split.

---

### CeoSignUpScreen — new business wizard
**Purpose:** Creates a whole new business: 9 steps on one screen, committed atomically at the end.
**File:** [lib/features/auth/screens/ceo_sign_up_screen.dart](../lib/features/auth/screens/ceo_sign_up_screen.dart) (1,487 lines)

**Steps:** business name → business type → store details → your name → email → OTP → create PIN → confirm PIN → "your business is ready".

**Widget tree:** `BrandedAuthBackground` → `Column` → `_buildTopBar` (back + `_StepDots`) → `AnimatedSwitcher(_buildStepBody())` which fades between the 9 step widgets.

**State:** **The draft lives in Riverpod**, not in the widget — `onboardingDraftProvider` ([onboarding_draft.dart](../lib/features/auth/onboarding/onboarding_draft.dart)). The widget holds only `_step`, controllers, and timers.

**Key functions:**
- `_bootstrap()` — preloads country/state reference data.
- `_submitBusinessName/_submitBusinessType/_submitStoreDetails/_submitFullName` — validate a step and write it into the draft.
- `_submitEmail()` — sends the OTP.
- `_verifyOtp()`, `_resendOtp()`, `_startResendTimer()`, `_startLockoutTimer()` — OTP handling.
- `_onPinDigit/_onPinBackspace/_onPinComplete` — two-pass PIN entry.
- **`_commit()`** — the important one: runs `complete_onboarding` (a single cloud transaction) and mirrors the result locally.
- `_ensureOnline()` — blocks the flow when offline (this step genuinely needs the network).
- `formatPhoneNumber(raw, dialCode)` — normalises to international format.

**Notes:** The **collect-first / commit-once** design is genuinely good: nothing reaches the cloud until the final PIN confirm, so abandoning halfway leaves no half-built business. Holding the draft in a provider rather than widget state is the right call.

The size (1,487 lines, 46 `setState` calls) is the cost. Each step would normally be its own widget file.

---

### StaffSignUpScreen — join with invite code
**Purpose:** A staff member joins an existing business using an invite code. Same 9-step shape as CEO sign-up.
**File:** [lib/features/auth/screens/staff_sign_up_screen.dart](../lib/features/auth/screens/staff_sign_up_screen.dart) (1,394 lines)

**Steps:** invite code → email → OTP → name → phone → address → create PIN → confirm PIN → welcome.

**State:** `StaffSignUpDraft` — a plain class held in widget state (unlike the CEO flow, which uses a provider).

**Key functions:** `_submitCode()` (validates the invite), `_confirmEmail()`, `_verifyOtp()`, `_submitName/_submitPhone/_submitAddress`, `_onPinComplete()`, and **`_commit()`** which calls the `redeem_invite_code` cloud function.

**Notes:** Near-duplicate of `CeoSignUpScreen` — step dots, OTP handling, PIN entry, timers and phone formatting are all reimplemented rather than shared. The two `_StepDots` classes are literally duplicated. This is the clearest example of AI-generated duplication in the codebase.

---

### CreatePinScreen
**Purpose:** Two-pass PIN setup, used both by onboarding and by PIN reset.
**File:** [lib/features/auth/screens/create_pin_screen.dart](../lib/features/auth/screens/create_pin_screen.dart) (402 lines)

**Widget tree:** `BrandedAuthBackground` → title → `PinDots` → `PinKeypad`; swaps to `_buildSavingState` while committing.

**State:** `_firstPin`, `_pin`, `_isConfirming`, `_saving`. Reads `authProvider`, `databaseProvider`, `onboardingDraftProvider`.

**Functions:** `_onDigit`, `_onBackspace`, and `_advance()` — which handles both callers: for onboarding it commits the whole draft; for a reset it just writes the new PIN.

**Navigation:** From onboarding or `ExistingAccountScreen`. Leads to `BiometricSetupScreen`.

---

### BiometricSetupScreen
**Purpose:** Optional prompt to turn on fingerprint/face unlock after PIN setup.
**File:** [lib/features/auth/screens/biometric_setup_screen.dart](../lib/features/auth/screens/biometric_setup_screen.dart) (181 lines)

**Functions:** `_enableBiometrics()` (prompts hardware, saves preference), `_skip()`, `_done()` — all three set `auth.pendingPostLoginRoute`, which `_HomeRouter` then acts on.

**Notes:** Small, focused, easy to read — a good example of the "set a flag, let the router decide" pattern.

---

### ExistingAccountScreen / NoAccountFoundScreen
**Files:** [existing_account_screen.dart](../lib/features/auth/screens/existing_account_screen.dart) (276) · [no_account_found_screen.dart](../lib/features/auth/screens/no_account_found_screen.dart) (106)

- **ExistingAccountScreen** — the email already has a cloud account: shows the linked business and role to confirm before seeding this device. Functions: `_onContinue()`, `_onUseDifferentEmail()`, `_maskEmail()`, `_buildBusinessCard()`.
- **NoAccountFoundScreen** — brand-new email: offers "create a business" or "join with a code" rather than silently assuming one. Stateless.

---

### AccessGrantedScreen / SuccessDashboardEntryScreen
**Files:** [access_granted_screen.dart](../lib/features/auth/screens/access_granted_screen.dart) (447) · [success_dashboard_entry_screen.dart](../lib/features/auth/screens/success_dashboard_entry_screen.dart) (101)

Celebration screens shown once after joining or onboarding. `AccessGrantedScreen` animates a success icon and shows business/role details (`_fetchDetails()`, `_buildSuccessIcon()`, `_buildDetailCard()`). `SuccessDashboardEntryScreen` auto-forwards on a timer (`_startAutoForward()`).

---

### ComingSoonScreen
**Purpose:** Placeholder for Terms / Privacy / unbuilt routes.
**File:** [lib/features/auth/screens/coming_soon_screen.dart](../lib/features/auth/screens/coming_soon_screen.dart) (63 lines)

**Widget tree:** `Scaffold` → `AppBar(title)` → `Center` → `Padding` → `Column` → `Icon`, `SizedBox`, `Text`.

**State:** None — a pure `StatelessWidget` taking `title` and `message`.

**Notes:** **The simplest screen in the app, and the best starting point for reading Dart.** It shows constructor syntax, `required` named parameters, `const`, theme lookup via `Theme.of(context)`, and a basic widget tree — in 63 readable lines.

---

### Auth widgets (shared building blocks)
**Folder:** [lib/features/auth/widgets/](../lib/features/auth/widgets/)

| Widget | Purpose |
|---|---|
| `BrandedAuthBackground` | The branded backdrop: base surface, two corner glows, dotted grid (drawn with a `CustomPainter`) |
| `AuthBackground` | Simpler gradient backdrop |
| `AuthFormShell` / `AuthCenteredScroll` | Keyboard-aware scrolling shells for auth forms |
| `AuthInputCard` / `AuthErrorText` | Glass input wrapper; fixed-height error slot so layout doesn't jump |
| `AutocompleteField` | Suggestion field for country/state/LGA |
| `PinDots` / `PinKey` / `PinKeypad` | The shared branded PIN keypad |
| `OtpBoxRow` | Six OTP boxes driven by one hidden `TextField` |
| `OnboardingStepIndicator` | Animated dots-and-lines progress bar |
| `ShakeWidget` | Shake animation on a wrong PIN |

**Notes:** This folder is the healthiest part of the codebase — small, single-purpose, well-documented, genuinely reused. `AuthErrorText` reserving space to prevent layout jump is a thoughtful detail.

---

## B3. POS, cart and checkout

The selling flow: **POS (pick items) → Cart (review) → Checkout (take payment) → receipt.**

---

### PosHomeScreen — the till
**Purpose:** The main selling screen: search, filter, scan and tap products into the cart.
**File:** [lib/features/pos/screens/pos_home_screen.dart](../lib/features/pos/screens/pos_home_screen.dart) (709 lines)

**Widget tree:**
```
Guarded.screen(gate: Gates.makeSale)      ← waits for permissions, then:
└── ListenableBuilder(_controller)        ← rebuilds on PosController changes
    └── SharedScaffold(activeRoute: 'pos')
        ├── appBar: _buildAppBar (menu button, business name, view switcher)
        ├── body: Column
        │   ├── _buildHeader (store label, cart summary)
        │   ├── _buildSearchField + PosBarcodeScanButton
        │   ├── CategoryFilterBar (horizontal chips)
        │   ├── _buildInlineHint (coach banner, self-retiring)
        │   └── Expanded → ProductGrid (grid or list)
        └── _buildQuickSaleBtn
```

**State:**
- `_controller` — a `PosController` (a `ChangeNotifier`), created in `initState` via `Future.microtask`, **not** a provider.
- Local: `_isListView`, `_gridColumns` (persisted in `SharedPreferences`), `_showPosHint`, `_hasAutoShownPicker`.
- Watches: `firstLoadSkeletonActiveProvider`, `selectableStoresProvider`, `lockedStoreProvider`, `storeExplicitlyChosenProvider`, `industryLexiconProvider`, `currencySymbolProvider`.

**Functions:**
- `_loadViewPreferences()` / `_updateViewPreferences()` — grid vs list, column count.
- `_showViewSelectorModal()` — the layout picker sheet.
- `_addToCart(context, item)` — adds a product to the cart.
- `_showQuickSaleModal(context)` — opens `QuickSaleModal` for an off-catalogue item.
- `_buildSelectStorePlaceholder()` — shown while a multi-store user hasn't picked a store.
- `_selectedCategoryLabel()` — label for the active filter.

**Navigation:** Tab 1. Leads to `CartScreen` (tab 8), `QuickSaleModal`, `BarcodeScanPage`, `AddProductScreen` (unknown barcode).

**Notes:**
- **The store gate is the interesting logic here.** If you have 2+ stores and haven't *explicitly* picked one, POS refuses to show products and forces the picker — so nothing is ever accidentally sold from a silently-defaulted store.
- `PosController` being a local field rather than a provider is inconsistent with the rest of the app — it means the controller is rebuilt when the widget remounts, and it can't be read from anywhere else. This is a genuine oddity. See [C1](#c1-non-idiomatic-patterns-in-this-codebase).

---

### PosController
**File:** [lib/features/pos/controllers/pos_controller.dart](../lib/features/pos/controllers/pos_controller.dart) (212 lines)

**Purpose:** Holds the POS's filtering/search state and the live product list.

**Functions:** `_subscribeToProducts()`, `_loadCategories()`, `_loadManufacturers()`, `_onCustomerSelected()`, `setFallbackStore(id)`, `selectCategory(id)`, `selectManufacturer(id)`, `selectGroup(tier)`, `updateSearch(query)`.

**Notes:** A textbook `ChangeNotifier` — takes its dependencies by constructor (database, navigation, cart), which makes it testable. Worth reading as an example of separating logic from UI. It's just wired up unusually (see above).

---

### ProductGrid
**Purpose:** Renders products as a grid or list, with the tap/hold interactions.
**File:** [lib/features/pos/widgets/product_grid.dart](../lib/features/pos/widgets/product_grid.dart) (739 lines)

**Widget tree:** `GridView.builder` or `ListView.builder` → `_ProductCard` → `_buildGridLayout` / `_buildListLayout`.

**Functions (on `_ProductCardState`):**
- `_handleTap()` — adds one unit to the cart.
- `_openAddModal()` — long-press: choose a quantity.
- `_launchFling(source)` — the animation of the product flying into the cart icon.

**Notes:** Shows out-of-stock, low-stock and in-cart states. The fling animation is a nice touch, and it's properly disposed.

---

### CartScreen
**Purpose:** Review the order: change quantities, apply discounts, pick or change the customer, save the cart for later.
**File:** [lib/features/pos/screens/cart_screen.dart](../lib/features/pos/screens/cart_screen.dart) (1,726 lines)

**Widget tree:**
```
SharedScaffold(activeRoute: 'cart')
├── appBar (title, NotificationBell, saved-carts button)
└── body: Column
    ├── customer strip (tap to change / add)
    ├── Expanded → ListView of cart item tiles
    │              each with _discountBadge / _customPriceBadge
    ├── _totalRow (subtotal, discount, crate deposits, total)
    └── Checkout button
```

**State:** Reads `cartProvider` (`CartService`); listens to cart and active-customer changes; watches `creditBalancesKoboProvider`, `currentBusinessProvider`, `activeStoreLabelProvider`.

**Functions:**
- `_onCartChanged()` / `_onActiveCustomerChanged()` — listener callbacks that rebuild.
- `_saveCurrentCart()` / `_viewSavedCarts()` — park an order and come back to it.
- `_clearWithAnimation()` — animated empty-out.
- `_showChangeCustomerModal()` / `_buildCustomerTile()` — customer picker (gated on `Gates.addCustomer` to create a new one).
- `_editItem(ctx, item)` — opens `EditItemModal`.
- `_discountBadge(item)` / `_customPriceBadge()` — the little price-override chips.
- `_totalRow(...)` — the totals block.

**Navigation:** Tab 8. Leads to `CheckoutPage`, `EditItemModal`.

**Notes:** `MainLayout` instantiates this as `CartScreen(cart: [], onCustomerChanged: _voidOnCustomerChanged)` with a **no-op callback and an empty list** — the real data comes from `cartProvider`. Those two constructor parameters are vestigial and misleading; a reader would reasonably assume the cart is passed in. Worth knowing so you don't chase them.

---

### CheckoutPage
**Purpose:** Take payment, book the money correctly, write the order, print/share the receipt.
**File:** [lib/features/pos/screens/checkout_page.dart](../lib/features/pos/screens/checkout_page.dart) (2,321 lines)

**The three payment modes** (`enum PayMode`, line 73) — the heart of this screen:
- `cashTransfer` — customer pays now; a shortfall becomes debt, an excess tops up their wallet.
- `wallet` — charge the order to their existing wallet credit; a shortfall becomes debt.
- `credit` — nothing paid now; the whole amount is debt.

**Widget tree:**
```
Scaffold
├── appBar
└── body: swaps between two views
    ├── _buildCheckoutForm()
    │   ├── _buildPaymentMethods  (_methodChip × 3)
    │   ├── _tenderPicker         (cash / transfer)
    │   ├── _buildCashTransferInput
    │   ├── _buildCrateDepositSection (_crateDepositRow per manufacturer)
    │   ├── _creditSaleCard / _buildCreditInfoCheckbox
    │   ├── _debtLimitWarning
    │   ├── _resultPreview / _buildCreditPreview
    │   └── order summary (_orderItemTile, _summaryRow)
    └── _buildReceiptView()
        ├── _buildPrintingBanner
        └── _buildReceiptActions (print / share / done)
```

**State:** ~21 `setState` sites — payment mode, tender type, amount, crate deposit lines, printing state. Reads `orderServiceProvider`, `cartProvider`, `customerServiceProvider`, `printerServiceProvider`, `currentBusinessProvider`, `selectableStoresProvider`.

**Key functions:**
- **`_confirmPayment()`** — the single most important function in the app. Validates, writes the order, moves stock (FIFO), books wallet/debt, records crate deposits, enqueues the cloud push.
- `_detectCartStaleness()` / `_showStalenessDialog()` — catches a price or stock change that happened while the cart sat open.
- `_walletBalanceFor(customerId)` — available wallet credit.
- `_editBrandDeposit(mfrId, name, fullKobo)` — override a crate deposit per brand.
- `_buildCrateDepositSection()` / `_buildReadOnlyCratesSection()` — empties-tracking UI.
- `_printReceipt()` / `_shareReceipt()` / `_showPrinterPicker(...)` — thermal printing and image share.
- `_debtLimitWarning(limitKobo, projectedKobo)` — warns before exceeding a customer's credit limit.

**Navigation:** From `CartScreen`. Returns to POS on completion.

**Notes:**
- Two conventions here are load-bearing and worth internalising: revenue is recognised **at checkout** (use `orderCountsAsSale`, never filter on `status == 'completed'`), and stock is drawn down **FIFO** with the per-line cost snapshotted onto the order line.
- The staleness check before committing is genuinely good offline-first thinking.
- At 2,321 lines this is the largest single-screen file. `_confirmPayment` alone spans ~290 lines and does validation, persistence, money booking and navigation — it would normally be a service method.

---

### EditItemModal
**Purpose:** Change a cart line's quantity, apply a discount, or set a custom price.
**File:** [lib/features/pos/widgets/edit_item_modal.dart](../lib/features/pos/widgets/edit_item_modal.dart) (924 lines)

**Functions:** `_updateQty(delta)`, `_initialQtyText()`, `_customPriceSection(...)` (gated on `Gates.setCustomPrice`), `_discountSection(...)` (capped by `currentUserMaxDiscountPercentProvider`), `_kindChip(label, kind)` (percent vs fixed), `_qtyBtn(...)`, `_microAdjustChip(label, onTap)`.

**Notes:** Good example of a permission shaping UI rather than just blocking it — the discount cap is read from the user's role limit and enforced in the input.

---

### QuickSaleModal
**Purpose:** Sell something that isn't in the catalogue. For a cashier this becomes an approval request instead of a direct add.
**File:** [lib/features/pos/widgets/quick_sale_modal.dart](../lib/features/pos/widgets/quick_sale_modal.dart) (444 lines)

**Functions:** `_buildProduct(name, priceNaira)`, `_addToCart()` (manager+), `_sendForApproval()` (below manager), `_onStatusChange(request)` (reacts when the approval lands via sync), `_withdrawAndClose()`, `_resolveActiveStoreId()`, plus `_buildForm()` / `_buildWaiting()`.

**Notes:** A nice demonstration of the offline-first approval pattern: the modal writes a request row, then *watches* that row; the approval arrives through normal sync and the modal reacts. No polling, no direct call.

---

### Barcode scanning
**Files:** [barcode_scanner.dart](../lib/features/pos/services/barcode_scanner.dart) (abstract) · [mobile_scanner_barcode_scanner.dart](../lib/features/pos/services/mobile_scanner_barcode_scanner.dart) · [pos_barcode_scan_button.dart](../lib/features/pos/widgets/pos_barcode_scan_button.dart)

An `abstract class BarcodeScanner` with one method, `scanOnce(context)`, and a camera-backed implementation. `PosBarcodeScanButton._scan()` adds a matched product through the *same* path a tap uses; an unknown barcode toasts and opens Add Product pre-filled.

**Notes:** The interface/implementation split is deliberate — it lets tests inject a fake scanner. This is the cleanest example of dependency inversion in the codebase.

---

### Receipt building
**Files:** [receipt_builder.dart](../lib/features/pos/services/receipt_builder.dart) (380) · [receipt_paper_size.dart](../lib/features/pos/services/receipt_paper_size.dart) · [receipt_widget.dart](../lib/shared/widgets/receipt_widget.dart) (538)

`ThermalReceiptService` builds the byte stream for a thermal printer; `ReceiptPaperSize` is the app's own paper-width enum, deliberately decoupled from the print library's so a library change can't silently reshape receipts. `ReceiptWidget` is the on-screen/shareable version.

---

## B4. Orders

### OrdersScreen
**Purpose:** Browse pending, completed and cancelled orders; reprint receipts; refund; mark delivered.
**File:** [lib/features/orders/screens/orders_screen.dart](../lib/features/orders/screens/orders_screen.dart) (2,244 lines)

**Widget tree:**
```
SharedScaffold(activeRoute: 'orders')
├── appBar: _buildAppBar
└── body: TabBarView (3 tabs)
    └── each tab: AppRefreshWrapper → CustomScrollView
        ├── SliverPersistentHeader(_PinnedHeaderDelegate)
        │   └── _buildSearchBar + _buildFilterDropdown
        ├── _SummaryStrip (counts and totals)
        └── paginated slivers of _OrderCard
            └── _StatusBadge, _PaymentBadge, _CreditDebtBadge
```

**State:** `TabController`; search text; per-tab period filter. Watches `paginatedOrdersProvider`, `ordersStatsProvider`, `pendingOrdersProvider`, `creditBalancesKoboProvider`, `usersByBusinessProvider`, `lockedStoreProvider`.

**Functions:**
- `_changeFilter(tab, value)` — period filter per tab (`Gates.seeExtendedDateRanges` widens the options).
- `_onSearchChanged(value)` / `_applySearch(list)` — client-side search.
- `_buildPaginatedOrderSlivers(...)` / `_buildOrderSlivers(...)` — lazy-loaded lists.
- `_markAsDelivered(...)` / `_executeMarkDelivered(...)` — confirm then apply (gated `Gates.confirmOrder`).
- `_refundPendingOrder(order)` / `_executeRefund(order, reason)` — refund with a reason (gated `Gates.refundOrder`).
- `_viewReceipt(context, richOrder)` — reopen a receipt.
- `_printReceipt(...)` / `_shareReceipt(...)` / `_logReprint(orderId)` — reprints are audit-logged.
- `_resolveStoreAddress(storeId)` — address for the receipt header.
- `_showRiderSelection(context, orderId)` — assign a delivery rider.

**Navigation:** Tab 3. Opens receipts and refund dialogs.

**Notes:** Pagination is the right call for a table that grows forever. The `confirm → execute` split on destructive actions is a good pattern used consistently. Money columns are hidden behind `Gates.seeOrderMoney`.

---

### CrateReturnModal / CrateReturnApprovalScreen
**Files:** [crate_return_modal.dart](../lib/features/orders/widgets/crate_return_modal.dart) (644) · [crate_return_approval_screen.dart](../lib/features/orders/screens/crate_return_approval_screen.dart) (327)

**Purpose:** Customers return empty crates and get their deposit back — either as cash or as wallet credit. Below-manager submissions go into an approval queue.

**Modal functions:** `_buildRows()` (per-manufacturer return lines), `_buildRefundModeToggle()` (cash vs wallet — cash is gated `Gates.confirmOrderCashRefund`), `_confirm()`.
**Approval screen functions:** `_approve(id)`, `_reject(id)`, `_showRejectionDialog()`, `_SubmissionBatchTile`.

**Notes:** Crate deposits are refundable money the business *holds*, not income — that distinction drives a lot of the reporting code. Empties are only tracked for products where `unit == 'bottle'` and tracking is on, so plastic bottles can't leak into crate counts.

---

## B5. Inventory

### InventoryScreen
**Purpose:** The stock hub — products, suppliers and empty crates, with summary cards and search.
**File:** [lib/features/inventory/screens/inventory_screen.dart](../lib/features/inventory/screens/inventory_screen.dart) (2,508 lines)

**Widget tree:**
```
Guarded.screen(gate: Gates.viewInventory)
└── SharedScaffold(activeRoute: 'inventory')
    ├── appBar: _buildAppBar
    └── body: NestedScrollView
        ├── header: _buildSummaryCards (_summaryCard × N)
        ├── SliverPersistentHeader(_StickyTabBarDelegate) → _buildTabBar
        └── TabBarView (tabs vary by permission)
            ├── _buildProductsTab   → _buildProductRow, _expiryChip
            ├── _buildSuppliersTab  → _buildSupplierFilter
            ├── _buildCratesTab     → _buildManufacturerCard, _buildCrateStatsRow
            └── InventoryHistoryTab
```

**State:** `TabController` rebuilt dynamically by `_computeVisibleTabs` / `_syncTabController`; manual product `StreamSubscription`; watches `emptyCratesByManufacturerProvider`, `fullCratesByManufacturerProvider`, `storeCrateBalancesProvider`, `firstRunSurfaceStateProvider`, and more.

**Notable functions:**
- `_computeVisibleTabs(context)` — which tabs exist depends on permissions and business type.
- `_subscribeToProducts()` — manual stream subscription.
- `_daysToExpiry(expiry)` / `_isNearExpiry(p)` / `_sortNearExpiryFirst(...)` / `_expiryChip(...)` — expiry warnings.
- `_showAddManufacturerDialog()` / `_showUpdateManufacturerDialog(...)` — brand management, including the per-brand crate deposit value.
- `_showUpdateCrateGroupDialog(grp)` — crate size groups.
- `_showAddSupplierDialog()`.
- `_computeCrateStats(...)` — full/empty crate roll-ups per manufacturer.

**Navigation:** Tab 2. Leads to `ProductDetailScreen`, `AddProductScreen`, `StockCountScreen`, `ReceiveStockScreen`, `SupplierDetailScreen`, `ManageCategoriesSheet`.

**Notes:** Dynamically rebuilding a `TabController` when the visible tab set changes is genuinely fiddly and the code handles it carefully (`_listEquals` guard to avoid rebuild loops). The file's size is the problem — three substantial tabs plus four dialogs in one file.

---

### AddProductScreen
**Purpose:** Add a new product — or, if the name matches an existing one, add stock to it.
**File:** [lib/features/inventory/screens/add_product_screen.dart](../lib/features/inventory/screens/add_product_screen.dart) (2,310 lines)

**Widget tree:** `Scaffold` → `AppBar` → scrolling body of `_fastFormChildren(...)` with an expandable `_moreDetailsChildren(...)` section → pinned save button.

**State:** ~25 controllers; 45 `setState` sites; suggestion lists for supplier/manufacturer/category/product name.

**Function groups:**
- *Autocomplete:* `_onSupplierChanged`, `_selectSupplier`, `_clearSupplier` — and the same triple for manufacturer, category and product name.
- *Create-on-the-fly:* `_createNewManufacturer/Category/Supplier(name)` and `_getOrCreate...(name)`.
- *Fields:* `_onBarcodeChanged(value)`, `_pickExpiryDate()`, `_pickPhoto()`, `_barcodeField()`, `_expiryField(...)`.
- *Save:* `_save()`, `_saveFastAddNewProduct()`, `_persistNewProduct(intent)`.

**Notes:**
- The "Fast Add" parsing/validation is extracted into a testable model ([fast_add_product_model.dart](../lib/features/inventory/models/fast_add_product_model.dart)) — `FastAddContext` and `FastAddInput` mean the screen never pre-computes. That's the right instinct.
- But the four near-identical autocomplete blocks (~12 methods that differ only in which entity they search) are copy-paste that one generic widget would have replaced. This is the most repetitive file in the codebase.

---

### ProductDetailScreen
**Purpose:** One product: view and edit details, prices, stock, photo and sales history.
**File:** [lib/features/inventory/screens/product_detail_screen.dart](../lib/features/inventory/screens/product_detail_screen.dart) (2,410 lines)

**Widget tree:** `CustomScrollView` → `_buildSliverAppBar` (collapsing photo header) → `_buildBody` → `_infoCard` sections, `_buildSalesGrid`, `_buildTargetGrid`, `_buildDeliveryCard`.

**Functions:** `_loadProductData()`, `_refreshLiveStock()`, `_loadEmptyCrateStock(mfrId)`, `_seedFieldsFrom(product)`, `_resetEdits()`, `_reloadDerived()`, `_saveChanges()`, `_pickExpiry()`, `_pickImage()`, `_showUpdateStockModal()` (opens `_UpdateStockSheet`), `_confirmDelete(context)`, `_inlinePriceInput(controller)`, `_expiryBadge(...)`.

**`_UpdateStockSheet`** (same file): add or remove stock. For a stock keeper this writes a **pending approval request** instead of changing stock directly.

**Notes:** Uses `ref.listen` on four providers to refresh derived data — a legitimate use (side effect, not rebuild). Inline editing with a save/reset pair is well handled.

---

### UpdateProductSheet
**File:** [lib/features/inventory/widgets/update_product_sheet.dart](../lib/features/inventory/widgets/update_product_sheet.dart) (1,562 lines)

Edit form mirroring `AddProductScreen`, including the same four autocomplete blocks. Distinct function: `_promptCostBackfill(...)` — when a buying price is set for the first time, offers to restate the untitled cost history.

**Notes:** Substantially duplicates `AddProductScreen`. If you fix a bug in one, check the other.

---

### StockCountScreen
**Purpose:** Physical stock count: count what's on the shelf, compare with the system, record damages.
**File:** [lib/features/inventory/screens/stock_count_screen.dart](../lib/features/inventory/screens/stock_count_screen.dart) (1,761 lines)

**Functions:** `_loadProducts()`, `_diff(index)` (counted vs system), `_confirmAndSave()`, `_showReviewSheet(...)` (variance review before committing), `_saveCount()`, `_notifyManagersAndCeo(...)`, `_recordDamages(context)`, `_viewHistory(context)`, `_showDayDetail(...)`, `_buildCountSessionCard(...)`, `_buildStorePicker(context)`, `_buildTable(context)`.

**Notes:** The review-before-save step is important: a stock count is a money event, so the variance is shown and confirmed rather than silently applied. Damages are crate-aware — a lost full crate forfeits both the drink and the deposit, while a damaged stored empty is crate-only, so nothing double-counts.

---

### Inventory widgets
| Widget | Purpose | File |
|---|---|---|
| `InventoryHistoryTab` | Stock movement history with period filter | [inventory_history_tab.dart](../lib/features/inventory/widgets/inventory_history_tab.dart) (462) |
| `ManageCategoriesSheet` | Rename/delete categories; deleted ones move products to Uncategorized | [manage_categories_sheet.dart](../lib/features/inventory/widgets/manage_categories_sheet.dart) (372) |
| `ProductPhotoField` | The shared photo picker used by Add and Update | [product_photo_field.dart](../lib/features/inventory/widgets/product_photo_field.dart) (130) |
| `CrateMoneyArrangementSection` | Per-brand "does money change hands for crates?" setting | [crate_money_arrangement_section.dart](../lib/features/inventory/widgets/crate_money_arrangement_section.dart) (257) |

---

## B6. Receiving stock

A separate flow from Add Product: this is a **delivery arriving from a supplier**, and it's cart-shaped like the POS.

```
ReceiveStockScreen (pick products) → ReceiveCartScreen (review) → ReceiveCheckoutScreen (invoice, commit)
```

### ReceiveStockScreen
**Purpose:** Pick the products that arrived in a delivery.
**File:** [lib/features/receiving/screens/receive_stock_screen.dart](../lib/features/receiving/screens/receive_stock_screen.dart) (304 lines)

**Functions:** `_initStreams()`, `_toggleSearch()`, `_buildReceiveHint()`, `_buildSearchField(...)`, `_buildBottomBar(context)`.
**Gates:** `Gates.receiveStock`, `Gates.editProductPrice`.

### ReceiveCartScreen
**File:** [receive_cart_screen.dart](../lib/features/receiving/screens/receive_cart_screen.dart) (356 lines) — a `ConsumerWidget` reading `receiveCartProvider`. Review quantities and costs before checkout.

### ReceiveCheckoutScreen
**Purpose:** Pick one supplier, record the invoice, crates moved, optional payment — then commit atomically.
**File:** [lib/features/receiving/screens/receive_checkout_screen.dart](../lib/features/receiving/screens/receive_checkout_screen.dart) (965 lines)

**Functions:** `_loadData()`, `_pickDate()`, `_pickSupplier()` (`_SupplierPickerSheet`), `_confirm()`, `_showConfirmationDialog(...)`, `_lineRow(...)`, `_crateRow(...)`, `_storeName()`.

**Notes:** Commits through `receiveStockServiceProvider` in one transaction: stock in, a new FIFO cost layer, the supplier ledger entry, and crate movement. A line with **no buying price is accepted** — a stock keeper often doesn't know the cost yet — but `UncostedReceiveWarning` makes it visible, because uncosted units later sell at zero cost and inflate profit.

### Receive cart state
**File:** [lib/features/receiving/state/receive_cart.dart](../lib/features/receiving/state/receive_cart.dart) (183 lines)

`ReceiveCartNotifier extends Notifier<List<ReceiveCartLine>>` — methods `addOrIncrement`, `setQty`, `setProductQty`, `setBuyingPrice`, `setRetailPrice`, `setWholesalePrice`, `remove`, `clear`.

**Notes:** **This is the most modern Riverpod code in the app** — a `Notifier` with immutable state and `copyWith`. If you want to see how the rest of the app *would* look written today, read this file. Compare it with `CartService` (a `ChangeNotifier` holding `List<Map<String, dynamic>>`) to see the difference.

### Receiving widgets
`ReceiveProductGrid`, `EditReceiveItemModal` (`_updateQty`), `NewProductCard`, `UncostedReceiveWarning`.

---

## B7. Dashboard and reports

### HomeScreen — the dashboard
**Purpose:** The landing screen: period-filtered metric cards (sales, profit, expenses, stock value, credit) and staff performance.
**File:** [lib/features/dashboard/screens/home_screen.dart](../lib/features/dashboard/screens/home_screen.dart) (1,274 lines)

**Widget tree:**
```
SharedScaffold(activeRoute: 'dashboard')
├── appBar (business name, NotificationBell)
└── body: AppRefreshWrapper → ListView
    ├── GetStartedCard          (CEO only, first-run checklist)
    ├── _buildPeriodHeader      (+ _buildReportButton, _buildPeriodDropdown)
    ├── _buildMetricsList       (_robustMetricCard × N — each gate-checked)
    ├── _buildTotalSkusCard
    ├── _buildCreditsBalanceCard
    └── _buildStaffSalesSection (_buildStaffRow × N)
```

**Every metric card is individually gated:** `Gates.seeSalesMetric`, `seeProfitMetric`, `seeExpensesMetric`, `seeStockValueMetric`, `seeCreditBalanceMetric`, `seeStaffSales`. `seeExtendedDateRanges` controls how far back the period dropdown goes.

**State:** `_selectedPeriod`; two manual `StreamSubscription`s (inventory, expenses) re-subscribed when the store changes. Watches `lockedStoreProvider`, `creditBalancesKoboProvider`, `industryLexiconProvider`, `reportsAttentionDotProvider`, `firstLoadSkeletonActiveProvider`.

**Functions:** `_initializeData()`, `_subscribeInventory(storeId)`, `_subscribeExpenses(storeId)`, `_isDateInPeriod(date, period)`, `_openSalesDetail(...)`, `_robustMetricCard(...)`.

**Navigation:** Tab 0. Leads to `ReportsHubScreen`, `SalesDetailScreen`, `ExpensesScreen`.

**Notes:** `industryLexiconProvider` is worth knowing: it renames nouns per industry ("drinks" vs "products") so one codebase serves several trades. The two manual store-scoped stream subscriptions are the pattern a `StreamProvider.family` would replace.

---

### ReportsHubScreen
**Purpose:** Menu of available reports, each card gated and badged with anything needing attention.
**File:** [lib/features/dashboard/screens/reports_hub_screen.dart](../lib/features/dashboard/screens/reports_hub_screen.dart) (297 lines)

**Gates:** `dailyReconciliation`, `profitReportEntry`, `supplierAccountsReport`, `crateDepositsReport`, `viewApprovals`, `confirmCrateDeposit`.
Badge counts come from `viewerScopedPendingStockRequestsProvider`, `viewerScopedPendingQuickSaleRequestsProvider`, `viewerScopedPendingCrateDepositsProvider`.

---

### Daily Reconciliation (list + detail)
**Files:** [daily_reconciliation_list_screen.dart](../lib/features/dashboard/screens/daily_reconciliation_list_screen.dart) (396) · [daily_reconciliation_detail_screen.dart](../lib/features/dashboard/screens/daily_reconciliation_detail_screen.dart) (2,148)

**Purpose:** The end-of-day/week/month close. Rolls up sales, stock, shrinkage, debts, expenses and crates, and freezes a snapshot once reviewed.

**List screen functions:** `_handlePeriodChange(value, theme)` (Day/Week/Month/Year — a Manager is capped at Month), `_exportCsv(buckets, scope)`, `_bucketCard(...)`, `_emptyState(theme)`.

**Detail screen cards** — each a method: `_salesCard`, `_plCard` (CEO only), `_vanSalesCard`, `_cashFlowCard`, `_stockReconciliationCard`, `_businessWorthCard`, `_debtsExpensesCard`, `_cratesCard`, `_crateMoneyCard`, `_crateShortfallSection`.
Other functions: `_frozenFiguresReady(...)`, `_maybeWriteSnapshot(...)`, `_deltaChips(figures)`, `_changedChip(label)`, `_reviewedBanner(...)`, `_openCrateWriteOffSheet(...)`, `_confirmCrateWriteOff(...)`, `_exportCsv(...)`.

**The cost wall:** a Manager never sees cost, COGS, margin, profit or goods-received; their shrinkage is valued at selling price instead. That's enforced here and in the gates.

**Notes:** The money maths lives in [recon_data.dart](../lib/features/dashboard/reconciliation/recon_data.dart) (2,966 lines) as **pure functions** — `ReconInputs` gathers every input, and `reconDataFrom(inputs)` computes without needing a widget. That refactor is the single best piece of engineering in this codebase: it's why the same total can be tested and why three screens agree on one number. Read `ReconInputs`' doc comment for the reasoning.

`ChangedSinceReviewBadge` is deliberately one shared widget used in two places, so the list and the detail can't drift apart.

---

### Other reports
| Screen | Purpose | File |
|---|---|---|
| `ProfitReportScreen` | CEO-only revenue/COGS/margin with per-product breakdown; `_exportCsv`, `_uncostedNote`, `_headline`, `_productRow` | [profit_report_screen.dart](../lib/features/dashboard/screens/profit_report_screen.dart) (638) |
| `SalesDetailScreen` | Drill-down from a dashboard tile; `mode` is `'sales'` or `'profit'`; `_buildRows`, `_discountTotal`, `_exportCsv` | [sales_detail_screen.dart](../lib/features/dashboard/screens/sales_detail_screen.dart) (545) |
| `SupplierAccountsReportScreen` | Balance/paid/received per supplier; `_aggregate(...)` | [supplier_accounts_report_screen.dart](../lib/features/dashboard/screens/supplier_accounts_report_screen.dart) (301) |
| `CrateDepositsReportScreen` | Proves `Held = Taken − Refunded − Kept`; `_exportCsv`, `_heldCard`, `_breakdownCard` | [crate_deposits_report_screen.dart](../lib/features/dashboard/screens/crate_deposits_report_screen.dart) (325) |

**Notes:** `SalesDetailScreen`'s doc comment records a real bug class: the drill-down headline **must** equal the tile that opened it, which required sharing the scope predicate and subtracting order discounts. Worth reading as an example of why shared pure functions matter.

---

### StockApprovalsScreen
**Purpose:** One queue for everything awaiting a manager: stock adjustments, quick sales, crate deposits.
**File:** [lib/features/dashboard/screens/stock_approvals_screen.dart](../lib/features/dashboard/screens/stock_approvals_screen.dart) (1,076 lines)

**Three card types**, each a `ConsumerStatefulWidget` with its own `_decide({required bool approve})`:
- `_ApprovalCard` — stock adjustment requests
- `_QuickSaleApprovalCard` — off-catalogue sale requests
- `_CrateDepositApprovalCard` — crate deposit confirmations (`Gates.confirmCrateDeposit`)

Shared helpers per card: `_pendingChip`, `_detailRow`, `_timeAgo(dt)`, `_fullStamp(dt)`. `_RejectReasonDialog` collects a reason.

**Notes:** A CEO sees every store, a Manager only their assigned stores — the scoping lives in the `viewerScoped*` providers, not in this screen. That's the right place for it. The three card types share ~80% of their code and were clearly copy-pasted; `_timeAgo` and `_fullStamp` exist three times in this one file.

---

### Get-started checklist
**Files:** [get_started_checklist.dart](../lib/features/dashboard/get_started_checklist.dart) (148) · [get_started_card.dart](../lib/features/dashboard/widgets/get_started_card.dart) (227)

Three first-run milestones (add a product, make a sale, invite your team) derived from data rather than stored flags. `GetStartedDismissalNotifier` latches dismissal per device.

**Notes:** Deriving "done" from data instead of a stored flag means it's automatically correct on a new device. The card renders zero height when it shouldn't show, so it can be dropped unconditionally at the top of the list — a tidy pattern.

---

## B8. Customers

### CustomersScreen
**Purpose:** Customer list with search and live credit/debt balances.
**File:** [lib/features/customers/screens/customers_screen.dart](../lib/features/customers/screens/customers_screen.dart) (404 lines)

**Widget tree:** `Scaffold` → `_buildAppBar` → search field → `AppRefreshWrapper` → `CustomScrollView` → `_buildCustomerCard` per customer → FAB gated on `Gates.addCustomer`.

**State:** Watches `customerServiceProvider`, `creditBalancesKoboProvider`, `lockedStoreProvider`, `activeStoreLabelProvider`.

**Navigation:** Tab 4 → `CustomerDetailScreen`, `AddCustomerSheet`.

---

### CustomerDetailScreen
**Purpose:** One customer's whole relationship: wallet, credit history, orders and crate balances.
**File:** [lib/features/customers/screens/customer_detail_screen.dart](../lib/features/customers/screens/customer_detail_screen.dart) (2,749 lines — **the largest file in the app**)

**Widget tree:**
```
CustomScrollView
├── _buildHeader        (avatar, name, contact)
├── _buildCreditCard    (wallet balance, debt, limit)
├── SliverPersistentHeader(_SliverTabBarDelegate) → _buildTabBar
└── TabBarView
    ├── _buildCreditHistoryTab  (_buildCreditSummaryRow, _buildSummaryTile)
    ├── _buildOrdersTab
    └── _buildCratesTab         (_buildCrateReturnCard, _buildCrateBalanceRow)
```

**Money actions**, each gated and each opening a sheet:
- `_showAddFundsSheet()` — top up wallet (`Gates.addCustomerCredit`)
- `_showRefundCashSheet()` — refund wallet as cash (`Gates.refundCustomerWallet`); `_refundAvailRow(...)` shows what's actually refundable
- `_showSetLimitSheet()` — debt limit (`Gates.setDebtLimit`)
- `_confirmVoidTopup(txn)` — reverse a top-up
- `_showRecordCrateReturnSheet()` — crate return (`Gates.recordCrateReturn`)
- `_confirmAndDelete()` — soft delete (`Gates.deleteCustomer`)
- `_openEditSheet()` — edit details (`Gates.editCustomer`)

**Receipts:** `_showReceipt(order)`, `_printReceiptFromDetail(...)`, `_shareReceiptFromDetail(...)`.
**Helpers:** `_initials(name)`, `_friendlyRefType(ref)`, `_orderStatusVariant(status)`, `_showCratesTab()`.

**Notes:** A wallet **credit** and a **debt** are the same number with opposite signs, and the screen is careful about which it shows. `_showCratesTab()` hides the crates tab entirely for non-crate businesses. The file also defines its own `_GlassyCard`, `_InfoRow`, `_EmptyState`, `_SheetContainer`, `_SheetHandle`, `_SheetField`, `_SliverTabBarDelegate` — several of which are duplicated in other detail screens. See [C1](#c1-non-idiomatic-patterns-in-this-codebase).

---

### Customer sheets and service
| File | Purpose |
|---|---|
| [add_customer_sheet.dart](../lib/features/customers/widgets/add_customer_sheet.dart) (355) | Create a customer; `_groupDropdown()` picks retailer/wholesaler pricing tier |
| [edit_customer_sheet.dart](../lib/features/customers/widgets/edit_customer_sheet.dart) (379) | Same form prefilled; deliberately **not** dismissible by tapping outside so details aren't lost |
| [customer_service.dart](../lib/features/customers/data/services/customer_service.dart) (211) | `addCustomer`, `updateCustomer`, `softDeleteCustomer`, `topUpWallet`, `refundCashFromWallet`, `voidTopup`, `updateWalletLimit`, `addCratesToBalance`, `updateEmptyCratesBalance` |

**Notes:** The `Customer` model's doc comment records a caught bug: two legacy fields were hardcoded empty with "fetch it one day" TODOs, and finishing the crate one as written would have discounted crate *debtors*. Crate balances are derived from the ledger instead. A good lesson in not trusting an unfinished TODO.

---

## B9. Expenses

### ExpensesScreen
**Purpose:** Record and review expenses, run budgets, and approve staff-submitted spending.
**File:** [lib/features/expenses/screens/expenses_screen.dart](../lib/features/expenses/screens/expenses_screen.dart) (2,004 lines)

**Widget tree:**
```
Guarded (Gates.viewExpenses)
└── Scaffold
    ├── appBar: _buildAppBar (period + store scope)
    └── body: Column
        ├── _buildHeaderArea (+ _buildBudgetBar / _buildBudgetSet / _buildBudgetUnset)
        ├── _buildPendingApprovals (_buildPendingRow × N)
        └── TabBarView
            ├── _buildExpensesTab → _ExpenseCard (+ _StatusBadge)
            └── _buildStatsTab    → _buildBudgetComparisonCard,
                                    _buildTopStaffCard,
                                    _buildAnnualProjectionCard
```

**Functions:** `_isInPeriod(date, period)`, `_recordedByName(userId, users)`, `_openBudgetDialog(scopeStoreId, currentKobo)`, `_approveExpense(exp)`, `_rejectExpense(exp)`, `_canEdit(exp)`, `_canDelete()` (CEO only), `_deleteExpense(exp)`, `_buildCardMenu(exp)`, `_categoryName(...)`, `_storeLabel(...)`, `_getIconForCategory(category)`.

**Gates:** `viewExpenses`, `addExpense`, `approveExpenses`, `seeExtendedDateRanges`.

**Notes:** `_canDelete()` hardcodes `role?.slug == 'ceo'` instead of using a gate — the one place in the app that bypasses the gate registry. Worth knowing, since it's the pattern the registry exists to replace.

---

### AddExpenseScreen
**Purpose:** Record an expense (or edit an existing one's descriptive fields).
**File:** [lib/features/expenses/screens/add_expense_screen.dart](../lib/features/expenses/screens/add_expense_screen.dart) (703 lines)

**Functions:** `_onAmountChanged()`, `_onCategoryChanged()`, `_pickReceipt()` (photo proof), `_pickDate()`, `_submit()`, `_submitEdit()`, `_methodLabel(code)`, `_recordingForBanner(context, label)`.

**Notes:** Amount, method and account are **immutable after creation** — editing only touches descriptive fields. That's a deliberate money-integrity rule; changing an amount would silently rewrite history. If the amount exceeds the user's approval limit (`currentUserMaxExpenseApprovalKoboProvider`), it's saved as pending instead of approved.

---

## B10. Suppliers and payments

### PaymentsScreen
**Purpose:** Supplier list with live ledger balances.
**File:** [lib/features/payments/screens/payments_screen.dart](../lib/features/payments/screens/payments_screen.dart) (459 lines)

**Widget tree:** `Scaffold` → `_buildAppBar` → `_buildSuppliersBody` → `_SupplierRow` list + `_TransactionHistoryLink` → FAB (add supplier).

**State:** A `ConsumerWidget` — no local state. Watches `allSuppliersProvider`, `supplierBalancesKoboProvider`, `currencySymbolProvider`.

**Navigation:** Tab 5 → `SupplierDetailScreen`, `SupplierTransactionsScreen`, `SupplierFormSheet`.

**Notes:** One of the cleanest screens in the app — a stateless `ConsumerWidget` where the data all comes from providers. Good model to copy.

---

### SupplierDetailScreen
**Purpose:** One supplier: balance, ledger history, and crate position.
**File:** [lib/features/inventory/screens/supplier_detail_screen.dart](../lib/features/inventory/screens/supplier_detail_screen.dart) (2,256 lines)

**Widget tree:** `CustomScrollView` → `_buildHeader` → `_buildBalanceCard` → `_SliverTabBarDelegate` tab bar → `_buildHistoryTab` / `_buildCratesTab`.

**Crate functions:** `_buildCrateActionCard(...)`, `_buildCrateSummaryCard(...)`, `_buildCrateMovementStats(...)`, `_buildSupplierCrateRow(...)`, `_showRecordCrateSheet(supplier)`, `_submitCrateMovement(...)`, `_buildPlacedDepositSection(...)`.
**Money-float functions:** `_floatBrands()`, `_buildFloatActionCard(...)`, `_showFloatMoneySheet(supplier)`, `_submitFloatMovement(...)`, `_typedKobo(text)`.
**Ledger functions:** `_showEntryActions(...)`, `_confirmVoid(...)`, `_confirmDelete(supplier)`, `_buildLedgerSummaryRow(...)`.

**Notes:** **A supplier account is a wallet, not a debt.** `balance = payments − goods received`; positive means credit *you* hold with them. Use `supplierWalletBalanceKobo` — `supplierPayableKobo` is the inverse and mixing them up flips every sign. This is the single most confusing money concept in the codebase.

Voiding an entry writes a **compensating row** rather than editing history — that's why the balance nets out correctly and the audit trail survives.

---

### Supplier widgets
| File | Purpose |
|---|---|
| [record_supplier_activity.dart](../lib/features/payments/widgets/record_supplier_activity.dart) (1,161) | `RecordInvoiceSheet` (goods received) and `RecordPaymentSheet` (money paid, with `_pickReceipt()` proof); `_ChooserTile` picks which |
| [supplier_form_sheet.dart](../lib/features/payments/widgets/supplier_form_sheet.dart) (361) | Add/edit a supplier (editing is CEO-only, gated at the caller) |
| [supplier_ledger_entry_tile.dart](../lib/features/payments/widgets/supplier_ledger_entry_tile.dart) (171) | One ledger row — invoices red, payments green, voids struck through |
| [supplier_transactions_screen.dart](../lib/features/payments/screens/supplier_transactions_screen.dart) (363) | Read-only history across all suppliers, period-filtered |

**Notes:** `mixin _SheetColors` in `record_supplier_activity.dart` is the codebase's one use of a Dart **mixin** (a way to share methods into multiple classes without inheritance) — worth reading once for the syntax.

---

## B11. Van sales

A driver takes stock on the road, sells it, and settles up. There are **two separate surfaces**: the manager's (hub, load, reconcile) and the driver's (terminal).

```
Manager:  VanSalesHubScreen → LoadVanScreen → (driver sells) → VanReturnScreen
                            → VanReconcileScreen → close trip
                            → DriversListScreen → DriverProfileScreen → DriverPaymentsScreen

Driver:   DriverTerminalScreen (their entire app) → DriverRunScreen
```

### DriverTerminalScreen
**Purpose:** The driver's whole app — a stripped till with no store picker, no customer, no credit, no discount, no crates.
**File:** [lib/features/van_sales/screens/driver_terminal_screen.dart](../lib/features/van_sales/screens/driver_terminal_screen.dart) (715 lines)

**Widget tree:** `Scaffold` → `BalancePill` (what they owe) → `_StockLine` list (what's on the van) → `_TakePaymentBar` → `_ReceiptView`. Empty states: `_NoOpenTrip`, `_EmptyVan`, `_SwapOnlyBanner`.

**Functions:** `_bump(productId, delta, onVan)` (adjust quantity), `_ring(...)` (ring up the sale).

**Navigation:** Rendered by `_HomeRouter` **instead of** `MainLayout`. Leads only to `DriverRunScreen`.

**Notes:** This is the clearest architectural idea in the app. A driver is restricted *structurally* — the screens they must not reach were never built into their tree — rather than by hiding widgets someone could un-hide. `Gates.vanManage` then backs it up at every write. Read the class doc comment; it explains the reasoning well.

---

### Manager-side van screens
| Screen | Purpose | Key functions | File |
|---|---|---|---|
| `VanSalesHubScreen` | Manager's way in; lists vans with status | `_VanCard`, `_DriversLink`, `_StatusChip` | [van_sales_hub_screen.dart](../lib/features/van_sales/screens/van_sales_hub_screen.dart) (575) |
| `LoadVanScreen` | Load (or restock) a van at an editable per-line load price | `_addProduct(p)`, `_dispatch()`, `_refreshBelowCost()` | [load_van_screen.dart](../lib/features/van_sales/screens/load_van_screen.dart) (788) |
| `VanReturnScreen` | Record what came back | `_addProduct(id, name)`, `_submit()` | [van_return_screen.dart](../lib/features/van_sales/screens/van_return_screen.dart) (602) |
| `VanReconcileScreen` | The settle-up: whole position at load price, then close | `_actions(...)`, `_confirmAndClose(...)` | [van_reconcile_screen.dart](../lib/features/van_sales/screens/van_reconcile_screen.dart) (842) |
| `DriversListScreen` | Every driver and what they owe | `_DriverRow`, `DriverStandingBadge` | [drivers_list_screen.dart](../lib/features/van_sales/screens/drivers_list_screen.dart) (295) |
| `DriverProfileScreen` | One driver's whole money story, 4 tabs | `_balanceCard(...)`, `_onPeriodChanged(v)`, `_driverSince(trips)` | [driver_profile_screen.dart](../lib/features/van_sales/screens/driver_profile_screen.dart) (1,323) |
| `DriverPaymentsScreen` | One trip's money: signed for / handed in / still out | `_BalanceCard`, `_LedgerRow` | [driver_payments_screen.dart](../lib/features/van_sales/screens/driver_payments_screen.dart) (319) |
| `DriverRunScreen` | The driver's **read-only** view of their own run | `_TakenCard`, `_SaleRow` | [driver_run_screen.dart](../lib/features/van_sales/screens/driver_run_screen.dart) (261) |

**Van widgets:** `RecordDriverPaymentSheet` (`_submit`, `_pickReceipt` — proof is *optional* here, unlike supplier payments), `VanWriteOffSheet` (`_submit` — shortages are driver-liable by default; forgiving one is an audited decision), `VanCloseBarrier` (disables Confirm while road sales are unsynced), `VanReceiptView` (`_print`, `_share`), `VanSaleReceiptSheet`, `DriverLedgerEntryTile`.

**Notes worth carrying:**
- **`VanReturnScreen` starts the quantity field empty on purpose, with no "return everything left" button.** Pre-filling from system stock would be actively dangerous: if the driver's device holds unsynced sales, the system's idea of what's left is wrong, and one tap would record a fiction.
- **`VanReconcileScreen` uses `computeVanTripPosition`, a pure function** — so the figure a manager confirms is provably the figure the close writes.
- **A removed driver stays on the list if their balance isn't zero.** Offboarding must not be able to hide a debt.
- `DriverProfileScreen`'s period selector deliberately does **not** move the balance — a balance is cumulative; only the tabs filter.

---

## B12. Staff

### StaffManagementScreen
**Purpose:** Staff and invites, in two tabs.
**File:** [lib/features/staff/screens/staff_management_screen.dart](../lib/features/staff/screens/staff_management_screen.dart) (922 lines)

**Widget tree:** `SharedScaffold` → `TabBar` → `_StaffTab` (`_StaffCard`, `_RoleTag`) / `_InvitesTab` (`_InviteCard`, `_InviteMeta`) → shared invite FAB.

**Functions:** `_SearchField`, `_InvitesTabState._revoke(invite)`, `_StaffCard._avatarColor()`.

**Navigation:** Pushed from the drawer (`Gates.manageStaff`). Leads to `InviteStaffScreen`, `StaffDetailScreen`.

---

### StaffDetailScreen
**Purpose:** One staff member: role, status, store assignments, and the actions on them.
**File:** [lib/features/staff/screens/staff_detail_screen.dart](../lib/features/staff/screens/staff_detail_screen.dart) (976 lines)

**Functions:** `_loadMetrics()`, `_invitableRoles(all, mySlug)` (you can only assign roles below your own), `_changeRole(...)` (`Gates.changeStaffRole`), `_toggleSuspend(membership)` (`Gates.suspendStaff`), `_removeStaff(membership, user)` (`Gates.staffRemove`), `_acknowledgeDriverBalance(...)`, `_editStoreAssignments(user)` (`Gates.assignStaffStores`), `_storeSummary(names)`, `_infoRows(...)`.

**Notes:** `_acknowledgeDriverBalance` is a nice guard: you can't quietly remove a driver who still owes money without acknowledging it. Opening your *own* card gives a read-only view — you still can't manage yourself.

---

### InviteStaffScreen / StaffPermissionsScreen
| File | Purpose | Functions |
|---|---|---|
| [invite_staff_screen.dart](../lib/features/staff/screens/invite_staff_screen.dart) (566) | Generate and share an invite code | `_randomCode()`, `_generate()`, `_copyCode()`, `_shareSms()`, `_shareWhatsApp()`, `_invitableRoles(...)` |
| [staff_permissions_screen.dart](../lib/features/staff/screens/staff_permissions_screen.dart) (402) | Per-person permission overrides | `_setEffective(key, target, roleDefault)`, `_toggle(...)`, `_restoreDefaults(count)`, `_guard()` |

**Notes:** The override model is worth understanding: a toggle shows the **effective** value (role default unless overridden); flipping it away from the default stores an override, flipping it back **clears** the override so it inherits again. The CEO is never overridable.

---

## B13. Stores and transfers

### StoresScreen
**Purpose:** All stores with live stock stats; create, edit, delete.
**File:** [lib/features/stores/screens/stores_screen.dart](../lib/features/stores/screens/stores_screen.dart) (1,299 lines)

**Functions:** `_showAddSheet(context)`, `_showEditSheet(context, store)`, `_confirmDelete(context, store)`, `_buildStoreCard(...)`; `_StoreCard` runs its own inventory subscription (`_subscribeInventory`, re-subscribed in `didUpdateWidget`).

**Gates:** `manageStores`, `requestStoreTransfer`, `dispatchStoreTransfer`, `receiveStoreTransfer`.

**Navigation:** Tab 7 → `StoreDetailsScreen`.

---

### StoreDetailsScreen / RequestStockScreen / StoreTransferHub
| File | Purpose | Functions |
|---|---|---|
| [store_details_screen.dart](../lib/features/stores/screens/store_details_screen.dart) (616) | One store: metrics, inventory, quick actions | `_openRequestScreen(...)`, `_buildMetricOverview(...)`, `_buildRestrictedView(canRequest)` |
| [request_stock_screen.dart](../lib/features/stores/screens/request_stock_screen.dart) (372) | Ask another store to send stock | `_submit()`, `_lockedStoreField(...)` |
| [store_transfer_hub.dart](../lib/features/stores/widgets/store_transfer_hub.dart) (688) | The four-section transfer hub | `_accept()`, `_reject()`, `_receive()`, `_cancel()`, `_askQuantity()` |

**The transfer lifecycle** (each section hides when empty):
1. **Requests to fulfil** — someone asked *this* store for stock → Accept & dispatch / Reject (`dispatchStoreTransfer`)
2. **Incoming stock** — `in_transit` arriving here → Confirm receipt (`receiveStoreTransfer`)
3. **Your requests** — what you asked for
4. **Dispatched** — what you sent

**Notes:** Transfers are **request-initiated**: the store that *needs* stock asks. No stock moves until the holder accepts and dispatches, and it sits in `in_transit` until confirmed — so stock is never in two places or nowhere. `_askQuantity()` returns a Dart **record** (`({int quantity, int empties})`), a modern language feature — the only place it's used.

---

## B14. Settings

Two different settings homes depending on role:

- **CEO** → `SettingsScreen` (business-wide)
- **Manager / Cashier / Stock keeper** → `StaffSettingsScreen` (personal only)

### SettingsScreen (CEO)
**File:** [lib/core/settings/settings_screen.dart](../lib/core/settings/settings_screen.dart) (272 lines)

**Widget tree:** `GlassyScaffold` → search `TextField` → `SettingsTile` rows → `_buildDangerZone`.

**Functions:** `_open(context, screen)`, `_buildDangerZone(context)`, `_chevron(context)`.

**Sub-pages:**
| Screen | Purpose | File |
|---|---|---|
| `BusinessInfoScreen` | Name, type, currency, logo | [business_info_screen.dart](../lib/core/settings/business_info_screen.dart) (641) |
| `StoresSettingsScreen` | Register/edit stores and vans — the only place a store is created after onboarding | [stores_settings_screen.dart](../lib/core/settings/stores_settings_screen.dart) (511) |
| `RolesPermissionsScreen` → `RolePermissionsDetailScreen` | Per-role permissions, discount cap, expense limit, store scope | [roles_permissions_screen.dart](../lib/core/settings/roles_permissions_screen.dart) (154) · [role_permissions_detail_screen.dart](../lib/core/settings/role_permissions_detail_screen.dart) (1,045) |
| `SecuritySettingsScreen` | Auto-lock interval (synced) + biometrics (device-local) | [security_settings_screen.dart](../lib/core/settings/security_settings_screen.dart) (264) |
| `AppearanceSettingsScreen` | The **business** accent colour, synced to all devices | [appearance_settings_screen.dart](../lib/core/settings/appearance_settings_screen.dart) (222) |
| `SubscriptionScreen` | Read-only plan/status/renewal | [subscription_screen.dart](../lib/core/settings/subscription_screen.dart) (252) |
| `ActivityLogsAccessScreen` / `SyncIssuesAccessScreen` | Per-role toggles for two view permissions | [activity_logs_access_screen.dart](../lib/core/settings/activity_logs_access_screen.dart) · [sync_issues_access_screen.dart](../lib/core/settings/sync_issues_access_screen.dart) |
| `DeleteBusinessScreen` | Irreversible delete, confirmed by PIN, online-only | [delete_business_screen.dart](../lib/core/settings/delete_business_screen.dart) (175) |
| `ThemeSettingsScreen` | Per-device light/dark/system | [theme_settings_screen.dart](../lib/core/theme/theme_settings_screen.dart) (138) |

**`RolePermissionsDetailScreen` functions:** `_togglePermission(key, enable)`, `_commitDiscount(value)`, `_commitViewAllStores(enable)`, `_commitExpense()`, `_setStoreEffective(...)`, `_toggleStore(...)`, `_restoreStoreDefaults(storeId, count)`, `_scopeSelector(t)`, `_storePicker(...)`.

**Notes:** The synced-vs-device-local split is deliberate and consistent: business accent colour and auto-lock sync to every device; light/dark mode and biometrics are per-device. The CEO role is locked all-on everywhere — its access can never be removed.

### StaffSettingsScreen
**File:** [lib/features/settings/screens/staff_settings_screen.dart](../lib/features/settings/screens/staff_settings_screen.dart) (111 lines) — edit own name/avatar, change PIN, pick display mode. Small and readable.

### ProfileScreen
**File:** [lib/features/profile/screens/profile_screen.dart](../lib/features/profile/screens/profile_screen.dart) (360 lines)

**Functions:** `_buildStats()`, `_confirmAndResign()`, `_openEditProfileSheet(user)`.
Built from the reusable kit in [profile_ui.dart](../lib/features/profile/widgets/profile_ui.dart): `ProfileHeaderCard`, `ProfileStatGrid`, `ProfileStatCard`, `ProfileInfoCard`, `ProfileInfoRow`.

**Notes:** `profile_ui.dart` is a good example of extracting a reusable widget kit — `StaffDetailScreen` uses the same pieces, so the two screens can't drift apart visually.

---

## B15. Sync, diagnostics and subscription

### Sync Issues
**Purpose:** The troubleshooting screen — what failed to sync and why, with retries.
**File:** [lib/features/sync/screens/sync_issues_screen.dart](../lib/features/sync/screens/sync_issues_screen.dart) (1,371 lines)

**Widget tree:** `Scaffold` → `_deferredCard` → `_healthCard` → orphan / pending / failed item tiles → `_auditCard` + `_auditTable`.

**Functions:** `_probeProfile()` (checks the cloud identity resolves), `_runAudit()` (per-table row-count comparison), `_loadDeferredTables()`, `_retryDeferredPull()`, `_retryAllOrphans()`, `_rejectedSaleOrderId(item)`, `_confirmCancelRejectedSale(...)`, `_diagnose(row)` (turns a diagnostic row into a sentence).

**Notes:** Failed syncs being **visible and actionable** rather than silent is a core design choice for an offline-first app. `_SyncErrorKind` classifies errors so the user gets a human explanation instead of a Postgres code. In practice, most reported "sync bugs" turn out to be device DNS/VPN issues (errno 7) — check this screen before suspecting code.

### Other sync pieces
| File | Purpose |
|---|---|
| [first_load_overlay_controller.dart](../lib/features/sync/controllers/first_load_overlay_controller.dart) (393) | Owns all timing/retry for the first-load overlay; derives state from five injected inputs and owns **no UI** — very testable |
| [resolve_unsynced_data_dialog.dart](../lib/features/sync/widgets/resolve_unsynced_data_dialog.dart) (207) | Blocks logout when unsynced rows exist; `_export()`, `_discardAndLogout()` |
| [sync_pull_banner.dart](../lib/shared/widgets/sync_pull_banner.dart) (536) | The only sync animation: thin top progress line, failure pill, brief success |

### Subscription
| File | Purpose |
|---|---|
| [subscription_access.dart](../lib/features/subscription/subscription_access.dart) | `enum SubscriptionAccess { active, trialActive, trialExpired, inactive, grace }` |
| [subscription_locked_screen.dart](../lib/features/subscription/screens/subscription_locked_screen.dart) (168) | Full-screen lock replacing the whole app |
| [thank_you_subscription_screen.dart](../lib/features/subscription/screens/thank_you_subscription_screen.dart) (286) | Shown once per activation |
| [subscription_badge.dart](../lib/features/subscription/widgets/subscription_badge.dart) (60) | PRO / FREE TRIAL tag |

**Notes:** `grace` means "don't lock" — used whenever subscription state is *unknown* (fresh install, null trial date, unrecognised status). The app only ever locks on a **known** expired state. That's the right default: a sync hiccup must never lock a paying shop out of its till.

### SchemaErrorScreen
**File:** [lib/features/diagnostics/screens/schema_error_screen.dart](../lib/features/diagnostics/screens/schema_error_screen.dart) (183 lines) — the refuse-to-boot screen when the database schema is broken beyond self-repair. Better to stop than to run against a corrupt schema.

---

## B16. Shared widgets you will see everywhere

**Folder:** [lib/shared/widgets/](../lib/shared/widgets/)

| Widget | Purpose |
|---|---|
| `AppButton` | The standard button |
| `AppInput` | **The standard input — a documented design rule says never use raw `TextField`** |
| `SharedScaffold` / `GlassyScaffold` / `GlassyCard` | Page shells and card surface |
| `AppRefreshWrapper` | The **only** pull-to-refresh in the app; arms on real overscroll only |
| `AppDrawer` / `MenuButton` / `TabNavigator` | Navigation chrome |
| `NotificationBell` / `NotificationsModal` | Notification surface |
| `AppFAB` / `AppSpeedDialFab` / `AmberButton` / `StatusBadge` | Actions and badges |
| `PinDialog` | `PinDialog.show(context)` → returns the approving user, or null. Used to gate a protected action behind a manager's PIN |
| `ErrorFallback` | The friendly crash screen; deliberately self-contained with fixed colours so it can render even when the theme is gone |
| `ForceUpdateWrapper` / `AutoLockWrapper` | App-wide wrappers around `MaterialApp` |
| `Skeleton` / `first_load_skeletons.dart` | First-load placeholders (the app avoids spinners) |
| `FirstRunEmptyState` | Persona-aware empty state shared by POS and Inventory |
| `ViewSelectorSheet` / `PrinterPicker` / `UserTipsModal` | Small shared sheets |
| `OptimizedBackdropFilter` | Disables expensive blur during route animations |
| `ActivityLogScreen` | Tab 9 — the audit trail |

**Notes:** `AppRefreshWrapper`'s doc comment is worth reading — it explains why refresh arms only on an `OverscrollNotification` from an active drag, so mid-list scrolling never triggers it.

---

# Part C — Reading the code critically

## C1. Non-idiomatic patterns in this codebase

You asked to be told which code works but isn't how a Flutter developer would normally write it, so you don't learn bad habits from your own app. Here they are, most important first. **None of these are bugs** — the app ships and works. They're places where the shape of the code will teach you the wrong lesson.

---

### 1. Screens are enormous ⚠️ most important

**What:** Twelve files exceed 1,000 lines. The largest:

| Lines | File |
|---|---|
| 2,749 | `customer_detail_screen.dart` |
| 2,508 | `inventory_screen.dart` |
| 2,410 | `product_detail_screen.dart` |
| 2,321 | `checkout_page.dart` |
| 2,310 | `add_product_screen.dart` |
| 2,256 | `supplier_detail_screen.dart` |
| 2,244 | `orders_screen.dart` |
| 2,148 | `daily_reconciliation_detail_screen.dart` |
| 2,004 | `expenses_screen.dart` |

**Why it happens:** an AI asked to "add a feature to this screen" appends a `_buildX()` method. Nothing ever forces extraction, so the file grows forever.

**How a Flutter dev would write it:** each `_buildSomething()` that returns a self-contained chunk of UI becomes its own widget class in its own file. That gives you `const` constructors (Flutter can then skip rebuilding it), independent testability, and a file you can hold in your head.

**Rule of thumb:** if a widget's `build` doesn't fit on one screen, extract. A `_buildX` method taking 4+ parameters is a widget wearing a disguise.

---

### 2. Duplicated private helper widgets

**What:** the same small widget is redefined in file after file, because a `_`-prefixed class is private to its file and can't be reused:

| Class | Copies | Where |
|---|---|---|
| `_Empty` | 5 | van sales screens |
| `_EmptyState` | 4 | approvals, staff, van sales, customers |
| `_SliverTabBarDelegate` | 3 | customer detail, supplier detail, driver profile |
| `_InfoRow` | 3 | customer detail, supplier detail, driver profile |
| `_GlassyCard` | 2 | customer detail, supplier detail |
| `_StepDots` | 2 | CEO sign-up, staff sign-up |
| `_StatusBadge`, `_SaveButton`, `_SaleRow`, `_RoleTag`, `_RoleToggle` | 2 each | various |

`_timeAgo()` and `_fullStamp()` appear **three times inside one file** (`stock_approvals_screen.dart`).

**How a Flutter dev would write it:** one public `EmptyState` / `InfoRow` / `SliverTabBarDelegate` in `lib/shared/widgets/`, imported everywhere. The codebase already knows how to do this — `profile_ui.dart` and the auth widgets folder are exactly right. It just wasn't applied consistently.

**Why it matters to you:** fix a bug in one `_EmptyState` and four others still have it.

---

### 3. Manual `StreamSubscription` instead of `StreamProvider`

**What:** 11 widget files subscribe to database streams by hand — `initState` opens it, `dispose` cancels it, `setState` stores each value:

`main_layout.dart`, `home_screen.dart`, `inventory_screen.dart`, `stores_screen.dart`, `store_details_screen.dart`, `customer_detail_screen.dart`, `checkout_page.dart`, `pos_controller.dart`, `quick_sale_modal.dart`, `profile_screen.dart`, `receive_stock_screen.dart`.

```dart
// The pattern used here:
StreamSubscription<List<OrderData>>? _sub;
@override void initState() {
  _sub = db.ordersDao.watchPendingOrders()
      .listen((orders) { if (mounted) setState(() => _pending = orders); });
}
@override void dispose() { _sub?.cancel(); super.dispose(); }
```

**How a Flutter dev would write it:** a `StreamProvider` (or the codebase's own `businessScopedStream`) and one `ref.watch`. Riverpod handles subscribe, cancel, loading and error states, and caches across rebuilds. The app already has 113 such providers — these 11 just predate or bypass them.

**Why it matters:** hand-rolled subscriptions are where leaks and "setState called after dispose" crashes come from. This code does guard with `if (mounted)`, but that's a guard you shouldn't need.

---

### 4. Four state-management systems at once

Riverpod + `ChangeNotifier` services + a `ValueNotifier` singleton + `setState`. The `mirrorNotifier` bridge exists purely to reconcile the singleton with Riverpod.

**How it would normally be:** one system. `NavigationService`'s state would be a Riverpod `Notifier`, and `mirrorNotifier` wouldn't need to exist.

**Why it's not simply wrong:** this is what incremental growth looks like, and the bridge is well-built and test-enforced. But when *you* add state, use Riverpod — don't extend the singleton.

---

### 5. `PosController` created in `initState`, not a provider

**What:** [pos_home_screen.dart:63](../lib/features/pos/screens/pos_home_screen.dart#L63) builds its controller inside a `Future.microtask` in `initState`, holds it in a nullable field, and every `build` has to handle `_controller == null`.

**How a Flutter dev would write it:** a `Provider`/`NotifierProvider`. The null-check branch disappears, the controller survives widget rebuilds, and it becomes readable from elsewhere.

**Notes:** the controller class *itself* is well written (constructor-injected dependencies, testable). Only the wiring is odd.

---

### 6. Vestigial constructor parameters

`CartScreen` declares `cart` and `onCustomerChanged`, and `MainLayout` passes `cart: []` with a no-op callback. The real data comes from `cartProvider`. A reader reasonably assumes the cart is passed in; it isn't.

**How it would be:** delete the parameters. Dead parameters actively mislead.

---

### 7. State correction inside `build()`

`MainLayout.build` fixes up the active store and bounces non-sellers off the POS tab, deferring the writes with `addPostFrameCallback`. The deferral is correct — you must never mutate state during a build. But a `build` method should *describe* UI, not *correct* state.

**How it would be:** a `ref.listen` at the app level, or logic inside the notifier that owns the value.

---

### 8. Near-duplicate flows

- `CeoSignUpScreen` (1,487) and `StaffSignUpScreen` (1,394) reimplement the same 9-step wizard: step dots, OTP, timers, PIN entry, phone formatting.
- `AddProductScreen` (2,310) and `UpdateProductSheet` (1,562) reimplement the same four autocomplete blocks.
- The three approval card types in `stock_approvals_screen.dart` share ~80% of their code.

**Why it matters:** these are the places where a bug fixed once stays broken elsewhere. When you touch one, check its twin.

---

### 9. One raw role check

`ExpensesScreen._canDelete()` uses `role?.slug == 'ceo'` instead of a gate. Everything else in the app goes through `Gates` — this is the exact pattern the registry was built to eliminate.

---

### What this codebase does genuinely well

So you also learn the right lessons from it:

1. **`recon_data.dart`'s pure functions.** `ReconInputs` + `reconDataFrom()` separate money maths from widgets, so it can be tested and three screens can agree on one number. Best engineering in the repo.
2. **The Gate registry.** Named, centralised permissions instead of scattered role strings — and `Guarded.screen` waiting for permissions to resolve so allowed users never see a denial flash.
3. **`BarcodeScanner` as an interface** with a camera implementation — real dependency inversion, testable with a fake.
4. **`ReceiveCartNotifier`.** Modern Riverpod: immutable state, `copyWith`, a `Notifier`. This is what new code should look like.
5. **Collect-first / commit-once onboarding.** Nothing reaches the cloud until the final confirm, so abandoning halfway leaves no wreckage.
6. **The driver terminal as a separate screen**, not a hidden-widgets mode — restriction by structure, not by concealment.
7. **Offline-first discipline throughout.** The app never blocks opening on a network call, and sync failures are visible and actionable rather than silent.
8. **The comments.** Unusually good — most non-obvious decisions record *why*, often with the issue number. Read them; they're the best documentation in the repo.
9. **258 test files**, including golden tests and ban-tests that fail the build if someone reintroduces a known-bad pattern.

---

### How to use this section

When you copy a pattern out of this codebase, ask: *is this file one of the good examples above, or one of the large ones?* Copy from `receive_cart.dart`, `payments_screen.dart`, `pos_controller.dart`, the auth widgets, and `profile_ui.dart`. Be more careful copying from the 2,000-line detail screens.

---

**Next:** [LEARNING_ROADMAP.md](LEARNING_ROADMAP.md) — a phased path through this material with hands-on exercises.
