// #659: the drawer's Log Out button locks on the first tap and spins until the
// logout future ends.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer_parts.dart';

void main() {
  testWidgets('two quick taps log out once and the button spins until done',
      (tester) async {
    var calls = 0;
    final done = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DrawerFooter(
            onDisplay: null,
            bottomPadding: 0,
            onLogOut: () {
              calls++;
              return done.future;
            },
          ),
        ),
      ),
    );

    final button = find.byKey(AppDrawerKeys.logOut);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // Two taps with no frame in between.
    await tester.tap(button);
    await tester.tap(button);
    expect(calls, 1);

    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(calls, 1);

    done.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a finished logout unlocks the button again', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DrawerFooter(
            onDisplay: null,
            bottomPadding: 0,
            onLogOut: () async => calls++,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(AppDrawerKeys.logOut));
    await tester.pump();
    await tester.tap(find.byKey(AppDrawerKeys.logOut));
    await tester.pump();
    expect(calls, 2);
  });
}
