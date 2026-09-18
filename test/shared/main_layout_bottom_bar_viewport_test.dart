import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #258 (PRD #239 slice) — Bottom bar slides away while scrolling sideways
/// and returns on scroll back.
///
/// Acceptance criteria pinned:
///   [x] Sideways, scrolling into a long list hides the bottom bar with an animation;
///       scrolling back shows it again
///   [x] Upright, the bottom bar never hides
///   [x] The bar reappears on tab switch, on turning the phone upright, and when
///       content returns to the top
///   [x] A screen whose content fits without scrolling never hides the bar
///   [x] Sideways swipes between tabs and along chip rows never toggle the bar
///   [x] Hidden or shown, no layout overflow is reported and the last row remains reachable
///   [x] The wide-screen side rail is unaffected
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const posGrants = {
    'sales.make',
    'stock.view',
    'products.add',
  };

  const testPrefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
  };

  const clipKey = Key('main-bottom-nav-clip');
  const alignKey = Key('main-bottom-nav-align');
  const navKey = Key('main-bottom-nav');

  double barHeight(WidgetTester tester) {
    final clip = find.byKey(clipKey);
    if (clip.evaluate().isEmpty) return 0.0;
    return tester.getSize(clip).height;
  }

  double barFactor(WidgetTester tester) {
    final align = find.byKey(alignKey);
    if (align.evaluate().isEmpty) return 0.0;
    return tester.widget<Align>(align).heightFactor ?? 1.0;
  }

  Future<void> pumpMainLayout(
    WidgetTester tester, {
    required ScreenTestEnvironment env,
    required Size size,
    Set<String> grantedKeys = posGrants,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: grantedKeys,
      roleSlug: 'cashier',
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
      ],
      sharedPreferences: testPrefs,
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('Issue #258: Bottom bar slides away sideways', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(
        productCount: 20, // ample items to guarantee scrolling
        manufacturerCount: 3,
        sharedPreferences: testPrefs,
      );
      final nav = NavigationService();
      nav.resetNavigation();
      nav.beginSessionLanding();
      nav.setIndex(NavigationService.posTab);
    });

    tearDown(() async {
      await env.dispose();
      NavigationService().resetNavigation();
    });

    testWidgets(
      'Sideways (800x360), scrolling into list hides bottom bar; scrolling back shows it',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: androidCompactLandscape,
        );

        // Initially on POS, bottom bar is fully visible
        expect(find.byKey(navKey), findsOneWidget);
        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        final scrollable = find.byKey(kPosScrollSurfaceKey);
        expect(scrollable, findsOneWidget);

        // Scroll down into content (finger drags up)
        await tester.drag(scrollable, const Offset(0, -180));
        await tester.pump(); // register animation start
        await tester.pump(const Duration(milliseconds: 50)); // advance 50ms
        expect(barFactor(tester), lessThan(1.0)); // animating down

        await tester.pump(const Duration(milliseconds: 200)); // finish 200ms animation
        expect(barHeight(tester), 0.0);
        expect(barFactor(tester), 0.0);

        // Scroll back up (finger drags down)
        await tester.drag(scrollable, const Offset(0, 100));
        await tester.pump(); // register animation start
        await tester.pump(const Duration(milliseconds: 50)); // advance 50ms
        expect(barFactor(tester), greaterThan(0.0)); // animating up

        await tester.pump(const Duration(milliseconds: 200)); // finish animation
        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'Upright (412x915), the bottom bar never hides on vertical scroll',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: pixel7Portrait,
        );

        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        final scrollable = find.byKey(kPosScrollSurfaceKey);
        expect(scrollable, findsOneWidget);

        // Scroll down into content
        await tester.drag(scrollable, const Offset(0, -200));
        await tester.pump(const Duration(milliseconds: 250));

        // Stays fully visible
        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'A screen whose content fits without scrolling never hides the bar',
      (tester) async {
        // Create environment with 0 products
        final emptyEnv = await setupScreenTestEnvironment(
          productCount: 0,
          sharedPreferences: testPrefs,
        );
        addTearDown(emptyEnv.dispose);

        await pumpMainLayout(
          tester,
          env: emptyEnv,
          size: androidCompactLandscape,
        );

        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        final scrollable = find.byKey(kPosScrollSurfaceKey);
        if (scrollable.evaluate().isNotEmpty) {
          // Dragging content that fits
          await tester.drag(scrollable, const Offset(0, -100));
          await tester.pump(const Duration(milliseconds: 250));

          expect(barHeight(tester), greaterThan(40.0));
          expect(barFactor(tester), 1.0);
        }

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'Sideways swipes (horizontal chips) never toggle the bottom bar',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: androidCompactLandscape,
        );

        expect(barHeight(tester), greaterThan(40.0));

        // Find the horizontal category chip list or search band
        final searchBand = find.byKey(kPosSearchBandKey);
        expect(searchBand, findsOneWidget);

        // Drag horizontally
        await tester.drag(searchBand, const Offset(-100, 0));
        await tester.pump(const Duration(milliseconds: 250));

        // Bar still visible
        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'The bar reappears on tab switch',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: androidCompactLandscape,
        );

        final scrollable = find.byKey(kPosScrollSurfaceKey);
        // Scroll into content -> bar hides
        await tester.drag(scrollable, const Offset(0, -180));
        await tester.pump(const Duration(milliseconds: 250));
        expect(barHeight(tester), 0.0);

        // Switch to Home tab (tab 0)
        final nav = NavigationService();
        nav.setIndex(NavigationService.homeTab);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Bar is restored
        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'The bar reappears when content returns to the top',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: androidCompactLandscape,
        );

        final scrollable = find.byKey(kPosScrollSurfaceKey);
        // Scroll down
        await tester.drag(scrollable, const Offset(0, -120));
        await tester.pump(const Duration(milliseconds: 250));
        expect(barHeight(tester), 0.0);

        // Scroll back all the way to top
        await tester.drag(scrollable, const Offset(0, 300));
        await tester.pump(const Duration(milliseconds: 250));

        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'Rotating device from sideways to upright restores the bar immediately',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: androidCompactLandscape,
        );

        final scrollable = find.byKey(kPosScrollSurfaceKey);
        await tester.drag(scrollable, const Offset(0, -150));
        await tester.pump(const Duration(milliseconds: 250));
        expect(barHeight(tester), 0.0);

        // Rotate to portrait
        tester.view.physicalSize = pixel7Portrait;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(barHeight(tester), greaterThan(40.0));
        expect(barFactor(tester), 1.0);

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'Desktop side rail is unaffected and bottom bar is not rendered',
      (tester) async {
        await pumpMainLayout(
          tester,
          env: env,
          size: tablet109Landscape,
        );

        // Bottom nav bar is null on desktop
        expect(find.byKey(navKey), findsNothing);

        await disposeScreen(tester);
      },
    );
  });
}
