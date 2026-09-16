import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #243 / PRD #239 — the Inventory screen must hold its content at every
/// supported viewport.
///
/// Two assertions per viewport, both mandatory:
///
///   1. No layout overflow is reported.
///   2. At least one complete product row is laid out and hit-testable.
///
/// The second is the one that matters. An overflow-only test passes a screen
/// whose list has been squeezed to zero height, because a scroll view given no
/// room throws nothing — precisely the silent failure mode this PRD exists to
/// prevent. There is deliberately no per-screen pixel budget: both assertions
/// are self-scaling.
///
/// Measured on `origin/main` before the fix (Products tab, populated):
///
/// | viewport | tab body | list height | complete rows |
/// |---|---|---|---|
/// | 320x568 portrait | 297.3dp | 105.3dp | 1 |
/// | 800x360 landscape | 95.6dp | **0.0dp** | **0**, + 67px overflow |
/// | 915x412 landscape | 147.6dp | **0.0dp** | **0**, + 15px overflow |
/// | 412x915 portrait | 626.9dp | 427.9dp | 5 |
///
/// The two landscape rows are the defect in both of its modes at once: a red
/// band *and* a list at exactly zero height.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every permission the Inventory screen's tabs and actions read.
  const inventoryGrants = {
    'sales.make',
    'stock.view',
    'products.add',
    'stock.add',
    'products.edit_price',
  };

  /// The complete product rows the Products tab lays out.
  Finder productRows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith(kInventoryProductRowKeyPrefix),
        description: 'inventory product row',
      );

  /// The first tab's own scroll view — the one scrollable surface.
  ///
  /// Scoped through [TabSliverBody] on purpose: a `NestedScrollView` builds its
  /// outer viewport as a `CustomScrollView` too, so an unscoped `.first` grabs
  /// the header scroller and every gesture lands on the wrong surface.
  Finder tabSurface() => find
      .descendant(
        of: find.byType(TabSliverBody).first,
        matching: find.byType(CustomScrollView),
      )
      .first;

  /// The two binding constraints — the smallest supported portrait phone and
  /// the shortest supported landscape phone — plus landscape and portrait
  /// controls proving the fix did not change normal phones.
  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  group('Inventory holds its content — populated catalogue', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 8);
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows a complete product row without overflowing',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const InventoryScreen(),
          grantedKeys: inventoryGrants,
          overrides: [
            firstRunSurfaceStateProvider
                .overrideWithValue(FirstRunSurfaceState.hasContent),
          ],
        );

        expectNoOverflow(tester, reason: 'Inventory overflowed at $name');
        await expectContentRowVisible(
          tester,
          productRows(),
          scrollable: tabSurface(),
          reason: 'Inventory showed no complete product row at $name',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('Inventory holds its content — empty catalogue', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 0);
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders the first-run empty state without overflowing',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const InventoryScreen(),
          grantedKeys: inventoryGrants,
          overrides: [
            firstRunSurfaceStateProvider
                .overrideWithValue(FirstRunSurfaceState.addProductCta),
          ],
        );

        expectNoOverflow(tester, reason: 'Inventory overflowed at $name');
        expect(
          find.byType(FirstRunEmptyState),
          findsOneWidget,
          reason: 'The empty catalogue must reach the first-run empty state',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('Inventory keeps the behaviour the restructure could have cost', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 20);
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('each tab remembers its scroll position across tab switches',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const InventoryScreen(),
        grantedKeys: {...inventoryGrants, 'suppliers.manage'},
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      ScrollPosition productsPosition() => tester
          .state<ScrollableState>(
            find
                .descendant(of: tabSurface(), matching: find.byType(Scrollable))
                .first,
          )
          .position;

      await tester.drag(tabSurface(), const Offset(0, -240));
      await tester.pumpAndSettle();
      final scrolledTo = productsPosition().pixels;
      expect(scrolledTo, greaterThan(0), reason: 'The Products tab must scroll');

      await tester.tap(find.text('Suppliers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Products'));
      await tester.pumpAndSettle();

      expect(
        productsPosition().pixels,
        closeTo(scrolledTo, 1.0),
        reason: 'Switching away and back must not lose the reader\'s place',
      );

      await disposeScreen(tester);
    });

    testWidgets('swiping sideways still moves between tabs', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const InventoryScreen(),
        grantedKeys: {...inventoryGrants, 'suppliers.manage'},
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      expect(find.text('Add Supplier'), findsNothing);

      // A measured drag just past the half-page snap point, not a fling: a
      // fling at this width carries the pager two whole tabs, which would
      // land on History and prove nothing about the neighbour.
      final pager = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final onePage = pager.position.viewportDimension;

      final swipe = await tester.startGesture(tester.getCenter(tabSurface()));
      for (var step = 0; step < 8; step++) {
        await swipe.moveBy(Offset(-onePage * 0.08, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await tester.pumpAndSettle();

      expect(
        pager.position.pixels,
        closeTo(onePage, 1.0),
        reason: 'A sideways swipe must land on exactly the next tab',
      );
      expect(
        find.text('Add Supplier'),
        findsOneWidget,
        reason: 'A sideways swipe must still reach the next tab',
      );

      await disposeScreen(tester);
    });

    testWidgets('a summary card still filters the list when tapped',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const InventoryScreen(),
        grantedKeys: inventoryGrants,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      expect(productRows().evaluate(), isNotEmpty);

      // Every seeded product has stock, so "Out of Stock" must empty the list.
      await tester.tap(find.text('Out of Stock'));
      await tester.pumpAndSettle();

      expect(
        productRows().evaluate(),
        isEmpty,
        reason: 'The summary cards must still drive the stock filter',
      );
      expect(find.textContaining('matching filters'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('pull-to-refresh still arms on the restructured surface',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const InventoryScreen(),
        grantedKeys: inventoryGrants,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      // AppRefreshWrapper arms on an OverscrollNotification from an active drag
      // at the very top. The gesture has to reach it from the tab's own scroll
      // view, which is the wiring the restructure could have broken. The pull is
      // released back under the trigger threshold so the test observes the
      // spinner without kicking off a real sync.
      double spinnerTop() => tester
          .widget<AnimatedPositioned>(
            find
                .descendant(
                  of: find.byType(AppRefreshWrapper),
                  matching: find.byType(AnimatedPositioned),
                )
                .first,
          )
          .top!;

      final parked = spinnerTop();
      final gesture = await tester.startGesture(tester.getCenter(tabSurface()));
      for (var step = 0; step < 6; step++) {
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final pulled = spinnerTop();

      await gesture.moveBy(const Offset(0, -180));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        pulled,
        greaterThan(parked),
        reason: 'Overpulling the tab surface must still descend the spinner',
      );
      expect(
        spinnerTop(),
        closeTo(parked, 0.5),
        reason: 'Releasing under the threshold must settle the spinner back',
      );

      await disposeScreen(tester);
    });
  });
}
