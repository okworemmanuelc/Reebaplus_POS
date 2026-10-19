// Resolve unsynced data dialog restyle (#443). The typed-DISCARD box lives in
// this pop-up, so it must scroll and fit above the keyboard (owner phone check,
// #402): AlertDialog(scrollable: true) with no second scroll view inside it.
// Wording, export gating and the discard unlock are unchanged (the photo
// wording is pinned by resolve_unsynced_photos_dialog_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/sync/widgets/resolve_unsynced_data_dialog.dart';
import 'package:reebaplus_pos/features/sync/widgets/sync_parts.dart';

Future<void> _open(
  WidgetTester tester, {
  required Size size,
  required int orphanCount,
  required int photoCount,
  bool isResign = false,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: TextButton(
                onPressed: () => showResolveUnsyncedDataDialog(
                  context,
                  ref,
                  pendingCount: 0,
                  orphanCount: orphanCount,
                  photoCount: photoCount,
                  isResign: isResign,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the pop-up scrolls once and holds the typed-confirm box', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(390, 844),
      orphanCount: 0,
      photoCount: 1,
    );
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.scrollable, isTrue);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
      reason: 'one scroll view (the dialog\'s own), not two nested',
    );
    expect(find.byKey(SyncKeys.resolveInput), findsOneWidget);
    expect(find.byKey(SyncKeys.resolveDiscard), findsOneWidget);
  });

  testWidgets('records: export first, the box and Discard wait for it', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(390, 844),
      orphanCount: 2,
      photoCount: 0,
    );
    expect(find.text('Records that can\'t sync'), findsOneWidget);
    expect(find.text('Export records'), findsOneWidget);
    expect(find.text('Export the records to unlock discard.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.byKey(SyncKeys.resolveDiscard))
          .onPressed,
      isNull,
    );
    // Cancel closes it and returns to the screen underneath.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('resign wording keeps its own button and instruction', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(390, 844),
      orphanCount: 0,
      photoCount: 2,
      isResign: true,
    );
    expect(find.text('Discard & leave'), findsOneWidget);
    expect(find.textContaining('and leave your account.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'discard');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(SyncKeys.resolveDiscard))
          .onPressed,
      isNotNull,
      reason: 'the confirmation word is case-insensitive, as before',
    );
  });

  testWidgets('the typed-confirm box turns autocorrect off', (tester) async {
    await _open(
      tester,
      size: const Size(390, 844),
      orphanCount: 0,
      photoCount: 1,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).autocorrect, false);
  });

  // The pop-up sits above the screen, so the keyboard reaches it on the whole
  // phone view: 360x640 and 390x844 at the app's largest text size (1.15).
  for (final (name, size, keyboard) in const [
    ('390x844', Size(390, 844), 340.0),
    ('360x640', Size(360, 640), 280.0),
  ]) {
    for (final (label, orphans, photos) in const [
      ('photos only', 0, 3),
      ('records and photos', 2, 3),
    ]) {
      testWidgets('fits above the keyboard, $label, $name', (tester) async {
        await _open(
          tester,
          size: size,
          orphanCount: orphans,
          photoCount: photos,
          textScale: 1.15,
        );
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(find.byKey(SyncKeys.resolveInput), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (orphans == 0) {
          await tester.enterText(find.byType(TextField), 'DISCARD');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
