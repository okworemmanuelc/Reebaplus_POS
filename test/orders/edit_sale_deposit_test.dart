// #732 (PR C, ADR 0035 addendum) — crates added by an edit take a crate deposit
// exactly as at checkout: held money, never revenue, netted against what the
// edit frees, and released when those crates come back.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

import '../helpers/dispatch_test_utils.dart';

const _rate = 50000;
const _price = 100000;

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
    customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
  });

  tearDown(() => db.close());

  Future<String> product(String? brand) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        name: brand == null ? 'Rice' : 'Star Bottle',
        retailerPriceKobo: const Value(_price),
        manufacturerId: Value(brand),
        unit: Value(brand == null ? 'Piece' : 'Bottle'),
        trackEmpties: Value(brand != null)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: id,
        storeId: storeId,
        quantity: const Value(100)));
    await db.costBatchesDao.recordInflowBatch(
        productId: id, storeId: storeId, quantity: 100, costKobo: 60000);
    return id;
  }

  Future<String> brand({int rate = _rate}) async {
    final id = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(id),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: Value(rate)));
    return id;
  }

  /// A completed, fully paid sale of [qty] units of [productId].
  Future<String> sale(
    String productId,
    int qty, {
    bool walkIn = false,
    int? paid,
    Map<String, double> exchanged = const {},
  }) async {
    final total = qty * _price;
    final paidNow = paid ?? total;
    final who = walkIn ? null : customerId;
    final id = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(who),
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
          productId: Value(productId),
          storeId: storeId,
          quantity: qty.toDouble(),
          unitPriceKobo: _price,
          buyingPriceKobo: const Value(60000),
          totalKobo: total,
        ),
      ],
      customerId: who,
      amountPaidKobo: paidNow,
      totalAmountKobo: total,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
      cratesReturnedByManufacturer: exchanged,
    );
    await db.ordersDao.markCompleted(id, staffId);
    return id;
  }

  Future<String> lineOf(String orderId, String productId) async =>
      (await (db.select(db.orderItems)
                ..where((i) =>
                    i.orderId.equals(orderId) & i.productId.equals(productId)))
              .getSingle())
          .id;

  Future<EditSaleOutcome> edit(
    String orderId, {
    required String added,
    double crates = 2,
    Map<String, int> deposit = const {},
    Map<String, double> newQty = const {},
    int? paid,
    RefundDestination dest = RefundDestination.cashOrTransfer,
    String? method,
  }) => db.ordersDao.editCompletedSale(
    orderId: orderId,
    newQtyByLineId: newQty,
    addedLines: [EditAddedLine(productId: added, quantity: crates)],
    reason: 'customer took more',
    staffId: staffId,
    deviceTag: 'TESTAB',
    amountPaidKobo: paid,
    depositPaidByManufacturer: deposit,
    refundDestination: dest,
    refundMethod: method,
  );

  Future<List<PaymentTransactionData>> pays(String id, String type) =>
      (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(id) & p.type.equals(type)))
          .get();

  Future<List<WalletTransactionData>> walletRows(String id, String ref) =>
      (db.select(db.walletTransactions)
            ..where((w) => w.orderId.equals(id) & w.referenceType.equals(ref)))
          .get();

  Future<List<OrderCrateLineData>> crateLines(String id) =>
      db.orderCrateLinesDao.getForOrder(id);

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

  group('Taking the deposit', () {
    test('the full deposit is held on top of the goods, never with them',
        () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 2);
      final before = await balance();

      final plan = await db.ordersDao.planEditSale(id, const {}, [
        EditAddedLine(productId: star, quantity: 2),
      ]);
      expect(plan.crateBrands.single.line.fullDepositKobo, 100000);
      expect(plan.crateBrands.single.name, 'Star');
      expect(plan.settlement(100000).dueKobo, 300000);

      final out = await edit(id, added: star, deposit: {m: 100000});
      expect(out.depositKobo, 100000);
      expect(out.collectedKobo, 300000);
      expect(out.chargedKobo, 0);

      final adj = out.adjustmentOrderId;
      final line = (await crateLines(adj)).single;
      expect(line.cratesTaken, 2);
      expect(line.depositRateKobo, _rate);
      expect(line.depositPaidKobo, 100000);
      expect((await pays(adj, 'sale')).single.amountKobo, 200000);
      expect((await pays(adj, 'crate_deposit')).single.amountKobo, 100000);
      expect((await walletRows(adj, 'crate_deposit')).single.amountKobo, 100000);
      expect((await walletRows(adj, 'order_payment')).single.amountKobo, 200000,
          reason: 'the goods debit does not carry the deposit');
      expect(await balance(), before, reason: 'held, not spendable');
      expect(await debt(m), 0, reason: 'money-track: no crates owed');

      final header = await db.ordersDao.findById(adj);
      expect(header!.totalAmountKobo, 200000);
      expect(header.crateDepositPaidKobo, 0);
    });

    test('a part deposit is kept per brand and nothing is owed', () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 2);
      final out = await edit(id, added: star, deposit: {m: 30000});
      expect((await crateLines(out.adjustmentOrderId)).single.depositPaidKobo,
          30000);
      expect(await debt(m), 0);
    });

    test('zero means crate-track: crates owed and no money rows', () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 2);
      final out = await edit(id, added: star, deposit: {m: 0});
      final adj = out.adjustmentOrderId;
      expect((await crateLines(adj)).single.depositPaidKobo, 0);
      expect(await debt(m), 2);
      expect(await pays(adj, 'crate_deposit'), isEmpty);
      expect(await walletRows(adj, 'crate_deposit'), isEmpty);
    });

    test('a walk-in takes none and an over-full deposit is refused', () async {
      final m = await brand();
      final star = await product(m);
      final walkIn = await sale(await product(null), 1, walkIn: true);
      await expectRefusal(
        edit(walkIn, added: star, deposit: {m: 100000}),
        ReturnRefusal.badDeposit,
      );
      final named = await sale(await product(null), 1);
      await expectRefusal(
        edit(named, added: star, deposit: {m: 100001}),
        ReturnRefusal.badDeposit,
      );
      await expectRefusal(
        edit(named, added: await product(null), deposit: {m: 1000}),
        ReturnRefusal.badDeposit,
      );

      final out = await edit(walkIn, added: star);
      expect(await pays(out.adjustmentOrderId, 'crate_deposit'), isEmpty);
    });

    test('the deposit must be covered by money; goods may go on the balance',
        () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 2);
      await expectRefusal(
        edit(id, added: star, deposit: {m: 100000}, paid: 99999),
        ReturnRefusal.depositNotCovered,
      );
      final out = await edit(id, added: star, deposit: {m: 100000}, paid: 150000);
      expect(out.collectedKobo, 150000);
      expect(out.chargedKobo, 150000, reason: '200,000 goods, 50,000 of it paid');
      final adj = out.adjustmentOrderId;
      expect((await pays(adj, 'sale')).single.amountKobo, 50000);
      expect((await pays(adj, 'crate_deposit')).single.amountKobo, 100000);
    });

    test('a business that does not track crates shows no brands', () async {
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(tracksEmptyCrates: Value(false)));
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 2);
      final plan = await db.ordersDao.planEditSale(id, const {}, [
        EditAddedLine(productId: star, quantity: 2),
      ]);
      expect(plan.crateBrands, isEmpty);
    });
  });

  group('A deposit on an edit that also refunds', () {
    test('the refund pays the deposit first; the customer gets the rest',
        () async {
      final m = await brand();
      final star = await product(m);
      final rice = await product(null);
      final id = await sale(rice, 4);
      final out = await edit(
        id,
        added: star,
        crates: 1,
        deposit: {m: _rate},
        newQty: {await lineOf(id, rice): 2},
        method: 'cash',
      );
      final adj = out.adjustmentOrderId;
      expect(out.refundKobo, 50000, reason: '200,000 freed - 100,000 goods - '
          '50,000 deposit');
      expect((await pays(adj, 'refund')).single.amountKobo, 100000);
      expect((await pays(adj, 'crate_deposit')).single.amountKobo, _rate);
      expect(await pays(adj, 'sale'), isEmpty);
    });

    test('a deposit bigger than the refund: the customer pays the difference',
        () async {
      final m = await brand();
      final star = await product(m);
      final rice = await product(null);
      final id = await sale(rice, 4);
      await (db.update(db.products)..where((p) => p.id.equals(star)))
          .write(const ProductsCompanion(retailerPriceKobo: Value(20000)));
      final plan = await db.ordersDao.planEditSale(
        id,
        {await lineOf(id, rice): 2},
        [EditAddedLine(productId: star, quantity: 3)],
      );
      final settle = plan.settlement(150000);
      expect(settle.dueKobo, 10000, reason: '150,000 - (200,000 - 60,000)');
      expect(settle.minPayKobo, 10000);
      await expectRefusal(
        edit(
          id,
          added: star,
          crates: 3,
          deposit: {m: 150000},
          newQty: {await lineOf(id, rice): 2},
          paid: 9999,
        ),
        ReturnRefusal.depositNotCovered,
      );
      final out = await edit(
        id,
        added: star,
        crates: 3,
        deposit: {m: 150000},
        newQty: {await lineOf(id, rice): 2},
        method: 'cash',
      );
      final adj = out.adjustmentOrderId;
      expect(out.refundKobo, 0);
      expect(out.collectedKobo, 10000);
      expect((await pays(adj, 'refund')).single.amountKobo, 140000);
      expect((await pays(adj, 'crate_deposit')).single.amountKobo, 150000);
    });

    test('add to balance: the deposit is set off, only the rest stays credit',
        () async {
      final m = await brand();
      final star = await product(m);
      final rice = await product(null);
      final id = await sale(rice, 4);
      final out = await edit(
        id,
        added: star,
        crates: 1,
        deposit: {m: _rate},
        newQty: {await lineOf(id, rice): 2},
        dest: RefundDestination.balance,
      );
      final adj = out.adjustmentOrderId;
      expect(out.refundKobo, 0);
      expect(await balance(), 50000);
      final refund = (await pays(adj, 'refund')).single;
      final held = (await pays(adj, 'crate_deposit')).single;
      expect(refund.amountKobo, _rate);
      expect(held.amountKobo, _rate);
      expect(refund.method, held.method, reason: 'no money moved');
    });
  });

  group('Returning the added crates', () {
    test('a deposit on added crates comes back through the refund, with no '
        'empties handed back and the sale\'s own settled crates carrying none',
        () async {
      final m = await brand();
      final star = await product(m);
      // 10 crates, all swapped for empties at checkout: settled, no deposit.
      final id = await sale(star, 10, exchanged: {m: 10});
      await edit(id, added: star, deposit: {m: 100000});
      final line = await lineOf(id, star);

      final one = await db.ordersDao.planPartReturn(id, {line: 1});
      expect(one.depositRefundKobo, _rate);
      expect(one.emptiesToHandBack, isEmpty);

      final out = await db.ordersDao.returnPartOfSale(
        orderId: id,
        qtyByLineId: {line: 2},
        reason: 'brought back',
        staffId: staffId,
        deviceTag: 'TESTAB',
      );
      final adj = out.adjustmentOrderId;
      expect((await pays(adj, 'crate_deposit')).single.amountKobo, -100000);
      expect((await walletRows(adj, 'crate_deposit_refunded')).single.amountKobo,
          100000);
      expect(
        await (db.select(db.crateLedger)
              ..where((l) =>
                  l.referenceOrderId.equals(adj) & l.customerId.isNull()))
            .get(),
        isEmpty,
        reason: 'the money was theirs, the empties are not',
      );

      final next = await db.ordersDao.planPartReturn(id, {line: 2});
      expect(next.depositRefundKobo, 0, reason: 'released once');
      expect(next.emptiesToHandBack.single.crates, 2);
    });

    test('a part deposit releases what was paid per crate', () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 1);
      final edited = await edit(id, added: star, deposit: {m: 30000});
      final plus = await lineOf(edited.adjustmentOrderId, star);
      final plan = await db.ordersDao.planPartReturn(id, {plus: 1});
      expect(plan.depositRefundKobo, 15000);
    });

    test('a crate cancels its debt first and never releases a deposit too',
        () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(star, 3); // 3 crates owed
      await edit(id, added: star, deposit: {m: 100000});
      final line = await lineOf(id, star);

      final owed = await db.ordersDao.planPartReturn(id, {line: 3});
      expect(owed.depositRefundKobo, 0);
      final beyond = await db.ordersDao.planPartReturn(id, {line: 4});
      expect(beyond.depositRefundKobo, _rate);
    });

    test('to the balance the released deposit stays as credit', () async {
      final m = await brand();
      final star = await product(m);
      final id = await sale(await product(null), 1);
      final edited = await edit(id, added: star, deposit: {m: 100000});
      final plus = await lineOf(edited.adjustmentOrderId, star);
      final out = await db.ordersDao.returnPartOfSale(
        orderId: id,
        qtyByLineId: {plus: 2},
        reason: 'brought back',
        staffId: staffId,
        deviceTag: 'TESTAB',
        destination: RefundDestination.balance,
      );
      final adj = out.adjustmentOrderId;
      expect(await pays(adj, 'crate_deposit'), isEmpty);
      expect((await walletRows(adj, 'crate_refund')).single.amountKobo, 100000);
    });

    test('an edit that takes back crates releases their deposit against what '
        'it adds', () async {
      final m = await brand();
      final star = await product(m);
      final rice = await product(null);
      final id = await sale(rice, 1);
      final first = await edit(id, added: star, deposit: {m: 100000});
      final plus = await lineOf(first.adjustmentOrderId, star);

      // Two crates back (200,000 goods + 100,000 deposit), one rice more.
      final out = await edit(
        id,
        added: rice,
        crates: 1,
        newQty: {plus: 0},
        method: 'cash',
      );
      final adj = out.adjustmentOrderId;
      expect((await pays(adj, 'crate_deposit')).single.amountKobo, -100000);
      expect(out.chargedKobo, 0);
    });
  });

  test('a refused edit withdraws the deposit and its crate line', () async {
    final m = await brand();
    final star = await product(m);
    final id = await sale(await product(null), 2);
    final out = await edit(id, added: star, deposit: {m: 100000});
    final adj = out.adjustmentOrderId;

    final claim = (await (db.select(db.syncQueue)
          ..where((q) => q.actionType.equals(kAdjustmentClaimAction)))
        .getSingle());
    final payload = jsonDecode(claim.payload) as Map<String, dynamic>;
    final undone = await db.ordersDao.undoRejectedReversal(
      reversalId: payload['p_reversal_id'] as String,
      orderId: id,
      adjustmentOrderId: adj,
    );
    expect(undone, isTrue);

    expect(await pays(adj, 'crate_deposit'), isEmpty);
    expect(await pays(adj, 'sale'), isEmpty);
    expect(await walletRows(adj, 'crate_deposit'), isEmpty);
    expect(await crateLines(adj), isEmpty);
    expect(await db.ordersDao.findById(adj), isNull);
    expect(await balance(), 0);
    final queued = await (db.select(db.syncQueue)
          ..where((q) => q.actionType.like('order_crate_lines%')))
        .get();
    expect(
      queued.where((q) => q.payload.contains(adj)),
      isEmpty,
      reason: 'its upload is gone too',
    );
  });

  test('the deposit stays out of sales', () async {
    final m = await brand();
    final star = await product(m);
    final id = await sale(await product(null), 2);
    await edit(id, added: star, deposit: {m: 100000});
    final all = await db.ordersDao.watchAllOrdersWithItems().first;
    final split = computeSalesSplitKobo(all);
    expect(split.salesKobo, 200000 + 200000);
    expect(split.returnsKobo, 0);
  });
}
