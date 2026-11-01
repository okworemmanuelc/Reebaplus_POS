import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// #628 — a part quantity from the cart through checkout, cancel and return:
/// the line, the stock, the FIFO layer and what goes up to the cloud.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);

    storeId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );
    staffId = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: businessId,
            name: 'Cashier',
            pin: '0000',
          ),
        );
    productId = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Star',
            retailerPriceKobo: const Value(100000),
            unit: const Value('Piece'),
          ),
        );
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(10),
          ),
        );
    await db
        .into(db.costBatches)
        .insert(
          CostBatchesCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            qtyRemaining: 10,
            qtyOriginal: 10,
            costKobo: const Value(40000),
            receivedAt: Value(DateTime.utc(2026, 1, 1)),
          ),
        );
  });

  tearDown(() => db.close());

  Future<String> sell(num qty, int totalKobo) async {
    final number = await OrderService(db).addOrder(
      customerId: null,
      cart: [
        {
          'id': productId,
          'qty': qty,
          'unitPriceKobo': 100000,
          'buyingPriceKobo': 40000,
          'name': 'Star',
        },
      ],
      totalAmountKobo: totalKobo,
      amountPaidKobo: totalKobo,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    return (await (db.select(
      db.orders,
    )..where((o) => o.orderNumber.equals(number))).getSingle()).id;
  }

  Future<double> stock() async => (await (db.select(
    db.inventory,
  )..where((i) => i.productId.equals(productId))).getSingle()).quantity;

  Future<List<Map<String, dynamic>>> queued(String table) async {
    final rows = await (db.select(
      db.syncQueue,
    )..where((q) => q.actionType.equals('$table:upsert'))).get();
    return [
      for (final r in rows) jsonDecode(r.payload) as Map<String, dynamic>,
    ];
  }

  test('1.5 stays 1.5 on the line, the stock, the ledger and the batch', () async {
    final orderId = await sell(1.5, 150000);

    final line = await (db.select(
      db.orderItems,
    )..where((i) => i.orderId.equals(orderId))).getSingle();
    expect(line.quantity, 1.5);
    expect(line.totalKobo, 150000);
    expect(line.buyingPriceKobo, 40000);
    expect(await stock(), 8.5);

    final tx = await (db.select(
      db.stockTransactions,
    )..where((t) => t.orderId.equals(orderId))).getSingle();
    expect(tx.quantityDelta, -1.5);

    final batch = await (db.select(
      db.costBatches,
    )..where((b) => b.productId.equals(productId))).getSingle();
    expect(batch.qtyRemaining, 8.5);
  });

  test('the push carries 0.5 as a decimal and a whole line as an integer', () async {
    await sell(0.5, 50000);
    await sell(2, 200000);

    final quantities = [
      for (final row in await queued('order_items')) row['quantity'],
    ];
    expect(quantities, containsAll(<Object>[0.5, 2]));
    expect(quantities.whereType<int>().single, 2);
  });

  test('a quantity off the quarter grid never reaches the outbox', () async {
    await expectLater(sell(0.3, 30000), throwsArgumentError);
    expect(await stock(), 10);
  });

  test('a cancel brings the part back, costed', () async {
    final orderId = await sell(1.5, 150000);
    await db.ordersDao.markCancelled(orderId, 'mistake', staffId);

    expect(await stock(), 10);
    final restored =
        await (db.select(db.costBatches)..where(
              (b) => b.productId.equals(productId) & b.qtyOriginal.equals(1.5),
            ))
            .getSingle();
    expect(restored.qtyRemaining, 1.5);
    expect(restored.costKobo, 40000);
  });

  test('a return writes off a damaged part at its cost', () async {
    final orderId = await sell(1.5, 150000);
    await db
        .update(db.orders)
        .write(const OrdersCompanion(status: Value('completed')));
    final line = await (db.select(
      db.orderItems,
    )..where((i) => i.orderId.equals(orderId))).getSingle();

    final outcome = await db.ordersDao.returnCompletedSale(
      orderId: orderId,
      reason: 'dropped',
      staffId: staffId,
      damageReasonKey: 'broken',
      damagedQtyByLine: {line.id: 0.5},
    );

    expect(outcome!.damagedUnits, 0.5);
    expect(await stock(), 9.5);
  });
}
