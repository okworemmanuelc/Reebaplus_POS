import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// #710 (PRD #707 item 4) — the Refund destination. "Add to customer's
/// balance" writes NO refund cash-out row and leaves the payment credit leg
/// standing; "cash / transfer" is today's behaviour with a chosen method.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId, staffId, productId;
  String? customerId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Beer',
        retailerPriceKobo: const Value(100000)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
  });

  tearDown(() => db.close());

  // [qty] @ ₦1000, [paidKobo] paid now. cid null = walk-in.
  Future<String> sell(int qty, int paidKobo, {String? cid, String method = 'cash'}) {
    final goods = qty * 100000;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(cid),
        totalAmountKobo: goods,
        netAmountKobo: goods,
        amountPaidKobo: Value(paidKobo),
        paymentType: method,
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
          unitPriceKobo: 100000,
          totalKobo: goods,
        ),
      ],
      customerId: cid,
      amountPaidKobo: paidKobo,
      totalAmountKobo: goods,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: method,
    );
  }

  Future<int> balance() async {
    final rows = await (db.select(db.walletTransactions)
          ..where((w) => w.customerId.equals(customerId!)))
        .get();
    return rows.fold<int>(0, (s, r) => s + r.signedAmountKobo);
  }

  Future<List<PaymentTransactionData>> refunds(String orderId) =>
      (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(orderId) & p.type.equals('refund')))
          .get();

  Future<int> saleCash(String orderId) async => (await (db.select(
                  db.paymentTransactions)
                ..where((p) =>
                    p.orderId.equals(orderId) &
                    p.type.equals('sale') &
                    p.voidedAt.isNull()))
              .get())
          .fold<int>(0, (s, r) => s + r.amountKobo);

  test('balance: customer balance up by paid, no refund row, sale row intact',
      () async {
    final id = await sell(2, 200000, cid: customerId);
    expect(await balance(), 0);
    await db.ordersDao.markCancelled(id, 'x', staffId,
        destination: RefundDestination.balance);
    expect(await balance(), 200000);
    expect(await refunds(id), isEmpty);
    expect(await saleCash(id), 200000, reason: 'till figure unchanged');
    // goods debit reversed with a refund credit; payment credit NOT voided.
    final legs = await (db.select(db.walletTransactions)
          ..where((w) => w.orderId.equals(id)))
        .get();
    expect(legs.where((l) => l.referenceType == 'void'), isEmpty);
    expect(legs.where((l) => l.referenceType == 'refund').length, 1);
    final o = await db.ordersDao.findById(id);
    expect(o!.status, 'cancelled');
  });

  test('balance on a part-paid sale: balance up by the paid part only',
      () async {
    final id = await sell(2, 50000, cid: customerId);
    expect(await balance(), -150000);
    await db.ordersDao.markCancelled(id, 'x', staffId,
        destination: RefundDestination.balance);
    expect(await balance(), 50000);
    expect(await refunds(id), isEmpty);
  });

  test('cashOrTransfer default is exactly today: refund row, balance back to 0',
      () async {
    final id = await sell(2, 200000, cid: customerId, method: 'transfer');
    await db.ordersDao.markCancelled(id, 'x', staffId);
    final r = await refunds(id);
    expect(r.length, 1);
    expect(r.single.amountKobo, 200000);
    expect(r.single.method, 'transfer', reason: 'copies the original method');
    expect(await balance(), 0);
  });

  test('cashOrTransfer with a chosen method overrides the original', () async {
    final id = await sell(2, 200000, cid: customerId, method: 'transfer');
    await db.ordersDao.markCancelled(id, 'x', staffId,
        destination: RefundDestination.cashOrTransfer, refundMethod: 'cash');
    final r = await refunds(id);
    expect(r.single.method, 'cash');
    expect(r.single.amountKobo, 200000);
    expect(await balance(), 0);
  });

  test('walk-in cannot go to balance: refused, nothing written', () async {
    final id = await sell(1, 100000);
    await expectLater(
      db.ordersDao.markCancelled(id, 'x', staffId,
          destination: RefundDestination.balance),
      throwsA(isA<ReturnRefusedException>()),
    );
    expect((await db.ordersDao.findById(id))!.status, isNot('cancelled'));
    expect(await refunds(id), isEmpty);
    // walk-in cash still works
    await db.ordersDao.markCancelled(id, 'x', staffId);
    expect((await refunds(id)).length, 1);
  });

  test('pure credit sale: debt cancels, no refund row either way', () async {
    final id = await sell(2, 0, cid: customerId);
    expect(await balance(), -200000);
    await db.ordersDao.markCancelled(id, 'x', staffId,
        destination: RefundDestination.balance);
    expect(await balance(), 0);
    expect(await refunds(id), isEmpty);
  });

  test('Return (completed sale): balance destination via returnCompletedSale',
      () async {
    final id = await sell(2, 200000, cid: customerId);
    await (db.update(db.orders)..where((o) => o.id.equals(id)))
        .write(const OrdersCompanion(status: Value('completed')));
    final out = await db.ordersDao.returnCompletedSale(
      orderId: id,
      reason: 'x',
      staffId: staffId,
      destination: RefundDestination.balance,
    );
    expect(out!.refundKobo, 200000);
    expect(await balance(), 200000);
    expect(await refunds(id), isEmpty);
    expect(await saleCash(id), 200000);
  });

  test('Return (completed sale): cash method', () async {
    final id = await sell(2, 200000, cid: customerId, method: 'transfer');
    await (db.update(db.orders)..where((o) => o.id.equals(id)))
        .write(const OrdersCompanion(status: Value('completed')));
    await db.ordersDao.returnCompletedSale(
      orderId: id,
      reason: 'x',
      staffId: staffId,
      refundMethod: 'cash',
    );
    expect((await refunds(id)).single.method, 'cash');
    expect(await balance(), 0);
  });

  // Net till movement for an order: sale + wallet_topup - refund (unvoided).
  Future<int> tillNet(String orderId) async {
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.orderId.equals(orderId) & p.voidedAt.isNull()))
        .get();
    return rows.fold<int>(0, (s, r) {
      if (r.type == 'refund') return s - r.amountKobo;
      if (r.type == 'sale' || r.type == 'wallet_topup') return s + r.amountKobo;
      return s;
    });
  }

  test('overpaid sale, balance: till unchanged, balance = full tendered',
      () async {
    final id = await sell(2, 300000, cid: customerId); // ₦2,000 goods, ₦3,000 in
    expect(await db.ordersDao.refundablePaidKobo(id), 300000);
    final before = await tillNet(id);
    expect(before, 300000);
    final balBefore = await balance();
    expect(balBefore, 100000, reason: 'overpay already credited');
    await db.ordersDao.markCancelled(id, 'x', staffId,
        destination: RefundDestination.balance);
    expect(await tillNet(id), before, reason: 'no refund, no topup reversal');
    expect(await refunds(id), isEmpty);
    expect(await balance(), 300000, reason: 'pre-sale 0 + everything tendered');
    final topups = await (db.select(db.paymentTransactions)
          ..where((p) =>
              p.orderId.equals(id) & p.type.equals('wallet_topup')))
        .get();
    expect(topups.every((t) => t.amountKobo > 0), isTrue);
  });

  test('overpaid sale, cash: unchanged from before (till nets to 0)', () async {
    final id = await sell(2, 300000, cid: customerId);
    await db.ordersDao.markCancelled(id, 'x', staffId);
    expect(await tillNet(id), 0);
    expect(await balance(), 0);
  });

  test('two-method split (cash + transfer sale rows), both modes', () async {
    for (final toBalance in [true, false]) {
      final id = await sell(2, 200000, cid: customerId);
      // Second tender row, as a split checkout would leave it.
      final first = await (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(id) & p.type.equals('sale')))
          .getSingle();
      await db.paymentTransactionsDao.postReversalPayment(
        original: first,
        reversalType: 'sale',
        performedBy: staffId,
        amountKobo: 50000,
        method: 'transfer',
      );
      if (toBalance) {
        await db.ordersDao.markCancelled(id, 'x', staffId,
            destination: RefundDestination.balance);
        expect(await refunds(id), isEmpty);
      } else {
        await db.ordersDao.markCancelled(id, 'x', staffId,
            destination: RefundDestination.cashOrTransfer,
            refundMethod: 'transfer');
        final r = await refunds(id);
        expect(r.length, 2, reason: 'one refund per tender row');
        expect(r.every((x) => x.method == 'transfer'), isTrue);
        expect(r.fold<int>(0, (a, x) => a + x.amountKobo), 250000);
      }
    }
  });

  test('refundablePaidKobo is 0 for a pure credit sale', () async {
    final id = await sell(2, 0, cid: customerId);
    expect(await db.ordersDao.refundablePaidKobo(id), 0);
  });
}
