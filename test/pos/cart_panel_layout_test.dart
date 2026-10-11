// #385 — the cart panel on tablets: the owner saw the "Cart" title shrink to a
// dot, and "Walk-in Customer", "Save Cart" and "Recall" cut short. These pump
// the real frame (MainLayout) with the panel open at 800×1280 (slide-in) and
// 1280×800 (fixed), at normal text and at the app's largest (1.3), and assert
// each of those labels is drawn whole.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';

import '../helpers/screen_harness.dart';
import 'cart_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
    'hint_cart_tap_edit': 2,
  };

  late ScreenTestEnvironment env;

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
    env = await setupScreenTestEnvironment(sharedPreferences: prefs);
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    required Size size,
    TextScaler? textScaler,
  }) async {
    NavigationService().setIndex(NavigationService.posTab);
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: EdgeInsets.zero,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: const {'sales.make', 'stock.view', 'products.add'},
      roleSlug: 'manager',
      roleName: 'Manager',
      roleRank: 3,
      textScaler: textScaler,
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
      sharedPreferences: prefs,
      settle: false,
    );
    fillMockupCart(
      ProviderScope.containerOf(context, listen: false).read(cartProvider),
    );
    await settle(tester);
    final viewCart = find.byKey(const Key('view-cart-bar'));
    if (viewCart.evaluate().isNotEmpty) {
      await tester.tap(viewCart);
      await settle(tester);
    }
  }

  Finder inPanel(Finder f) =>
      find.descendant(of: find.byKey(const Key('cart-panel')), matching: f);

  const sizes = {
    '800x1280 (slide-in)': Size(800, 1280),
    '1280x800 (fixed)': Size(1280, 800),
    // The narrowest panels: a small tablet upright (60% of 600) and the
    // smallest wide screen (the fixed panel's 360 floor).
    '600x960 (slide-in, narrowest)': Size(600, 960),
    '1024x768 (fixed, narrowest)': Size(1024, 768),
  };
  const mockupSizes = {'800x1280 (slide-in)', '1280x800 (fixed)'};
  const scales = {'1.0': TextScaler.noScaling, '1.3': TextScaler.linear(1.3)};

  sizes.forEach((sizeName, size) {
    scales.forEach((scaleName, scaler) {
      final at = '$sizeName, text $scaleName';
      testWidgets('panel labels are drawn whole at $at', (tester) async {
        await pumpPanel(tester, size: size, textScaler: scaler);

        expect(inPanel(find.text('Cart')), findsOneWidget);
        expectTextWhole(tester, inPanel(find.text('Cart')), at: at);
        // The customer's name may wrap under it (never cut short); at the
        // mockup sizes with normal text it stays on one line, as drawn.
        expectTextWhole(
          tester,
          inPanel(find.text('Walk-in Customer')),
          at: at,
          allowWrap: !(mockupSizes.contains(sizeName) && scaleName == '1.0'),
        );
        expectTextWhole(tester, inPanel(find.text('Save Cart')), at: at);
        expectTextWhole(tester, inPanel(find.text('Recall')), at: at);
        expectTextWhole(
          tester,
          inPanel(find.text('Proceed to Checkout')),
          at: at,
        );
        expect(tester.takeException(), isNull);

        await disposeScreen(tester);
      });
    });

    testWidgets('fly-to-cart lands on the panel header at $sizeName', (
      tester,
    ) async {
      await pumpPanel(tester, size: size);
      final target = find.byWidgetPredicate(
        (w) => w is FlyTarget && w.id == FlyTargetId.cart && w.priority == 1,
      );
      expect(inPanel(target), findsOneWidget);
      // The panel header's target is the one a flight resolves to.
      final bounds = Offset.zero & size;
      final resolved = FlyTargetRegistry.resolve(FlyTargetId.cart, bounds);
      expect(resolved, isNotNull);
      expect(
        tester.getRect(inPanel(target)).contains(resolved!),
        isTrue,
        reason: 'A flight would land at $resolved, outside the panel header',
      );
      await disposeScreen(tester);
    });
  });
}
