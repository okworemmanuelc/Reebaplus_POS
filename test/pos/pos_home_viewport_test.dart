import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';

import '../helpers/pos_home_harness.dart';
import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #259 / PRD #239 — the POS home screen must hold its product grid at
/// every supported viewport.
///
/// Two assertions per viewport, both mandatory:
///
///   1. No layout overflow is reported.
///   2. At least one complete product card is laid out and hit-testable.
///
/// The second is the one that matters. POS is the worst case in the whole PRD
/// precisely because it fails *silently*: the discovery sweep (#241) measured
/// the product grid laid out at **0.0dp of 463dp** on a populated catalogue at
/// 800x360 — a cashier sees a screen that looks fine and cannot start a sale.
/// An overflow-only test passes that screen, because a scroll view handed zero
/// height throws nothing.
///
/// Measured on `origin/main` before the fix:
///
/// | viewport | state | grid height | complete cards | overflow |
/// |---|---|---|---|---|
/// | 800x360 landscape | populated | **0.0dp** | **0** | 21px |
/// | 800x360 landscape | empty | — | — | 102px |
///
/// There is deliberately no per-screen pixel budget here. The prior POS suite
/// asserted fixed chrome under a 165dp ceiling and had to carry a comment
/// warning the reader not to lower it to make a control fit; the PRD's Testing
/// Decisions reject exactly that. Both assertions below are self-scaling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The complete product cards the grid lays out.
  Finder productTiles() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith(kPosProductTileKeyPrefix),
        description: 'pos product tile',
      );

  /// POS's one vertical scroll surface.
  ///
  /// Prefers the keyed surface the collapsing-header restructure installs. The
  /// fallback is what exists *before* the fix — the grid's own `GridView` — so
  /// the red run fails on the assertion with an honest count rather than
  /// crashing on a finder that matches nothing.
  Finder posSurface() {
    final restructured = find.byKey(kPosScrollSurfaceKey);
    if (restructured.evaluate().isNotEmpty) return restructured;
    return find.byType(GridView);
  }

  /// The two binding constraints — the smallest supported portrait phone and
  /// the shortest supported landscape phone — plus a landscape phone and a
  /// comfortable portrait control proving the fix did not change normal phones.
  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  group('POS holds its product grid — populated catalogue', () {
    late PosTestEnvironment env;

    setUp(() async {
      env = await setupTestPosEnvironment(productCount: 8);
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows a complete product card without overflowing',
          (tester) async {
        await pumpPosHome(
          tester,
          env: env,
          size: size,
          overrides: [
            firstRunSurfaceStateProvider
                .overrideWithValue(FirstRunSurfaceState.hasContent),
          ],
        );

        expectNoOverflow(tester, reason: 'POS overflowed at $name');
        await expectContentRowVisible(
          tester,
          productTiles(),
          scrollable: posSurface(),
          reason: 'POS showed no complete product card at $name',
        );

        await disposePosHome(tester);
      });
    });

    testWidgets(
        'androidCompactLandscape at the maximum text scale still reaches a card',
        (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: androidCompactLandscape,
        // The app's real ceiling: `main.dart` clamps the inherited scale to
        // 1.3, so this is the largest text POS ever has to lay out. Testing
        // past the clamp would be inventing a viewport the app cannot produce.
        textScaler: const TextScaler.linear(1.3),
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      expectNoOverflow(
        tester,
        reason: 'POS overflowed sideways at the maximum text scale',
      );
      await expectContentRowVisible(
        tester,
        productTiles(),
        scrollable: posSurface(),
        reason:
            'Frozen chrome grows with the system font size — the trade-off the '
            'layout plan raised against the collapsing header. A complete card '
            'must still be reachable at the maximum text scale.',
      );

      await disposePosHome(tester);
    });
  });

  group('POS holds its product grid — empty catalogue', () {
    late PosTestEnvironment env;

    setUp(() async {
      env = await setupTestPosEnvironment(productCount: 0);
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders the first-run empty state without overflowing',
          (tester) async {
        await pumpPosHome(
          tester,
          env: env,
          size: size,
          overrides: [
            firstRunSurfaceStateProvider
                .overrideWithValue(FirstRunSurfaceState.addProductCta),
          ],
        );

        expectNoOverflow(tester, reason: 'POS overflowed at $name');
        expect(
          find.byType(FirstRunEmptyState),
          findsOneWidget,
          reason: 'The empty catalogue must reach the first-run empty state',
        );

        await disposePosHome(tester);
      });
    });
  });

  group('POS keeps every control the restructure could have cost', () {
    late PosTestEnvironment env;

    setUp(() async {
      env = await setupTestPosEnvironment(productCount: 8);
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('every control present upright is still present sideways',
        (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: androidCompactLandscape,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      // "Nothing is removed in landscape" (PRD #239). Each of these may scroll
      // out of view, but none may be hidden, collapsed behind a menu, or gated
      // on orientation.
      for (final control in kPosLandscapeControlKeys) {
        expect(
          find.byKey(control),
          findsOneWidget,
          reason: '$control must still exist sideways',
        );
      }

      await disposePosHome(tester);
    });

    testWidgets('search still filters the grid', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: androidCompactLandscape,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      // A sliver grid builds lazily, so this is the number of tiles laid out
      // near the viewport — not the whole catalogue of 8. Asserting the exact
      // figure would be asserting the cache extent, which is not behaviour.
      final beforeSearch = productTiles().evaluate().length;
      expect(beforeSearch, greaterThan(1));

      await tester.enterText(find.byKey(kPosSearchFieldKey), 'Product 3');
      await tester.pumpAndSettle();

      expect(
        productTiles().evaluate().length,
        1,
        reason: 'Search must still narrow the grid from the frozen band',
      );
      expect(
        find.byKey(posProductTileKey(
          env.products.firstWhere((p) => p.name == 'Product 3').id,
        )),
        findsOneWidget,
        reason: 'The surviving tile must be the one that was searched for',
      );

      await disposePosHome(tester);
    });

    testWidgets('category filtering still works from the frozen band',
        (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: pixel7Portrait,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      expect(productTiles().evaluate(), isNotEmpty);

      // Every seeded product sits in "Drinks", so the Uncategorized bucket
      // must come back empty.
      await tester.tap(find.text('Uncategorized'));
      await tester.pumpAndSettle();

      expect(
        productTiles().evaluate(),
        isEmpty,
        reason: 'The category chips must still drive the grid',
      );

      await disposePosHome(tester);
    });

    testWidgets('tapping a tile still adds it to the cart', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: pixel7Portrait,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      await tester.tap(productTiles().first);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('added to cart'),
        findsOneWidget,
        reason: 'A tap on a tile must still reach the cart',
      );

      // Let the success notification retire before the tree comes down, or its
      // timer outlives the test and trips `!timersPending`.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await disposePosHome(tester);
    });

    testWidgets('hold-to-edit still opens the quantity sheet', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: pixel7Portrait,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      await tester.longPress(productTiles().first);
      await tester.pumpAndSettle();

      expect(
        find.byType(EditItemModal),
        findsOneWidget,
        reason: 'Tap-and-hold must still reach the quantity/discount sheet',
      );

      await disposePosHome(tester);
    });

    testWidgets('pull-to-refresh still arms on the restructured surface',
        (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: pixel7Portrait,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      // AppRefreshWrapper arms on an OverscrollNotification from an active drag
      // at the very top. The gesture has to reach it from POS's own scroll
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
      final gesture = await tester.startGesture(tester.getCenter(posSurface()));
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
        reason: 'Overpulling POS must still descend the spinner',
      );
      expect(
        spinnerTop(),
        closeTo(parked, 0.5),
        reason: 'Releasing under the threshold must settle the spinner back',
      );

      await disposePosHome(tester);
    });

    testWidgets('the search bar and category chips freeze at the top',
        (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: pixel7Portrait,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      double topOf(Key key) => tester.getTopLeft(find.byKey(key)).dy;

      final bandAtRest = topOf(kPosSearchBandKey);
      final tierAtRest = topOf(kPosTierRowKey);

      // Scroll well past the tier row, then again. "Frozen" means the band
      // stops at the top and stays there — not that it never moves: at rest it
      // sits below the tier row and rides up until it reaches its pinned spot.
      await tester.drag(posSurface(), const Offset(0, -260));
      await tester.pumpAndSettle();
      final bandFrozen = topOf(kPosSearchBandKey);

      // The tier row has scrolled away: either it has moved up, or the sliver
      // has unmounted it entirely for being off screen. Both are the contract;
      // what is forbidden is it still sitting where it started.
      final tierRow = find.byKey(kPosTierRowKey);
      if (tierRow.evaluate().isNotEmpty) {
        expect(
          topOf(kPosTierRowKey),
          lessThan(tierAtRest - 1.0),
          reason: 'The price-tier / store row must scroll away',
        );
      }

      await tester.drag(posSurface(), const Offset(0, -260));
      await tester.pumpAndSettle();

      expect(
        bandFrozen,
        lessThan(bandAtRest),
        reason: 'The band must ride up to the top as the tier row scrolls off',
      );
      expect(
        topOf(kPosSearchBandKey),
        closeTo(bandFrozen, 1.0),
        reason: 'Once at the top the search bar and chips must freeze there, '
            'so search and category filtering stay one tap away while browsing',
      );
      expect(
        find.byKey(kPosSearchFieldKey),
        findsOneWidget,
        reason: 'The frozen band must still be mounted after scrolling',
      );
      expect(
        find.byKey(kPosCategoryChipsKey),
        findsOneWidget,
        reason: 'Category filtering must stay one tap away while browsing',
      );

      await disposePosHome(tester);
    });
  });
}
