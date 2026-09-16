import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

import 'screen_harness.dart';

/// POS-specific wrapper over the shared [ScreenTestEnvironment] harness.
///
/// The database, Supabase initialisation and Riverpod-override boilerplate this
/// file used to own now lives in `screen_harness.dart` (issue #243), so every
/// screen can reuse it instead of cloning ~380 lines per screen. What stays here
/// is what is genuinely about the POS home screen: its SharedPreferences keys,
/// and the grid measurements its overflow suite asserts on.
export 'screen_harness.dart'
    show
        TestCartService,
        initTestSupabase,
        kRealisticPhoneInsets,
        kBottomNavBodyHeight,
        kDefaultSeedProductCount;

/// Holds pre-seeded database entities for POS tests.
typedef PosTestEnvironment = ScreenTestEnvironment;

/// Harness context returned by [pumpPosHome].
class PosHomeHarnessContext {
  final PosTestEnvironment env;
  final BuildContext context;

  const PosHomeHarnessContext({required this.env, required this.context});

  AppDatabase get db => env.db;
  String get businessId => env.businessId;
  String get storeId => env.storeId;
  List<ProductData> get products => env.products;
}

/// Bootstraps an in-memory test DB and seeds business, store, category,
/// products, and stock rows, with the POS's own preference defaults. Run in
/// [setUp] so Drift SQLite operations execute in real async time.
Future<PosTestEnvironment> setupTestPosEnvironment({
  int productCount = kDefaultSeedProductCount,
}) {
  return setupScreenTestEnvironment(
    productCount: productCount,
    businessName: 'POS Test Biz',
    sharedPreferences: const {
      'pos_grid_columns': 2,
      'pos_is_list_view': false,
      'hint_pos_gestures': 2,
    },
  );
}

/// Pumps [PosHomeScreen] with full data scaffolding, deterministic preferences,
/// realistic device insets, and Riverpod overrides.
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
  final context = await pumpScreen(
    tester,
    env: env,
    size: size,
    screen: const PosHomeScreen(),
    padding: padding,
    bottomNavHeight: bottomNavHeight,
    overrides: overrides,
    textScaler: textScaler,
    theme: theme,
    sharedPreferences: {
      'pos_grid_columns': posGridColumns,
      'pos_is_list_view': false,
      'hint_pos_gestures': showCoachHint ? 0 : 2,
    },
  );
  return PosHomeHarnessContext(env: env, context: context);
}

/// Cleanly unmounts [PosHomeScreen] and flushes Drift's stream cleanup timers
/// before the test body exits, avoiding '!timersPending' assertions.
Future<void> disposePosHome(WidgetTester tester) => disposeScreen(tester);

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

/// Measures the combined vertical span (in dp) of fixed controls above
/// [ProductGrid]: _buildHeader + _buildSearchField + CategoryFilterBar.
///
/// In short viewports with Phase 0 scale (0.70) and 40dp compact fields, this
/// measures ~154dp. On origin/main with width-scale (1.50) and 53dp fields,
/// this measures ~259dp+.
double fixedChromeHeight(WidgetTester tester) {
  final context = tester.element(find.byType(PosHomeScreen));
  final headerPad = context.getRSize(16);
  final headerDropdown = find.byType(AppDropdown<PriceTier>);
  expect(
    headerDropdown,
    findsOneWidget,
    reason: 'Header dropdown must be mounted',
  );

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
    final isVisible =
        rect.top < gridRect.bottom - 0.5 &&
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
