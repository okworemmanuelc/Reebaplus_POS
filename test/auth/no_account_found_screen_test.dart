import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: NoAccountFoundScreen(email: 'newbiz@example.com'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the heading, the email, and both entry points',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('No account found'), findsOneWidget);
    expect(find.textContaining('newbiz@example.com'), findsOneWidget);
    expect(find.text('Create a new business'), findsOneWidget);
    expect(find.text('Join with invite code'), findsOneWidget);
  });

  testWidgets('Join with invite code routes to Staff Sign Up',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Join with invite code'));
    await tester.pumpAndSettle();

    expect(find.byType(StaffSignUpScreen), findsOneWidget);
    // Step 0 of the Staff Sign Up flow — the invite-code entry.
    expect(find.text('Enter your invite code'), findsOneWidget);
  });
}
