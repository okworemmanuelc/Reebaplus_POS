// #732 (PR B, ADR 0035 addendum) — goods added to a completed sale by an edit
// come back like the original goods, at the price they were added at.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

const _addedPrice = 120000;
const _addedCost = 70000;

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String customerId;

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
  });

  tearDown(() => db.close());

  /// 10 units in a layer at 60,000, the rest at [_addedCost]: a sale of 10 drains
  /// the first layer, so anything an edit adds costs [_addedCost].
  Future<String> product({String name = 'Rice', String? brand}) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        name: name,
        retailerPriceKobo: const Value(100000),
        manufacturerId: Value(brand),
        unit: Value(brand == null ? 'Piece' : 'Bottle'),
        trackEmpties: Value(brand != null)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: id,
        storeId: storeId,
        quantity: const Value(110)));
    await db.costBatchesDao.recordInflowBatch(
        productId: id,
        storeId: storeId,
        quantity: 10,
        costKobo: 60000,
        receivedAt: DateTime(2026, 1, 1));
    await db.costBatchesDao.recordInflowBatch(
        productId: id,
        storeId: storeId,
        quantity: 100,
        costKobo: _addedCost,
        receivedAt: DateTime(2026, 2, 1));
    return id;
  }

  Future<String> brand() async {
    final id = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(id),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    return id;
  }

  Future<String> sale(
    String productId, {
    int qty = 10,
    int? paid,
    int discount = 0,
    int deposit = 0,
    String? depositBrand,
    bool walkIn = false,
  }) async {
    final goods = qty * 100000 - discount;
    final grand = goods + deposit;
    final paidNow = paid ?? grand;
    final id = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(walkIn ? null : customerId),
        totalAmountKobo: grand,
        discountKobo: Value(discount),
        netAmountKobo: grand,
        amountPaidKobo: Value(paidNow),
        paymentType: paidNow == 0 ? 'credit' : 'cash',
        status: 'pending',
        staffId: Value(staffId),
        storeId: Value(storeId),
        crateDepositPaidKobo: Value(deposit),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(productId),
          storeId: storeId,
          quantity: qty.toDouble(),
          unitPriceKobo: 100000,
          buyingPriceKobo: const Value(60000),
          totalKobo: qty * 100000,
        ),
      ],
      customerId: walkIn ? null : customerId,
      amountPaidKobo: paidNow,
      totalAmountKobo: grand,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
      crateDepositPaidByManufacturer:
          deposit > 0 ? {depositBrand!: deposit} : const {},
    );
    await db.ordersDao.markCompleted(id, staffId);
    return id;
  }

  Future<void> setPrice(String productId, int kobo) =>
      (db.update(db.products)..where((p) => p.id.equals(productId)))
          .write(ProductsCompanion(retailerPriceKobo: Value(kobo)));

  /// Adds [qty] of [productId] today at [price], all paid unless [paid] says.
  Future<EditSaleOutcome> add(
    String orderId,
    String productId,
    double qty, {
    int price = _addedPrice,
    int? paid,
  }) async {
    await setPrice(productId, price);
    return db.ordersDao.editCompletedSale(
      orderId: orderId,
      newQtyByLineId: const {},
      addedLines: [EditAddedLine(productId: productId, quantity: qty)],
      reason: 'customer took more',
      staffId: staffId,
      deviceTag: 'TESTAB',
      amountPaidKobo: paid,
    );
  }

  Future<OrderItemData> originalLine(String orderId) async =>
      (await (db.select(db.orderItems)..where((i) => i.orderId.equals(orderId)))
              .get())
          .single;

  Future<PartReturnOutcome> giveBack(
    String orderId,
    String lineId,
    double qty, {
    RefundDestination dest = RefundDestination.cashOrTransfer,
    Map<String, double> damaged = const {},
  }) =>
      db.ordersDao.returnPartOfSale(
        orderId: orderId,
        qtyByLineId: {lineId: qty},
        reason: 'brought back',
        staffId: staffId,
        deviceTag: 'TESTAB',
        destination: dest,
        refundMethod: 'cash',
        damagedQtyByLine: damaged,
      );

  Future<List<OrderItemData>> minusLinesOf(String adjustmentId) async =>
      (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(adjustmentId)))
              .get())
          .where((l) => l.quantity < 0)
          .toList();

  Future<double> inv(String productId) async => (await (db.select(db.inventory)
            ..where((t) => t.productId.equals(productId)))
          .getSingle())
      .quantity;

  Future<List<PaymentTransactionData>> refunds(String orderId) =>
      (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(orderId) & p.type.equals('refund')))
          .get();

  Future<int> balance() => db.walletTransactionsDao.getBalanceKobo(customerId);

  Future<double> debt(String mfr) async {
    final rows = await db.cratePoolDao.watchCustomerCrateDebt(customerId).first;
    return rows
        .where((r) => r.manufacturerId == mfr)
        .fold<double>(0, (s, r) => s + r.balance);
  }

  Future<void> expectRefusal(Future<Object?> f, ReturnRefusal r) async {
    try {
      await f;
      fail('expected $r');
    } on ReturnRefusedException catch (e) {
      expect(e.refusal, r);
    }
  }

  group('what can come back', () {
    test('one row per product: original + added - returned', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final goods = await db.ordersDao.returnableGoods(id);
      expect(goods.length, 1);
      expect(goods.single.standing, 12);
      expect(goods.single.hasAdded, isTrue);
      expect(goods.single.lineId, (await originalLine(id)).id);
      expect(saleHasAdjustments(goods), isTrue);
    });

    test('over-return is refused, on the combined quantity', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final line = (await originalLine(id)).id;
      await expectRefusal(
        db.ordersDao.planPartReturn(id, {line: 13}),
        ReturnRefusal.overReturn,
      );
      await giveBack(id, line, 12);
      await expectRefusal(
        db.ordersDao.planPartReturn(id, {line: 1}),
        ReturnRefusal.overReturn,
      );
    });
  });

  group('price and cost', () {
    test('a product only the edit added comes back alone at its own price and '
        'cost', () async {
      final rice = await product();
      final beans = await product(name: 'Beans');
      final id = await sale(rice);
      final edit = await add(id, beans, 2);
      final plus = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(edit.adjustmentOrderId)))
              .get())
          .single;
      expect(plus.buyingPriceKobo, 60000, reason: "beans' first layer");

      final out = await giveBack(id, plus.id, 1);
      expect(out.goodsKobo, _addedPrice);
      final minus = (await minusLinesOf(out.adjustmentOrderId)).single;
      expect(minus.quantity, -1);
      expect(minus.unitPriceKobo, _addedPrice);
      expect(minus.buyingPriceKobo, plus.buyingPriceKobo);
      expect(adjustsLineIdOf(minus), plus.id);
      expect(await inv(beans), 110 - 2 + 1);
      expect((await refunds(out.adjustmentOrderId)).single.amountKobo, _addedPrice);
    });

    test('a return spanning both prices: refund and profit are right', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final out = await giveBack(id, (await originalLine(id)).id, 11);

      expect(out.goodsKobo, 10 * 100000 + _addedPrice);
      final minus = await minusLinesOf(out.adjustmentOrderId);
      final byPrice = {for (final l in minus) l.unitPriceKobo: l};
      expect(byPrice[100000]!.quantity, -10);
      expect(byPrice[100000]!.buyingPriceKobo, 60000);
      expect(byPrice[_addedPrice]!.quantity, -1);
      expect(byPrice[_addedPrice]!.buyingPriceKobo, _addedCost);

      final profit = minus.fold<double>(
        0,
        (s, l) => s + l.quantity * (l.unitPriceKobo - l.buyingPriceKobo),
      );
      expect(profit, -(10 * 40000 + (_addedPrice - _addedCost)));
      expect(
        (await refunds(out.adjustmentOrderId)).single.amountKobo,
        10 * 100000 + _addedPrice,
      );
      expect(await balance(), 0);
    });

    test('the claim names the lines consumed, in the existing format', () async {
      final p = await product();
      final id = await sale(p);
      final edit = await add(id, p, 2);
      final orig = (await originalLine(id)).id;
      final plus = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(edit.adjustmentOrderId)))
              .get())
          .single
          .id;
      final out = await giveBack(id, orig, 11);
      final claim = (await db.select(db.syncQueue).get())
          .where((q) => q.actionType == 'domain:pos_claim_sale_adjustment')
          .map((q) => jsonDecode(q.payload) as Map<String, dynamic>)
          .singleWhere(
            (m) => m['p_adjustment_order_id'] == out.adjustmentOrderId,
          );
      expect(claim['p_lines'], unorderedEquals([
        {'order_item_id': orig, 'quantity': 10.0},
        {'order_item_id': plus, 'quantity': 1.0},
      ]));
    });

    test('after several edits added goods go oldest edit first', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      await add(id, p, 3, price: 130000);
      final line = (await originalLine(id)).id;

      final first = await giveBack(id, line, 11);
      expect(first.goodsKobo, 10 * 100000 + _addedPrice);
      final second = await giveBack(id, line, 2);
      expect(second.goodsKobo, _addedPrice + 130000);
      expect((await db.ordersDao.returnableGoods(id)).single.standing, 2);
      final third = await giveBack(id, line, 2);
      expect(third.goodsKobo, 2 * 130000);
      expect((await db.ordersDao.returnableGoods(id)).single.standing, 0);
    });

    test('a damaged unit is written off at the cost of the line consumed',
        () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final line = (await originalLine(id)).id;
      await giveBack(id, line, 10);
      await giveBack(id, line, 2, damaged: {line: 1});
      final layers = await (db.select(db.costBatches)
            ..where((b) => b.productId.equals(p)))
          .get();
      final restored = layers.where(
        (b) => b.costKobo == _addedCost && b.qtyOriginal == 1,
      );
      expect(restored, isNotEmpty, reason: '2 back, 1 written off');
    });

    test('the discount stays on the original goods', () async {
      final rice = await product();
      final beans = await product(name: 'Beans');
      final id = await sale(rice, discount: 100000);
      final edit = await add(id, beans, 2);
      final plus = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(edit.adjustmentOrderId)))
              .get())
          .single
          .id;

      final addedOnly = await db.ordersDao.planPartReturn(id, {plus: 1});
      expect(addedOnly.discountShareKobo, 0);
      expect(addedOnly.goodsKobo, _addedPrice);

      final originals = await db.ordersDao.planPartReturn(id, {
        (await originalLine(id)).id: 5,
      });
      expect(originals.discountShareKobo, 50000);

      final allOriginals = await db.ordersDao.planPartReturn(id, {
        (await originalLine(id)).id: 10,
      });
      expect(allOriginals.discountShareKobo, 100000);
    });
  });

  group('money', () {
    test('a credit sale whose added goods were paid: the cash goes back from '
        'the edit', () async {
      final p = await product();
      final id = await sale(p, paid: 0);
      await add(id, p, 2);
      final out = await giveBack(id, (await originalLine(id)).id, 12);
      expect(
        (await refunds(out.adjustmentOrderId)).single.amountKobo,
        2 * _addedPrice,
      );
      expect(await balance(), 0);
    });

    test('a mixed edit: everything that was paid comes back exactly once',
        () async {
      final rice = await product();
      final beans = await product(name: 'Beans');
      final id = await sale(rice, qty: 10);
      await setPrice(beans, 150000);
      final line = (await originalLine(id)).id;
      final edit = await db.ordersDao.editCompletedSale(
        orderId: id,
        newQtyByLineId: {line: 8},
        addedLines: [EditAddedLine(productId: beans, quantity: 1)],
        reason: 'swap',
        staffId: staffId,
        deviceTag: 'TESTAB',
        refundMethod: 'cash',
      );
      expect(edit.refundKobo, 50000, reason: '200,000 freed, 150,000 reused');

      final goods = await db.ordersDao.returnableGoods(id);
      final out = await db.ordersDao.returnPartOfSale(
        orderId: id,
        qtyByLineId: {for (final g in goods) g.lineId: g.standing},
        reason: 'all back',
        staffId: staffId,
        deviceTag: 'TESTAB',
        refundMethod: 'cash',
      );
      expect(out.refundKobo, 8 * 100000 + 150000);
      expect(await balance(), 0);
    });
  });

  group('a whole return of an edited sale', () {
    test('is a final adjustment: nothing stays standing, the sale stays '
        'completed', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final out = await giveBack(id, (await originalLine(id)).id, 12);
      expect(out.refundKobo, 10 * 100000 + 2 * _addedPrice);
      expect(await inv(p), 110);
      expect(await balance(), 0);
      expect((await db.ordersDao.findById(id))!.status, 'completed');
      expect((await db.ordersDao.returnableGoods(id)).single.standing, 0);
    });

    test('the full Return is refused, nothing written', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final before = (await db.select(db.syncQueue).get()).length;
      await expectRefusal(
        db.ordersDao.returnCompletedSale(
          orderId: id,
          reason: 'all back',
          staffId: staffId,
        ),
        ReturnRefusal.hasAdjustments,
      );
      expect((await db.ordersDao.findById(id))!.status, 'completed');
      expect((await db.select(db.syncQueue).get()).length, before);
    });
  });

  group('the edit sheet', () {
    test('the quantity is everything on the sale; lowering takes originals '
        'first', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final line = (await originalLine(id)).id;
      final plan = await db.ordersDao.planEditSale(id, {line: 11}, const []);
      expect(plan.minus!.qtyByLine, {line: 1});
      expect(plan.returnedKobo, 100000);
      expect(plan.hasPlus, isFalse);
    });

    test('raising past the combined quantity adds the difference', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      final line = (await originalLine(id)).id;
      final plan = await db.ordersDao.planEditSale(id, {line: 13}, const []);
      expect(plan.hasMinus, isFalse);
      expect(plan.plusLines.single.qty, 1);
    });

    test('a product only an edit added can be lowered', () async {
      final rice = await product();
      final beans = await product(name: 'Beans');
      final id = await sale(rice);
      final edit = await add(id, beans, 2);
      final plus = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(edit.adjustmentOrderId)))
              .get())
          .single
          .id;
      final plan = await db.ordersDao.planEditSale(id, {plus: 1}, const []);
      expect(plan.minus!.qtyByLine, {plus: 1});
      expect(plan.returnedKobo, _addedPrice);
    });
  });

  group('30 days run from the original sale', () {
    Future<void> age(String orderId, int days) =>
        (db.update(db.orders)..where((o) => o.id.equals(orderId))).write(
          OrdersCompanion(
            createdAt: Value(DateTime.now().subtract(Duration(days: days))),
          ),
        );

    test('goods added yesterday to a 31-day-old sale cannot come back',
        () async {
      final p = await product();
      final id = await sale(p);
      final edit = await add(id, p, 2);
      await age(id, 31);
      final plus = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(edit.adjustmentOrderId)))
              .get())
          .single
          .id;
      await expectRefusal(
        db.ordersDao.planPartReturn(id, {plus: 1}),
        ReturnRefusal.tooOld,
      );
    });

    test('a 29-day-old sale still can', () async {
      final p = await product();
      final id = await sale(p);
      await add(id, p, 2);
      await age(id, 29);
      await giveBack(id, (await originalLine(id)).id, 11);
    });
  });

  group('van sales', () {
    Future<String> vanSale(String productId) async {
      final id = await sale(productId);
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await (db.update(db.orders)..where((o) => o.id.equals(id))).write(
        OrdersCompanion(vanTripId: Value(UuidV7.generate())),
      );
      return id;
    }

    test('still cannot gain goods, so nothing added can come back', () async {
      final p = await product();
      final id = await vanSale(p);
      final line = (await originalLine(id)).id;
      await expectRefusal(
        db.ordersDao.planEditSale(id, {line: 11}, const []),
        ReturnRefusal.notForRoadSale,
      );
      await expectRefusal(
        db.ordersDao.planEditSale(id, const {}, [
          EditAddedLine(productId: p, quantity: 1),
        ]),
        ReturnRefusal.notForRoadSale,
      );
      final goods = await db.ordersDao.returnableGoods(id);
      expect(goods.single.hasAdded, isFalse);
      expect(goods.single.standing, 10);
    });
  });

  group('crates', () {
    test('returning added crates cancels their debt', () async {
      final m = await brand();
      final p = await product(name: 'Star Bottle', brand: m);
      final id = await sale(p);
      await add(id, p, 5);
      expect(await debt(m), 15);
      final out = await giveBack(id, (await originalLine(id)).id, 15);
      expect(await debt(m), 0);
      expect(
        await (db.select(db.crateLedger)
              ..where((l) =>
                  l.referenceOrderId.equals(out.adjustmentOrderId) &
                  l.customerId.isNull()))
            .get(),
        isEmpty,
        reason: 'no empties are handed back: they were never brought in',
      );
    });

    test('one crate never both cancels a debt and releases a deposit, and the '
        'deposit is released once', () async {
      final m = await brand();
      final p = await product(name: 'Star Bottle', brand: m);
      final id = await sale(p, deposit: 500000, depositBrand: m);
      await add(id, p, 5);
      expect(await debt(m), 5, reason: 'only the added crates are owed');
      final line = (await originalLine(id)).id;

      final first = await db.ordersDao.planPartReturn(id, {line: 3});
      expect(first.depositRefundKobo, 0, reason: 'these 3 cancel the debt');
      await giveBack(id, line, 3);
      expect(await debt(m), 2);

      final second = await db.ordersDao.planPartReturn(id, {line: 12});
      expect(second.depositRefundKobo, 500000);
      await giveBack(id, line, 12);
      expect(await debt(m), 0);

      final deposit = await (db.select(db.walletTransactions)
            ..where((t) => t.referenceType.equals('crate_deposit_refunded')))
          .get();
      expect(deposit.fold<int>(0, (s, r) => s + r.amountKobo), 500000);
    });

    test('part return of a deposit sale with no edit is unchanged', () async {
      final m = await brand();
      final p = await product(name: 'Star Bottle', brand: m);
      final id = await sale(p, deposit: 500000, depositBrand: m);
      final plan = await db.ordersDao.planPartReturn(id, {
        (await originalLine(id)).id: 4,
      });
      expect(plan.depositRefundKobo, 200000);
    });
  });
}
