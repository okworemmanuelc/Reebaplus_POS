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

  testWidgets('renders seven step-progress dots (§6 full-name step)',
      (tester) async {
    await pumpScreen(tester);

    // _StepDots renders one AnimatedContainer per step. The §6 full-name step
    // (inserted after OTP) bumps the flow from 6 → 7 dots. No other widget on
    // the invite-code step uses an AnimatedContainer, so this count is exact
    // and guards against the renumbering regressing _totalSteps.
    expect(find.byType(AnimatedContainer), findsNWidgets(7));
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
