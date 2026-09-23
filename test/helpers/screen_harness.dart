import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

/// One shared harness for pumping a real screen at a real viewport.
///
/// ### Why this exists (Issue #243 / PRD #239)
///
/// Checking a screen for the "fixed chrome starves the content" defect has to be
/// cheap, or the sweep across the app never finishes. The prior art — the POS
/// home harness — carried ~380 lines of in-memory database, Supabase
/// initialisation and Riverpod overrides. Cloned per screen that is thousands of
/// lines of scaffolding. Everything screen-agnostic lives here instead, so
/// covering a screen costs roughly ten lines: seed an environment in `setUp`,
/// call [pumpScreen] with the widget and a named viewport from `viewports.dart`,
/// assert. `pos_home_harness.dart` is now a thin POS-specific wrapper over this.

/// Test double for [CartService] that prevents "used after being disposed"
/// assertion errors when the singleton [NavigationService] fires listeners
/// across test runs.
class TestCartService extends CartService {
  TestCartService(super.auth, super.nav);

  @override
  // ignore: must_call_super
  void dispose() {
    // Intentionally no-op: singleton NavigationService.lockedStoreId callbacks
    // would otherwise throw on an already-disposed CartService.
  }
}

/// Initialises a placeholder Supabase instance if the process has none.
/// Self-contained: no Tier-2 env-var dependency.
Future<SupabaseClient> initTestSupabase() async {
  try {
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  } catch (_) {
    // Already initialised in this process.
  }
  return Supabase.instance.client;
}

/// Standard top status bar (24dp) and bottom gesture inset (24dp), modelled on
/// Android phones. Screens are laid out under real insets or the measurements
/// lie by ~48dp.
const EdgeInsets kRealisticPhoneInsets = EdgeInsets.only(top: 24, bottom: 24);

/// Height of the bottom navigation bar MainLayout renders under every screen.
const double kBottomNavBodyHeight = 56.0;

/// Default number of products seeded into a screen environment.
const int kDefaultSeedProductCount = 5;

/// A seeded in-memory database plus the ids a screen test needs to address it.
class ScreenTestEnvironment {
  final AppDatabase db;
  final String businessId;
  final String storeId;
  final StoreData store;
  final String categoryId;
  final List<ProductData> products;
  final List<ManufacturerData> manufacturers;

  const ScreenTestEnvironment({
    required this.db,
    required this.businessId,
    required this.storeId,
    required this.store,
    required this.categoryId,
    required this.products,
    required this.manufacturers,
  });

  /// Bounded on the real clock. When a widget test fails, flutter_test leaves
  /// the widget tree mounted, so its Drift subscriptions stay on the test's
  /// stopped fake clock and close() never finishes. Without the bound, that
  /// failure turns into a hang with no error message.
  Future<void> dispose() async {
    await db.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError(
        'Test database did not close within 10s. A widget test probably '
        'failed earlier and left the screen mounted. Look for the first '
        'failure above.',
      ),
    );
  }
}

/// Bootstraps an in-memory Drift database and seeds a business, a store, a
/// category, [manufacturerCount] manufacturers, and [productCount] products
/// with stock.
///
/// Pass `productCount: 0` for the empty-catalogue state — the state that catches
/// content squeezed to zero height, because a scroll view given no room throws
/// nothing and an overflow-only assertion would pass it.
///
/// Run this in `setUp` so Drift's SQLite work happens in real async time rather
/// than inside `pumpWidget`.
Future<ScreenTestEnvironment> setupScreenTestEnvironment({
  int productCount = kDefaultSeedProductCount,
  int manufacturerCount = 0,
  String businessName = 'Test Biz',
  String? businessType,
  Map<String, Object> sharedPreferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(sharedPreferences);
  await initTestSupabase();

  // closeStreamsSynchronously: a Drift stream that loses its last listener
  // normally schedules a Timer.run cleanup, and close() waits for it. Riverpod
  // providers cancel their Drift subscriptions when the harness disposes the
  // container, which happens after the widget test's fake clock has stopped.
  // The timer lands on that dead clock, and close() in tearDown waits
  // forever. A widget test ignores its own timeout in this case, so the whole
  // `flutter test` run hangs.
  final db = AppDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
  );
  final businessId = UuidV7.generate();
  db.businessIdResolver = () => businessId;

  // Force onCreate before the first insert.
  await db.customSelect('SELECT 1').get();

  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(
          id: Value(businessId),
          name: businessName,
          type: businessType == null ? const Value.absent() : Value(businessType),
        ),
      );

  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ),
      );
  final store = await db.storesDao.getStore(storeId);

  final categoryId = UuidV7.generate();
  await db.into(db.categories).insert(
        CategoriesCompanion.insert(
          id: Value(categoryId),
          businessId: businessId,
          name: 'Drinks',
        ),
      );

  final seededManufacturers = <ManufacturerData>[];
  for (int i = 1; i <= manufacturerCount; i++) {
    final mId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: Value(mId),
            businessId: businessId,
            name: 'Manufacturer $i',
          ),
        );
    seededManufacturers.add(
      await (db.select(db.manufacturers)..where((t) => t.id.equals(mId)))
          .getSingle(),
    );
  }

  final seededProducts = <ProductData>[];
  for (int i = 1; i <= productCount; i++) {
    final pId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(pId),
            businessId: businessId,
            categoryId: Value(categoryId),
            name: 'Product $i',
            retailerPriceKobo: const Value(100000), // ₦1,000.00
            wholesalerPriceKobo: const Value(90000), // ₦900.00
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            storeId: storeId,
            productId: pId,
            quantity: const Value(50),
          ),
        );
    seededProducts.add(
      await (db.select(db.products)..where((t) => t.id.equals(pId)))
          .getSingle(),
    );
  }

  return ScreenTestEnvironment(
    db: db,
    businessId: businessId,
    storeId: storeId,
    store: store!,
    categoryId: categoryId,
    products: seededProducts,
    manufacturers: seededManufacturers,
  );
}

