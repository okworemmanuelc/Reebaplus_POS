// #427: the Orders screen's Online tab + badge, the Online Order detail, the
// view / answer gates (hide, don't block) and the keyboard-up pop-ups.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/orders/screens/online_order_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';

import '../helpers/screen_harness.dart';
import 'online_order_fixtures.dart';

const _view = {'sales.make', 'online_orders.view'};
const _answer = {'sales.make', 'online_orders.view', 'online_orders.answer'};
const _shopper = 'a0000000-0000-7000-8000-000000000001';

void main() {
  late ScreenTestEnvironment env;
  late String orderId;

  setUp(() async {
    env = await setupScreenTestEnvironment();
    orderId = await seedOnlineOrder(
      env.db,
      businessId: env.businessId,
      storeId: env.storeId,
      shopperAccountId: _shopper,
      productId: env.products.first.id,
    );
  });
  tearDown(() => env.dispose());

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Set<String> grants = _answer,
    Size size = const Size(390, 844),
    bool followView = false,
  }) => pumpScreen(
    tester,
    env: env,
    size: size,
    screen: screen,
    grantedKeys: grants,
    roleSlug: 'cashier',
    roleName: 'Cashier',
    roleRank: 2,
    followView: followView,
    textScaler: const TextScaler.linear(1.15),
  );

  testWidgets('no Online tab without online_orders.view', (tester) async {
    await pump(tester, const OrdersScreen(), grants: const {'sales.make'});
    expect(find.byKey(OnlineOrderKeys.tab), findsNothing);
    expect(find.text('Online'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('Online tab shows the New badge and the order', (tester) async {
    await pump(tester, const OrdersScreen(initialIndex: 1), grants: _view);
    expect(find.byKey(OnlineOrderKeys.tab), findsOneWidget);
    final badge = tester.widget<Badge>(find.byKey(OnlineOrderKeys.tabBadge));
    expect(badge.isLabelVisible, isTrue);
    expect(find.byKey(OnlineOrderKeys.card(orderId)), findsOneWidget);
    expectNoOverflow(tester);
    await disposeScreen(tester);
  });

  testWidgets('an expired order is not counted as New', (tester) async {
    await env.db.customStatement(
        "UPDATE online_orders SET status = 'expired' WHERE id = ?", [orderId]);
    await pump(tester, const OrdersScreen(initialIndex: 1), grants: _view);
    final badge = tester.widget<Badge>(find.byKey(OnlineOrderKeys.tabBadge));
    expect(badge.isLabelVisible, isFalse);
    expect(find.byKey(OnlineOrderKeys.card(orderId)), findsOneWidget);
    expect(find.text('EXPIRED'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('detail shows the order; actions hidden without answer',
      (tester) async {
    await pump(
      tester,
      OnlineOrderDetailScreen(onlineOrderId: orderId),
      grants: _view,
    );
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('08030000000'), findsOneWidget);
    expect(find.text('Star Lager'), findsOneWidget);
    expect(find.byKey(OnlineOrderKeys.accept), findsNothing);
    expect(find.byKey(OnlineOrderKeys.decline), findsNothing);
    expectNoOverflow(tester);
    await disposeScreen(tester);
  });

  testWidgets('decline with a reason writes the answer', (tester) async {
    await pump(tester, OnlineOrderDetailScreen(onlineOrderId: orderId));
    await tester.ensureVisible(find.byKey(OnlineOrderKeys.decline));
    await tester.tap(find.byKey(OnlineOrderKeys.decline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(OnlineOrderKeys.declineConfirm));
    await tester.pumpAndSettle();
    final row = await (env.db.select(
      env.db.onlineOrders,
    )..where((t) => t.id.equals(orderId))).getSingle();
    expect(row.status, 'declined');
    expect(row.declineReason, 'Out of stock');
    await tester.pump(const Duration(seconds: 5)); // the success toast
    await disposeScreen(tester);
  });

  testWidgets('accept on a first order asks existing-or-new', (tester) async {
    await pump(tester, OnlineOrderDetailScreen(onlineOrderId: orderId));
    await tester.ensureVisible(find.byKey(OnlineOrderKeys.accept));
    await tester.tap(find.byKey(OnlineOrderKeys.accept));
    await tester.pumpAndSettle();
    expect(find.byKey(OnlineOrderKeys.linkNew), findsOneWidget);
    await tester.tap(find.byKey(OnlineOrderKeys.linkNew));
    await tester.pumpAndSettle();
    final row = await (env.db.select(
      env.db.onlineOrders,
    )..where((t) => t.id.equals(orderId))).getSingle();
    expect(row.status, 'accepted');
    expect(row.customerId, isNotNull);
    await tester.pump(const Duration(seconds: 5)); // the success toast
    await disposeScreen(tester);
  });

  // The keyboard opens on the whole view, so the pop-up feels it too.
  const phones = <(String, Size, double)>[
    ('390x844', Size(390, 844), 340),
    ('360x640', Size(360, 640), 280),
  ];
  for (final (name, size, keyboard) in phones) {
    testWidgets('decline "Other" box fits above the keyboard $name',
        (tester) async {
      await pump(
        tester,
        OnlineOrderDetailScreen(onlineOrderId: orderId),
        size: size,
        followView: true,
      );
      await tester.ensureVisible(find.byKey(OnlineOrderKeys.decline));
      await tester.tap(find.byKey(OnlineOrderKeys.decline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      expect(find.byKey(OnlineOrderKeys.declineOther), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });

    testWidgets('customer search box fits above the keyboard $name',
        (tester) async {
      await pump(
        tester,
        OnlineOrderDetailScreen(onlineOrderId: orderId),
        size: size,
        followView: true,
      );
      await tester.ensureVisible(find.byKey(OnlineOrderKeys.accept));
      await tester.tap(find.byKey(OnlineOrderKeys.accept));
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      expect(find.byKey(OnlineOrderKeys.linkSearch), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });
  }
}
