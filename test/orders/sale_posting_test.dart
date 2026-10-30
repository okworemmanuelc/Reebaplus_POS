import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// #575 — characterization ("draft in -> rows out") tests for Sale posting:
/// `OrdersDao.createOrder` (via `OrderService.addOrder` for the walk-in FIFO
/// case) and `OrdersDao.markCancelled`. They pin what the code produces TODAY
/// on the v1 (live) path; they are not a statement of what it should do.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    return (storeId, staffId);
  }

  Future<String> seedCustomer() => db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));

  Future<String> seedProduct(
    String storeId, {
    String name = 'Cola',
    int priceKobo = 100000,
    int scalarCostKobo = 100,
    String? manufacturerId,
  }) async {
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: name,
        retailerPriceKobo: Value(priceKobo),
        buyingPriceKobo: Value(scalarCostKobo),
        manufacturerId: Value(manufacturerId),
        unit: Value(manufacturerId == null ? 'Piece' : 'Bottle'),
        trackEmpties: Value(manufacturerId != null)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
    return productId;
  }

  Future<void> seedBatch(String productId, String storeId,
      {required int qty, required int costKobo, required DateTime at}) {
    return db.into(db.costBatches).insert(CostBatchesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        qtyRemaining: qty,
        qtyOriginal: qty,
        costKobo: Value(costKobo),
        receivedAt: Value(at)));
  }

  Future<int> stock(String productId, String storeId) async {
    final row = await (db.select(db.inventory)
          ..where(
              (i) => i.productId.equals(productId) & i.storeId.equals(storeId)))
        .getSingle();
    return row.quantity;
  }

  Future<List<StockTransactionData>> stockTx(String orderId) =>
      (db.select(db.stockTransactions)
            ..where((t) => t.orderId.equals(orderId))
            ..orderBy([(t) => OrderingTerm.asc(t.movementType)]))
          .get();

  Future<List<PaymentTransactionData>> payments(String orderId) =>
      (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(orderId))
            ..orderBy([(p) => OrderingTerm.asc(p.type)]))
          .get();

  Future<List<WalletTransactionData>> wallet(String orderId) =>
      (db.select(db.walletTransactions)
            ..where((w) => w.orderId.equals(orderId))
            ..orderBy([(w) => OrderingTerm.asc(w.signedAmountKobo)]))
          .get();

  Future<OrderData> orderById(String id) =>
      (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();

  Future<List<OrderItemData>> items(String orderId) => (db.select(db.orderItems)
        ..where((i) => i.orderId.equals(orderId))
        ..orderBy([(i) => OrderingTerm.asc(i.totalKobo)]))
      .get();

  /// Single-line registered-customer sale straight through `createOrder`.
  Future<String> sell(
    String storeId,
    String staffId,
    String? customerId,
    String productId, {
    required int qty,
    required int paidKobo,
    String method = 'cash',
    Map<String, int> deposits = const {},
  }) {
    final goods = qty * 100000;
    final deposit = deposits.values.fold<int>(0, (s, v) => s + v);
    final grand = goods + deposit;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: grand,
        netAmountKobo: grand,
        amountPaidKobo: Value(paidKobo),
        paymentType: 'cash',
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
          quantity: qty,
          unitPriceKobo: 100000,
          totalKobo: goods,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: paidKobo,
      totalAmountKobo: grand,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: method,
      crateDepositPaidByManufacturer: deposits,
    );
  }

  Future<String> idOf(String orderNumber) async => (await (db.select(db.orders)
            ..where((o) => o.orderNumber.equals(orderNumber)))
          .getSingle())
      .id;

  // Scenario 1 is shared by the cash-sale and cancel tests.
  Future<(String orderId, String storeId, String staffId, String a, String b)>
      cashSale() async {
    final (storeId, staffId) = await seedBase();
    final a = await seedProduct(storeId, name: 'A');
    final b = await seedProduct(storeId, name: 'B', priceKobo: 50000);
    await seedBatch(a, storeId,
        qty: 1, costKobo: 100, at: DateTime.utc(2026, 1, 1));
    await seedBatch(a, storeId,
        qty: 10, costKobo: 150, at: DateTime.utc(2026, 2, 1));
    await seedBatch(b, storeId,
        qty: 5, costKobo: 30, at: DateTime.utc(2026, 1, 1));
    final number = await OrderService(db).addOrder(
      customerId: null,
      cart: [
        {
          'id': a,
          'qty': 3,
          'unitPriceKobo': 100000,
          'buyingPriceKobo': 100,
          'name': 'A'
        },
        {
          'id': b,
          'qty': 2,
          'unitPriceKobo': 50000,
          'buyingPriceKobo': 30,
          'name': 'B'
        },
      ],
      totalAmountKobo: 400000,
      amountPaidKobo: 400000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    return (await idOf(number), storeId, staffId, a, b);
  }

  test('1. walk-in cash sale, 2 lines: order, FIFO-costed lines, stock, payment',
      () async {
    final (orderId, storeId, _, a, b) = await cashSale();

    final o = await orderById(orderId);
    expect(o.status, 'completed');
    expect(o.totalAmountKobo, 400000);
    expect(o.netAmountKobo, 400000);
    expect(o.amountPaidKobo, 400000);
    expect(o.customerId, isNull);

    // Lines (ordered by total): B 2 @ 500, A 3 @ 1000. COGS per unit from FIFO:
    // B 2@30; A (1@100 + 2@150)/3 = 133 (integer division).
    final lines = await items(orderId);
    expect(lines.map((l) => (l.quantity, l.buyingPriceKobo)),
        [(2, 30), (3, 133)]);

    // One negative 'sale' stock movement per line; inventory decremented.
    final tx = await stockTx(orderId);
    expect(tx.map((t) => (t.movementType, t.quantityDelta)).toSet(),
        {('sale', -3), ('sale', -2)});
    expect(await stock(a, storeId), 97);
    expect(await stock(b, storeId), 98);

    // Exactly one goods 'sale' payment row, cash, store-stamped.
    final pays = await payments(orderId);
    expect(pays, hasLength(1));
    expect(pays.single.type, 'sale');
    expect(pays.single.method, 'cash');
    expect(pays.single.amountKobo, 400000);
    expect(pays.single.storeId, storeId);

    // FIFO draw-down: A's oldest batch spent, newer partly; B partly.
    final batches = await db.select(db.costBatches).get();
    expect(batches.map((x) => (x.qtyOriginal, x.qtyRemaining)).toSet(),
        {(1, 0), (10, 8), (5, 3)});

    // Walk-in: no wallet legs.
    expect(await wallet(orderId), isEmpty);
  });

  test('2. registered customer, nothing tendered (pay-from-wallet): debit only',
      () async {
    final (storeId, staffId) = await seedBase();
    final cust = await seedCustomer();
    final p = await seedProduct(storeId);

    final orderId =
        await sell(storeId, staffId, cust, p, qty: 2, paidKobo: 0);

    expect(await payments(orderId), isEmpty,
        reason: 'no cash tendered, so no payment_transactions row');
    final legs = await wallet(orderId);
    expect(legs, hasLength(1));
    expect(legs.single.type, 'debit');
    expect(legs.single.signedAmountKobo, -200000);
    expect(legs.single.referenceType, 'order_payment');
    expect(await db.walletTransactionsDao.getBalanceKobo(cust), -200000,
        reason: 'the wallet goes negative — that is the customer debt');
    final o = await orderById(orderId);
    expect(o.amountPaidKobo, 0);
    // NOTE: a direct createOrder keeps the header status the caller passed
    // ('pending'); only OrderService.addOrder promotes it to 'completed'.
    expect(o.status, 'pending');
    expect(await stock(p, storeId), 98);
  });

  test('3a. crate business, crate-track sale: issues crates, no deposit rows',
      () async {
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    final (storeId, staffId) = await seedBase();
    final cust = await seedCustomer();
    final mfr = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(mfr),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    final p = await seedProduct(storeId, name: 'Beer', manufacturerId: mfr);

    final orderId =
        await sell(storeId, staffId, cust, p, qty: 3, paidKobo: 300000);

    final ledger = await (db.select(db.crateLedger)
          ..where((l) => l.referenceOrderId.equals(orderId)))
        .get();
    expect(ledger, hasLength(1));
    expect(ledger.single.movementType, 'issued');
    expect(ledger.single.quantityDelta, 3);
    expect(ledger.single.manufacturerId, mfr);
    expect(ledger.single.customerId, cust);
    final pays = await payments(orderId);
    expect(pays.map((x) => (x.type, x.amountKobo)), [('sale', 300000)]);

    // Cancel completes the ledger with a system 'adjusted' correction.
    await db.ordersDao.markCancelled(orderId, 'refund', staffId);
    final after = await (db.select(db.crateLedger)
          ..where((l) => l.referenceOrderId.equals(orderId)))
        .get();
    expect(after.map((l) => (l.movementType, l.quantityDelta)).toSet(),
        {('issued', 3), ('adjusted', -3)});
  });

  test('3b. crate business, money-track sale: deposit held, no crates issued',
      () async {
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    final (storeId, staffId) = await seedBase();
    final cust = await seedCustomer();
    final mfr = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(mfr),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    final p = await seedProduct(storeId, name: 'Beer', manufacturerId: mfr);

    // 1 bottle (N1,000) + N500 deposit, paid in full.
    final orderId = await sell(storeId, staffId, cust, p,
        qty: 1, paidKobo: 150000, deposits: {mfr: 50000});

    final o = await orderById(orderId);
    expect(o.crateDepositPaidKobo, 50000);
    expect(o.totalAmountKobo, 150000);
    final pays = await payments(orderId);
    expect(pays.map((x) => (x.type, x.amountKobo)),
        [('crate_deposit', 50000), ('sale', 100000)]);
    expect(await db.walletTransactionsDao.getDepositsHeldKobo(cust), 50000);
    expect(await db.walletTransactionsDao.getBalanceKobo(cust), 0);
    expect(
        await (db.select(db.crateLedger)
              ..where((l) => l.referenceOrderId.equals(orderId)))
            .get(),
        isEmpty,
        reason: 'a deposit-paid brand issues no customer crate balance');
    // Goods debit, goods credit, held-deposit credit.
    final legs = await wallet(orderId);
    expect(legs.map((l) => (l.signedAmountKobo, l.referenceType)).toSet(), {
      (-100000, 'order_payment'),
      (100000, 'topup_cash'),
      (50000, 'crate_deposit'),
    });
  });

  test('4. partial cash: one cash payment row + wallet debt legs', () async {
    final (storeId, staffId) = await seedBase();
    final cust = await seedCustomer();
    final p = await seedProduct(storeId);

    final orderId =
        await sell(storeId, staffId, cust, p, qty: 2, paidKobo: 80000);

    final pays = await payments(orderId);
    expect(pays.map((x) => (x.type, x.method, x.amountKobo)),
        [('sale', 'cash', 80000)]);
    final legs = await wallet(orderId);
    expect(legs.map((l) => (l.signedAmountKobo, l.referenceType)),
        [(-200000, 'order_payment'), (80000, 'topup_cash')]);
    expect(await db.walletTransactionsDao.getBalanceKobo(cust), -120000,
        reason: 'N2,000 owed - N800 paid = N1,200 debt');
    expect((await orderById(orderId)).amountPaidKobo, 80000);
  });

  test('5. markCancelled on the cash sale appends compensating rows only',
      () async {
    final (orderId, storeId, staffId, a, b) = await cashSale();
    final stockBefore = await stockTx(orderId);
    final linesBefore = await items(orderId);

    await db.ordersDao.markCancelled(orderId, 'customer changed mind', staffId);

    final o = await orderById(orderId);
    expect(o.status, 'cancelled');
    expect(o.cancelledAt, isNotNull);

    // Stock: original 'sale' rows untouched, matching 'return' rows appended.
    final tx = await stockTx(orderId);
    expect(tx, hasLength(4));
    expect(tx.where((t) => t.movementType == 'sale').map((t) => t.id).toSet(),
        stockBefore.map((t) => t.id).toSet());
    expect(
        tx
            .where((t) => t.movementType == 'return')
            .map((t) => t.quantityDelta)
            .toSet(),
        {3, 2});
    expect(await stock(a, storeId), 100);
    expect(await stock(b, storeId), 100);

    // Payments: the original sale row is not voided or edited; a full 'refund'
    // row is appended alongside it.
    final pays = await payments(orderId);
    expect(pays.map((x) => (x.type, x.amountKobo)),
        [('refund', 400000), ('sale', 400000)]);
    expect(pays.every((x) => x.voidedAt == null), isTrue);

    // Cost layers: consumed batches stay as they were; fixed-id restore
    // layers (qty = units sold, at the line COGS) are added.
    final batches = await db.select(db.costBatches).get();
    expect(batches, hasLength(5));
    final restores = batches.where((x) => x.qtyOriginal == x.qtyRemaining &&
        ((x.qtyOriginal == 3 && x.costKobo == 133) ||
            (x.qtyOriginal == 2 && x.costKobo == 30)));
    expect(restores, hasLength(2));

    // Order lines are unchanged (same COGS snapshot).
    expect((await items(orderId)).map((l) => (l.id, l.buyingPriceKobo)),
        linesBefore.map((l) => (l.id, l.buyingPriceKobo)));

    // A second cancel is a no-op.
    await db.ordersDao.markCancelled(orderId, 'again', staffId);
    expect(await stockTx(orderId), hasLength(4));
    expect(await payments(orderId), hasLength(2));
  });

  test('5b. markCancelled on a partial-cash customer sale reverses every wallet '
      'leg with new rows', () async {
    final (storeId, staffId) = await seedBase();
    final cust = await seedCustomer();
    final p = await seedProduct(storeId);
    final orderId =
        await sell(storeId, staffId, cust, p, qty: 2, paidKobo: 80000);
    final before = (await wallet(orderId)).map((l) => l.id).toSet();

    await db.ordersDao.markCancelled(orderId, 'refund', staffId);

    final legs = await wallet(orderId);
    expect(legs, hasLength(4));
    expect(legs.where((l) => before.contains(l.id)), hasLength(2),
        reason: 'the original legs are still there, untouched');
    expect(legs.map((l) => (l.signedAmountKobo, l.referenceType)).toSet(), {
      (-200000, 'order_payment'),
      (80000, 'topup_cash'),
      (-80000, 'void'),
      (200000, 'refund'),
    });
    expect(await db.walletTransactionsDao.getBalanceKobo(cust), 0);
    expect(await stock(p, storeId), 100);
  });
}
