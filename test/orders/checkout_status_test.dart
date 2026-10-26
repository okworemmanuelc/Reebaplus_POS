import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// PRD #337 / #547 — Checkout creates the Order `pending` only for a
/// crate-bearing sale; every other sale is born `completed` with completedAt =
/// the checkout instant and no confirmer.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
              id: Value(staffId),
              businessId: businessId,
              name: 'Cashier',
              pin: '0000'),
        );
  });

  tearDown(() => db.close());

  Future<void> setBusiness({String? type, bool? tracks}) =>
      (db.update(db.businesses)..where((b) => b.id.equals(businessId))).write(
        BusinessesCompanion(
          type: type == null ? const Value.absent() : Value(type),
          tracksEmptyCrates:
              tracks == null ? const Value.absent() : Value(tracks),
        ),
      );

  Future<String> seedProduct({
    required String unit,
    bool trackEmpties = false,
  }) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: 'P-$id',
            retailerPriceKobo: const Value(100000),
            unit: Value(unit),
            trackEmpties: Value(trackEmpties),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: id,
            storeId: storeId,
            quantity: const Value(100),
          ),
        );
    return id;
  }

  Map<String, dynamic> line(String? productId) => {
        'id': productId,
        'qty': 1,
        'unitPriceKobo': 100000,
        'name': 'Item',
      };

  Future<OrderData> checkout(List<Map<String, dynamic>> cart) async {
    final number = await OrderService(db).addOrder(
      customerId: null,
      cart: cart,
      totalAmountKobo: 100000 * cart.length,
      amountPaidKobo: 100000 * cart.length,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    return (db.select(db.orders)..where((o) => o.orderNumber.equals(number)))
        .getSingle();
  }

  void expectPending(OrderData o) {
    expect(o.status, 'pending');
    expect(o.completedAt, isNull);
    expect(o.confirmedBy, isNull);
    expect(o.staffId, staffId);
  }

  void expectCompletedAtCheckout(OrderData o, DateTime before) {
    expect(o.status, 'completed');
    expect(o.completedAt, isNotNull);
    expect(o.completedAt!.isBefore(before.subtract(const Duration(seconds: 2))),
        isFalse);
    expect(o.completedAt!.isAfter(DateTime.now().add(const Duration(seconds: 2))),
        isFalse);
    expect(o.confirmedBy, isNull, reason: 'nobody confirmed it');
    expect(o.staffId, staffId, reason: 'the seller is still credited');
  }

  group('Checkout status decision', () {
    test('plain product at a crate business → completed', () async {
      await setBusiness(type: 'Bar');
      final p = await seedProduct(unit: 'Piece');
      final before = DateTime.now();
      expectCompletedAtCheckout(await checkout([line(p)]), before);
    });

    test('crate-tracked bottle at a crate business → pending', () async {
      await setBusiness(type: 'Bar');
      final p = await seedProduct(unit: 'Bottle', trackEmpties: true);
      expectPending(await checkout([line(p)]));
    });

    test('mixed cart (bottle + plain) → pending as one order', () async {
      await setBusiness(type: 'Bar');
      final b = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final p = await seedProduct(unit: 'Piece');
      expectPending(await checkout([line(p), line(b)]));
    });

    test('bottle with track-empties off → completed', () async {
      await setBusiness(type: 'Bar');
      final p = await seedProduct(unit: 'Bottle', trackEmpties: false);
      final before = DateTime.now();
      expectCompletedAtCheckout(await checkout([line(p)]), before);
    });

    test('Quick-Sale-only cart → completed', () async {
      await setBusiness(type: 'Bar');
      final before = DateTime.now();
      expectCompletedAtCheckout(await checkout([line(null)]), before);
    });

    test('Quick Sale + tracked bottle → pending (the bottle decides)',
        () async {
      await setBusiness(type: 'Bar');
      final b = await seedProduct(unit: 'Bottle', trackEmpties: true);
      expectPending(await checkout([line(null), line(b)]));
    });

    test('crate-tracked bottle at a non-crate business type → completed',
        () async {
      await setBusiness(type: 'Supermarket');
      final p = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final before = DateTime.now();
      expectCompletedAtCheckout(await checkout([line(p)]), before);
    });

    test('crate business with tracksEmptyCrates=false → completed', () async {
      await setBusiness(type: 'Bar', tracks: false);
      final p = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final before = DateTime.now();
      expectCompletedAtCheckout(await checkout([line(p)]), before);
    });
  });

  group('the decided status rides both sync paths', () {
    test('v1: the orders:upsert push carries status + completed_at', () async {
      await setBusiness(type: 'Bar');
      final p = await seedProduct(unit: 'Piece');
      final order = await checkout([line(p)]);

      final push = (await getPendingQueue(db))
          .where((r) => r.actionType == 'orders:upsert')
          .map(decodePayload)
          .where((m) => m['id'] == order.id)
          .toList();
      expect(push, isNotEmpty);
      expect(push.last['status'], 'completed');
      expect(push.last['completed_at'], isNotNull);
    });

    test('v1: a crate-bearing push stays pending with no completed_at',
        () async {
      await setBusiness(type: 'Bar');
      final b = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final order = await checkout([line(b)]);

      final push = (await getPendingQueue(db))
          .where((r) => r.actionType == 'orders:upsert')
          .map(decodePayload)
          .where((m) => m['id'] == order.id)
          .last;
      expect(push['status'], 'pending');
      expect(push['completed_at'], isNull);
    });

    test('v2: the envelope forwards p_status', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      await setBusiness(type: 'Bar');
      final p = await seedProduct(unit: 'Piece');
      final b = await seedProduct(unit: 'Bottle', trackEmpties: true);

      final plain = await checkout([line(p)]);
      final crate = await checkout([line(b)]);

      final byOrder = {
        for (final r in (await getPendingQueue(db))
            .where((r) => r.actionType == 'domain:pos_record_sale_v2'))
          (jsonDecode(r.payload) as Map<String, dynamic>)['p_order_id']:
              (jsonDecode(r.payload) as Map<String, dynamic>)['p_status'],
      };
      expect(byOrder[plain.id], 'completed');
      expect(byOrder[crate.id], 'pending');
    });
  });
}
