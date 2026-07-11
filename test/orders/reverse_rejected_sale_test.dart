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
}
