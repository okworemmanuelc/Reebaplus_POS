// #649 — a walk-in has no `order_crate_lines`, so Confirm's modal rebuilds the
// expected crates from the order's items. After an Empties Exchange it must ask
// only for what is still out, and never about a brand already cleared.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart';

import '../helpers/screen_harness.dart';

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      businessType: 'Bar',
      manufacturerCount: 2,
      productCount: 0,
    );
  });
  tearDown(() async => env.dispose());

  Future<ProductData> bottle(String manufacturerId) async {
    final id = UuidV7.generate();
    await env.db
        .into(env.db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: 'Bottle $id',
            retailerPriceKobo: const Value(100000),
            manufacturerId: Value(manufacturerId),
            unit: const Value('Bottle'),
            trackEmpties: const Value(true),
          ),
        );
    await env.db
        .into(env.db.inventory)
        .insert(
          InventoryCompanion.insert(
            businessId: env.businessId,
            productId: id,
            storeId: env.storeId,
            quantity: const Value(50),
          ),
        );
    return (env.db.select(
      env.db.products,
    )..where((p) => p.id.equals(id))).getSingle();
  }

  /// A walk-in sale of 3 crates of each product, recorded on the v1 path so its
  /// order items are local, then read back as the Pending tab hands it over.
  Future<OrderWithItems> walkIn(
    List<ProductData> products,
    Map<String, double> returned,
  ) async {
    final staffId = UuidV7.generate();
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: env.businessId,
            name: 'Cashier',
            pin: '0000',
          ),
        );
    final total = 300000 * products.length;
    final orderId = await env.db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: env.businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        totalAmountKobo: total,
        netAmountKobo: total,
        amountPaidKobo: Value(total),
        paymentType: 'cash',
        status: 'pending',
        staffId: Value(staffId),
        storeId: Value(env.storeId),
      ),
      items: [
        for (final p in products)
          OrderItemsCompanion.insert(
            businessId: env.businessId,
            orderId: 'placeholder',
            productId: Value(p.id),
            storeId: env.storeId,
            quantity: 3,
            unitPriceKobo: 100000,
            totalKobo: 300000,
          ),
      ],
      amountPaidKobo: total,
      totalAmountKobo: total,
      staffId: staffId,
      storeId: env.storeId,
      cratesReturnedByManufacturer: returned,
    );
    final order = await (env.db.select(
      env.db.orders,
    )..where((o) => o.id.equals(orderId))).getSingle();
    final items = await (env.db.select(
      env.db.orderItems,
    )..where((i) => i.orderId.equals(orderId))).get();
    return OrderWithItems(order, [
      for (final item in items)
        OrderItemDataWithProductData(
          item,
          products.firstWhere((p) => p.id == item.productId),
        ),
    ], null);
  }

  Future<void> pumpModal(WidgetTester tester, OrderWithItems order) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(800, 1280),
      screen: CrateReturnModal(orderWithItems: order),
      settle: false,
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String prefill(WidgetTester tester, String manufacturerId) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byKey(Key('crate-return-count-$manufacturerId')),
          matching: find.byType(TextField),
        ),
      )
      .controller!
      .text;

  testWidgets('a part-exchanged walk-in expects only what is outstanding', (
    tester,
  ) async {
    final star = env.manufacturers[0].id;
    final order = await tester.runAsync(
      () async => walkIn([await bottle(star)], {star: 1}),
    );
    await pumpModal(tester, order!);

    expect(find.textContaining('Took 2 crates'), findsOneWidget);
    expect(prefill(tester, star), '2');
    await disposeScreen(tester);
  });

  testWidgets('a brand already cleared is not offered', (tester) async {
    final star = env.manufacturers[0].id;
    final hero = env.manufacturers[1].id;
    final order = await tester.runAsync(
      () async => walkIn([await bottle(star), await bottle(hero)], {star: 3}),
    );
    await pumpModal(tester, order!);

    expect(find.byKey(Key('crate-return-count-$star')), findsNothing);
    expect(find.byKey(Key('crate-return-count-$hero')), findsOneWidget);
    expect(find.textContaining('Took 3 crates'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('no exchange: the full quantity, as before', (tester) async {
    final star = env.manufacturers[0].id;
    final order = await tester.runAsync(
      () async => walkIn([await bottle(star)], const {}),
    );
    await pumpModal(tester, order!);

    expect(find.textContaining('Took 3 crates'), findsOneWidget);
    await disposeScreen(tester);
  });
}
