// The POS view selector offers exactly two layouts: list and grid.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/widgets/view_selector_sheet.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(800, 1280)]) {
    testWidgets('only List and Grid at ${size.width}dp', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      bool? picked;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ViewSelectorSheet(
              currentIsList: true,
              onSelect: (isList) => picked = isList,
            ),
          ),
        ),
      );

      expect(find.text('List View'), findsOneWidget);
      expect(find.text('Grid View'), findsOneWidget);
      expect(find.textContaining('Columns'), findsNothing);

      await tester.tap(find.text('Grid View'));
      expect(picked, isFalse);
    });
  }
}
