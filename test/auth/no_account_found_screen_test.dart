import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: NoAccountFoundScreen(email: 'newbiz@example.com'),
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

  testWidgets('Join with invite code routes to the placeholder',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Join with invite code'));
    await tester.pumpAndSettle();

    expect(find.byType(ComingSoonScreen), findsOneWidget);
    expect(find.textContaining('Staff sign-up is coming soon'), findsOneWidget);
  });
}
