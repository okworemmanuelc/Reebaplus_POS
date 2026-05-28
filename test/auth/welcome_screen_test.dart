import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';

void main() {
  Future<void> pumpWelcome(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('renders logo, name, tagline, and the three CTAs', (tester) async {
    await pumpWelcome(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Reebaplus'), findsOneWidget);
    expect(
      find.text('Sales, stock, and staff — all in your pocket.'),
      findsOneWidget,
    );
    expect(find.text('Create a new business'), findsOneWidget);
    expect(find.text('Join with invite code'), findsOneWidget);
    expect(find.textContaining('Sign in'), findsOneWidget);
  });

  testWidgets('Join with invite code routes to the placeholder', (tester) async {
    await pumpWelcome(tester);

    await tester.tap(find.text('Join with invite code'));
    await tester.pumpAndSettle();

    expect(find.byType(ComingSoonScreen), findsOneWidget);
    expect(find.textContaining('Staff sign-up is coming soon'), findsOneWidget);
  });
}
