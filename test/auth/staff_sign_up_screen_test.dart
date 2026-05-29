import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: StaffSignUpScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the invite-code step', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Enter your invite code'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('shows an inline error when the code is malformed',
      (tester) async {
    await pumpScreen(tester);

    // Too short / wrong length — fails the 8-char regex before any network
    // call, so the inline error is shown on the same step ("Try again").
    await tester.enterText(find.byType(TextField).first, 'ABC');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.text('Enter the 8-character invite code.'), findsOneWidget);
    // Still on the invite-code step.
    expect(find.text('Enter your invite code'), findsOneWidget);
  });
}
