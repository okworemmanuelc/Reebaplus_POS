// #711 (PRD #707) — Return a Completed crate sale. The customer's crate debt,
// the shop's empty count (pool) and the deposits held all end where they were
// before the sale; empties handed in go back; deposit still held is paid back
// by the Refund destination; a deposit already settled at Confirm is never paid
// twice.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String customerId;
  late OrderService svc;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId), businessId: businessId, name: 'Cashier', pin: '0'));
    customerId = await db.customersDao
        .addCustomer(CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    svc = OrderService(db);
  });

  tearDown(() => db.close());

  Future<(String, String)> brand(String name) async {
    final mfr = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(mfr),
        businessId: businessId,
        name: name,
        depositAmountKobo: const Value(50000)));
    final product = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(product),
        businessId: businessId,
        name: '$name Bottle',
        retailerPriceKobo: const Value(100000),
        manufacturerId: Value(mfr),
        unit: const Value('Bottle'),
        trackEmpties: const Value(true)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: product,
        storeId: storeId,
        quantity: const Value(100)));
    return (mfr, product);
  }

  /// One order, one line per product (qty crates each). [deposits] = money-track
  /// brands (deposit paid at the sale); [customer] null = walk-in.
  Future<String> sell(
    List<String> products,
    int qty, {
    Map<String, int> deposits = const {},
    Map<String, double> exchanged = const {},
    bool withCustomer = true,
    String status = 'pending',
  }) {
    final goods = qty * 100000 * products.length;
    final dep = deposits.values.fold<int>(0, (s, v) => s + v);
    final grand = goods + dep;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(withCustomer ? customerId : null),
        totalAmountKobo: grand,
        netAmountKobo: grand,
        amountPaidKobo: Value(grand),
        paymentType: 'cash',
        status: status,
        staffId: Value(staffId),
        storeId: Value(storeId),
        crateDepositPaidKobo: Value(dep),
      ),
      items: [
        for (final p in products)
          OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: 'placeholder',
            productId: Value(p),
            storeId: storeId,
            quantity: qty.toDouble(),
            unitPriceKobo: 100000,
            totalKobo: qty * 100000,
          ),
      ],
      customerId: withCustomer ? customerId : null,
      amountPaidKobo: grand,
      totalAmountKobo: grand,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
      crateDepositPaidByManufacturer: deposits,
      cratesReturnedByManufacturer: exchanged,
    );
  }

  Future<void> confirm(String id, List<CrateReturnLine> lines,
          {bool asCash = false}) =>
      svc.markAsCompleted(id, staffId,
          customerId: customerId,
          storeId: storeId,
          crateReturns: lines,
          refundAsCash: asCash);

  CrateReturnLine crateLine(String mfr, double taken, double returned,
          {int paid = 0}) =>
      CrateReturnLine(
          manufacturerId: mfr,
          takenCrates: taken,
          returnedCrates: returned,
          rateKobo: 50000,
          paidKobo: paid);

  Future<double> debt(String mfr) async {
    final rows = await db.cratePoolDao.watchCustomerCrateDebt(customerId).first;
    return rows
        .where((r) => r.manufacturerId == mfr)
        .fold<double>(0, (s, r) => s + r.balance);
  }

  Future<double> pool(String mfr) => db.cratePoolDao
      .expectedEmptiesAt(manufacturerId: mfr, storeId: storeId);

  Future<int> held() => db.walletTransactionsDao.getDepositsHeldKobo(customerId);
  Future<int> spendable() => db.walletTransactionsDao.getBalanceKobo(customerId);

  Future<void> doReturn(String id,
      {RefundDestination dest = RefundDestination.cashOrTransfer,
      String? method,
      Map<String, double> damaged = const {}}) =>
      db.ordersDao.returnCompletedSale(
        orderId: id,
        reason: 'brought back',
        staffId: staffId,
        destination: dest,
        refundMethod: method,
        damagedQtyByLine: damaged,
      );

  Future<List<PaymentTransactionData>> pays(String id, String type) =>
      (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(id) & p.type.equals(type)))
          .get();

  Future<void> expectRefusal(Future<void> f, ReturnRefusal r) async {
    try {
      await f;
      fail('expected $r');
    } on ReturnRefusedException catch (e) {
      expect(e.refusal, r);
    }
  }

  group('crate-track customer (no deposit)', () {
    test('owes all: debt cancelled, nothing handed back', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 5);
      await confirm(id, []); // nothing counted back
      expect(await debt(m), 5);
      await doReturn(id);
      expect(await debt(m), 0);
      expect(await pool(m), 0);
      expect((await db.ordersDao.findById(id))!.status, 'cancelled');
      expect((await pays(id, 'refund')).single.amountKobo, 500000);
    });

    test('owes some: only the still-owed part is cancelled, the 2 empties go '
        'back', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 5);
      await confirm(id, [crateLine(m, 5, 2)]);
      expect(await debt(m), 3);
      expect(await pool(m), 2);
      final plan = await db.ordersDao.returnPlan(id);
      expect(plan.emptiesToHandBack.single.crates, 2);
      expect(plan.emptiesToHandBack.single.brandName, 'Star');
      await doReturn(id);
      expect(await debt(m), 0, reason: 'back to pre-sale, not -2');
      expect(await pool(m), 0, reason: 'the 2 empties left the shop again');
      final handBack = await (db.select(db.crateLedger)
            ..where((l) =>
                l.referenceOrderId.equals(id) &
                l.reason.equals('order_returned_empties')))
          .getSingle();
      expect(handBack.quantityDelta, -2);
      expect(handBack.customerId, isNull);
      expect(handBack.storeId, storeId);
    });

    test('owes none: all 5 empties go back, debt stays 0', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 5);
      await confirm(id, [crateLine(m, 5, 5)]);
      expect(await debt(m), 0);
      expect(await pool(m), 5);
      await doReturn(id);
      expect(await debt(m), 0);
      expect(await pool(m), 0);
      expect(
        await (db.select(db.crateLedger)
              ..where((l) =>
                  l.referenceOrderId.equals(id) &
                  l.customerId.isNotNull() &
                  l.reason.equals('order_cancelled')))
            .get(),
        isEmpty,
        reason: 'nothing was owed, so no customer row is written',
      );
    });

    test('damaged units still write off for a crate line', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 5);
      await confirm(id, []);
      final item = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(id)))
              .get())
          .single;
      await doReturn(id, damaged: {item.id: 2});
      expect(await debt(m), 0);
      final stock = await (db.select(db.inventory)
            ..where((t) => t.productId.equals(p)))
          .getSingle();
      expect(stock.quantity, 98, reason: '100 - 5 sold + 5 back - 2 damaged');
    });
  });

  group('deposit customer (money-track)', () {
    test('deposit held, paid back as cash', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 1, deposits: {m: 50000});
      await db.ordersDao.markCompleted(id, staffId);
      expect(await held(), 50000);
      await doReturn(id);
      expect(await held(), 0);
      expect(await spendable(), 0);
      expect((await pays(id, 'refund')).single.amountKobo, 100000);
      final dep = await pays(id, 'crate_deposit');
      expect(dep.map((r) => r.amountKobo).toList()..sort(), [-50000, 50000]);
    });

    test('deposit held, paid back to balance: credit, no cash out', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 1, deposits: {m: 50000});
      await db.ordersDao.markCompleted(id, staffId);
      await doReturn(id, dest: RefundDestination.balance);
      expect(await held(), 0);
      expect(await spendable(), 150000,
          reason: 'goods 100000 + deposit 50000 stay as credit');
      expect(await pays(id, 'refund'), isEmpty);
      expect((await pays(id, 'crate_deposit')).map((r) => r.amountKobo),
          [50000]);
    });

    test('partly settled: the refunded brand is not paid twice', () async {
      final (a, pa) = await brand('Star');
      final (b, pb) = await brand('Gulder');
      final id = await sell([pa, pb], 1, deposits: {a: 50000, b: 50000});
      // Brand A came back at Confirm (deposit credited to the wallet); B not
      // counted.
      await confirm(id, [crateLine(a, 1, 1, paid: 50000)]);
      expect(await held(), 50000, reason: 'only B still held');
      expect(await spendable(), 50000, reason: 'A refund is spendable');
      expect(await pool(a), 1);
      final plan = await db.ordersDao.returnPlan(id);
      expect(plan.depositRefundKobo, 50000);
      await doReturn(id);
      expect(await held(), 0);
      expect(await spendable(), 50000, reason: 'A refund stays; nothing twice');
      expect(await pool(a), 0, reason: 'A empty handed back');
      final dep = await pays(id, 'crate_deposit');
      expect(dep.map((r) => r.amountKobo).toList()..sort(), [-50000, 100000],
          reason: 'one cash-out of B only');
    });

    test('deposit kept for crates that stayed out: refused', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 1, deposits: {m: 50000});
      await confirm(id, [crateLine(m, 1, 0, paid: 50000)]);
      await expectRefusal(doReturn(id), ReturnRefusal.depositKept);
      expect((await db.ordersDao.findById(id))!.status, 'completed');
    });
  });

  group('walk-in who exchanged empties at checkout', () {
    test('empties go back, pool and cash end clean', () async {
      final (m, p) = await brand('Star');
      final id = await sell([p], 5,
          withCustomer: false, exchanged: {m: 5}, status: 'completed');
      expect((await db.ordersDao.findById(id))!.status, 'completed');
      expect(await pool(m), 5);
      await doReturn(id);
      expect(await pool(m), 0);
      expect((await pays(id, 'refund')).single.amountKobo, 500000);
    });
  });
}
