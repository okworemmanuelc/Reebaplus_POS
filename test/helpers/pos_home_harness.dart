import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

/// Test double for [CartService] that prevents "used after being disposed"
/// assertion errors when singleton [NavigationService] fires listeners across test runs.
class TestCartService extends CartService {
  TestCartService(super.auth, super.nav);

  @override
  // ignore: must_call_super
  void dispose() {
    // Intentionally no-op to prevent singleton NavigationService.lockedStoreId
    // callbacks from throwing on an already-disposed CartService.
  }
}

/// Initializes a placeholder Supabase instance for tests if not already initialized.
/// Kept completely self-contained in the harness (no Tier-2 env-var dependencies).
Future<SupabaseClient> initTestSupabase() async {
  try {
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  } catch (_) {
    // Already initialized in this process.
  }
  return Supabase.instance.client;
}

/// Standard top status bar (24dp) and bottom gesture inset (24dp) modeled on Android phones.
const EdgeInsets kRealisticPhoneInsets = EdgeInsets.only(top: 24, bottom: 24);

/// Height of the bottom navigation bar rendered by MainLayout.
const double kBottomNavBodyHeight = 56.0;

/// Holds pre-seeded database entities for POS tests.
class PosTestEnvironment {
  final AppDatabase db;
  final String businessId;
  final String storeId;
  final StoreData store;
  final String categoryId;
  final List<ProductData> products;

  const PosTestEnvironment({
    required this.db,
    required this.businessId,
    required this.storeId,
    required this.store,
    required this.categoryId,
    required this.products,
  });

  Future<void> dispose() async {
    await db.close();
  }
}

/// Harness context returned by [pumpPosHome].
class PosHomeHarnessContext {
  final PosTestEnvironment env;
  final BuildContext context;

  const PosHomeHarnessContext({
    required this.env,
    required this.context,
  });

  AppDatabase get db => env.db;
  String get businessId => env.businessId;
  String get storeId => env.storeId;
  List<ProductData> get products => env.products;
}

/// Default product count seeded for POS home tests.
const int kDefaultSeedProductCount = 5;

/// Bootstraps an in-memory test DB and seeds business, store, category,
/// products, and stock rows. Run in [setUp] so Drift SQLite operations
/// execute in real async time without isolate blocking.
Future<PosTestEnvironment> setupTestPosEnvironment({
  int productCount = kDefaultSeedProductCount,
}) async {
  SharedPreferences.setMockInitialValues({
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
  });
  await initTestSupabase();

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final businessId = UuidV7.generate();
  db.businessIdResolver = () => businessId;

  // Force onCreate
  await db.customSelect('SELECT 1').get();

  // Seed business
  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'POS Test Biz',
        ),
      );

  // Seed store
  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ),
      );
  final store = await db.storesDao.getStore(storeId);

  // Seed category
  final categoryId = UuidV7.generate();
  await db.into(db.categories).insert(
        CategoriesCompanion.insert(
          id: Value(categoryId),
          businessId: businessId,
          name: 'Drinks',
        ),
      );

  // Seed products + stock in inventory table
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
    final p = await (db.select(db.products)..where((t) => t.id.equals(pId))).getSingle();
    seededProducts.add(p);
  }

  return PosTestEnvironment(
    db: db,
    businessId: businessId,
    storeId: storeId,
    store: store!,
    categoryId: categoryId,
    products: seededProducts,
  );
}

