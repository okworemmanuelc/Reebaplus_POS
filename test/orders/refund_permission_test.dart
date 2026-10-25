import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/screen_harness.dart';
import 'orders_fixture.dart' show settleOrders;

const _granted = GateContext(
  grantedKeys: {'sales.view', 'orders.view', 'sales.cancel'},
  roleRank: GateTier.manager,
  isReady: true,
);
const _revoked = GateContext(
  grantedKeys: {'sales.view', 'orders.view'},
  roleRank: GateTier.manager,
  isReady: true,
);
final _context = StateProvider<GateContext>((ref) => _granted);

// The acceptance criterion is no persistence changes at all, including the
// outbox. Compare the real in-memory database rather than mocking the refund.
Future<Map<String, Object?>> _snapshot(AppDatabase db) async {
  final result = <String, Object?>{};
  for (final table in db.allTables) {
    result[table.actualTableName] = (await db.customSelect(
      'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
    ).get()).map((r) => r.data).toList();
  }
  return result;
}

void main() {
  late ScreenTestEnvironment env;
  late OrderService service;
  late String orderId;
  late String customerId;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 2, manufacturerCount: 2, businessType: 'Bar',
    );
    final db = env.db;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
    await db.into(db.users).insert(UsersCompanion.insert(
      id: const Value('test-user-id'), businessId: env.businessId,
      name: 'Refunding manager', pin: '1234',
    ));
    customerId = await db.customersDao.addCustomer(CustomersCompanion.insert(
      businessId: env.businessId, name: 'Refund customer',
    ));
    final manufacturerId = env.manufacturers.first.id;
    await (db.update(db.manufacturers)..where((r) => r.id.equals(manufacturerId)))
        .write(const ManufacturersCompanion(depositAmountKobo: Value(25000)));
    for (var i = 0; i < 2; i++) {
      await (db.update(db.products)..where((r) => r.id.equals(env.products[i].id)))
          .write(ProductsCompanion(
            unit: const Value('Bottle'), trackEmpties: const Value(true),
            manufacturerId: Value(env.manufacturers[i].id),
          ));
    }
    service = OrderService(db);
    final number = await service.addOrder(
      customerId: customerId,
      cart: [for (final product in env.products)
        {'id': product.id, 'qty': 1, 'unitPriceKobo': 100000, 'name': product.name}],
      totalAmountKobo: 225000, amountPaidKobo: 225000, paymentType: 'cash',
      staffId: 'test-user-id', storeId: env.storeId,
      crateDepositPaidKobo: 25000,
      crateDepositPaidByManufacturer: {manufacturerId: 25000},
    );
    orderId = (await (db.select(db.orders)..where((r) => r.orderNumber.equals(number)))
        .getSingle()).id;
    // Positive controls: the refund can reverse real stock, money and crates.
    expect((await db.select(db.inventory).get()).map((r) => r.quantity), [49, 49]);
    expect(await db.select(db.walletTransactions).get(), isNotEmpty);
    expect(await db.select(db.paymentTransactions).get(), isNotEmpty);
    expect(await db.select(db.crateLedger).get(), isNotEmpty);
    expect(await db.select(db.orderCrateLines).get(), isNotEmpty);
  });
  tearDown(() => env.dispose());

  test('the refund command refuses a revoked grant without any writes', () async {
    final before = await _snapshot(env.db);
    await expectLater(
      () => service.markAsCancelled(orderId, 'Changed mind', 'test-user-id',
        gateContext: _revoked),
      throwsA(isA<GateDeniedError>().having((e) => e.gateName, 'gate', 'refundOrder')),
    );
    expect(await _snapshot(env.db), before);
  });

  test('an authorized refund preserves the existing stock, cash and crate reversals', () async {
    final db = env.db;
    final sale = await (db.select(db.paymentTransactions)
      ..where((r) => r.type.equals('sale'))).getSingle();
    final queuedBefore = (await db.select(db.syncQueue).get()).length;
    await service.markAsCancelled(orderId, 'Changed mind', 'test-user-id',
      gateContext: _granted);
    final order = await (db.select(db.orders)..where((r) => r.id.equals(orderId)))
        .getSingle();
    expect(order.status, 'cancelled');
    expect(order.cancellationReason, 'Changed mind');
    expect((await db.select(db.inventory).get()).map((r) => r.quantity), [50, 50]);
    expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0);
    expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
    final refund = await (db.select(db.paymentTransactions)
      ..where((r) => r.type.equals('refund'))).getSingle();
    expect(refund.amountKobo, 200000);
    expect(await (db.select(db.paymentTransactions)..where((r) => r.id.equals(sale.id)))
        .getSingle(), sale);
    expect((await db.select(db.crateLedger).get())
        .fold<int>(0, (sum, r) => sum + r.quantityDelta), 0);
    expect((await db.select(db.syncQueue).get()).length, greaterThan(queuedBefore));
  });

  testWidgets('revocation while confirmation is open refuses refund without any writes',
      (tester) async {
    final context = await pumpScreen(
      tester, env: env, size: const Size(390, 844),
      screen: const OrdersScreen(), settle: false,
      overrides: [
        orderServiceProvider.overrideWithValue(service),
        gateContextProvider.overrideWith((ref) => ref.watch(_context)),
      ],
    );
    try {
      await settleOrders(tester);
      final refund = find.byKey(OrdersKeys.refund).first;
      await Scrollable.ensureVisible(tester.element(refund));
      await tester.tap(refund);
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(
        of: find.byKey(const Key('orders-refund-reason')),
        matching: find.byType(TextField),
      ), 'Changed mind');
      await tester.pump();
      final before = await tester.runAsync(() => _snapshot(env.db));
      ProviderScope.containerOf(context, listen: false)
          .read(_context.notifier).state = _revoked;
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, 'Issue Refund'));
      await settleOrders(tester);
      expect(await tester.runAsync(() => _snapshot(env.db)), before);
      expect(find.text('You no longer have access to Refund Order.'), findsOneWidget);
    } finally {
      AppNotification.hide();
      await disposeScreen(tester);
    }
  });
}
