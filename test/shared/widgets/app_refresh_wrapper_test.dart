import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  Future<void> pumpWrapper(WidgetTester tester) => tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: AppRefreshWrapper(
                onRefresh: onRefresh,
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
    for (var step = 0; step < 8; step++) {
      await gesture.moveBy(const Offset(0, 30));
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
