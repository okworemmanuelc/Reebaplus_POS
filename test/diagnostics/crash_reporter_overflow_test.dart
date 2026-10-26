import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/services/crash_reporter.dart';

class OverflowingScreen extends StatelessWidget {
  const OverflowingScreen({super.key});

  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 100,
      height: 200,
      child: Column(children: [SizedBox(height: 400)]),
    ),
  );
}

void main() {
  testWidgets('overflow context names the owning screen and widget (#60)', (
    tester,
  ) async {
    final original = FlutterError.onError;
    final seen = <FlutterErrorDetails>[];
    FlutterError.onError = seen.add;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OverflowingScreen())),
      );
    } finally {
      FlutterError.onError = original;
    }
    expect(seen, isNotEmpty);
    final context = CrashReporter.describeOverflowContext(seen.first);
    expect(context, contains('OverflowingScreen'));
    expect(context, contains('widget=Column'));
  });

  test('a non-overflow error yields no overflow context', () {
    final details = FlutterErrorDetails(exception: StateError('boom'));
    expect(CrashReporter.describeOverflowContext(details), isNull);
  });
}
