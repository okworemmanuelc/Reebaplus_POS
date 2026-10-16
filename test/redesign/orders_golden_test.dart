// Visual goldens for the Orders restyle (#393 PR 2, PRD #346 Wave 2 A): the
// Orders tab (Pending, CEO) at 390×844, 844×390 (insets), 800×1280 and
// 1280×800, the Completed tab at 390×844, the receipt and crate return
// sheets at 390×844 and 844×390, and Crate Return Approval at the four sizes;
// light + dark. Sample data only; times hang off noon today (time-proof).
//
//     flutter test --update-goldens test/redesign/orders_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/orders/screens/crate_return_approval_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';

import '../helpers/screen_harness.dart';
import '../orders/orders_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await seedOrdersSample(env);
  });
  tearDown(() async => env.dispose());

  const cases = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 48)),
    ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), EdgeInsets.only(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), EdgeInsets.only(top: 24)),
  ];

  Future<void> snap(WidgetTester tester, String name) async {
    await expectLater(
      find.byType(Navigator).first,
      matchesGoldenFile('goldens/$name.png'),
    );
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light ? 'light' : 'dark';

    for (final (size, s, pad) in cases) {
      testWidgets('orders $size $theme', (tester) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const OrdersScreen(),
          size: s,
          padding: pad,
          brightness: brightness,
        );
        await snap(tester, 'orders_${size}_$theme');
      });

      testWidgets('crate_return_approval $size $theme', (tester) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const CrateReturnApprovalScreen(),
          size: s,
          padding: pad,
          brightness: brightness,
        );
        await snap(tester, 'crate_return_approval_${size}_$theme');
      });
    }

    testWidgets('orders completed 390x844 $theme', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(initialIndex: 1),
        brightness: brightness,
      );
      await snap(tester, 'orders_completed_390x844_$theme');
    });

    for (final (size, s, pad) in cases.take(2)) {
      testWidgets('orders receipt sheet $size $theme', (tester) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const OrdersScreen(initialIndex: 1),
          size: s,
          padding: pad,
          brightness: brightness,
        );
        // The order number (the customer name would open their profile).
        await tester.tap(find.text('Order #ORD-000104-A1B2C3'));
        await settleOrders(tester);
        expect(find.byKey(OrdersKeys.receiptSheet), findsOneWidget);
        await snap(tester, 'orders_receipt_sheet_${size}_$theme');
      });

      testWidgets('crate return sheet $size $theme', (tester) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const OrdersScreen(),
          size: s,
          padding: pad,
          brightness: brightness,
        );
        final confirm = find.descendant(
          of: find.byKey(orderRowKey(kPendingCrateOrderId)),
          matching: find.byKey(OrdersKeys.confirm),
        );
        // Centre it: scrolled to the top it would sit under the pinned tab bar.
        await Scrollable.ensureVisible(tester.element(confirm), alignment: 0.5);
        await tester.pump();
        await tester.tap(confirm);
        await settleOrders(tester);
        expect(find.byKey(OrdersKeys.crateReturnSheet), findsOneWidget);
        await snap(tester, 'crate_return_sheet_${size}_$theme');
      });
    }
  }
}
