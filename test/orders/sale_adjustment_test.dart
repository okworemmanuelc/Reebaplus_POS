// #712 (PRD #707 slice 5, ADR 0035) — the sale adjustment record and part
// return. Everything an adjustment writes references the ADJUSTMENT's id; the
// sale is never changed; returnable quantity is derived from the minus lines.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
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

  Future<(String, String)> crateBrand(String name, {int stock = 100}) async {
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
        quantity: Value(stock.toDouble())));
    await db.costBatchesDao.recordInflowBatch(
        productId: product, storeId: storeId, quantity: stock.toDouble(), costKobo: 60000);
    return (mfr, product);
  }

  Future<String> plainProduct({int stock = 100}) async {
    final product = UuidV7.generate();
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
        quantity: Value(stock.toDouble())));
    await db.costBatchesDao.recordInflowBatch(
        productId: product, storeId: storeId, quantity: stock.toDouble(), costKobo: 60000);
    return product;
  }

  /// One order, one line. [paid] defaults to the grand total (goods + deposit).
  Future<String> sell(
    String product,
    int qty, {
    bool withCustomer = true,
    int? paid,
    int discount = 0,
    int deposit = 0,
    String? depositBrand,
    String status = 'pending',
  }) {
    final goods = qty * 100000 - discount;
    final grand = goods + deposit;
    final paidNow = paid ?? grand;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(withCustomer ? customerId : null),
        totalAmountKobo: grand,
        discountKobo: Value(discount),
        netAmountKobo: grand,
        amountPaidKobo: Value(paidNow),
        paymentType: paidNow == 0 ? 'credit' : 'cash',
        status: status,
        staffId: Value(staffId),
        storeId: Value(storeId),
        crateDepositPaidKobo: Value(deposit),
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
          totalKobo: qty * 100000,
        ),
      ],
      customerId: withCustomer ? customerId : null,
      amountPaidKobo: paidNow,
      totalAmountKobo: grand,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
      crateDepositPaidByManufacturer:
          deposit > 0 ? {depositBrand!: deposit} : const {},
    );
  }

  Future<String> lineId(String orderId) async => (await (db.select(db.orderItems)
            ..where((i) => i.orderId.equals(orderId)))
          .getSingle())
      .id;

  Future<double> lineQty(String orderId) async => (await (db.select(db.orderItems)
            ..where((i) => i.orderId.equals(orderId)))
          .getSingle())
      .quantity;

  Future<PartReturnOutcome> part(
    String orderId,
    double qty, {
    RefundDestination dest = RefundDestination.cashOrTransfer,
    String? method,
    Map<String, double> damaged = const {},
  }) async => db.ordersDao.returnPartOfSale(
        orderId: orderId,
        qtyByLineId: {await lineId(orderId): qty},
        reason: 'brought some back',
        staffId: staffId,
        deviceTag: 'TESTAB',
        destination: dest,
        refundMethod: method,
        damagedQtyByLine: damaged,
      );

  Future<List<PaymentTransactionData>> pays(String id, [String? type]) =>
      (db.select(db.paymentTransactions)
            ..where((p) => type == null
                ? p.orderId.equals(id)
                : p.orderId.equals(id) & p.type.equals(type)))
          .get();

  Future<List<WalletTransactionData>> wallet(String id) =>
      (db.select(db.walletTransactions)..where((w) => w.orderId.equals(id)))
          .get();

  Future<double> inv(String product) async => (await (db.select(db.inventory)
            ..where((t) => t.productId.equals(product)))
          .getSingle())
      .quantity;

  Future<double> debt(String mfr) async {
    final rows = await db.cratePoolDao.watchCustomerCrateDebt(customerId).first;
    return rows
        .where((r) => r.manufacturerId == mfr)
        .fold<double>(0, (s, r) => s + r.balance);
  }

  Future<int> balance() => db.walletTransactionsDao.getBalanceKobo(customerId);
  Future<int> held() => db.walletTransactionsDao.getDepositsHeldKobo(customerId);

  Future<void> expectRefusal(Future<Object?> f, ReturnRefusal r) async {
    try {
      await f;
      fail('expected $r');
    } on ReturnRefusedException catch (e) {
      expect(e.refusal, r);
    }
  }

  group('10 of 40 crates returned', () {
    test('stock, money, crates, deposit and the 30 left', () async {
      final (m, p) = await crateBrand('Star');
      // 40 crates at 1,000 each, 500 deposit per crate, all paid in cash.
      final id = await sell(p, 40, deposit: 2000000, depositBrand: m);
      await db.ordersDao.markCompleted(id, staffId);
      expect((await db.ordersDao.findById(id))!.status, 'completed');
      expect(await inv(p), 60);
      final spendableBefore = await balance();
      expect(await held(), 2000000);

      final out = await part(id, 10);

      // The adjustment record.
      final adj = (await db.ordersDao.adjustmentsOf(id)).single;
      expect(adj.id, out.adjustmentOrderId);
      expect(adj.kind, 'adjustment');
      expect(adj.adjustsOrderId, id);
      expect(adj.status, 'completed');
      expect(adj.customerId, customerId);
      expect(adj.storeId, storeId);
      expect(adj.totalAmountKobo, -1000000);
      expect(adj.netAmountKobo, -1000000);
      expect(adj.amountPaidKobo, -1000000);
      expect(adj.orderNumber, startsWith('ORD-'));
      final minus = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(adj.id)))
              .getSingle());
      expect(minus.quantity, -10);
      expect(minus.unitPriceKobo, 100000);
      expect(minus.buyingPriceKobo, 60000);
      expect(minus.totalKobo, -1000000);
      expect(adjustsLineIdOf(minus), await lineId(id));

      // The sale is untouched.
      final parent = (await db.ordersDao.findById(id))!;
      expect(parent.status, 'completed');
      expect(parent.kind, 'sale');
      expect(await lineQty(id), 40);

      // Stock: 10 back, a `return` row on the ADJUSTMENT.
      expect(await inv(p), 70);
      final stock = await (db.select(db.stockTransactions)
            ..where((s) => s.movementType.equals('return')))
          .getSingle();
      expect(stock.orderId, adj.id);
      expect(stock.quantityDelta, 10);
      // Cost layer restored at the line's cost.
      final layers = await db.select(db.costBatches).get();
      expect(
        layers.where((c) => c.costKobo == 60000 && c.qtyOriginal == 10),
        isNotEmpty,
      );

      // Money: cash back for the 10 crates and their deposit, on the adjustment.
      final refund = (await pays(adj.id, 'refund')).single;
      expect(refund.amountKobo, 1000000);
      final depPay = (await pays(adj.id, 'crate_deposit')).single;
      expect(depPay.amountKobo, -500000);
      expect(await pays(id, 'refund'), isEmpty);
      final legs = await wallet(adj.id);
      expect(legs.map((l) => '${l.referenceType}:${l.signedAmountKobo}').toList()
            ..sort(),
          [
            'crate_deposit_refunded:-500000',
            'refund:1000000',
            'void:-1000000',
          ]);
      expect(await balance(), spendableBefore);
      expect(await held(), 1500000);

      // Crates: the 10 cancel what the customer owed (all 40 owed? no: the
      // deposit brand issues no customer debt), so nothing is owed and the
      // empties pool is untouched.
      expect(await debt(m), 0);

      // 30 left to return.
      final left = await db.ordersDao.returnableQtyByLine(id);
      expect(left.values.single, 30);
    });

    test('crate-track customer: returned crates cancel what is owed first',
        () async {
      final (m, p) = await crateBrand('Star');
      final id = await sell(p, 40);
      await svc.markAsCompleted(id, staffId,
          customerId: customerId,
          storeId: storeId,
          crateReturns: [
            CrateReturnLine(
                manufacturerId: m,
                takenCrates: 40,
                returnedCrates: 15,
                rateKobo: 50000,
                paidKobo: 0),
          ]);
      expect(await debt(m), 25);
      expect(await db.cratePoolDao.expectedEmptiesAt(
              manufacturerId: m, storeId: storeId),
          15);

      final out = await part(id, 10);
      expect(await debt(m), 15, reason: '10 of the 25 still owed are cancelled');
      expect(await db.cratePoolDao.expectedEmptiesAt(
              manufacturerId: m, storeId: storeId),
          15, reason: 'nothing handed back yet');
      final rows = await (db.select(db.crateLedger)
            ..where((l) => l.referenceOrderId.equals(out.adjustmentOrderId)))
          .get();
      expect(rows.single.quantityDelta, -10);
      expect(rows.single.reason, 'order_part_returned');

      // A second return of 20: the 15 still owed are cancelled, 5 empties go
      // back to the customer.
      final out2 = await part(id, 20);
      expect(await debt(m), 0);
      expect(await db.cratePoolDao.expectedEmptiesAt(
              manufacturerId: m, storeId: storeId),
          10);
      final rows2 = await (db.select(db.crateLedger)
            ..where((l) => l.referenceOrderId.equals(out2.adjustmentOrderId)))
          .get();
      expect(rows2.map((r) => '${r.reason}:${r.quantityDelta}').toList()..sort(),
          ['order_part_returned:-15.0', 'order_returned_empties:-5.0']);
    });

    test('a second part return cannot exceed what remains', () async {
      final (_, p) = await crateBrand('Star');
      final id = await sell(p, 40);
      await svc.markAsCompleted(id, staffId,
          customerId: customerId, storeId: storeId, crateReturns: const []);
      await part(id, 10);
      await expectRefusal(part(id, 31), ReturnRefusal.overReturn);
      await expectRefusal(part(id, 0), ReturnRefusal.nothingToReturn);
      await part(id, 30);
      expect((await db.ordersDao.returnableQtyByLine(id)).values.single, 0);
      await expectRefusal(part(id, 1), ReturnRefusal.overReturn);
      expect((await db.ordersDao.adjustmentsOf(id)).length, 2);
    });
  });

  group('money by kind of sale', () {
    test('walk-in cash: cash out, no wallet', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, withCustomer: false, status: 'completed');
      final out = await part(id, 1, method: 'transfer');
      final refund = (await pays(out.adjustmentOrderId, 'refund')).single;
      expect(refund.amountKobo, 100000);
      expect(refund.method, 'transfer');
      expect(await wallet(out.adjustmentOrderId), isEmpty);
      expect(await inv(p), 97);
      await expectRefusal(
        part(id, 1, dest: RefundDestination.balance),
        ReturnRefusal.noCustomerBalance,
      );
    });

    test('named customer to balance: no cash out, credit stays', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, status: 'completed');
      final before = await balance();
      final out = await part(id, 1, dest: RefundDestination.balance);
      expect(await pays(out.adjustmentOrderId), isEmpty);
      expect(await balance(), before + 100000);
      expect((await db.ordersDao.adjustmentsOf(id)).single.amountPaidKobo,
          -100000);
    });

    test('credit (unpaid) sale: only the debt shrinks', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, paid: 0, status: 'completed');
      expect(await balance(), -400000);
      final out = await part(id, 1);
      expect(await pays(out.adjustmentOrderId), isEmpty);
      expect(await balance(), -300000);
      expect(out.refundKobo, 0);
    });

    test('part paid: refund is proportional to what was paid', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, paid: 200000, status: 'completed');
      expect(await balance(), -200000);
      final out = await part(id, 2); // goods 200000, half paid
      expect((await pays(out.adjustmentOrderId, 'refund')).single.amountKobo,
          100000);
      expect(await balance(), -100000,
          reason: 'debt 200000 -> 100000: unpaid share cancelled, paid share '
              'handed back as cash');
      // The rest: 2 left, 100000 paid still standing, goods 200000 left.
      final out2 = await part(id, 2);
      expect((await pays(out2.adjustmentOrderId, 'refund')).single.amountKobo,
          100000);
      expect(await balance(), 0);
    });

    test('discount is shared pro rata and exactly', () async {
      final p = await plainProduct();
      final id = await sell(p, 3, discount: 10000, status: 'completed');
      final a = await part(id, 1);
      final b = await part(id, 2);
      final adjs = await db.ordersDao.adjustmentsOf(id);
      final byId = {for (final x in adjs) x.id: x};
      expect(byId[a.adjustmentOrderId]!.discountKobo, -3333);
      expect(byId[b.adjustmentOrderId]!.discountKobo, -6667,
          reason: 'the last return takes the rest of the discount');
      expect(
          byId[a.adjustmentOrderId]!.netAmountKobo +
              byId[b.adjustmentOrderId]!.netAmountKobo,
          -290000);
    });
  });

  group('reports and lists', () {
    test('the sale day is unchanged; the return day shows Returns', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, status: 'completed');
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await (db.update(db.orders)..where((o) => o.id.equals(id)))
          .write(OrdersCompanion(createdAt: Value(yesterday)));
      await part(id, 1);

      final all = await db.ordersDao.watchAllOrdersWithItems().first;
      bool sameDay(DateTime a, DateTime b) =>
          a.year == b.year && a.month == b.month && a.day == b.day;
      final saleDay = computeSalesSplitKobo(all,
          inSpan: (d) => sameDay(d, yesterday));
      expect(saleDay.salesKobo, 400000);
      expect(saleDay.returnsKobo, 0);
      final today = computeSalesSplitKobo(all,
          inSpan: (d) => sameDay(d, DateTime.now()));
      expect(today.salesKobo, 0);
      expect(today.returnsKobo, -100000);
      expect(today.netKobo, -100000);
      final entries = saleDayEntries(all)
          .where((e) => e.o.order.kind == 'adjustment')
          .toList();
      expect(entries.single.sign, 1);
      // Whole span: net sales = 300000.
      expect(computeTotalSalesKobo(all), 300000);
    });

    test('adjustments never appear as their own order rows', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, status: 'completed');
      await part(id, 1);
      final page = await db.ordersDao.getOrdersPage(status: 'completed');
      expect(page.map((o) => o.order.id), [id]);
      final stats = await db.ordersDao
          .watchOrdersStats(status: 'completed')
          .first;
      expect(stats.count, 1);
      expect((await db.ordersDao.watchAllOrders().first).length, 1);
      expect((await db.ordersDao.watchCompletedOrders().first).length, 1);
      final staff = await db.ordersDao.getSalesTotalsForStaff(staffId);
      expect(staff.orderCount, 1);
      expect(staff.totalKobo, 300000);
    });
  });

  group('sync', () {
    test('the payload carries the new columns and the claim holds the rows',
        () async {
      final p = await plainProduct();
      final id = await sell(p, 4, status: 'completed');
      final out = await part(id, 1);
      final queue = await db.select(db.syncQueue).get();

      final orderRows = queue.where((q) =>
          q.actionType.startsWith('orders:') &&
          decodePayload(q)['id'] == out.adjustmentOrderId);
      final payload = decodePayload(orderRows.single);
      expect(payload['kind'], 'adjustment');
      expect(payload['adjusts_order_id'], id);

      final claim = queue.singleWhere(
          (q) => q.actionType == 'domain:pos_claim_sale_adjustment');
      final c = jsonDecode(claim.payload) as Map<String, dynamic>;
      expect(c['p_parent_order_id'], id);
      expect(c['p_adjustment_order_id'], out.adjustmentOrderId);
      expect((c['p_lines'] as List).single['quantity'], 1);
      expect(claim.heldByOrderId, isNull);
      final held = queue.where((q) => q.heldByOrderId == c['p_reversal_id']);
      expect(held, isNotEmpty);
      expect(held.map((q) => q.actionType.split(':').first).toSet(),
          containsAll(['orders', 'order_items', 'stock_transactions']));
    });

    test('a refused adjustment is withdrawn and the parent is untouched',
        () async {
      final p = await plainProduct();
      final id = await sell(p, 4, status: 'completed');
      final out = await part(id, 1);
      final queue = await db.select(db.syncQueue).get();
      final claim = queue.singleWhere(
          (q) => q.actionType == 'domain:pos_claim_sale_adjustment');
      final rid = (jsonDecode(claim.payload) as Map)['p_reversal_id'] as String;
      expect(await inv(p), 97);

      final undone = await db.ordersDao.undoRejectedReversal(
        reversalId: rid,
        orderId: id,
        adjustmentOrderId: out.adjustmentOrderId,
      );
      expect(undone, isTrue);
      expect(await db.ordersDao.adjustmentsOf(id), isEmpty);
      expect(await inv(p), 96, reason: 'the 1 unit is taken back off the shelf');
      expect(await pays(out.adjustmentOrderId), isEmpty);
      expect((await db.ordersDao.findById(id))!.status, 'completed');
      expect((await db.ordersDao.returnableQtyByLine(id)).values.single, 4);
    });
  });

  group('damaged units', () {
    test('are written off, not restocked', () async {
      final p = await plainProduct();
      final id = await sell(p, 4, status: 'completed');
      await part(id, 2, damaged: {await lineId(id): 1});
      expect(await inv(p), 96 + 2 - 1);
    });
  });
}
