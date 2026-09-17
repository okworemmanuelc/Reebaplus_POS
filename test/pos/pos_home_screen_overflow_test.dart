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
            (w.key! as ValueKey<String>)
                .value
                .startsWith(kPosProductTileKeyPrefix),
        description: 'pos product tile',
      );

  /// Width → expected columns, with the `pos_grid_columns` preference at 2.
  ///
  /// Under 380dp a phone is capped at 2; over 600dp the grid takes
  /// `(width / 180).floor()`; in between the preference governs.
  const widthToColumns = <String, (Size, int)>{
    'pixel7Portrait (412dp wide, preference governs)': (pixel7Portrait, 2),
    'pixel7Landscape (915dp wide, 915/180 = 5)': (pixel7Landscape, 5),
    'androidCompactLandscape (800dp wide, 800/180 = 4)': (
      androidCompactLandscape,
      4,
    ),
    'se1Landscape (568dp wide, under 600 so preference governs)': (
      Size(568, 320),
      2,
    ),
  };

  group('POS product grid density', () {
    widthToColumns.forEach((name, expectation) {
      final (size, expectedColumns) = expectation;

      testWidgets('$name lays out $expectedColumns columns of real tiles',
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

    testWidgets('columnsFor caps a narrow phone at two columns', (tester) async {
      // The width branches, without pumping a screen. 320dp is the smallest
      // supported portrait phone and must never take a 3-column preference.
      expect(ProductGrid.columnsFor(320, 3), equals(2));
      expect(ProductGrid.columnsFor(360, 4), equals(2));
      // Between 380 and 600 the user's preference is respected as-is.
      expect(ProductGrid.columnsFor(412, 3), equals(3));
      // Above 600 the width wins when it asks for more than the preference.
      expect(ProductGrid.columnsFor(800, 2), equals(4));
      // ...but never fewer: a high preference is not reduced.
      expect(ProductGrid.columnsFor(800, 6), equals(6));
    });
  });
}
