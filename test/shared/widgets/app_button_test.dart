import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('a double tap on an unfinished future fires once (#659)', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      _host(
        AppButton(
          text: 'Go',
          onAsyncPressed: () {
            calls++;
            return gate.future;
          },
        ),
      ),
    );

    // Two taps with no frame between them: the lock must already be taken.
    await tester.tap(find.byType(InkWell));
    await tester.tap(find.byType(InkWell));
    await tester.pump();

    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a dialog over the button hides the spinner, not the lock', (
    tester,
  ) async {
    final answered = Completer<void>();
    final saved = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: AppButton(
                text: 'Go',
                onAsyncPressed: () async {
                  calls++;
                  // Waiting on the person: the dialog is up.
                  await showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      content: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Answer'),
                      ),
                    ),
                  );
                  answered.complete();
                  // Waiting on the save.
                  await saved.future;
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AppButton));
    // Settles only because nothing is spinning behind the dialog.
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Still locked, even though the button looks normal.
    final inkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(AppButton),
        matching: find.byType(InkWell),
      ),
    );
    inkWell.onTap!();
    expect(calls, 1);

    await tester.tap(find.text('Answer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(answered.isCompleted, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    saved.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the lock releases after completion', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(AppButton(text: 'Go', onAsyncPressed: () async => calls++)),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(calls, 2);
  });

  testWidgets('the lock releases after an error', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        AppButton(
          text: 'Go',
          onAsyncPressed: () async {
            calls++;
            throw StateError('boom');
          },
        ),
      ),
    );
    // The error propagates as normal (to the zone), it is not swallowed.
    await runZonedGuarded(() async {
      await tester.tap(find.byType(InkWell));
      await tester.pump();
    }, (_, _) {});
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await runZonedGuarded(() async {
      await tester.tap(find.byType(InkWell));
      await tester.pump();
    }, (_, _) {});
    expect(calls, 2);
  });

  testWidgets('plain onPressed behaves as before', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(AppButton(text: 'Go', onPressed: () => calls++)),
    );
    await tester.tap(find.byType(InkWell));
    await tester.tap(find.byType(InkWell));
    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('isLoading still disables and spins', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(AppButton(text: 'Go', isLoading: true, onPressed: () => calls++)),
    );
    await tester.tap(find.byType(InkWell));
    expect(calls, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('no setState after dispose when unmounted mid-run', (
    tester,
  ) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      _host(AppButton(text: 'Go', onAsyncPressed: () => gate.future)),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    await tester.pumpWidget(_host(const SizedBox()));
    gate.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('onPressed and onAsyncPressed together is rejected', () {
    expect(
      () => AppButton(text: 'x', onPressed: () {}, onAsyncPressed: () async {}),
      throwsAssertionError,
    );
  });
}
