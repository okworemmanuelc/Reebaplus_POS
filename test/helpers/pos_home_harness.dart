import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';

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
