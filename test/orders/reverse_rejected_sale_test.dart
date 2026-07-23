// reverse_rejected_sale_test.dart
//
// Oversell recovery — Slice 2b (complete local undo). `reverseRejectedSaleLocal`
// returns a device to its exact pre-sale state after the server PERMANENTLY
// rejected a sale (an oversell). It is purely local (the rejected sale never
// reached the cloud) and never enqueued.
//
// Pins: (1) a walk-in sale → order cancelled + inventory refunded, no wallet
// touched; (2) a register-as-credit sale → order cancelled + inventory refunded
// + the customer's balance returns to its pre-sale value via compensating legs;
// (3) idempotency; (4) the reversal enqueues nothing.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

class _Fx {
  _Fx({
    required this.storeId,
    required this.staffId,
    required this.productId,
  });
  final String storeId;
  final String staffId;
  final String productId;
}

Future<_Fx> _seed(AppDatabase db, String businessId, {int stock = 5}) async {
  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main',
        ),
      );
  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );
  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Beer',
          retailerPriceKobo: const Value(100000),
        ),
      );
  await db.into(db.inventory).insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: Value(stock),
        ),
      );
  return _Fx(storeId: storeId, staffId: staffId, productId: productId);
}

Future<String> _sell(
  AppDatabase db,
  String businessId,
  _Fx f, {
  String? customerId,
  required int qty,
  required int amountPaidKobo,
}) {
  final total = qty * 100000;
  return db.ordersDao.createOrder(
    order: OrdersCompanion.insert(
      businessId: businessId,
      orderNumber: 'ORD-${UuidV7.generate().substring(0, 6)}',
      customerId: Value(customerId),
      totalAmountKobo: total,
      netAmountKobo: total,
      amountPaidKobo: Value(amountPaidKobo),
      paymentType: customerId == null ? 'cash' : 'credit',
      status: 'completed',
      staffId: Value(f.staffId),
      storeId: Value(f.storeId),
    ),
    items: [
      OrderItemsCompanion.insert(
        businessId: businessId,
        orderId: 'placeholder',
        productId: Value(f.productId),
        storeId: f.storeId,
        quantity: qty,
        unitPriceKobo: 100000,
        totalKobo: total,
      ),
    ],
    customerId: customerId,
    amountPaidKobo: amountPaidKobo,
    totalAmountKobo: total,
    staffId: f.staffId,
    storeId: f.storeId,
    paymentMethod: 'cash',
  );
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v2 path — the sale writes an order + inventory deduction + wallet legs
    // locally, but NO order_items / stock_transactions (they'd come from the
    // RPC), exactly the state a rejected v2 sale leaves behind.
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
  });

  tearDown(() => db.close());

  test('walk-in: cancels the order and refunds inventory, no wallet', () async {
    final f = await _seed(db, businessId, stock: 5);
    final orderId =
        await _sell(db, businessId, f, qty: 2, amountPaidKobo: 200000);
    expect((await db.select(db.inventory).getSingle()).quantity, 3);

    await db.ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: [(productId: f.productId, storeId: f.storeId, quantity: 2)],
      staffId: f.staffId,
    );

    final order = await db.select(db.orders).getSingle();
    expect(order.status, 'cancelled');
    expect(order.cancellationReason, 'rejected_by_server');
    expect((await db.select(db.inventory).getSingle()).quantity, 5,
        reason: 'inventory restored to pre-sale');
    expect(await db.select(db.walletTransactions).get(), isEmpty);
  });

  test(
      'register-as-credit: cancels + refunds inventory + restores the '
      "customer's balance to pre-sale", () async {
    final f = await _seed(db, businessId, stock: 5);
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );
    // Sell 2 (₦2000) on credit, pay ₦500 now → owes ₦1500.
    final orderId = await _sell(
      db,
      businessId,
      f,
      customerId: customerId,
      qty: 2,
      amountPaidKobo: 50000,
    );
    expect(
      await db.walletTransactionsDao.getBalanceKobo(customerId),
      -150000,
      reason: 'customer owes 1500 after the credit sale',
    );

    await db.ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: [(productId: f.productId, storeId: f.storeId, quantity: 2)],
      staffId: f.staffId,
    );

    expect((await db.select(db.orders).getSingle()).status, 'cancelled');
    expect((await db.select(db.inventory).getSingle()).quantity, 5);
    expect(
      await db.walletTransactionsDao.getBalanceKobo(customerId),
      0,
      reason: 'wallet returns to its exact pre-sale balance (0)',
    );
  });

  test('is idempotent — a second reversal is a no-op', () async {
    final f = await _seed(db, businessId, stock: 5);
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );
    final orderId = await _sell(
      db,
      businessId,
      f,
      customerId: customerId,
      qty: 2,
      amountPaidKobo: 50000,
    );

    final items = [
      (productId: f.productId, storeId: f.storeId, quantity: 2)
    ];
    await db.ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: items,
      staffId: f.staffId,
    );
    final walletCountAfterFirst =
        (await db.select(db.walletTransactions).get()).length;
    final invAfterFirst = (await db.select(db.inventory).getSingle()).quantity;

    // Second call must NOT double-refund inventory or post more wallet rows.
    await db.ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: items,
      staffId: f.staffId,
    );
    expect((await db.select(db.walletTransactions).get()).length,
        walletCountAfterFirst);
    expect((await db.select(db.inventory).getSingle()).quantity, invAfterFirst);
    expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0);
  });

  test(
      'crate sale: reversal un-issues the customer empties balance and appends '
      'a compensating ledger row, enqueuing nothing', () async {
    // A crate business (Bar) selling a no-deposit ("crate-track") brand issues
    // empties to the customer via customer_crate_balances — an LWW cache that
    // WON'T self-heal on the next pull, so the reversal must undo it locally.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(mfrId),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Star Bottle',
        retailerPriceKobo: const Value(100000),
        manufacturerId: Value(mfrId),
        unit: const Value('Bottle'),
        trackEmpties: const Value(true)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(20)));

    // Sell 5 on credit with NO deposit paid → crate-track: issues 5 empties.
    const total = 5 * 100000;
    final orderId = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: total,
        netAmountKobo: total,
        amountPaidKobo: const Value(0),
        paymentType: 'credit',
        status: 'completed',
        staffId: Value(staffId),
        storeId: Value(storeId),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(productId),
          storeId: storeId,
          quantity: 5,
          unitPriceKobo: 100000,
          totalKobo: total,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: 0,
      totalAmountKobo: total,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
    );

    Future<int?> crateBal() async =>
        (await (db.select(db.customerCrateBalances)
                  ..where((t) =>
                      t.customerId.equals(customerId) &
                      t.manufacturerId.equals(mfrId)))
                .getSingleOrNull())
            ?.balance;

    expect(await crateBal(), 5, reason: '5 empties issued at sale');
    final queuedBeforeReversal = (await db.select(db.syncQueue).get()).length;

    await db.ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: [(productId: productId, storeId: storeId, quantity: 5)],
      staffId: staffId,
    );

    expect(await crateBal(), 0,
        reason: 'the issued empties balance is fully un-issued');

    // A compensating 'adjusted' −5 ledger row nets the sale's 'issued' +5.
    final adjusted = await (db.select(db.crateLedger)
          ..where((t) => t.movementType.equals('adjusted')))
        .get();
    expect(adjusted, hasLength(1));
    expect(adjusted.first.quantityDelta, -5);
    expect(adjusted.first.customerId, customerId);
    expect(adjusted.first.referenceOrderId, orderId);

    // Ledger nets to 0 → the derived crate debt returns to its pre-sale value.
    final ledgerSum = (await (db.select(db.crateLedger)
              ..where((t) => t.customerId.equals(customerId)))
            .get())
        .fold<int>(0, (s, r) => s + r.quantityDelta);
    expect(ledgerSum, 0, reason: 'issued +5 and adjusted −5 net to the cache');

    // The reversal enqueues nothing — the rejected sale never reached the cloud.
    expect((await db.select(db.syncQueue).get()).length, queuedBeforeReversal,
        reason: 'the crate reversal must not enqueue');
  });
}
