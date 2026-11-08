// #764 (owner follow-up): the phone's back button and a screen's on-screen
// back arrow must behave the same. The arrows go back with
// `Navigator.maybePop` (or are switched off), which respects the screen's own
// PopScope; the phone button went through `handleBackPress`, which used
// `Navigator.pop` and walked straight past it. Checkout refuses to be left
// while a sale is saving (`PopScope(canPop: !_isProcessing)`, its arrow off),
// because leaving then keeps the cart and lets it be sold twice — the phone
// button could still leave.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

void main() {
  final nav = NavigationService();
  setUp(nav.resetNavigation);
  tearDown(() => nav.tabNavigatorKeys = []);

  testWidgets(
    'back holds on a screen that refuses to be left, and leaves once allowed',
    (tester) async {
      final tabKey = GlobalKey<NavigatorState>();
      final canLeave = ValueNotifier<bool>(false);
      addTearDown(canLeave.dispose);
      nav.tabNavigatorKeys = [tabKey];

      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            key: tabKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('tab root')),
            ),
          ),
        ),
      );
      tabKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ValueListenableBuilder<bool>(
            valueListenable: canLeave,
            builder: (_, can, _) => PopScope(
              canPop: can,
              child: const Scaffold(body: Text('saving the sale')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      nav.handleBackPress(tabKey.currentContext!);
      await tester.pumpAndSettle();
      expect(find.text('saving the sale'), findsOneWidget);

      canLeave.value = true;
      await tester.pump();
      // Past handleBackPress's 500 ms double-fire guard (wall clock).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      nav.handleBackPress(tabKey.currentContext!);
      await tester.pumpAndSettle();
      expect(find.text('saving the sale'), findsNothing);
      expect(find.text('tab root'), findsOneWidget);
    },
  );
}
