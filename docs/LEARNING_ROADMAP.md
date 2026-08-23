# Learning Flutter with Reebaplus POS

A suggested **order** to learn Flutter and Dart, using this app as the textbook. You already know JavaScript, so this skips programming fundamentals and focuses on what's different.

Companion reference: [CODEBASE_MAP.md](CODEBASE_MAP.md) — browsable, any order, any time. This file is the path; that one is the map.

---

## Before you start

### Set up your loop

```bash
flutter devices                # what can I run on?
flutter run                    # build + install + attach (use an emulator)
```

While it's running, in that terminal:
- `r` — **hot reload**: inject code changes, keep app state. Sub-second. Your main loop.
- `R` — **hot restart**: restart from `main()`, lose state. Use when you change `initState`, a provider, or anything `const`.
- `q` — quit.

> ⚠️ **Never run `flutter build apk` for testing.** It's slow and this project's workflow is emulator-only. `flutter run` is the loop.

Other commands you'll want:

```bash
flutter analyze                          # static analysis — run before every commit
flutter test                             # all 258 tests
flutter test test/currency_format_test.dart   # one file
dart run build_runner build --delete-conflicting-outputs   # regenerate Drift .g.dart files
```

### How to use each phase

Each phase has **Read → Look for → Try**. Do the "Try" — a 30-second edit you watch hot-reload teaches more than an hour of reading. All the exercises are low-risk and revert with `git checkout` on a file you haven't otherwise touched.

### One warning about your own codebase

Parts of this app are much larger than a Flutter developer would normally write — several screens exceed 2,000 lines, and some small widgets are copy-pasted across five files. That's normal for AI-assisted growth, and it isn't broken, but **don't take file size as the model to copy.** [Part C of the map](CODEBASE_MAP.md#c1-non-idiomatic-patterns-in-this-codebase) lists exactly which patterns to imitate and which to avoid. Skim it now, then re-read it after Phase 3 when it'll mean more.

---

## Phase 1 — Dart, and the shape of a widget

**Goal:** read Dart without tripping over syntax.

### Read

1. [`lib/features/auth/screens/coming_soon_screen.dart`](../lib/features/auth/screens/coming_soon_screen.dart) — 63 lines, the simplest screen in the app. Read the whole thing.
2. [`lib/features/auth/screens/welcome_screen.dart`](../lib/features/auth/screens/welcome_screen.dart) — 233 lines, adds an animation and small private widgets.
3. [`lib/core/utils/number_format.dart`](../lib/core/utils/number_format.dart) — plain Dart functions, no widgets.

### Look for

**Coming from JS, these five things will trip you:**

| Dart | What it means |
|---|---|
| `String? name` | Can be null. Without `?`, it *cannot* — the compiler enforces it. |
| `name!` | "I promise this isn't null." Crashes if you're wrong. |
| `name ?? 'default'` | Same as JS `??`. |
| `final` vs `const` | `final` = set once at runtime. `const` = known at compile time, and for widgets means "build once, reuse forever". |
| `required this.title` | Named parameter, compulsory, checked at compile time. |

In `ComingSoonScreen`, notice:
- `class ComingSoonScreen extends StatelessWidget` — a component with no changing data.
- `const ComingSoonScreen({super.key, required this.title, required this.message})` — the constructor. `super.key` passes Flutter's identity key up.
- `Widget build(BuildContext context)` — this is your `render()`. It returns a tree.
- Widgets nest as constructor arguments: `Scaffold(body: Center(child: Padding(child: Column(children: [...]))))`. There is no JSX and no stylesheet — **padding, centring and spacing are all widgets.**

In `WelcomeScreen`, additionally notice `initState()` (≈ `useEffect(fn, [])`) and `dispose()` (≈ the cleanup return) on the `State` class.

### Try it

Open [`coming_soon_screen.dart`](../lib/features/auth/screens/coming_soon_screen.dart). Find the `Icon` at line 40 and change its size:

