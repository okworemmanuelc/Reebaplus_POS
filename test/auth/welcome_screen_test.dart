import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';

void main() {
  Future<void> pumpWelcome(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: WelcomeScreen())),
    );
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

  testWidgets('Join with invite code routes to Staff Sign Up', (tester) async {
    await pumpWelcome(tester);

    await tester.tap(find.text('Join with invite code'));
    await tester.pumpAndSettle();

    expect(find.byType(StaffSignUpScreen), findsOneWidget);
    expect(find.text('Enter your invite code'), findsOneWidget);
  });
}
