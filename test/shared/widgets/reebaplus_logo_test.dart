// The official logo has a light and a dark artwork. ReebaplusLogo is the only
// place that picks between them, so screens can't show the wrong one for the
// theme (e.g. the black wordmark on a dark page).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/widgets/reebaplus_logo.dart';

String _assetOf(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  return (image.image as AssetImage).assetName;
}

void main() {
  test('every logo variant exists on disk', () {
    for (final lockup in [false, true]) {
      for (final b in Brightness.values) {
        final path = ReebaplusLogo.assetFor(lockup: lockup, brightness: b);
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    }
  });

  testWidgets('follows the theme brightness', (tester) async {
    for (final b in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: b),
          home: const ReebaplusLogo(height: 40),
        ),
      );
      await tester.pumpAndSettle(); // let the theme cross-fade finish
      expect(
        _assetOf(tester),
        b == Brightness.dark
            ? 'assets/images/brand/reebaplus_mark_dark.png'
            : 'assets/images/brand/reebaplus_mark_light.png',
      );
    }
  });

  testWidgets('brightness override wins over the theme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: const ReebaplusLogo(
          height: 40,
          lockup: true,
          brightness: Brightness.dark,
        ),
      ),
    );
    expect(_assetOf(tester), 'assets/images/brand/reebaplus_lockup_dark.png');
  });

  test('screens use ReebaplusLogo, never the brand files directly', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll(r'\', '/');
      if (path == 'lib/shared/widgets/reebaplus_logo.dart') continue;
      final src = f.readAsStringSync();
      if (src.contains('assets/images/brand/') ||
          src.contains('reebaplus_logo.png')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty, reason: 'Use ReebaplusLogo instead.');
  });
}