```dart
Icon(
  Icons.hourglass_empty_rounded,
  size: 96,   // was 56
```

Reach the screen via the drawer → Display, or just temporarily return `const ComingSoonScreen(title: 'Test', message: 'Hello')` from another screen's `build`. Hit `r`. Then change `Icons.hourglass_empty_rounded` to `Icons.rocket_launch` and reload again.

**Then break it on purpose:** delete the `?` from a nullable variable somewhere and run `flutter analyze`. Reading Dart's null-safety errors early makes them much less scary later.

**Map sections:** [ComingSoonScreen](CODEBASE_MAP.md#comingsoonscreen) · [WelcomeScreen](CODEBASE_MAP.md#welcomescreen) · [Glossary](CODEBASE_MAP.md#glossary)

---

## Phase 2 — Widgets and layout

**Goal:** predict what a widget tree will look like on screen, and build one yourself.

### Read

1. [`lib/shared/widgets/shared_scaffold.dart`](../lib/shared/widgets/shared_scaffold.dart) (46 lines) — how every tab screen gets its drawer and app bar.
2. [`lib/features/auth/widgets/pin_keypad.dart`](../lib/features/auth/widgets/pin_keypad.dart) (144) — `PinDots`, `PinKey`, `PinKeypad`: three small widgets composing into one control. **This is what good Flutter looks like.**
3. [`lib/features/profile/widgets/profile_ui.dart`](../lib/features/profile/widgets/profile_ui.dart) (367) — a reusable widget kit used by two different screens.
4. [`lib/features/payments/screens/payments_screen.dart`](../lib/features/payments/screens/payments_screen.dart) (459) — a full, clean screen.

### Look for

**The layout primitives**, which cover most of what you'll write:

| Widget | Does |
|---|---|
| `Column` / `Row` | Vertical / horizontal stack. `children:` is a list. |
| `Expanded` / `Flexible` | Take remaining space inside a Column/Row (≈ `flex: 1`). |
| `Stack` / `Positioned` | Overlap children (≈ `position: absolute`). |
| `Padding` / `SizedBox` | Space. `SizedBox(height: 16)` is the idiomatic gap. |
| `Container` | Box with decoration/colour/size. |
| `ListView.builder` | Lazily-built scrolling list — only builds visible rows. |
| `SingleChildScrollView` | Makes fixed content scrollable. |

**`mainAxisAlignment` vs `crossAxisAlignment`** is the flexbox mapping, and it's the thing beginners get wrong most: in a `Column`, main = vertical, cross = horizontal. In a `Row`, it's the other way round.

**Theming:** notice nothing hardcodes colours. It's `Theme.of(context).colorScheme.primary`. Since this app has 5 accent themes × light/dark, a hardcoded colour breaks 9 of 10 combinations.

**Also notice** how `PinKeypad` takes a `leadingKey` parameter so the login screen can slot a biometric button into the keypad's empty corner — composition instead of a boolean flag. That's the habit to copy.

### Try it

**A —** In [`payments_screen.dart`](../lib/features/payments/screens/payments_screen.dart), find `_SupplierRow` and change its layout: swap a `Row` to a `Column`, or add `SizedBox(width: 8)` between elements. Hot reload after each change and watch what moves.

**B —** Add a debug border to see a widget's real bounds:

```dart
Container(
  decoration: BoxDecoration(border: Border.all(color: Colors.red)),
  child: /* the widget you're inspecting */,
)
```

This is the Flutter equivalent of `outline: 1px solid red` and it's the fastest way to understand layout.

**C —** Build your own from scratch. Create `lib/features/auth/screens/my_test_screen.dart`, copy `ComingSoonScreen`, and add a `Row` of two `Icon`s under the message. Push to it temporarily from a button somewhere.

**Map sections:** [Theming and shared shells](CODEBASE_MAP.md#a7-theming-and-shared-shells) · [Auth widgets](CODEBASE_MAP.md#auth-widgets-shared-building-blocks) · [PaymentsScreen](CODEBASE_MAP.md#paymentsscreen)

---

## Phase 3 — State: `setState`, then Riverpod

**Goal:** know which of the app's four state mechanisms you're looking at, and add a provider yourself.

This is the biggest conceptual jump from React. Take it slowly.

### Read, in this order

1. **`setState` first** — [`lib/features/auth/screens/biometric_setup_screen.dart`](../lib/features/auth/screens/biometric_setup_screen.dart) (181). Small, local state only.
2. **A stateless Riverpod consumer** — [`lib/features/payments/screens/payments_screen.dart`](../lib/features/payments/screens/payments_screen.dart). A `ConsumerWidget` that only reads providers. Note it has *no* local state at all.
3. **The provider definitions** — [`lib/core/providers/app_providers.dart`](../lib/core/providers/app_providers.dart), first 130 lines only. See how `databaseProvider`, `authProvider`, `cartProvider` are declared.
4. **A modern notifier** — [`lib/features/receiving/state/receive_cart.dart`](../lib/features/receiving/state/receive_cart.dart) (183). **The best state code in the app.** Immutable list, `copyWith`, a `Notifier`.
5. **A `ChangeNotifier` controller** — [`lib/features/pos/controllers/pos_controller.dart`](../lib/features/pos/controllers/pos_controller.dart) (212). Dependencies injected via constructor.

### Look for

**The mental model**, in JS terms:

```dart
// Declaring a provider ≈ creating a store
final myThingProvider = Provider<Thing>((ref) => Thing());

// In a widget:
final thing = ref.watch(myThingProvider);   // subscribe → rebuilds on change
final thing = ref.read(myThingProvider);    // one-shot → use in onPressed
ref.listen(myThingProvider, (prev, next) { … });  // side effect, no rebuild
```

**The rule that matters:** `watch` in `build`, `read` in callbacks. Using `read` in `build` gives you a stale value that never updates; using `watch` in a callback throws.

**`AsyncValue`** wraps anything async. You handle three cases:

```dart
ref.watch(someStreamProvider).when(
  data: (value) => Text('$value'),
  loading: () => const CircularProgressIndicator(),
  error: (e, st) => Text('Error: $e'),
);
```

**Now identify all four systems** (details in [map A2](CODEBASE_MAP.md#a2-state-management-what-the-app-actually-uses)):

| You see | It is |
|---|---|
| `ref.watch(...)` | Riverpod |
| `setState(() => ...)` | Local widget state |
| `ListenableBuilder` / `ValueListenableBuilder` | A ChangeNotifier / ValueNotifier |
| `nav.currentIndex.value = 2` | The NavigationService singleton |

**The house rule you must not break:** for business data, use `businessScopedStream` (from [`business_scoped_stream.dart`](../lib/core/providers/business_scoped_stream.dart)), never a raw `StreamProvider`. A raw one can build before login and read the wrong tenant's data. There's a test that fails the build if you use one.

### Try it

**A — Watch a rebuild happen.** In `payments_screen.dart`'s `build`, add:

```dart
debugPrint('PaymentsScreen rebuilt at ${DateTime.now()}');
```

Open the Suppliers tab, then add or edit a supplier. Watch the terminal: the rebuild fires by itself when the underlying data changes. Nobody called `setState`. That's Riverpod.

**B — Add your own provider.** In `app_providers.dart`:

```dart
final myCounterProvider = StateProvider<int>((ref) => 0);
```

Then in any `ConsumerWidget`'s build:

```dart
final count = ref.watch(myCounterProvider);
// ...
Text('Count: $count'),
ElevatedButton(
  onPressed: () => ref.read(myCounterProvider.notifier).state++,
  child: const Text('Increment'),
),
```

Hot restart (`R`, not `r` — you added a provider). Tap it. Then **navigate to another tab and back**: the count survives, because it lives in the provider, not the widget. That's the whole point of Riverpod in one experiment.

**C — Read the difference.** Open `receive_cart.dart` and `cart_service.dart` side by side. Same job — a cart — written years apart. One has immutable state and `copyWith`; the other is a `ChangeNotifier` over `List<Map<String, dynamic>>`. Decide which you'd rather debug.

**Map sections:** [State management](CODEBASE_MAP.md#a2-state-management-what-the-app-actually-uses) · [Receive cart state](CODEBASE_MAP.md#receive-cart-state) · [PosController](CODEBASE_MAP.md#poscontroller)

---

## Phase 4 — Navigation and permissions

**Goal:** trace how the app decides what to show, and add a screen.

### Read

1. [`lib/main.dart`](../lib/main.dart), the `_HomeRouter` class (line 632 to end) — **read `_resolve()` line by line.** It's the whole app's routing in one method.
2. [`lib/shared/widgets/main_layout.dart`](../lib/shared/widgets/main_layout.dart) (517) — the 10-tab shell.
3. [`lib/shared/services/navigation_service.dart`](../lib/shared/services/navigation_service.dart) (222) — tab index, back-button handling, active store.
4. [`lib/shared/widgets/app_drawer.dart`](../lib/shared/widgets/app_drawer.dart), the `_buildNavList` method — every item and its gate.
5. [`lib/core/permissions/gate_registry.dart`](../lib/core/permissions/gate_registry.dart) — skim; ~50 named gates.

### Look for

**There is no route table.** No `go_router`, no named routes. Three layers instead ([map A3](CODEBASE_MAP.md#a3-navigation-three-layers)):

1. `_HomeRouter._resolve()` picks the root screen from app state.
2. `MainLayout` holds 10 tabs, each with its own independent `Navigator`.
3. Inside a tab, `Navigator.push(MaterialPageRoute(...))`.

**Pushing and returning a value** — this is Dart's `await` doing something JS routers don't:

```dart
final result = await Navigator.of(context).push<bool>(
  MaterialPageRoute(builder: (_) => const ConfirmScreen()),
);
// execution pauses here until that screen pops
if (result == true) { … }
```

**Permissions shape the tree, not just the buttons.** In `main_layout.dart`, `Gates.makeSale` decides whether the POS tab *exists* in `tabOrder`. In the drawer, gates decide whether items are built at all. The house rule is *hide what the role can't use*.

**`Guarded.screen`** ([guarded.dart](../lib/core/permissions/guarded.dart)) waits for permissions to resolve before deciding — otherwise a CEO would see "no access" flash while grants load. Subtle and worth copying.

### Try it

**A — Trace the router.** Add `debugPrint` lines inside `_resolve()` in `main.dart`, one per branch:

```dart
if (user == null) {
  debugPrint('[router] no user');
  ...
}
```

Hot restart, then log out and back in. The terminal narrates your app's routing decisions.

**B — Add a screen and reach it.** Create `lib/features/auth/screens/my_test_screen.dart` (copy `ComingSoonScreen`'s shape). Then in `app_drawer.dart`'s `_buildNavList`, add an item near the Display one:

```dart
ListTile(
  leading: const Icon(Icons.science_outlined),
  title: const Text('My test screen'),
  onTap: () => _pushRoute(context, ref, const MyTestScreen()),
),
```

Hot restart, open the drawer, tap it. You've now added a route end-to-end.

**C — Feel a gate.** Temporarily wrap your drawer item:

```dart
if (Gates.manageStaff.allows(ref))
  ListTile( ... ),
```

Log in as a cashier: the item is gone. Not disabled — absent.

**Map sections:** [Navigation](CODEBASE_MAP.md#a3-navigation-three-layers) · [MainLayout](CODEBASE_MAP.md#mainlayout--the-logged-in-shell) · [AppDrawer](CODEBASE_MAP.md#appdrawer--the-side-menu) · [Permissions](CODEBASE_MAP.md#a6-permissions-the-gate-system)

---

## Phase 5 — Data: Drift, async and sync

**Goal:** follow one piece of data from the database to the screen, and back out to the cloud.

### Read

1. [`lib/core/database/app_database.dart`](../lib/core/database/app_database.dart), lines 42–250 only — table definitions (`Businesses`, `Stores`, `Users`, `Products`). Don't read all 66.
2. [`lib/core/database/daos_orders.dart`](../lib/core/database/daos_orders.dart) — pick two or three methods and read them properly.
3. [`lib/core/providers/business_scoped_stream.dart`](../lib/core/providers/business_scoped_stream.dart) (105) — the helper every business-data provider uses.
4. [`lib/main.dart`](../lib/main.dart) `_bootstrap()`, lines 62–118 — startup order.
5. [`lib/features/sync/screens/sync_issues_screen.dart`](../lib/features/sync/screens/sync_issues_screen.dart) — skim `_runAudit()` and `_diagnose()`.

### Look for

**`Future` vs `Stream`** — the distinction that makes this app reactive:

```dart
Future<List<Order>> getOrders();     // one answer, then done      (≈ Promise)
Stream<List<Order>> watchOrders();   // re-emits on every change    (≈ Observable)
```

Drift's `watch*` methods re-fire whenever the underlying table changes. That's why the UI updates after a write without anyone calling refresh. **Method naming is the tell:** `get*` = Future, `watch*` = Stream.

**The offline-first write path** ([map A5](CODEBASE_MAP.md#a5-the-data-layer-offline-first)):

```
action → SQLite write → sync_queue row → (background) push → Supabase
                                                                ↓
                                          pull → SQLite → UI updates
```

Nothing blocks on the network. Note in `_bootstrap()` that Supabase is initialised **without `await`** — deliberately.

**Money is integer kobo.** Every money column ends `_kobo` and is an `int`. Display with `formatCurrency()`; never hardcode `₦`, because the symbol is a business setting. Never use `double` for money.

**Generated code:** `app_database.g.dart` is machine-written. Edit `app_database.dart`, then run `dart run build_runner build --delete-conflicting-outputs`.

### Try it

**A — Watch a stream fire.** In [`main_layout.dart`](../lib/shared/widgets/main_layout.dart), find the `watchPendingOrders()` subscription in `initState` and add a print:

```dart
.listen((orders) {
  debugPrint('[orders] pending count: ${orders.length}');
  if (mounted) setState(() => _pendingOrders = orders);
});
```

Hot restart, then complete a sale. The stream fires by itself and the Orders tab badge updates. You've watched the reactive chain end to end.

**B — Read a DAO method and predict.** Pick any `watch*` method in `daos_orders.dart`. Read the query. Predict what changes to the database would make it re-emit. Then make one in the app and check.

**C — See the sync queue.** Turn off the emulator's network (or enable airplane mode), make a sale, then open **Sync Issues** from the drawer. Your write is sitting in the queue. Turn the network back on and watch it drain. This is the single most useful demo of what "offline-first" actually means in this app.

**D — Run the tests.** `flutter test test/golden/` — golden tests capture known-good database outcomes so a refactor can't silently change the money maths.

**Map sections:** [The data layer](CODEBASE_MAP.md#a5-the-data-layer-offline-first) · [Sync Issues](CODEBASE_MAP.md#sync-issues) · [Daily Reconciliation](CODEBASE_MAP.md#daily-reconciliation-list--detail)

---

## Phase 6 — The parts that make it a real shipped app

**Goal:** understand what's already in production under your name.

### Read

1. [`pubspec.yaml`](../pubspec.yaml) — dependencies and version.
2. [`android/app/build.gradle.kts`](../android/app/build.gradle.kts) — `applicationId`, signing config.
3. [`lib/core/services/crash_reporter.dart`](../lib/core/services/crash_reporter.dart) — how errors are captured.
4. [`lib/shared/widgets/force_update_wrapper.dart`](../lib/shared/widgets/force_update_wrapper.dart) (133) — how you force users onto a new version.

### Look for

**Versioning.** `pubspec.yaml` says `version: 1.0.7+7`. The part before `+` is the version *name* users see; after `+` is the version *code* Play Store orders releases by. **The build number must increase on every upload** or Play rejects it.

**Signing.** `android/key.properties` exists locally and is (correctly) not in git. Release builds sign with it; without it, Gradle falls back to the debug key — which Play Store will reject. Losing that keystore means you can never update this app again, so back it up somewhere safe.

**Package id:** `com.reebaplus.pos` — permanent. It cannot be changed after publishing.

**Crash handling** has three layers, all set up in `_bootstrap()`:
- `runZonedGuarded` catches uncaught async errors.
- `CrashReporter.install()` catches Flutter framework errors.
- `ErrorWidget.builder = ErrorFallback` replaces the red error box with a calm screen.

Errors go into a synced `error_logs` table, so you can see production crashes in Supabase.

**Dependency pinning worth understanding.** `url_launcher: ">=6.3.0 <6.4.0"` is pinned deliberately because platform config files must stay in sync with the plugin version. And the `hooks:` block at the top of `pubspec.yaml` stops `sqlite3` from downloading a library from GitHub at build time — which used to break offline builds. Both are comments worth reading: they're recorded pain.

### Try it

**A — Check what's live:**

```bash
flutter analyze                 # must be clean before any release
flutter test                    # 258 files
grep -n "^version:" pubspec.yaml
```

**B — Trigger the crash screen.** Temporarily add `throw Exception('test');` at the top of some screen's `build`, hot reload, and open it. You'll get the friendly `ErrorFallback`, not a red box, and a row lands in `error_logs`. **Remove it afterwards.**

**C — Read one ADR.** [`docs/adr/`](adr/) holds 23 architecture decision records explaining *why* things are the way they are. Start with [`0002-named-gate-registry.md`](adr/0002-named-gate-registry.md) (the permission system you met in Phase 4) and [`0005-fifo-batch-costing.md`](adr/0005-fifo-batch-costing.md) (how stock cost is calculated).

**Map sections:** [What this app is](CODEBASE_MAP.md#a1-what-this-app-is) · [Sync and diagnostics](CODEBASE_MAP.md#b15-sync-diagnostics-and-subscription)

---

## After the six phases

### Read in this order when you're ready for the deep end

1. [`recon_data.dart`](../lib/features/dashboard/reconciliation/recon_data.dart) — the pure-function money engine. The best code in the repo. Read `ReconInputs`' doc comment first.
2. [`checkout_page.dart`](../lib/features/pos/screens/checkout_page.dart) `_confirmPayment()` — everything the app knows about money in one function.
3. [`driver_terminal_screen.dart`](../lib/features/van_sales/screens/driver_terminal_screen.dart) — read the class doc comment for how to restrict a role by structure rather than concealment.

### A good first real contribution

Pick one duplicated widget from [map C1](CODEBASE_MAP.md#2-duplicated-private-helper-widgets) — `_EmptyState` is the easiest, with 4 copies — and:

1. Create one public `EmptyState` in `lib/shared/widgets/`.
2. Replace the copies one file at a time, running `flutter analyze` after each.
3. Run `flutter test`.

Small, safe, reversible, and it teaches you imports, widget parameters and the shared-widget layout in one go. It also genuinely improves the app.

### Habits worth keeping

- `flutter analyze` before every commit.
- Hot reload (`r`) constantly; hot restart (`R`) after provider, `initState` or `const` changes.
- Read the comments — they're the best documentation in this repo, and most record *why*.
- When adding state, use Riverpod. Don't extend `NavigationService`.
- When adding money code, use integer kobo and put the maths in a pure function.
- When a `build` method stops fitting on your screen, extract a widget.

---

**Reference:** [CODEBASE_MAP.md](CODEBASE_MAP.md) — every screen, function and file, browsable in any order.
