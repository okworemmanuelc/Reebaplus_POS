// #431 screen: Send to till shows on an accepted order for a seller, loads the
// accepted lines into the Cart tagged with the order, and writes nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/orders/screens/online_order_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';

import '../helpers/screen_harness.dart';
import 'online_order_fixtures.dart';

const _seller = {'sales.make', 'online_orders.view', 'online_orders.answer'};

void main() {
  late ScreenTestEnvironment env;
  late String orderId;

  setUp(() async {
    env = await setupScreenTestEnvironment();
    orderId = await seedOnlineOrder(
      env.db,
      businessId: env.businessId,
      storeId: env.storeId,
      productId: env.products.first.id,
    );
  });
  tearDown(() => env.dispose());

  Future<void> pump(WidgetTester tester, Set<String> keys) => pumpScreen(
    tester,
    env: env,
    size: const Size(390, 844),
    screen: OnlineOrderDetailScreen(onlineOrderId: orderId),
    grantedKeys: keys,
    roleSlug: 'cashier',
    roleName: 'Cashier',
    roleRank: 2,
  );

  testWidgets('a new order has no Send to till', (tester) async {
    await pump(tester, _seller);
    await tester.pumpAndSettle();
    expect(find.byKey(OnlineOrderKeys.sendToTill), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('without sales.make there is no Send to till', (tester) async {
    await env.db.onlineOrdersDao.accept(onlineOrderId: orderId);
    await pump(tester, const {'online_orders.view', 'online_orders.answer'});
    await tester.pumpAndSettle();
    expect(find.byKey(OnlineOrderKeys.sendToTill), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('Send to till fills the Cart, tagged, and leaves it Accepted',
      (tester) async {
    await env.db.onlineOrdersDao.accept(onlineOrderId: orderId);
    await pump(tester, _seller);
    await tester.pumpAndSettle();
    final button = find.byKey(OnlineOrderKeys.sendToTill);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(OnlineOrderDetailScreen)),
    );
    final cart = container.read(cartProvider);
    expect(cart.activeOnlineOrderId, orderId);
    expect(cart.value.single['unitPriceKobo'], 450000);
    expect(container.read(navigationProvider).currentIndex.value, 8);
    final row = await (env.db.select(
      env.db.onlineOrders,
    )..where((t) => t.id.equals(orderId))).getSingle();
    expect(row.status, 'accepted');
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });
}
