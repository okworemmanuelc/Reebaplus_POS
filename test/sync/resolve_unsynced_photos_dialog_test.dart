// resolve_unsynced_photos_dialog_test.dart
//
// #343. When a logout is held up only by product photos that won't upload,
// the Resolve dialog names them in plain words and, since a photo can't go in
// the records export, unlocks the typed discard without an export step.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';

Future<void> _open(
  WidgetTester tester, {
  required int orphanCount,
  required int photoCount,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showResolveUnsyncedDataDialog(
                context,
                ref,
                pendingCount: 0,
                orphanCount: orphanCount,
                photoCount: photoCount,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

FilledButton _discardButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Discard & log out'),
    );

void main() {
  testWidgets('photos only: named in plain words, no export, typed discard',
      (tester) async {
    await _open(tester, orphanCount: 0, photoCount: 1);

    expect(find.text('Photos that can\'t upload'), findsOneWidget);
    expect(
      find.textContaining('1 product photo on this device could not be '
          'uploaded'),
      findsOneWidget,
    );
    expect(find.text('Export records'), findsNothing);
    expect(_discardButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'DISCARD');
    await tester.pump();
    expect(_discardButton(tester).onPressed, isNotNull);
  });

  testWidgets('records and photos: export still required, photos mentioned',
      (tester) async {
    await _open(tester, orphanCount: 2, photoCount: 3);

    expect(find.text('Records that can\'t sync'), findsOneWidget);
    expect(find.textContaining('3 product photos could not be uploaded'),
        findsOneWidget);
    expect(find.text('Export records'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse, reason: 'discard waits for the export');
  });
}
