// Pop-ups with a text box must still fit when the keyboard is up (owner phone
// check on #402: the Refund pop-up's reason box showed "BOTTOM OVERFLOWED BY
// 12 PIXELS" with the keyboard open). Any overflow fails the test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/orders/screens/crate_return_approval_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await seedOrdersSample(env);
  });
  tearDown(() async => env.dispose());

  // Phones with the keyboard open: a tall phone and a small one.
  const phones = <(String, Size, double)>[
    ('390x844', Size(390, 844), 340),
    ('360x640', Size(360, 640), 280),
  ];

  for (final (name, size, keyboard) in phones) {
    testWidgets('refund pop-up fits above the keyboard $name', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(),
        size: size,
        followView: true,
        // The app's largest text size (#372 caps scaling at 1.15).
        textScaler: const TextScaler.linear(1.15),
      );
      final refund = find.byKey(OrdersKeys.refund).first;
      await Scrollable.ensureVisible(tester.element(refund), alignment: 0.5);
      await tester.pump();
      await tester.tap(refund);
      await settleOrders(tester);
      // The keyboard opens on the whole phone view, so the pop-up (which sits
      // above the screen) feels it too.
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await settleOrders(tester);

      expect(find.byKey(const Key('orders-refund-reason')), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });

    testWidgets('reject crate return pop-up fits above the keyboard $name', (
      tester,
    ) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const CrateReturnApprovalScreen(),
        size: size,
        followView: true,
        // The app's largest text size (#372 caps scaling at 1.15).
        textScaler: const TextScaler.linear(1.15),
      );
      await tester.tap(find.byTooltip('Reject').first);
      await settleOrders(tester);
      // The keyboard opens on the whole phone view, so the pop-up (which sits
      // above the screen) feels it too.
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await settleOrders(tester);

      expect(
        find.byKey(const Key('crate-return-reject-reason')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });
  }
}
