import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/manual_refresh.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

void main() {
  /// Counts refreshes. Never completes, so a started refresh parks before it
  /// reaches the real sync service.
  late int refreshes;
  FutureOr<void> onRefresh() {
    refreshes++;
    return Completer<void>().future;
  }

  setUp(() => refreshes = 0);

  /// The wrapper's spinner: `1.0` at a full pull, `null` while refreshing,
  /// `0.05` at rest.
  double? spinnerValue(WidgetTester tester) => tester
      .widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byType(AppRefreshWrapper),
          matching: find.byType(CircularProgressIndicator),
        ),
      )
      .value;

  /// [pull] stands in for the sync service's upload-then-download: it answers
  /// whether a pull really completed. Without it the screen's own refresh never
  /// completes, so the pull is never reached.
  Future<void> pumpWrapper(WidgetTester tester, {Future<bool> Function()? pull}) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (pull != null) manualRefreshPullProvider.overrideWithValue(pull),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: AppRefreshWrapper(
                onRefresh: pull == null ? onRefresh : () => refreshes++,
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        children: [
                          for (var i = 0; i < 3; i++)
                            SizedBox(height: 40, child: Text('Row $i')),
                        ],
                      ),
                    ),
                    const _EndsScrollInLayout(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  /// Drags the list down past its top by more than the trigger threshold.
  Future<TestGesture> overpull(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(find.text('Row 0')));
    // Timed moves, so letting go carries real fling velocity like a finger does.
    for (var step = 1; step <= 8; step++) {
      await gesture.moveBy(const Offset(0, 30), timeStamp: Duration(milliseconds: 16 * step));
      await tester.pump(const Duration(milliseconds: 16));
    }
    return gesture;
  }

  testWidgets('releasing a pull past the threshold starts a refresh', (tester) async {
    await pumpWrapper(tester);

    final gesture = await overpull(tester);
    expect(spinnerValue(tester), 1.0, reason: 'The pull must be armed');

    await gesture.up();
    await tester.pump();

    expect(refreshes, 1);

    // Let the refresh's minimum-spin timer fire.
    await tester.pump(const Duration(milliseconds: 600));
  });

  // A NestedScrollView (Inventory) that is resized mid-frame, e.g. by the
  // keyboard closing after the supplier form is saved, ends its leftover scroll
  // activity inside performLayout. setState is illegal there: it threw "Build
  // scheduled during frame" from the refresh and left the wrapper stuck.
  testWidgets('a scroll that ends during layout settles the pull without a refresh',
      (tester) async {
    await pumpWrapper(tester);

    final gesture = await overpull(tester);
    expect(spinnerValue(tester), 1.0, reason: 'The pull must be armed');

    tester
        .renderObject<_RenderEndsScrollInLayout>(find.byType(_EndsScrollInLayout))
        .endScrollDuringNextLayout();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(refreshes, 0, reason: 'Only letting go of a pull may refresh');
    expect(spinnerValue(tester), 0.05, reason: 'The pull settles back after the frame');

    await gesture.up();
  });

  // PRD #313: the circle is gone within 2 s; "Synced" waits for a pull that
  // really completed; a failed refresh shows nothing.
  group('circle and outcome', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(AppRefreshWrapper)));

    /// Pulls down past the threshold and lets go.
    Future<void> pullDown(WidgetTester tester) async {
      final gesture = await overpull(tester);
      await gesture.up();
      await tester.pump();
    }

    const spinning = null;
    const atRest = 0.05;

    testWidgets('a refresh that outlives 2 s: the circle settles, the refresh carries on', (
      tester,
    ) async {
      final pull = Completer<bool>();
      await pumpWrapper(tester, pull: () => pull.future);
      final container = containerOf(tester);

      await pullDown(tester);
      expect(spinnerValue(tester), spinning);
      expect(container.read(manualPullActiveProvider), isTrue);

      await tester.pump(const Duration(milliseconds: 1900));
      expect(spinnerValue(tester), spinning, reason: 'Still inside the 2 s cap');

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(spinnerValue(tester), atRest, reason: 'The circle is gone at 2 s');
      expect(container.read(manualPullActiveProvider), isFalse);
      expect(container.read(manualRefreshSyncedProvider), 0, reason: 'Nothing has synced yet');

      // The pull carries on silently and completes long after.
      await tester.pump(const Duration(seconds: 10));
      pull.complete(true);
      await tester.pump();
      expect(container.read(manualRefreshSyncedProvider), 1);
      expect(spinnerValue(tester), atRest);
    });

    testWidgets('a refresh that outlives 2 s and then fails shows nothing', (tester) async {
      final pull = Completer<bool>();
      await pumpWrapper(tester, pull: () => pull.future);
      final container = containerOf(tester);

      await pullDown(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(spinnerValue(tester), atRest);

      pull.completeError(StateError('pull failed'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(container.read(manualRefreshSyncedProvider), 0);
    });

    testWidgets('a new pull-down is accepted once the circle has settled', (tester) async {
      final pulls = <Completer<bool>>[];
      await pumpWrapper(
        tester,
        pull: () {
          pulls.add(Completer<bool>());
          return pulls.last.future;
        },
      );
      final container = containerOf(tester);

      await pullDown(tester);
      await tester.pump(const Duration(seconds: 1));
      await pullDown(tester);
      expect(pulls, hasLength(1), reason: 'The circle is still up: no second refresh');

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(spinnerValue(tester), atRest);

      await pullDown(tester);
      expect(pulls, hasLength(2), reason: 'The first refresh is still running');
      expect(spinnerValue(tester), spinning);

      // The first refresh ending must not cut the second circle short.
      pulls.first.complete(true);
      await tester.pump();
      expect(container.read(manualRefreshSyncedProvider), 1);
      expect(spinnerValue(tester), spinning);

      pulls.last.complete(false);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(spinnerValue(tester), atRest);
      expect(container.read(manualRefreshSyncedProvider), 1);
    });

    testWidgets('a fast refresh keeps the circle for the 550 ms floor, then says synced', (
      tester,
    ) async {
      await pumpWrapper(tester, pull: () async => true);
      final container = containerOf(tester);

      await pullDown(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(spinnerValue(tester), spinning, reason: 'Held for the floor');
      expect(container.read(manualRefreshSyncedProvider), 0);

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(spinnerValue(tester), atRest);
      expect(container.read(manualPullActiveProvider), isFalse);
      expect(container.read(manualRefreshSyncedProvider), 1);
    });

    testWidgets('a refresh whose pull did not really complete says nothing', (tester) async {
      await pumpWrapper(tester, pull: () async => false);
      final container = containerOf(tester);

      await pullDown(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(spinnerValue(tester), atRest);
      expect(container.read(manualRefreshSyncedProvider), 0);
    });

    testWidgets('a failed refresh says nothing', (tester) async {
      await pumpWrapper(tester, pull: () async => throw StateError('pull failed'));
      final container = containerOf(tester);

      await pullDown(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(spinnerValue(tester), atRest);
      expect(container.read(manualRefreshSyncedProvider), 0);
    });

    testWidgets('leaving the screen mid-refresh releases the banner', (tester) async {
      final pull = Completer<bool>();
      await pumpWrapper(tester, pull: () => pull.future);
      final container = containerOf(tester);
      final scope = tester.widget<ProviderScope>(find.byType(ProviderScope));

      await pullDown(tester);
      expect(container.read(manualPullActiveProvider), isTrue);

      // Same scope, wrapper gone.
      await tester.pumpWidget(
        ProviderScope(
          key: scope.key,
          overrides: scope.overrides,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      await tester.pump();

      expect(container.read(manualPullActiveProvider), isFalse);

      // Let the refresh's minimum-spin timer fire.
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}

/// Dispatches a [ScrollEndNotification] from inside performLayout — where the
/// framework ends a scroll view's activity on a resize.
class _EndsScrollInLayout extends SingleChildRenderObjectWidget {
  const _EndsScrollInLayout();

  @override
  _RenderEndsScrollInLayout createRenderObject(BuildContext context) =>
      _RenderEndsScrollInLayout(context);
}

class _RenderEndsScrollInLayout extends RenderProxyBox {
  _RenderEndsScrollInLayout(this.context);

  final BuildContext context;
  bool _endPending = false;

  void endScrollDuringNextLayout() {
    _endPending = true;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (!_endPending) return;
    _endPending = false;
    ScrollEndNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 0,
        pixels: 0,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: context,
    ).dispatch(context);
  }
}
