import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/data/area_selection.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/widgets/area_picker.dart';

void main() {
  final examples = <String, AreaSelection?>{
    'states': null,
    'lgas': const AreaSelection(country: 'Nigeria', state: 'Nasarawa'),
    'foreign': const AreaSelection(country: 'Ghana', state: 'Greater Accra', lga: 'Accra'),
  };
  for (final example in examples.entries) {
    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      for (final brightness in Brightness.values) {
        final mode = brightness.name;
        final orientation = size.width > size.height ? 'landscape' : 'portrait';
        testWidgets('area picker ${example.key} $orientation $mode', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
            home: Scaffold(body: Builder(builder: (context) => TextButton(
              onPressed: () => showAreaPicker(
                context, initialValue: example.value, allowWholeState: true,
              ),
              child: const SizedBox.shrink(),
            ))),
          ));
          await tester.tap(find.byType(TextButton).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await expectLater(find.byType(MaterialApp), matchesGoldenFile(
            'goldens/area_picker_${example.key}_${orientation}_$mode.png',
          ));
        });
      }
    }
  }
}
