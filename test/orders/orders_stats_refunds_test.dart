import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// #196 (PRD #155, slice #172) — **the Orders "Refunds Issued" tile reads real
/// refund money.** It used to be `SUM(CASE WHEN orders.status = 'refunded' …)`,
/// a count of a status nothing has written since refunds became
/// `payment_transactions` rows, so the tile on the Cancelled tab showed 0
/// forever — the PRD's own opening complaint, still live on that screen.
///
/// What is pinned here:
///   1. cancelling a paid sale makes the figure the refunded MONEY, not 0;
///   2. the figure comes from the payment ledger, not the order status — a
///      legacy `status = 'refunded'` order with no refund payment adds nothing,
///      and a `cancelled` order with a refund payment adds its amount;
///   3. a voided refund row does not count (the reconciliation's rule);
///   4. several refund rows on ONE order do not duplicate the order —
///      `count` / `totalAmountKobo` / `amountPaidKobo` stay intact (the reason
///      the DAO uses a correlated subquery rather than a join);
///   5. the tab's store scope applies to the refund figure too.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 per-table path: createOrder + markCancelled post every row locally.
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
  });

  tearDown(() => db.close());

  Future<String> seedStore(String name) async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: name));
    return storeId;
  }

  Future<String> seedStaff() async {
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    return staffId;
  }

  Future<String> seedProduct(String storeId) async {
    final productId = UuidV7.generate();
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
    return productId;
  }

  // A fully-paid cash sale of [qty] @ ₦1,000. Returns the order id.
  Future<String> sell({
    required String storeId,
    required String staffId,
    required String customerId,
    required String productId,
    int qty = 2,
  }) async {
    final goodsKobo = qty * 100000;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: goodsKobo,
        netAmountKobo: goodsKobo,
        amountPaidKobo: Value(goodsKobo),
        paymentType: 'cash',
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
          quantity: qty,
          unitPriceKobo: 100000,
          totalKobo: goodsKobo,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: goodsKobo,
      totalAmountKobo: goodsKobo,
      staffId: staffId,
      storeId: storeId,
    );
  }

  Future<OrdersStats> cancelledStats({String? storeId}) =>
      db.ordersDao.watchOrdersStats(status: 'cancelled', storeId: storeId).first;

  test('cancelling a paid sale puts real refund money on the tile', () async {
    final storeId = await seedStore('Main');
    final staffId = await seedStaff();
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final productId = await seedProduct(storeId);
    final orderId = await sell(
        storeId: storeId,
        staffId: staffId,
        customerId: customerId,
        productId: productId);

    // Before the cancel there is nothing on the Cancelled tab at all.
    expect((await cancelledStats()).refundsIssuedKobo, 0);

    await db.ordersDao.markCancelled(orderId, 'customer changed mind', staffId);

    final refund = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('refund')))
        .getSingle();
    expect(refund.amountKobo, 200000, reason: 'the ₦2,000 goods went back');

    final stats = await cancelledStats();
    expect(stats.count, 1);
    expect(stats.refundsIssuedKobo, 200000,
        reason: 'the tile must show the money the payment ledger says left, '
            'not the permanent 0 the retired `refunded` status produced');
  });

  test('the figure is the payment ledger, not the order status', () async {
    final storeId = await seedStore('Main');
    final staffId = await seedStaff();
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final productId = await seedProduct(storeId);

    // A LEGACY order still carrying the retired status, with no refund payment
    // row behind it. It is listed (legacy tolerance) but contributes no money —
    // exactly the asymmetry the old status-based column got backwards.
    await db.into(db.orders).insert(OrdersCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        storeId: Value(storeId),
        orderNumber: 'ORD-LEGACY-REFUNDED',
        totalAmountKobo: 500000,
        netAmountKobo: 500000,
        amountPaidKobo: const Value(500000),
        paymentType: 'cash',
        status: 'refunded',
        lastUpdatedAt: Value(DateTime.now())));

    var stats = await cancelledStats();
    expect(stats.count, 1, reason: 'a legacy `refunded` row stays listed');
    expect(stats.refundsIssuedKobo, 0,
        reason: 'no refund payment row means no refunded money, whatever the '
            'status says');

    // A real cancel of a real paid sale is what moves the figure.
    final orderId = await sell(
        storeId: storeId,
        staffId: staffId,
        customerId: customerId,
        productId: productId,
        qty: 1);
    await db.ordersDao.markCancelled(orderId, 'wrong item', staffId);

    stats = await cancelledStats();
    expect(stats.count, 2);
    expect(stats.refundsIssuedKobo, 100000);
  });

  test('a voided refund row is excluded', () async {
    final storeId = await seedStore('Main');
    final staffId = await seedStaff();
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final productId = await seedProduct(storeId);
    final orderId = await sell(
        storeId: storeId,
        staffId: staffId,
        customerId: customerId,
        productId: productId);
    await db.ordersDao.markCancelled(orderId, 'refund', staffId);
    expect((await cancelledStats()).refundsIssuedKobo, 200000);

    // Legacy in-place void (the pre-#169 shape, still readable): a voided row
    // is not money that left.
    await (db.update(db.paymentTransactions)
          ..where((p) => p.type.equals('refund')))
        .write(PaymentTransactionsCompanion(voidedAt: Value(DateTime.now())));

    expect((await cancelledStats()).refundsIssuedKobo, 0,
        reason: 'same rule as the reconciliation: voided rows never count');
  });

  test('two refund rows on one order do not duplicate the order', () async {
    // The trap a join would fall into: the order row would be emitted twice and
    // `count` / `totalAmountKobo` / `amountPaidKobo` would silently double.
    final storeId = await seedStore('Main');
    final staffId = await seedStaff();
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final productId = await seedProduct(storeId);
    final orderId = await sell(
        storeId: storeId,
        staffId: staffId,
        customerId: customerId,
        productId: productId);
    await db.ordersDao.markCancelled(orderId, 'refund', staffId);

    // A second, partial refund row on the same order (a later top-up reversal).
    await db.into(db.paymentTransactions).insert(
        PaymentTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            storeId: Value(storeId),
            amountKobo: 30000,
            method: 'cash',
            type: 'refund',
            orderId: Value(orderId),
            lastUpdatedAt: Value(DateTime.now())));

    final stats = await cancelledStats();
    expect(stats.count, 1, reason: 'one cancelled order, not two');
    expect(stats.totalAmountKobo, 200000,
        reason: 'Value Forfeited must not double when a second refund row '
            'exists');
    expect(stats.amountPaidKobo, 200000);
    expect(stats.refundsIssuedKobo, 230000,
        reason: 'both refund rows on the order are money that left');
  });

  test('the tile updates live when a refund row lands on its own', () async {
    // The refund figure comes from a correlated subquery on
    // `payment_transactions`, a table the joined query does not otherwise
    // mention — so the DAO has to declare it in `watchedTables` or the stream
    // never re-emits and the tile goes stale until something else touches
    // `orders`. This is the test that keeps that argument there.
    final storeId = await seedStore('Main');
    final staffId = await seedStaff();
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final productId = await seedProduct(storeId);
    final orderId = await sell(
        storeId: storeId,
        staffId: staffId,
        customerId: customerId,
        productId: productId);
    await db.ordersDao.markCancelled(orderId, 'refund', staffId);

    final emissions =
        db.ordersDao.watchOrdersStats(status: 'cancelled').map((s) => s.refundsIssuedKobo);
    final next = expectLater(
      emissions,
      emitsInOrder(<int>[200000, 230000]),
    );

    // A refund row and nothing else — the order header is untouched.
    await pumpEventQueue();
    await db.into(db.paymentTransactions).insert(
        PaymentTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            storeId: Value(storeId),
            amountKobo: 30000,
            method: 'cash',
            type: 'refund',
            orderId: Value(orderId),
            lastUpdatedAt: Value(DateTime.now())));

    await next;
  });

  test('a locked store scopes the refund figure with the list', () async {
    final mainId = await seedStore('Main');
    final branchId = await seedStore('Branch');
    final staffId = await seedStaff();
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final mainProduct = await seedProduct(mainId);
    final branchProduct = await seedProduct(branchId);

    final mainOrder = await sell(
        storeId: mainId,
        staffId: staffId,
        customerId: customerId,
        productId: mainProduct,
        qty: 2);
    final branchOrder = await sell(
        storeId: branchId,
        staffId: staffId,
        customerId: customerId,
        productId: branchProduct,
        qty: 3);
    await db.ordersDao.markCancelled(mainOrder, 'refund', staffId);
    await db.ordersDao.markCancelled(branchOrder, 'refund', staffId);

    expect((await cancelledStats()).refundsIssuedKobo, 500000,
        reason: 'All Stores sees both refunds');
    expect((await cancelledStats(storeId: mainId)).refundsIssuedKobo, 200000);
    expect((await cancelledStats(storeId: branchId)).refundsIssuedKobo, 300000);
  });
}
