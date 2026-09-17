import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/diagnostics/overflow_route_reporter.dart';
import 'package:reebaplus_pos/shared/widgets/tab_navigator.dart';

/// Hosts [OverflowingScreen] without a `*Screen` name of its own.
class _StarvedScreen extends StatelessWidget {
  const _StarvedScreen();

  @override
  Widget build(BuildContext context) => const OverflowingScreen();
}

/// A fixed 400dp column in a 200dp box — the loud mode.
class OverflowingScreen extends StatelessWidget {
  const OverflowingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Align loosens the screen's tight constraints so the 100x200 box holds;
    // a zero-width box never paints, so never reports its overflow.
    return const Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 100,
        height: 200,
        child: Column(children: [SizedBox(height: 400)]),
      ),
    );
  }
}

class InventoryLikeScreen extends StatelessWidget {
  const InventoryLikeScreen({super.key});

  @override
  Widget build(BuildContext context) => const OverflowingScreen();
}

/// Installs the hook for the duration of [body], collecting reports, and
/// restores the test binding's handler before the test ends.
Future<List<OverflowReport>> _collect(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final original = FlutterError.onError;
  final forwarded = <FlutterErrorDetails>[];
  final reports = <OverflowReport>[];
  FlutterError.onError = forwarded.add;
  OverflowRouteReporter.install(enabled: true, onReport: reports.add);
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
  expect(
    forwarded,
    isNotEmpty,
    reason: 'every report must still reach the previous handler',
  );
  return reports;
}

void main() {
  testWidgets('tags an overflow with its screen and tab', (tester) async {
    final reports = await _collect(tester, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: TabNavigator(
            navigatorKey: GlobalKey<NavigatorState>(),
            rootScreen: const InventoryLikeScreen(),
          ),
        ),
      );
    });

    expect(reports, hasLength(1));
    final report = reports.single;
    expect(report.screen, 'OverflowingScreen');
    expect(report.tab, 'InventoryLikeScreen');
    expect(report.offstage, isFalse);
    expect(report.widget, 'Column');
    expect(report.summary, contains('overflowed by 200 pixels on the bottom'));
    expect(
      report.toString(),
      startsWith(
        '[overflow] route=OverflowingScreen (tab: InventoryLikeScreen)',
      ),
    );
  });

  testWidgets('marks an overflow in a ticker-muted tab as offstage', (
    tester,
  ) async {
    final reports = await _collect(tester, () async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TickerMode(enabled: false, child: _StarvedScreen()),
        ),
      );
    });

    expect(reports.single.offstage, isTrue);
    expect(reports.single.route, 'OverflowingScreen (offstage)');
  });

  test('ignores errors that are not layout overflows', () {
    final details = FlutterErrorDetails(
      exception: FlutterError('Something else went wrong.'),
    );
    expect(OverflowRouteReporter.isOverflow(details), isFalse);
    expect(OverflowRouteReporter.describe(details), isNull);
  });

  test('an overflow without a creator chain still reports its summary', () {
    final report = OverflowRouteReporter.describe(
      FlutterErrorDetails(
        exception: FlutterError('A RenderFlex overflowed by 5.0 pixels on the right.'),
      ),
    );
    expect(report, isNotNull);
    expect(report!.route, '(unknown screen)');
    expect(report.summary, 'A RenderFlex overflowed by 5.0 pixels on the right.');
  });

  test('is inert when disabled (release builds)', () {
    final original = FlutterError.onError;
    OverflowRouteReporter.install(enabled: false);
    expect(identical(FlutterError.onError, original), isTrue);
  });
}