/// Pumps [screen] at [size] with the environment's database, a CEO role, real
/// device insets and the bottom navigation bar MainLayout puts under every
/// screen.
///
/// Returns the captured [BuildContext] so a test can read responsive getters.
Future<BuildContext> pumpScreen(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required Size size,
  required Widget screen,
  EdgeInsets? padding = kRealisticPhoneInsets,
  double bottomNavHeight = kBottomNavBodyHeight,
  List<Override> overrides = const [],
  Set<String> grantedKeys = const {'sales.make'},
  String roleSlug = 'ceo',
  String roleName = 'CEO',
  int roleRank = 4,
  TextScaler? textScaler,
  ThemeData? theme,
  Map<String, Object>? sharedPreferences,
  bool settle = true,
  List<StoreData>? selectableStores,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Only reset the mock store when the caller names the preferences this pump
  // needs. Omitting it keeps whatever [setupScreenTestEnvironment] seeded —
  // resetting unconditionally would silently wipe a screen's setUp defaults.
  if (sharedPreferences != null) {
    SharedPreferences.setMockInitialValues(sharedPreferences);
  }

  final nav = NavigationService();
  nav.clearStoreLock();
  nav.setLockedStore(env.storeId, explicit: true);
  addTearDown(nav.clearStoreLock);

  final role = RoleData(
    id: UuidV7.generate(),
    businessId: env.businessId,
    name: roleName,
    slug: roleSlug,
    isSystemDefault: true,
    isDeleted: false,
    createdAt: DateTime.now(),
    lastUpdatedAt: DateTime.now(),
  );

  final container = ProviderContainer(
    overrides: <Override>[
      databaseProvider.overrideWithValue(env.db),
      cartProvider.overrideWith(
        (ref) => TestCartService(
          ref.read(authProvider),
          ref.read(navigationProvider),
        ),
      ),
      currencySymbolProvider.overrideWithValue('₦'),
      firstLoadSkeletonActiveProvider.overrideWithValue(false),
      selectableStoresProvider.overrideWithValue(
        selectableStores ?? [env.store],
      ),
      gateContextProvider.overrideWithValue(
        GateContext(
          grantedKeys: grantedKeys,
          roleRank: roleRank,
          isReady: true,
        ),
      ),
      currentUserRoleProvider.overrideWithValue(role),
      currentUserPermissionsProvider.overrideWithValue(grantedKeys),
      currentBusinessNameProvider.overrideWithValue('Test Biz'),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);

  container.read(authProvider).value = UserData(
    id: 'test-user-id',
    businessId: env.businessId,
    name: 'Test Admin',
    pin: '1234',
    createdAt: DateTime.now(),
    lastUpdatedAt: DateTime.now(),
    avatarColor: '#3B82F6',
    biometricEnabled: false,
  );
  env.db.businessIdResolver = () => env.businessId;

  Widget content = screen;
  if (bottomNavHeight > 0) {
    content = Scaffold(
      body: content,
      bottomNavigationBar: SizedBox(height: bottomNavHeight),
    );
  }

  late BuildContext capturedContext;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme ?? AppTheme.dark(),
        // Size is read from the view rather than pinned to [size] (they start
        // equal), so a test that rotates via tester.view.physicalSize reaches
        // the screen.
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQueryData(
              size: MediaQuery.sizeOf(context),
              padding: padding ?? EdgeInsets.zero,
              textScaler: textScaler ?? TextScaler.noScaling,
            ),
            child: Builder(
              builder: (context) {
                capturedContext = context;
                return content;
              },
            ),
          ),
        ),
      ),
    ),
  );

  if (settle) {
    await tester.pumpAndSettle();
  }
  return capturedContext;
}

