import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';

import '../helpers/pos_home_harness.dart';
import '../helpers/viewports.dart';

/// POS responsive **density**: how many columns the product grid resolves to at
/// each width, and that the grid lays out real tiles there.
///
/// ### What changed here, and why (issue #259 / PRD #239)
///
/// This suite used to assert POS's fixed chrome (header + search + chips) came
/// in under a 165dp ceiling, and that the grid's content rect cleared a
/// per-viewport floor (`> 80dp`, `> 40dp`, `> 0dp`). Those assertions are gone.
///
/// They were rejected by the PRD's Testing Decisions, and the suite's own
/// comments are the argument for why: the ceiling had been raised from 160dp to
/// 165dp to admit a legitimate 48dp tap target, carried a warning reading "Do
/// not lower this budget to fit a control", and the 320dp case documented an
/// "HONEST NUMBER: ~9.8dp" of grid while asserting only `> 0.0dp` — a screen
/// that passed its own test while being, in that comment's words, "NOT usable".
/// A threshold that needs such a warning will eventually be lowered.
///
/// There is also no longer any fixed chrome to measure: POS is one scrolling
/// surface, the top bar and tier row scroll away, and the search bar and chips
/// pin at their own natural height. The two-assertion invariant that replaced
/// the budgets lives in `pos_home_viewport_test.dart`, which pumps POS at four
/// viewports in both data states and asserts no overflow **and** a complete,
/// hit-testable product card.
///
/// What is kept here is the coverage that suite does not duplicate: the column
/// arithmetic per width, which is real behaviour a cashier sees and which no
/// other test covers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosTestEnvironment env;

  setUp(() async {
    env = await setupTestPosEnvironment(productCount: 5);
  });

  tearDown(() async {
    await env.dispose();
  });

  /// The rendered grid's resolved column count.
  int renderedColumns(WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    return delegate.crossAxisCount;
  }

  Finder productTiles() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith(kPosProductTileKeyPrefix),
    description: 'pos product tile',
  );

  /// Width → expected columns.
  ///
  /// As many 170dp columns as fit, never fewer than 3. The width is the grid's
  /// own, so at 600dp+ the app frame's side rail (#352, ~73dp with its divider)
  /// comes off first.
  const widthToColumns = <String, (Size, int)>{
    'small phone (320dp wide)': (Size(320, 640), 3),
    'pixel7Portrait (412dp wide)': (pixel7Portrait, 3),
    'pixel7Landscape (915dp − 73dp rail = 842dp, 842/170 = 4)': (
      pixel7Landscape,
      4,
    ),
    'androidCompactLandscape (800dp − 73dp rail = 727dp, 727/170 = 4)': (
      androidCompactLandscape,
      4,
    ),
    'se1Landscape (568dp wide, 568/170 = 3)': (Size(568, 320), 3),
  };

  group('POS product grid density', () {
    widthToColumns.forEach((name, expectation) {
      final (size, expectedColumns) = expectation;

      testWidgets('$name lays out $expectedColumns columns of real tiles', (
        tester,
      ) async {
        await pumpPosHome(
          tester,
          env: env,
          size: size,
          overrides: [
            firstRunSurfaceStateProvider.overrideWithValue(
              FirstRunSurfaceState.hasContent,
            ),
          ],
        );

        expect(
          renderedColumns(tester),
          equals(expectedColumns),
          reason: 'Column arithmetic changed at ${size.width}dp wide',
        );

        // The columns are only meaningful if the grid actually laid tiles out.
        // Deliberately not a pixel budget: it counts what exists.
        expect(
          productTiles().evaluate(),
          isNotEmpty,
          reason: 'The grid resolved its columns but laid out no tiles',
        );

        await disposePosHome(tester);
      });
    });

    testWidgets('columnsFor: three on phones, width fills beyond that', (
      tester,
    ) async {
      for (final width in [320.0, 360.0, 412.0, 568.0]) {
        expect(ProductGrid.columnsFor(width), equals(3), reason: '$width');
      }
      expect(ProductGrid.columnsFor(800), equals(4));
      expect(ProductGrid.columnsFor(1280), equals(7));
    });

    test('only a small phone scales its tile down', () {
      expect(posTileScale(91), closeTo(0.91, 0.001));
      expect(posTileScale(100), equals(1));
      expect(posTileScale(170), equals(1));
    });
  });
}
