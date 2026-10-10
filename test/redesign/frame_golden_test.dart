// Visual goldens for the app frame (#352 PR 1, PRD #346 "Mechanics").
//
// Home and POS inside MainLayout at the four reference sizes, light and dark
// (Blue Classic), rendered with the real bundled fonts and icons that
// test/flutter_test_config.dart loads. POS at 1280x800 shows the fixed cart
// panel open.
//
// The PNGs live in test/redesign/goldens/ — never test/golden/, which CI runs
// on Linux, where pixel goldens made on macOS would fail. Regenerate with:
//
//     flutter test --update-goldens test/redesign/frame_golden_test.dart
//
// These pin the FRAME (bottom bar, rail, drawer-less shell, cart panel host,
// View Cart bar). The screens inside are restyled by Wave 1, which will
// regenerate them.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {
    'sales.make',
    'stock.view',
    'products.add',
    'reports.see_sales',
    'reports.see_profit',
    'reports.see_expenses',
  };

  const prefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
    'hint_cart_tap_edit': 2,
  };

  const sizes = <String, Size>{
    '390x844': Size(390, 844),
    '844x390': Size(844, 390),
    '800x1280': Size(800, 1280),
    '1280x800': Size(1280, 800),
  };

  late ScreenTestEnvironment env;

  // Home starts a connectivity listener; the plugin has no test
  // implementation, so answer "online over wifi" instead of throwing.
  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => <String>['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success(<String>['wifi']),
      ),
    );
  });

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 8,
      manufacturerCount: 2,
      sharedPreferences: prefs,
    );
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<void> pumpGolden(
    WidgetTester tester, {
    required String screen,
    required Brightness brightness,
    required Size size,
    required EdgeInsets padding,
    required String goldenName,
    bool openPanel = false,
  }) async {
    NavigationService().setIndex(switch (screen) {
      'home' => NavigationService.homeTab,
      'inventory' => 2,
      _ => NavigationService.posTab,
    });
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleSlug: 'manager',
      roleName: 'Manager',
      roleRank: 3,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
      sharedPreferences: prefs,
      settle: false,
    );

    if (screen == 'pos') {
      final cart = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(cartProvider);
      cart.addItem(env.products[0], qty: 2, maxStock: 100);
      cart.addItem(env.products[1], qty: 1, maxStock: 100);
    }

    // Let Drift streams deliver and every animation run out. Bounded:
    // spinners never settle.
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await settle();
    if (openPanel) {
      await tester.tap(find.byKey(const Key('view-cart-bar')));
      await settle();
    }

    await expectLater(
      find.byType(MainLayout),
      matchesGoldenFile('goldens/$goldenName.png'),
    );

    await disposeScreen(tester);
  }

  for (final screen in const ['home', 'pos']) {
    for (final brightness in Brightness.values) {
      final themeName = brightness == Brightness.light ? 'light' : 'dark';
      sizes.forEach((sizeName, size) {
        testWidgets(
          'frame $screen $sizeName $themeName',
          (tester) => pumpGolden(
            tester,
            screen: screen,
            brightness: brightness,
            size: size,
            padding: EdgeInsets.zero,
            goldenName: 'frame_${screen}_${sizeName}_$themeName',
          ),
        );
      });
    }
  }

  // #352 phone check: a sideways phone with a 24dp status bar and 3-button
  // navigation on the right. Home, POS, and POS with the slide-in panel open.
  const sidewaysInsets = EdgeInsets.only(top: 24, right: 48);
  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (screen, openPanel, name) in const [
      ('home', false, 'home'),
      ('pos', false, 'pos'),
      ('pos', true, 'pos_panel'),
    ]) {
      testWidgets(
        'frame $name 844x390 with insets $themeName',
        (tester) => pumpGolden(
          tester,
          screen: screen,
          brightness: brightness,
          size: const Size(844, 390),
          padding: sidewaysInsets,
          openPanel: openPanel,
          goldenName: 'frame_${name}_844x390_insets_$themeName',
        ),
      );
    }
  }

  // #377: upright with 3-button navigation (48dp bottom inset). The content
  // must run down to the bottom bar with no band of background above it.
  const uprightInsets = EdgeInsets.only(top: 24, bottom: 48);
  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final screen in const ['pos', 'inventory']) {
      testWidgets(
        'frame $screen 390x844 with bottom inset $themeName',
        (tester) => pumpGolden(
          tester,
          screen: screen,
          brightness: brightness,
          size: const Size(390, 844),
          padding: uprightInsets,
          goldenName: 'frame_${screen}_390x844_insets_$themeName',
        ),
      );
    }
  }
}