/// Pumps [PosHomeScreen] with full data scaffolding, deterministic preferences,
/// realistic device insets, and Riverpod overrides.
///
/// Returns a [PosHomeHarnessContext] with references to the environment and captured [BuildContext].
Future<PosHomeHarnessContext> pumpPosHome(
  WidgetTester tester, {
  required PosTestEnvironment env,
  required Size size,
  EdgeInsets? padding = kRealisticPhoneInsets,
  double bottomNavHeight = kBottomNavBodyHeight,
  List<Override> overrides = const [],
  TextScaler? textScaler,
  ThemeData? theme,
  bool showCoachHint = false,
  int posGridColumns = 2,
}) async {
  // 1. Viewport geometry
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 2. SharedPreferences (pinned grid columns + dismissed coach hint by default)
  SharedPreferences.setMockInitialValues({
    'pos_grid_columns': posGridColumns,
    'pos_is_list_view': false,
    'hint_pos_gestures': showCoachHint ? 0 : 2,
  });

  // 3. NavigationService setup (singleton)
  final nav = NavigationService();
  nav.clearStoreLock();
  nav.setLockedStore(env.storeId, explicit: true);
  addTearDown(nav.clearStoreLock);

  // 4. RoleData for CEO
  final roleId = UuidV7.generate();
  final role = RoleData(
    id: roleId,
    businessId: env.businessId,
    name: 'CEO',
    slug: 'ceo',
    isSystemDefault: true,
    isDeleted: false,
    createdAt: DateTime.now(),
    lastUpdatedAt: DateTime.now(),
  );

  // 5. Assemble Riverpod overrides
  final defaultOverrides = <Override>[
    databaseProvider.overrideWithValue(env.db),
    cartProvider.overrideWith((ref) {
      final cart = TestCartService(
        ref.read(authProvider),
        ref.read(navigationProvider),
      );
      return cart;
    }),
    currencySymbolProvider.overrideWithValue('₦'),
    firstLoadSkeletonActiveProvider.overrideWithValue(false),
    selectableStoresProvider.overrideWithValue([env.store]),
    gateContextProvider.overrideWithValue(
      const GateContext(
        grantedKeys: {'sales.make'},
        roleRank: 4,
        isReady: true,
      ),
    ),
    currentUserRoleProvider.overrideWithValue(role),
    currentBusinessNameProvider.overrideWithValue('POS Test Biz'),
    ...overrides,
  ];

  final container = ProviderContainer(
    overrides: defaultOverrides,
  );
  addTearDown(container.dispose);

  // Seed authenticated user so AuthService wires businessIdResolver properly
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

  // 6. Build and pump widget
  late BuildContext capturedContext;
  Widget appContent = const PosHomeScreen();
  if (bottomNavHeight > 0) {
    appContent = Scaffold(
      body: appContent,
      bottomNavigationBar: SizedBox(height: bottomNavHeight),
    );
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme ?? AppTheme.dark(),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: padding ?? EdgeInsets.zero,
            textScaler: textScaler ?? TextScaler.noScaling,
          ),
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return appContent;
            },
          ),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();

  return PosHomeHarnessContext(
    env: env,
    context: capturedContext,
  );
}

/// Cleanly unmounts [PosHomeScreen] and flushes Drift's stream cleanup timers
/// before the test body exits, avoiding '!timersPending' assertions.
Future<void> disposePosHome(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 50));
}

/// Returns the content [Rect] of the [ProductGrid] in logical dp.
Rect gridContentRect(WidgetTester tester) {
  final gridFinder = find.byType(ProductGrid);
  expect(gridFinder, findsOneWidget, reason: 'ProductGrid must be mounted');
  return tester.getRect(gridFinder);
}

/// Returns the content area of the [ProductGrid] in dp².
double gridContentArea(WidgetTester tester) {
  final rect = gridContentRect(tester);
  return rect.width * rect.height;
}

/// Measures the combined vertical span (in dp) of fixed controls above [ProductGrid]:
/// _buildHeader + _buildSearchField + CategoryFilterBar.
///
/// In short viewports with Phase 0 scale (0.70) and 40dp compact fields, this
/// measures ~154dp. On origin/main with width-scale (1.50) and 53dp fields,
/// this measures ~259dp+.
double fixedChromeHeight(WidgetTester tester) {
  final context = tester.element(find.byType(PosHomeScreen));
  final headerPad = context.getRSize(16);
  final headerDropdown = find.byType(AppDropdown<PriceTier>);
  expect(headerDropdown, findsOneWidget, reason: 'Header dropdown must be mounted');

  final headerTop = tester.getTopLeft(headerDropdown).dy - headerPad;
  final gridTop = tester.getTopLeft(find.byType(ProductGrid)).dy;

  return gridTop - headerTop;
}

/// Counts product card tiles that are visible within the [ProductGrid]
/// content rect (rendered in the active viewport).
int visibleProductTileCount(WidgetTester tester) {
  final gridRect = gridContentRect(tester);
  final inkWells = find.descendant(
    of: find.byType(GridView),
    matching: find.byType(InkWell),
  );

  int count = 0;
  for (final elem in inkWells.evaluate()) {
    final renderBox = elem.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) continue;
    final rect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
    final isVisible = rect.top < gridRect.bottom - 0.5 &&
        rect.bottom > gridRect.top + 0.5 &&
        rect.left >= gridRect.left - 0.5 &&
        rect.right <= gridRect.right + 0.5 &&
        rect.height > 0 &&
        rect.width > 0;
    if (isVisible) {
      count++;
    }
  }
  return count;
}
