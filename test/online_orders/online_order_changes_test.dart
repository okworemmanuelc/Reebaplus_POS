// #428: change before accepting (lower / remove, never raise), accepted_qty on
// every line, the price flag's data, and cancelling an accepted order.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_answer.dart';

import '../helpers/dispatch_test_utils.dart';
import 'online_order_fixtures.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String orderId;
  late String productA;
  late String productB;
  late String lineA;
  late String lineB;

  Future<String> addProduct(String name, int retail) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: name,
          retailerPriceKobo: Value(retail),
        ));
    return id;
  }

  Future<String> addLine(String productId, String name, int price, int qty) async {
    final id = UuidV7.generate();
    await db.into(db.onlineOrderLines).insert(OnlineOrderLinesCompanion.insert(
          id: id,
          businessId: businessId,
          onlineOrderId: orderId,
          productId: productId,
          productName: name,
          unitPriceKobo: price,
          requestedQty: qty,
        ));
    return id;
  }

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = await seedStore(db, businessId);
    orderId = await seedOnlineOrder(db, businessId: businessId, storeId: storeId);
    productA = await addProduct('Star Lager', 450000);
    productB = await addProduct('Malt', 300000);
    lineA = await addLine(productA, 'Star Lager', 450000, 4);
    lineB = await addLine(productB, 'Malt', 300000, 2);
  });
  tearDown(() => db.close());

  Future<OnlineOrderLineData> line(String id) => (db.select(db.onlineOrderLines)
        ..where((t) => t.id.equals(id))).getSingle();

  Future<List<Map<String, dynamic>>> queued(String table) async {
    final rows = await (db.select(db.syncQueue)
          ..where((t) => t.actionType.equals('$table:upsert')))
        .get();
    return [for (final r in rows) jsonDecode(r.payload) as Map<String, dynamic>];
  }

  test('lower one line, remove another: accepted_qty written on every line',
      () async {
    final outcome = await db.onlineOrdersDao.accept(
      onlineOrderId: orderId,
      acceptedQtys: {lineA: 3, lineB: 0},
    );
    expect(outcome, OnlineOrderAnswerOutcome.answered);
    expect((await line(lineA)).acceptedQty, 3);
    expect((await line(lineB)).acceptedQty, 0);
    final pushed = await queued('online_order_lines');
    expect(pushed.map((p) => p['accepted_qty']).toSet(), {3, 0});
    expect((await queued('online_orders')).single['status'], 'accepted');
  });

  test('untouched lines are accepted at the requested quantity', () async {
    await db.onlineOrdersDao.accept(onlineOrderId: orderId);
    expect((await line(lineA)).acceptedQty, 4);
    expect((await line(lineB)).acceptedQty, 2);
  });

  test('cannot raise a quantity or touch an unknown line; nothing written',
      () async {
    expect(
      () => db.onlineOrdersDao.accept(
        onlineOrderId: orderId,
        acceptedQtys: {lineA: 5},
      ),
      throwsArgumentError,
    );
    expect(
      () => db.onlineOrdersDao.accept(
        onlineOrderId: orderId,
        acceptedQtys: {'nope': 1},
      ),
      throwsArgumentError,
    );
    expect(
      () => db.onlineOrdersDao.accept(
        onlineOrderId: orderId,
        acceptedQtys: {lineA: 0, lineB: 0},
      ),
      throwsArgumentError,
      reason: 'removing every line is a decline',
    );
    final order = await (db.select(db.onlineOrders)
          ..where((t) => t.id.equals(orderId))).getSingle();
    expect(order.status, 'new');
    expect((await line(lineA)).acceptedQty, isNull);
    expect(await queued('online_order_lines'), isEmpty);
  });

  test('price flag data: current retail price per product', () async {
    await (db.update(db.products)..where((t) => t.id.equals(productA)))
        .write(const ProductsCompanion(retailerPriceKobo: Value(500000)));
    final prices = await db.onlineOrdersDao.watchRetailPrices(orderId).first;
    expect(prices[productA], 500000); // line saw 450000
    expect(prices[productB], 300000); // unchanged
  });

  test('cancel an accepted order with a reason; refused unless accepted',
      () async {
    expect(
      await db.onlineOrdersDao
          .cancelAccepted(onlineOrderId: orderId, reason: 'Out of stock'),
      OnlineOrderAnswerOutcome.alreadyAnswered,
      reason: 'a new order is declined, not cancelled',
    );
    await db.onlineOrdersDao.accept(onlineOrderId: orderId);
    expect(
      () => db.onlineOrdersDao.cancelAccepted(onlineOrderId: orderId, reason: ' '),
      throwsArgumentError,
    );
    expect(
      await db.onlineOrdersDao
          .cancelAccepted(onlineOrderId: orderId, reason: ' Van broke down '),
      OnlineOrderAnswerOutcome.answered,
    );
    final order = await (db.select(db.onlineOrders)
          ..where((t) => t.id.equals(orderId))).getSingle();
    expect(order.status, 'cancelled_by_shop');
    expect(order.cancelReason, 'Van broke down');
    final pushed = (await queued('online_orders')).last;
    expect(pushed['status'], 'cancelled_by_shop');
    expect(pushed['cancel_reason'], 'Van broke down');
  });
}
