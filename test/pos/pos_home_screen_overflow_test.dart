import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pos_home_harness.dart';
import '../helpers/viewports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosTestEnvironment env;

  setUp(() async {
    env = await setupTestPosEnvironment(productCount: 5);
  });

  tearDown(() async {
    await env.dispose();
  });

  group('PosHomeScreen responsive layout and overflow tests', () {
    testWidgets(
      'control: pixel7Portrait (412x915) has comfortable vertical room and full tile visibility',
      (tester) async {
        await pumpPosHome(
          tester,
          env: env,
          size: pixel7Portrait,
        );

        // Control check: portrait should never overflow
        expect(tester.takeException(), isNull);

        // In portrait 412dp, pos_grid_columns pref governs (2 columns)
        final gridView = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, equals(2));

        // Grid content rect has ample room for vertical scrolling
        final contentRect = gridContentRect(tester);
        expect(contentRect.height, greaterThan(200.0));

        // At least the first row of 2 tiles is laid out and visible
        final visibleTiles = visibleProductTileCount(tester);
        expect(visibleTiles, greaterThanOrEqualTo(2));

        await disposePosHome(tester);
      },
    );

    testWidgets(
      'regression: pixel7Landscape (915x412) preserves <=165dp fixed chrome and fits full product row',
      (tester) async {
        await pumpPosHome(
          tester,
          env: env,
          size: pixel7Landscape,
        );

        // No RenderFlex overflow
        expect(tester.takeException(), isNull);

        // Primary invariant: fixed chrome height (header + search + category chips)
        // must remain compressed (target <= 165dp; Phase 0 delivers ~162.2dp).
        // On origin/main with uncompressed scale (1.50) and 53dp fields, this is ~259dp+.
        //
        // The budget was 160dp against a measured 154.2dp until 2026-09-07, when
        // AppDropdown took its 48dp tap-target floor (+8.0dp on the header band,
        // this screen's only dropdown). The 8dp was NOT reclaimed by shaving
        // padding: a tap target is a floor, and buying grid pixels with it is
        // exactly the trade this plan forbids. Chrome is still 1.6x compressed
        // against main, and the real answer to POS landscape density is Phase 2's
        // re-flow, not another 8dp. Do not lower this budget to fit a control.
        final chromeHeight = fixedChromeHeight(tester);
        expect(
          chromeHeight,
          lessThanOrEqualTo(165.0),
          reason:
              'Fixed chrome must compress to <= 165dp in short viewports. Measured: ${chromeHeight.toStringAsFixed(1)}dp',
        );

        // Column calculation: availableWidth (915) > 600 -> (915 / 180).floor() = 5 columns
        final gridView = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, equals(5));

        // Grid content rect has room for products (measured ~109.8dp)
        final contentRect = gridContentRect(tester);
        expect(
          contentRect.height,
          greaterThan(80.0),
          reason:
              'Grid content rect (${contentRect.height.toStringAsFixed(1)}dp) must provide viewport area for product browsing',
        );

        // Exactly 5 products seeded in 5 columns -> all 5 fit in Row 1 and are visible in viewport
        final visibleTiles = visibleProductTileCount(tester);
        expect(
          visibleTiles,
          equals(5),
          reason:
              'All 5 products in Row 1 must be rendered and visible in the active viewport',
        );

        await disposePosHome(tester);
      },
    );

    testWidgets(
      'regression: androidCompactLandscape (800x360) compresses chrome and lays out 4 columns',
      (tester) async {
        await pumpPosHome(
          tester,
          env: env,
          size: androidCompactLandscape,
        );

        expect(tester.takeException(), isNull);

        // Fixed chrome is compressed
        final chromeHeight = fixedChromeHeight(tester);
        expect(
          chromeHeight,
          lessThanOrEqualTo(165.0),
          reason:
              'Fixed chrome must compress to <= 165dp. Measured: ${chromeHeight.toStringAsFixed(1)}dp',
        );

        // 800dp width > 600 -> (800 / 180).floor() = 4 columns
        final gridView = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, equals(4));

        // Grid content rect provides viewport space (measured ~57.8dp)
        final contentRect = gridContentRect(tester);
        expect(contentRect.height, greaterThan(40.0));

        // In 4 columns with 5 products seeded, Row 1 has 4 tiles visible
        final visibleTiles = visibleProductTileCount(tester);
        expect(visibleTiles, equals(4));

        await disposePosHome(tester);
      },
    );

    testWidgets(
      'short viewport baseline: 320dp device in landscape (568x320, SE1 landscape) does not crash',
      (tester) async {
        const se1Landscape = Size(568, 320);
        await pumpPosHome(
          tester,
          env: env,
          size: se1Landscape,
        );

        // Phase 0 invariant: no RenderFlex overflow crash even at 320dp height
        expect(tester.takeException(), isNull);

        // Fixed chrome is compressed under 0.70 scale
        final chromeHeight = fixedChromeHeight(tester);
        expect(
          chromeHeight,
          lessThanOrEqualTo(165.0),
          reason:
              'Fixed chrome must compress to <= 165dp. Measured: ${chromeHeight.toStringAsFixed(1)}dp',
        );

        // 568dp width < 600 -> default 2 columns
        final gridView = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, equals(2));

        // Grid content rect remains positive without overflow.
        //
        // HONEST NUMBER: ~9.8dp. This screen does NOT crash at 320dp landscape
        // and it is NOT usable there either — 9.8dp of grid is a sliver of one
        // card. It was ~17.8dp until 2026-09-07, when AppDropdown took its 48dp
        // tap-target floor; the floor is not negotiable, so the 8dp came out of
        // the grid. A 320dp-tall viewport simply cannot fit POS's stacked chrome
        // plus a usable grid, at ANY scale — Phase 2's re-flow (plan Section 4)
        // is the only thing that fixes it, which is precisely the case Section 4
        // argues.
        //
        // The assertion below therefore guards what this test actually claims in
        // its name: the Expanded does not collapse to zero or go negative. It is
        // deliberately NOT a usability threshold. Do not "fix" a future failure
        // here by lowering it again — if it goes to zero, POS has regressed.
        final contentRect = gridContentRect(tester);
        expect(contentRect.height, greaterThan(0.0));

        // In 2 columns, Row 1 has 2 tiles visible
        final visibleTiles = visibleProductTileCount(tester);
        expect(visibleTiles, equals(2));

        await disposePosHome(tester);
      },
    );

    testWidgets(
      'text scaling stress: pixel7Landscape with textScaler 1.3 does not overflow',
      (tester) async {
        await pumpPosHome(
          tester,
          env: env,
          size: pixel7Landscape,
          textScaler: const TextScaler.linear(1.3),
        );

        expect(tester.takeException(), isNull);
        final chromeHeight = fixedChromeHeight(tester);
        expect(chromeHeight, lessThanOrEqualTo(180.0));

        await disposePosHome(tester);
      },
    );
  });
}
