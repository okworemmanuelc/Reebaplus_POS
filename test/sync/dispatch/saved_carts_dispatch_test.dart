import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import '../../helpers/dispatch_test_utils.dart';

/// §4.6 / §5: saved_carts is in _syncedTenantTables but the original
/// DAO bypassed SyncDao. These tests lock in the wired-through path.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('OrdersDao saved_carts dispatch', () {
    test('saveCart enqueues a saved_carts:upsert row', () async {
      final cartId = await db.ordersDao.saveCart(
        SavedCartsCompanion.insert(
          businessId: businessId,
          name: 'Test Cart',
          cartData: '{"items": []}',
        ),
      );

      expect(await db.select(db.savedCarts).get(), hasLength(1));

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'saved_carts:upsert');

      final payload = decodePayload(pending.first);
      expect(payload['id'], cartId);
      expect(payload['business_id'], businessId);
    });

    test('deleteSavedCart enqueues a saved_carts:delete row', () async {
      final cartId = await db.ordersDao.saveCart(
        SavedCartsCompanion.insert(
          businessId: businessId,
          name: 'Test Cart',
          cartData: '{"items": []}',
        ),
      );
      // Drain the upsert from saveCart so we only see the delete.
      await db.delete(db.syncQueue).go();

      await db.ordersDao.deleteSavedCart(cartId);

      expect(await db.select(db.savedCarts).get(), isEmpty);

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'saved_carts:delete');
      final payload = decodePayload(pending.first);
      expect(payload['id'], cartId);
      expect(payload['is_deleted'], true);
    });

    test('saveCart stamps a 24h expiry and forwards cashier_id/expires_at',
        () async {
      final before = DateTime.now();
      final id = await db.ordersDao.saveCart(
        SavedCartsCompanion.insert(
          businessId: businessId,
          name: 'Test Cart',
          cartData: '{"items": []}',
          cashierId: const Value('cashier-1'),
        ),
      );

      final row = await (db.select(db.savedCarts)
            ..where((c) => c.id.equals(id)))
          .getSingle();
      expect(row.cashierId, 'cashier-1');
      expect(row.expiresAt, isNotNull);
      final minsToExpiry = row.expiresAt!.difference(before).inMinutes;
      expect(minsToExpiry, inInclusiveRange(23 * 60, 24 * 60 + 1));

      final payload = decodePayload((await getPendingQueue(db)).first);
      expect(payload['cashier_id'], 'cashier-1');
      expect(payload.containsKey('expires_at'), isTrue);
    });

    test('watchSavedCarts shows only the cashier\'s own, unexpired carts',
        () async {
      final now = DateTime.now();
      Future<void> save(
        String name, {
        String? cashier,
        DateTime? expires,
      }) =>
          db.ordersDao.saveCart(
            SavedCartsCompanion.insert(
              businessId: businessId,
              name: name,
              cartData: '{"items": []}',
              cashierId: Value(cashier),
              // Pass an explicit (possibly null) expiry so saveCart does not
              // auto-stamp the 24h default.
              expiresAt: Value(expires),
            ),
          );

      await save('mine', cashier: 'me', expires: now.add(const Duration(hours: 1)));
      await save('other', cashier: 'you', expires: now.add(const Duration(hours: 1)));
      await save('expired', cashier: 'me', expires: now.subtract(const Duration(hours: 1)));
      await save('legacy'); // null cashier + null expiry → visible to all

      final names =
          (await db.ordersDao.watchSavedCarts('me').first).map((c) => c.name).toSet();
      expect(names, containsAll(<String>{'mine', 'legacy'}));
      expect(names, isNot(contains('other')));
      expect(names, isNot(contains('expired')));
    });

    test('deleteExpiredCarts tombstones only expired rows', () async {
      final now = DateTime.now();
      await db.ordersDao.saveCart(SavedCartsCompanion.insert(
        businessId: businessId,
        name: 'fresh',
        cartData: '{"items": []}',
        expiresAt: Value(now.add(const Duration(hours: 1))),
      ));
      await db.ordersDao.saveCart(SavedCartsCompanion.insert(
        businessId: businessId,
        name: 'stale',
        cartData: '{"items": []}',
        expiresAt: Value(now.subtract(const Duration(hours: 1))),
      ));

      await db.ordersDao.deleteExpiredCarts();

      final remaining =
          (await db.select(db.savedCarts).get()).map((c) => c.name).toList();
      expect(remaining, equals(<String>['fresh']));
    });

    test('saveCart followed by deleteSavedCart coalesces correctly',
        () async {
      // Saving and immediately deleting in the same offline session must
      // not leave the upsert + delete both pending — the delete should
      // supersede the upsert (existing enqueueDelete behaviour for
      // tombstoning).
      final cartId = await db.ordersDao.saveCart(
        SavedCartsCompanion.insert(
          businessId: businessId,
          name: 'Test Cart',
          cartData: '{"items": []}',
        ),
      );
      await db.ordersDao.deleteSavedCart(cartId);

      final pending = await getPendingQueue(db);
      // The upsert should have been swept to 'completed'/'isSynced=true'
      // by enqueueDelete's supersede logic; only the delete remains
      // pending.
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'saved_carts:delete');
    });
  });
}
