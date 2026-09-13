// first_store_write_path_test.dart
//
// #231 — Atomic first-store write path and empty states.
//
// Tests `StoresDao.createStore`:
//  1. Stores table row is created with `kind: 'store'`, name, location, businessId.
//  2. `user_stores` binding is inserted for the creating user.
//  3. `users.store_id` is updated if currently null or empty.
//  4. `users.store_id` is NOT overwritten if already assigned to another store, but `user_stores` is still bound.
//  5. `activity_logs` entry is written with `action: 'store.create'`.
//  6. All modified tables are enqueued to `sync_queue` for cloud sync.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() async => db.close());

  Future<UserData> insertTestUser({
    required String id,
    String? storeId,
  }) async {
    final user = UsersCompanion.insert(
      id: Value(id),
      businessId: businessId,
      name: 'Test User',
      email: Value('$id@test.com'),
      pin: '1234',
      storeId: Value(storeId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await db.into(db.users).insert(user);
    return (db.select(db.users)..where((t) => t.id.equals(id))).getSingle();
  }

  group('StoresDao.createStore atomic write path', () {
    test('creates store, binds user_stores, sets users.store_id when null, logs activity, and enqueues sync', () async {
      final userId = UuidV7.generate();
      await insertTestUser(id: userId, storeId: null);

      final storeId = await db.storesDao.createStore(
        name: 'Main Store',
        location: 'Lagos, Nigeria',
        userId: userId,
      );

      // 1. Verify store row
      final storeRow = await (db.select(db.stores)..where((t) => t.id.equals(storeId))).getSingle();
      expect(storeRow.name, 'Main Store');
      expect(storeRow.location, 'Lagos, Nigeria');
      expect(storeRow.kind, 'store');
      expect(storeRow.businessId, businessId);
      expect(storeRow.isDeleted, isFalse);

      // 2. Verify user_stores row
      final userStoreRows = await (db.select(db.userStores)
            ..where((t) => t.userId.equals(userId) & t.storeId.equals(storeId)))
          .get();
      expect(userStoreRows.length, 1);
      expect(userStoreRows.first.businessId, businessId);

      // 3. Verify users.store_id was assigned
      final updatedUser = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingle();
      expect(updatedUser.storeId, storeId);

      // 4. Verify activity log
      final activityRows = await (db.select(db.activityLogs)
            ..where((t) => t.action.equals('store.create')))
          .get();
      expect(activityRows.length, 1);
      expect(activityRows.first.userId, userId);
      expect(activityRows.first.entityId, storeId);
      expect(activityRows.first.entityType, 'store');
      expect(activityRows.first.description, contains('Main Store'));

      // 5. Verify sync_queue entries
      final queue = await getPendingQueue(db);
      final actions = queue.map((q) => q.actionType).toList();
      expect(actions, contains('stores:upsert'));
      expect(actions, contains('user_stores:upsert'));
      expect(actions, contains('users:upsert'));
      expect(actions, contains('activity_logs:upsert'));
    });

    test('preserves existing users.store_id if user already has one assigned', () async {
      final existingStoreId = await db.storesDao.createStore(name: 'Initial Store');

      final userId = UuidV7.generate();
      await insertTestUser(id: userId, storeId: existingStoreId);

      final newStoreId = await db.storesDao.createStore(
        name: 'Second Store',
        location: 'Abuja, Nigeria',
        userId: userId,
      );

      // user_stores should still get the second store
      final userStoreRows = await (db.select(db.userStores)
            ..where((t) => t.userId.equals(userId) & t.storeId.equals(newStoreId)))
          .get();
      expect(userStoreRows.length, 1);

      // users.store_id should remain unchanged
      final user = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingle();
      expect(user.storeId, existingStoreId);

      // users table should NOT have a sync entry for store_id change
      final queue = await getPendingQueue(db);
      final userSyncs = queue.where((q) => q.actionType == 'users:upsert').toList();
      expect(userSyncs, isEmpty);
    });

    test('works gracefully when userId is null', () async {
      final storeId = await db.storesDao.createStore(
        name: 'Unassigned Store',
        location: null,
        userId: null,
      );

      final storeRow = await (db.select(db.stores)..where((t) => t.id.equals(storeId))).getSingle();
      expect(storeRow.name, 'Unassigned Store');
      expect(storeRow.location, isNull);

      final userStores = await db.select(db.userStores).get();
      expect(userStores, isEmpty);

      final queue = await getPendingQueue(db);
      final actions = queue.map((q) => q.actionType).toList();
      expect(actions, contains('stores:upsert'));
      expect(actions, contains('activity_logs:upsert'));
      expect(actions, isNot(contains('user_stores:upsert')));
      expect(actions, isNot(contains('users:upsert')));
    });
  });

  group('StoresDao.updateStore', () {
    test('updates store name and location, enqueues sync (coalesced with create)', () async {
      final storeId = await db.storesDao.createStore(
        name: 'Old Name',
        location: 'Old Loc',
      );

      await db.storesDao.updateStore(
        id: storeId,
        name: 'New Name',
        location: 'New Loc',
      );

      final updated = await (db.select(db.stores)..where((t) => t.id.equals(storeId))).getSingle();
      expect(updated.name, 'New Name');
      expect(updated.location, 'New Loc');

      final queue = await getPendingQueue(db);
      final storeSyncs = queue.where((q) => q.actionType == 'stores:upsert').toList();
      // Coalesced into a single pending upsert carrying the newest values
      expect(storeSyncs.length, 1);
      expect(decodePayload(storeSyncs.single)['name'], 'New Name');
      expect(decodePayload(storeSyncs.single)['location'], 'New Loc');
    });
  });
}
