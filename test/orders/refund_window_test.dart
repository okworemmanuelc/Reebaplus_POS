// #733 (PRD #707) — no refunds after 30 days: a sale whose ORIGINAL
// created_at is more than kRefundWindowDays old can't be Returned, part
// returned, edited, or (with money paid) refunded from the Pending tab.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String customerId;
  late String product;
  late OrderService svc;

  const granted = GateContext(
    grantedKeys: {'sales.cancel'},
    roleRank: GateTier.manager,
    isReady: true,
  );

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId), businessId: businessId, name: 'Cashier', pin: '0'));
    customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    product = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(product),
        businessId: businessId,
        name: 'Rice',
        retailerPriceKobo: const Value(100000),
        unit: const Value('Piece')));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: product,
        storeId: storeId,
        quantity: const Value(100)));
    await db.costBatchesDao.recordInflowBatch(
        productId: product, storeId: storeId, quantity: 100, costKobo: 60000);
    svc = OrderService(db);
  });

  tearDown(() => db.close());

  /// One sale of [qty] units, [paid] tendered, made [daysAgo] days ago.
  Future<String> sell({
    int qty = 2,
    int? paid,
    required int daysAgo,
    bool complete = true,
  }) async {
    final total = qty * 100000;
    final paidNow = paid ?? total;
    final id = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: total,
        netAmountKobo: total,
        amountPaidKobo: Value(paidNow),
        paymentType: paidNow == 0 ? 'credit' : 'cash',
        status: 'pending',
        staffId: Value(staffId),
        storeId: Value(storeId),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(product),
          storeId: storeId,
          quantity: qty.toDouble(),
          unitPriceKobo: 100000,
          buyingPriceKobo: const Value(60000),
          totalKobo: total,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: paidNow,
      totalAmountKobo: total,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
    );
    if (complete) await db.ordersDao.markCompleted(id, staffId);
    await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        OrdersCompanion(
            createdAt: Value(DateTime.now().subtract(Duration(days: daysAgo)))));
    return id;
  }

  Future<String> lineId(String orderId) async => (await (db.select(db.orderItems)
            ..where((i) => i.orderId.equals(orderId)))
          .getSingle())
      .id;

  /// Rows across every table a refund, return or edit writes to.
  Future<List<int>> snapshot() async => [
        (await db.select(db.orders).get()).length,
        (await db.select(db.orderItems).get()).length,
        (await db.select(db.paymentTransactions).get()).length,
        (await db.select(db.walletTransactions).get()).length,
        (await db.select(db.stockTransactions).get()).length,
        (await db.select(db.stockAdjustments).get()).length,
        (await db.select(db.syncQueue).get()).length,
      ];

  Future<void> expectTooOld(Future<Object?> Function() f) async {
    try {
      await f();
      fail('expected tooOld');
    } on ReturnRefusedException catch (e) {
      expect(e.refusal, ReturnRefusal.tooOld);
      expect(e.message,
          "This sale is more than 30 days old, so it can't be returned or refunded.");
    }
  }

  test('the window is one named constant of 30 days', () {
    expect(kRefundWindowDays, 30);
    final now = DateTime(2026, 11, 4, 12);
    expect(isPastRefundWindow(now.subtract(const Duration(days: 29)), now), false);
    expect(isPastRefundWindow(now.subtract(const Duration(days: 30)), now), false);
    expect(isPastRefundWindow(now.subtract(const Duration(days: 31)), now), true);
  });

  group('31-day-old completed sale', () {
    test('full Return refused, nothing written', () async {
      final id = await sell(daysAgo: 31);
      expect(await db.ordersDao.returnRefusal(id), ReturnRefusal.tooOld);
      expect(await svc.isReturnable(id), false);
      final before = await snapshot();
      await expectTooOld(() => db.ordersDao.returnCompletedSale(
          orderId: id, reason: 'old', staffId: staffId));
      await expectTooOld(() => svc.returnCompletedSale(
          orderId: id, reason: 'old', staffId: staffId, gateContext: granted));
      expect(await snapshot(), before);
      expect((await db.ordersDao.findById(id))!.status, 'completed');
    });

    test('part return refused (plan and write), nothing written', () async {
      final id = await sell(daysAgo: 31);
      final lid = await lineId(id);
      final before = await snapshot();
      await expectTooOld(() => db.ordersDao.planPartReturn(id, {lid: 1}));
      await expectTooOld(() => db.ordersDao.returnPartOfSale(
          orderId: id,
          qtyByLineId: {lid: 1},
          reason: 'old',
          staffId: staffId,
          deviceTag: 'TESTAB'));
      expect(await snapshot(), before);
    });

    test('edit refused (plan and write), nothing written', () async {
      final id = await sell(daysAgo: 31);
      final lid = await lineId(id);
      final before = await snapshot();
      await expectTooOld(() => db.ordersDao.planEditSale(id, {lid: 1}, const []));
      await expectTooOld(() => db.ordersDao.editCompletedSale(
          orderId: id,
          newQtyByLineId: {lid: 1},
          addedLines: const [],
          reason: 'old',
          staffId: staffId,
          deviceTag: 'TESTAB',
          refundMethod: 'cash'));
      expect(await snapshot(), before);
    });
  });

  group('29-day-old completed sale', () {
    test('still returnable, part-returnable and editable', () async {
      final id = await sell(daysAgo: 29);
      expect(await db.ordersDao.returnRefusal(id), isNull);
      final lid = await lineId(id);
      await db.ordersDao.planPartReturn(id, {lid: 1});
      await db.ordersDao.planEditSale(id, {lid: 1}, const []);
      await db.ordersDao.returnPartOfSale(
          orderId: id,
          qtyByLineId: {lid: 1},
          reason: 'brought one back',
          staffId: staffId,
          deviceTag: 'TESTAB');
      await db.ordersDao.returnCompletedSale(
          orderId: id, reason: 'rest', staffId: staffId);
    });

    test('full Return goes through', () async {
      final id = await sell(daysAgo: 29);
      await svc.returnCompletedSale(
          orderId: id, reason: 'fine', staffId: staffId, gateContext: granted);
      expect((await db.ordersDao.findById(id))!.status, 'cancelled');
    });
  });

  group('Pending-tab Refund', () {
    test('old order with nothing paid is still cancellable', () async {
      final id = await sell(daysAgo: 31, paid: 0, complete: false);
      expect(await svc.canRefundPending(id), true);
      await svc.markAsCancelled(id, 'never collected', staffId,
          gateContext: granted);
      expect((await db.ordersDao.findById(id))!.status, 'cancelled');
    });

    test('old order with money paid is refused, nothing written', () async {
      final id = await sell(daysAgo: 31, complete: false);
      expect(await svc.canRefundPending(id), false);
      final before = await snapshot();
      await expectTooOld(() => svc.markAsCancelled(id, 'too late', staffId,
          gateContext: granted));
      expect(await snapshot(), before);
      expect((await db.ordersDao.findById(id))!.status, 'pending');
    });

    test('29-day-old order with money paid can still be refunded', () async {
      final id = await sell(daysAgo: 29, complete: false);
      expect(await svc.canRefundPending(id), true);
      await svc.markAsCancelled(id, 'fine', staffId, gateContext: granted);
      expect((await db.ordersDao.findById(id))!.status, 'cancelled');
    });
  });
}
