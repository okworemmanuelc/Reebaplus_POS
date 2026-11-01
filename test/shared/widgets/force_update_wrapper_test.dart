import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/widgets/force_update_wrapper.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Future<int?> Function() min,
  int own = 12,
  bool android = true,
}) async {
  await tester.pumpWidget(
    ForceUpdateWrapper(
      fetchMinBuild: min,
      currentBuild: () async => own,
      isAndroid: android,
      openStore: () async {},
      child: const MaterialApp(home: Text('APP')),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('app is shown immediately, before the check answers', (t) async {
    await t.pumpWidget(
      ForceUpdateWrapper(
        fetchMinBuild: () async => 99,
        currentBuild: () async => 12,
        isAndroid: true,
        child: const MaterialApp(home: Text('APP')),
      ),
    );
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('build below minimum blocks', (t) async {
    await _pump(t, min: () async => 13);
    expect(find.text('Update Required'), findsOneWidget);
    expect(find.text('APP'), findsNothing);
  });

  testWidgets('build equal to minimum does not block', (t) async {
    await _pump(t, min: () async => 12);
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('build above minimum does not block', (t) async {
    await _pump(t, min: () async => 5);
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('offline (null answer) does not block', (t) async {
    await _pump(t, min: () async => null);
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('fetch error does not block', (t) async {
    await _pump(t, min: () async => throw Exception('boom'));
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('non-Android never blocks', (t) async {
    await _pump(t, min: () async => 99, android: false);
    expect(find.text('APP'), findsOneWidget);
  });
}
