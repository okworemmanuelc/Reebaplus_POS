// #713 (PRD #707 slice 6, ADR 0035) — edit a completed sale: one adjustment
// holding minus lines (a part return) and plus lines (new goods at today's price).

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
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

  Future<void> expectRefusal(Future<Object?> f, ReturnRefusal r) async {
    try {
      await f;
      fail('expected $r');
    } on ReturnRefusedException catch (e) {
      expect(e.refusal, r);
    }
  }


  const granted = GateContext(
    grantedKeys: {'sales.cancel'},
    roleRank: GateTier.manager,
    isReady: true,
  );
  const revoked = GateContext(
    grantedKeys: {'sales.make'},
    roleRank: GateTier.cashier,
    isReady: true,
  );

  Future<EditSaleOutcome> edit(
    String orderId, {
    double? newQty,
    List<EditAddedLine> add = const [],
    RefundDestination dest = RefundDestination.cashOrTransfer,
    String? method = 'cash',
    int? paid,
  }) async => db.ordersDao.editCompletedSale(
        orderId: orderId,
        newQtyByLineId: newQty == null ? {} : {await lineId(orderId): newQty},
        addedLines: add,
        reason: 'customer changed order',
        staffId: staffId,
        deviceTag: 'TESTAB',
        refundDestination: dest,
        refundMethod: method,
        amountPaidKobo: paid,
      );

  Future<String> completed(String product, int qty,
      {bool withCustomer = true, int? paid}) async {
    final id = await sell(product, qty, withCustomer: withCustomer, paid: paid);
    await db.ordersDao.markCompleted(id, staffId);
    return id;
  }

  Future<List<OrderItemData>> itemsOf(String id) =>
      (db.select(db.orderItems)..where((i) => i.orderId.equals(id))).get();

  group('Edit a completed sale', () {
    test('Cashier cannot run Edit; Manager can (Gates.editSale)', () async {
      final p = await plainProduct();
      final id = await completed(p, 2);
      final before = (await db.select(db.orders).get()).length;
      final lid = await lineId(id);
      await expectLater(
        () => svc.editCompletedSale(
          orderId: id,
          newQtyByLineId: {lid: 1},
          reason: 'x',
          staffId: staffId,
          gateContext: revoked,
        ),
        throwsA(isA<GateDeniedError>()),
      );
      expect((await db.select(db.orders).get()).length, before);
      expect(Gates.editSale.evaluate(revoked), isFalse);
      expect(Gates.editSale.evaluate(granted), isTrue);
      await svc.editCompletedSale(
        orderId: id,
        newQtyByLineId: {lid: 1},
        reason: 'x',
        staffId: staffId,
        gateContext: granted,
        refundMethod: 'cash',
      );
      expect((await db.ordersDao.adjustmentsOf(id)).length, 1);
    });

    test('remove-only edit == part return, same rows', () async {
      final p = await plainProduct();
      final a = await completed(p, 4);
      final b = await completed(p, 4);
      await part(a, 1);
      await edit(b, newQty: 3);
      final pa = (await db.ordersDao.adjustmentsOf(a)).single;
      final pb = (await db.ordersDao.adjustmentsOf(b)).single;
      expect(pb.totalAmountKobo, pa.totalAmountKobo);
      expect(pb.amountPaidKobo, pa.amountPaidKobo);
      expect((await itemsOf(pb.id)).single.quantity, -1);
      expect((await pays(pb.id)).map((r) => (r.type, r.amountKobo)).toList(),
          (await pays(pa.id)).map((r) => (r.type, r.amountKobo)).toList());
      expect((await wallet(pb.id)).map((r) => (r.referenceType, r.amountKobo)).toList(),
          (await wallet(pa.id)).map((r) => (r.referenceType, r.amountKobo)).toList());
      expect(await inv(p), 100 - 4 - 4 + 2);
    });

    test('add-only edit == a new sale linked to the parent', () async {
      final p = await plainProduct();
      final id = await completed(p, 2); // 2,000 paid
      final out = await edit(id, add: [EditAddedLine(productId: p, quantity: 3)], paid: 300000);
      final adj = (await db.ordersDao.adjustmentsOf(id)).single;
      expect(adj.adjustsOrderId, id);
      expect(adj.totalAmountKobo, 300000);
      expect(out.chargedKobo, 0);
      final plus = (await itemsOf(adj.id)).single;
      expect(plus.quantity, 3);
      expect(plus.unitPriceKobo, 100000);
      expect(plus.buyingPriceKobo, 60000); // FIFO draw
      expect(await inv(p), 100 - 2 - 3);
      final stock = await (db.select(db.stockTransactions)
            ..where((s) => s.orderId.equals(adj.id)))
          .getSingle();
      expect((stock.movementType, stock.quantityDelta), ('sale', -3));
      final sale = (await pays(adj.id, 'sale')).single;
      expect(sale.amountKobo, 300000);
      // Wallet: debit goods, credit cash; parent untouched.
      final w = await wallet(adj.id);
      expect(w.map((r) => r.signedAmountKobo).fold<int>(0, (a, b) => a + b), 0);
      expect((await db.ordersDao.findById(id))!.status, 'completed');
      expect(await lineQty(id), 2);
      // The claim carries NO lines but is queued, and the rows are held.
      final claim = (await db.select(db.syncQueue).get())
          .where((q) => q.actionType == 'domain:pos_claim_sale_adjustment')
          .single;
      expect(jsonDecode(claim.payload)['p_lines'], isEmpty);
    });

    test('crates: added crates are owed, removed crates are cancelled', () async {
      final (m, p) = await crateBrand('Star');
      final id = await completed(p, 10);
      expect(await debt(m), 10);
      await edit(id, add: [EditAddedLine(productId: p, quantity: 5)], paid: 500000);
      expect(await debt(m), 15, reason: 'the 5 added crates are issued');
      // #732 — the editor's quantity is everything on the sale: 15 down to 12.
      await edit(id, newQty: 12);
      expect(await debt(m), 12, reason: '3 of the original crates came back');
      expect(await inv(p), 100 - 10 - 5 + 3);
    });

    test('add-only: partly paid, the rest is charged to the balance', () async {
      final p = await plainProduct();
      final id = await completed(p, 1);
      final before = await balance();
      final out = await edit(id, add: [EditAddedLine(productId: p, quantity: 2)], paid: 50000);
      expect(out.collectedKobo, 50000);
      expect(out.chargedKobo, 150000);
      expect(await balance(), before - 150000);
    });

    test('walk-in cannot charge to a balance', () async {
      final p = await plainProduct();
      final id = await completed(p, 1, withCustomer: false);
      await expectRefusal(
        edit(id, add: [EditAddedLine(productId: p, quantity: 1)], paid: 10000),
        ReturnRefusal.walkInMustPay,
      );
      // Paying in full is fine.
      await edit(id, add: [EditAddedLine(productId: p, quantity: 1)]);
      expect((await pays((await db.ordersDao.adjustmentsOf(id)).single.id, 'sale')).single.amountKobo, 100000);
    });

    test('mixed edit nets in money, stock', () async {
      final p = await plainProduct();
      final id = await completed(p, 4); // 4,000 paid
      // Lower to 3 (return 1,000) and add 2 (2,000): net +1,000 due.
      final out = await edit(id, newQty: 3, add: [EditAddedLine(productId: p, quantity: 2)]);
      expect(out.addedKobo, 200000);
      expect(out.returnedKobo, 100000);
      expect(out.netKobo, 100000);
      expect(out.refundKobo, 0);
      expect(out.collectedKobo, 100000);
      final adj = (await db.ordersDao.adjustmentsOf(id)).single;
      expect(adj.totalAmountKobo, 100000);
      expect(await inv(p), 100 - 4 + 1 - 2);
      expect(await pays(adj.id, 'refund'), isEmpty);
      // Account: +1,000 back, -2,000 goods, +1,000 cash = 0 change.
      final w = await wallet(adj.id);
      expect(w.fold<int>(0, (a, r) => a + r.signedAmountKobo), 0);
    });

    test('mixed edit, net refund: only what is left over leaves the till', () async {
      final p = await plainProduct();
      final id = await completed(p, 4); // 4,000 paid
      // Return 3 (3,000), add 1 (1,000): 2,000 goes back.
      final out = await edit(id, newQty: 1, add: [EditAddedLine(productId: p, quantity: 1)]);
      expect(out.netKobo, -200000);
      expect(out.refundKobo, 200000);
      final adj = (await db.ordersDao.adjustmentsOf(id)).single;
      expect((await pays(adj.id, 'refund')).single.amountKobo, 200000);
      expect(adj.amountPaidKobo, -300000);
      expect(await balance(), 0 - 0); // customer square after the refund
    });

    test('net refund to the balance keeps the money as credit', () async {
      final p = await plainProduct();
      final id = await completed(p, 2);
      final out = await edit(id, newQty: 1, dest: RefundDestination.balance, method: null);
      expect(out.refundKobo, 0);
      expect(await balance(), 100000);
    });

    test('reports: sale day unchanged, edit day shows sales and returns', () async {
      final p = await plainProduct();
      final id = await completed(p, 4);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await (db.update(db.orders)..where((o) => o.id.equals(id)))
          .write(OrdersCompanion(createdAt: Value(yesterday)));
      await edit(id, newQty: 3, add: [EditAddedLine(productId: p, quantity: 2)]);
      final all = await db.ordersDao.watchAllOrdersWithItems().first;
      bool sameDay(DateTime a, DateTime b) =>
          a.year == b.year && a.month == b.month && a.day == b.day;
      final sale = computeSalesSplitKobo(all, inSpan: (d) => sameDay(d, yesterday));
      expect((sale.salesKobo, sale.returnsKobo), (400000, 0));
      final today = computeSalesSplitKobo(all, inSpan: (d) => sameDay(d, DateTime.now()));
      expect(today.salesKobo, 200000);
      expect(today.returnsKobo, -100000);
    });

    test('nothing changed and over-edits are refused', () async {
      final p = await plainProduct();
      final id = await completed(p, 2);
      await expectRefusal(edit(id), ReturnRefusal.nothingChanged);
      await expectRefusal(edit(id, newQty: 2), ReturnRefusal.nothingChanged);
    });
  });
}
