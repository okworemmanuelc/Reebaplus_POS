// #428 screens: lower / remove before Accept, the price flag, cancelling an
// accepted order, and the cancel pop-up above the keyboard.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/orders/screens/online_order_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import 'online_order_fixtures.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

const _answer = {'sales.make', 'online_orders.view', 'online_orders.answer'};

void main() {
  // Online ordering ships switched off; these tests cover it switched on.
  setUpAll(() => debugOverrideOnlineOrderingEnabled(true));
  tearDownAll(() => debugOverrideOnlineOrderingEnabled(null));
  late ScreenTestEnvironment env;
  late String orderId;
  late OnlineOrderLineData line;

  setUp(() async {
    env = await setupScreenTestEnvironment();
    orderId = await seedOnlineOrder(
      env.db,
      businessId: env.businessId,
      storeId: env.storeId,
      productId: env.products.first.id,
    );
    line = await (env.db.select(env.db.onlineOrderLines)).getSingle();
  });
  tearDown(() => env.dispose());

  Future<void> pump(WidgetTester tester, {bool followView = false}) =>
      pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        screen: OnlineOrderDetailScreen(onlineOrderId: orderId),
        grantedKeys: _answer,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: 2,
        followView: followView,
        textScaler: const TextScaler.linear(1.15),
      );

  Future<OnlineOrderLineData> reload() => (env.db.select(
    env.db.onlineOrderLines,
  )..where((t) => t.id.equals(line.id))).getSingle();

  Future<void> tapKey(WidgetTester tester, Key k) async {
    await tester.ensureVisible(find.byKey(k));
    await tester.tap(find.byKey(k));
    await tester.pumpAndSettle();
  }

  testWidgets('lower then accept stores the lowered quantity', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    await tapKey(tester, OnlineOrderKeys.lineLower(line.id));
    expect(find.textContaining('(asked for 2)'), findsOneWidget);
    await tapKey(tester, OnlineOrderKeys.accept);
    expect((await reload()).acceptedQty, 1);
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });

  testWidgets('removing the only line disables Accept; put back re-enables',
      (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    await tapKey(tester, OnlineOrderKeys.lineRemove(line.id));
    expect(find.textContaining('Removed'), findsOneWidget);
    expect(
      tester.widget<AppButton>(find.byKey(OnlineOrderKeys.accept)).onPressed,
      isNull,
    );
    await tapKey(tester, OnlineOrderKeys.lineRemove(line.id));
    expect(find.textContaining('Removed'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('price flag shows only when today\'s price differs',
      (tester) async {
    await (env.db.update(env.db.products)
          ..where((t) => t.id.equals(line.productId)))
        .write(const ProductsCompanion(retailerPriceKobo: Value(450000)));
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(OnlineOrderKeys.linePriceFlag(line.id)), findsNothing);
    await disposeScreen(tester);

    await (env.db.update(env.db.products)
          ..where((t) => t.id.equals(line.productId)))
        .write(const ProductsCompanion(retailerPriceKobo: Value(520000)));
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(OnlineOrderKeys.linePriceFlag(line.id)), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('cancel an accepted order with a reason', (tester) async {
    await env.db.onlineOrdersDao.accept(onlineOrderId: orderId);
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(OnlineOrderKeys.accept), findsNothing);
    await tapKey(tester, OnlineOrderKeys.cancelOrder);
    expect(
      tester.widget<AppButton>(find.byKey(OnlineOrderKeys.cancelConfirm)).onPressed,
      isNull,
      reason: 'a reason is required',
    );
    await tester.enterText(find.byType(TextField), 'Van broke down');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(OnlineOrderKeys.cancelConfirm));
    await tester.pumpAndSettle();
    final row = await (env.db.select(
      env.db.onlineOrders,
    )..where((t) => t.id.equals(orderId))).getSingle();
    expect(row.status, 'cancelled_by_shop');
    expect(row.cancelReason, 'Van broke down');
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });

  for (final (name, size, keyboard) in const [
    ('390x844', Size(390, 844), 340.0),
    ('360x640', Size(360, 640), 280.0),
  ]) {
    testWidgets('cancel reason box fits above the keyboard $name',
        (tester) async {
      await env.db.onlineOrdersDao.accept(onlineOrderId: orderId);
      await pumpScreen(
        tester,
        env: env,
        size: size,
        screen: OnlineOrderDetailScreen(onlineOrderId: orderId),
        grantedKeys: _answer,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: 2,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await tapKey(tester, OnlineOrderKeys.cancelOrder);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      expect(find.byKey(OnlineOrderKeys.cancelReason), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });
  }
}
