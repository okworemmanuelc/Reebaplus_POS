import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';

import '../helpers/pos_home_harness.dart';
import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// POS's sideways top bar must survive the viewport changing size while a
/// fling is running out.
///
/// The owner rotated the emulator on Supplier Accounts and the debugger stopped
/// on `RenderBox.size accessed beyond the scope of resize, layout, or permitted
/// parent access`. POS stays mounted in the tab stack, so it re-lays out on
/// every rotation wherever the cashier is. The paused stack:
///
///     RenderBox.size
///     _RenderSliverFloatingHeader.childExtent
///     _RenderSliverFloatingHeader.isScrollingUpdate
///     _SnapTriggerState.isScrollingListener
///     ScrollPosition.beginActivity → goIdle → goBallistic
///     BallisticScrollActivity.applyNewDimensions
///     RenderViewport.performLayout
///
/// Flutter's `SliverFloatingHeader` (#259's sideways top bar) listens to the
/// scroll position's `isScrollingNotifier` and reads its child's size when
/// scrolling stops. When the viewport changes size in the last moments of a
/// fling, the fling ends *inside* `RenderViewport.performLayout`, the listener
/// fires there, and reading another box's size mid-layout is illegal.
///
/// Rotation is one way to change the viewport mid-fling. #258's bottom bar is
/// another: sideways it slides away over 200ms as the cashier scrolls, handing
/// its 56dp back to POS a few dp per frame. So the tests grow the viewport a
/// frame at a time during a gentle fling — the shape of both. Before the fix
/// the 300px/s fling throws at both landscape sizes; upright never did,
/// because upright the bar is pinned, not floating.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosTestEnvironment env;

  setUp(() async {
    env = await setupTestPosEnvironment(productCount: 30);
  });

  tearDown(() async {
    await env.dispose();
  });

  /// Pumps POS under a MediaQuery whose size the test can change in place, so
  /// a resize re-lays out the same, already-scrolled POS rather than building
  /// a fresh one.
  Future<ValueNotifier<Size>> pumpResizablePos(
    WidgetTester tester,
    Size initial,
  ) async {
    final size = ValueNotifier<Size>(initial);
    addTearDown(size.dispose);
    await pumpScreen(
      tester,
      env: env,
      size: initial,
      screen: ValueListenableBuilder<Size>(
        valueListenable: size,
        builder: (context, value, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: value),
          child: child!,
        ),
        child: const PosHomeScreen(),
      ),
      overrides: [
        firstRunSurfaceStateProvider
            .overrideWithValue(FirstRunSurfaceState.hasContent),
      ],
      sharedPreferences: const {
        'pos_grid_columns': 2,
        'pos_is_list_view': false,
        'hint_pos_gestures': 2,
      },
    );
    return size;
  }

  Finder posSurface() => find.byKey(kPosScrollSurfaceKey);

  /// The top of the top bar, found through the menu button that lives in it.
  double topBarTop(WidgetTester tester) =>
      tester.getTopLeft(find.byType(MenuButton)).dy;

  /// A range of fling speeds, because which one ends inside a layout pass
  /// depends on the frame the fling runs out on. 300px/s is the one that threw
  /// before the fix at both landscape sizes; the rest keep the sweep honest if
  /// a framework change shifts that frame.
  const flingSpeeds = [150.0, 200.0, 250.0, 300.0, 400.0, 600.0, 900.0, 1200.0];

  const sideways = <String, Size>{
    'androidCompactLandscape (800x360)': androidCompactLandscape,
    'pixel7Landscape (915x412)': pixel7Landscape,
  };

  sideways.forEach((name, start) {
    testWidgets(
        '$name: the viewport growing while a fling runs out does not throw',
        (tester) async {
      final size = await pumpResizablePos(tester, start);

      for (final speed in flingSpeeds) {
        // Start inside the grid so the floating bar is part of the scroll.
        await tester.drag(posSurface(), const Offset(0, -250));
        await tester.pumpAndSettle();
        await tester.fling(posSurface(), const Offset(0, -60), speed);

        // The viewport grows 56dp over ~200ms — the bottom bar giving its
        // height back — while the fling decays.
        for (var frame = 1; frame <= 40; frame++) {
          final grow = (frame.clamp(0, 13) / 13.0) * kBottomNavBodyHeight;
          final next = Size(start.width, start.height + grow);
          tester.view.physicalSize = next;
          size.value = next;
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.takeException(),
            isNull,
            reason: 'Resizing during a ${speed}px/s fling threw at $name',
          );
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Back to the starting size and the top of the grid for the next run.
        // Jump rather than drag: dragging past the top arms pull-to-refresh,
        // whose banner never settles in a test.
        tester.view.physicalSize = start;
        size.value = start;
        await tester.pumpAndSettle();
        tester
            .state<ScrollableState>(
              find
                  .descendant(of: posSurface(), matching: find.byType(Scrollable))
                  .first,
            )
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await disposePosHome(tester);
    });
  });

  testWidgets(
      'sideways the top bar still scrolls away and returns on reverse scroll',
      (tester) async {
    await pumpResizablePos(tester, androidCompactLandscape);
    final atRest = topBarTop(tester);

    await tester.drag(posSurface(), const Offset(0, -300));
    await tester.pumpAndSettle();
    final menu = find.byType(MenuButton);
    if (menu.evaluate().isNotEmpty) {
      expect(
        topBarTop(tester),
        lessThan(atRest - 1.0),
        reason: 'Sideways the top bar must scroll away while browsing',
      );
    }

    // Scrolling back a little — nowhere near the top of the grid — brings the
    // whole bar back. Moved a frame at a time, as a finger does: the float
    // reads the scroll direction during layout, and `tester.drag` lifts the
    // finger before any frame runs, so layout would only ever see "idle".
    final finger = await tester.startGesture(tester.getCenter(posSurface()));
    for (var step = 0; step < 8; step++) {
      await finger.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger.up();
    await tester.pumpAndSettle();
    expect(
      topBarTop(tester),
      closeTo(atRest, 1.0),
      reason: 'One reverse scroll must bring the top bar back (PRD #239 '
          'amendment 3)',
    );

    await disposePosHome(tester);
  });

  testWidgets('upright the top bar stays pinned', (tester) async {
    await pumpResizablePos(tester, pixel7Portrait);
    final atRest = topBarTop(tester);

    await tester.drag(posSurface(), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(
      topBarTop(tester),
      closeTo(atRest, 1.0),
      reason: 'Upright POS must look and behave as it did before #259',
    );

    await disposePosHome(tester);
  });
}