/// Unmounts the screen and flushes Drift's stream-cleanup timers before the
/// test body exits, avoiding `!timersPending` assertions.
Future<void> disposeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 50));
}

// ---------------------------------------------------------------------------
// The two assertions (PRD #239)
// ---------------------------------------------------------------------------

/// Asserts no layout overflow was reported while the screen was pumped.
///
/// This is the *loud* failure mode — the red "BOTTOM OVERFLOWED BY N PIXELS"
/// band. It is necessary and on its own nowhere near sufficient: a scroll view
/// handed zero height throws nothing at all. Always pair it with
/// [expectContentRowVisible].
void expectNoOverflow(WidgetTester tester, {String? reason}) {
  final exception = tester.takeException();
  expect(
    exception,
    isNull,
    reason: reason ??
        'A layout overflow was reported: $exception',
  );
}

/// Asserts at least [minimum] complete rows matched by [rows] are laid out with
/// real height and are hit-testable.
///
/// This is the *silent* failure mode the PRD exists to prevent: with products in
/// the catalogue a starved list renders at zero height, shows nothing, and
/// reports no error. An overflow-only test passes it.
///
/// "Complete" means the row's rect falls entirely inside the viewport and
/// hit-tests to itself at its centre, so a list clipped to a 3dp sliver of its
/// first row does not count.
///
/// Pass [scrollable] to allow the assertion to scroll first. That is not a
/// weakening — it is the contract the PRD asks for. On the shortest supported
/// landscape phone the app bar, the summary cards, the tab bar and the filter
/// band together exceed the whole 360dp viewport, so no structure can put a row
/// on screen at rest there without hiding a control or shrinking a tap target,
/// both of which the PRD forbids. What the fix guarantees is that the screen is
/// *one scrollable surface*: the row exists, at full height, and one scroll
/// reaches it. Before the fix there was nothing to scroll to — the list was
/// exactly 0.0dp tall.
///
/// Returns the number of rows visible before any scrolling, so a test can
/// record the honest at-rest number rather than assert a pixel budget.
Future<int> expectContentRowVisible(
  WidgetTester tester,
  Finder rows, {
  int minimum = 1,
  Finder? scrollable,
  String? reason,
}) async {
  final atRest = visibleRowCount(tester, rows);
  var count = atRest;
  if (count < minimum && scrollable != null) {
    count = await _scrollUntilRowsVisible(tester, rows, scrollable, minimum);
  }
  expect(
    count,
    greaterThanOrEqualTo(minimum),
    reason: reason ??
        'Expected at least $minimum complete content row(s) laid out and '
            'hit-testable, found $count. A zero-height list reports no '
            'overflow — this is the silent failure mode.',
  );
  return atRest;
}

/// Drags [scrollable] up in viewport-sized steps until [minimum] rows are
/// visible or the surface stops moving. Bounded so a genuinely empty or
/// zero-height list fails fast rather than spinning.
Future<int> _scrollUntilRowsVisible(
  WidgetTester tester,
  Finder rows,
  Finder scrollable,
  int minimum,
) async {
  var best = visibleRowCount(tester, rows);
  for (var step = 0; step < 8 && best < minimum; step++) {
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scrollable, matching: find.byType(Scrollable)).first,
        )
        .position;
    final before = position.pixels;
    await tester.drag(scrollable, const Offset(0, -160));
    await tester.pumpAndSettle();
    best = visibleRowCount(tester, rows);
    if (position.pixels == before) break; // surface exhausted
  }
  return best;
}

/// Counts widgets matched by [rows] that are laid out with non-zero size, fall
/// entirely inside the viewport, and hit-test to themselves at their centre.
int visibleRowCount(WidgetTester tester, Finder rows) {
  final viewport = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  var count = 0;
  for (final element in rows.evaluate()) {
    final box = element.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) continue;
    if (box.size.height <= 0 || box.size.width <= 0) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final fullyVisible = rect.top >= viewport.top - 0.5 &&
        rect.bottom <= viewport.bottom + 0.5 &&
        rect.left >= viewport.left - 0.5 &&
        rect.right <= viewport.right + 0.5;
    if (!fullyVisible) continue;
    // Hit-testable: something at the row's centre must belong to this subtree.
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, rect.center, tester.view.viewId);
    final reachesRow = hit.path.any((entry) => entry.target == box);
    if (!reachesRow) continue;
    count++;
  }
  return count;
}

/// The rendered height of the widget matched by [finder], in logical dp.
/// Returns 0 when nothing matches, which is itself a finding.
double bandHeight(WidgetTester tester, Finder finder) {
  final elements = finder.evaluate();
  if (elements.isEmpty) return 0;
  final box = elements.first.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return 0;
  return box.size.height;
}
