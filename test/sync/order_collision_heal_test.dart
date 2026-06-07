// order_collision_heal_test.dart
//
// §30.8.1 legacy order-number collision self-heal. A pre-device-tag order can
// carry a number the cloud already holds under a different id; its upload then
// dup-keys forever AND blocks the cloud's colliding order from restoring here
// (its children FK-orphan every pull). OrdersDao.renumberForCollisionHeal
// appends THIS device's tag so the local order becomes ORD-NNNNNN-XXXXXX,
// re-enqueues it (so it uploads and frees the old number), and is idempotent.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

Future<String> _seedLegacyOrder(AppDatabase db, String businessId,
    {String number = 'ORD-000050'}) async {
  final id = UuidV7.generate();
  await db.into(db.orders).insert(OrdersCompanion.insert(
        id: Value(id),
        businessId: businessId,
        orderNumber: number,
        totalAmountKobo: 100000,
        netAmountKobo: 100000,
        paymentType: 'cash',
        status: 'completed',
      ));
  return id;
}

void main() {
  const tag = 'X7K2QP';

  test('renumberForCollisionHeal appends the device tag and re-enqueues a full '
      'orders upsert with the new number', () async {
    final boot = await bootstrapTestDb();
    try {
      final orderId = await _seedLegacyOrder(boot.db, boot.businessId);

      final newNumber =
          await boot.db.ordersDao.renumberForCollisionHeal(orderId, tag);

      expect(newNumber, 'ORD-000050-$tag');

      // Local order row carries the new number.
      final order = await (boot.db.select(boot.db.orders)
            ..where((t) => t.id.equals(orderId)))
          .getSingle();
      expect(order.orderNumber, 'ORD-000050-$tag');

      // A fresh orders:upsert was enqueued carrying the new number.
      final pending = await getPendingQueue(boot.db);
      final orderUpsert =
          pending.where((r) => r.actionType == 'orders:upsert').toList();
      expect(orderUpsert, isNotEmpty);
      final payload =
          jsonDecode(orderUpsert.last.payload) as Map<String, dynamic>;
      expect(payload['id'], orderId);
      expect(payload['order_number'], 'ORD-000050-$tag');
    } finally {
      await boot.db.close();
    }
  });

  test('is idempotent — a second heal with the same tag is a no-op', () async {
    final boot = await bootstrapTestDb();
    try {
      final orderId = await _seedLegacyOrder(boot.db, boot.businessId);

      await boot.db.ordersDao.renumberForCollisionHeal(orderId, tag);
      final second =
          await boot.db.ordersDao.renumberForCollisionHeal(orderId, tag);

      expect(second, isNull, reason: 'already carries this tag → no-op');
      final order = await (boot.db.select(boot.db.orders)
            ..where((t) => t.id.equals(orderId)))
          .getSingle();
      expect(order.orderNumber, 'ORD-000050-$tag',
          reason: 'must not double-append the tag');
    } finally {
      await boot.db.close();
    }
  });

  test('returns null for a missing order', () async {
    final boot = await bootstrapTestDb();
    try {
      final result = await boot.db.ordersDao
          .renumberForCollisionHeal(UuidV7.generate(), tag);
      expect(result, isNull);
    } finally {
      await boot.db.close();
    }
  });
}
