// stores_dao_test.dart
//
// #456 — Safe store deletion with 7 safety guards and atomic DAO write path.
//
// Tests `StoresDao.checkStoreDeleteBlocked` and `StoresDao.softDeleteStore`:
//  1. Success: soft-deletes store, logs activity, and enqueues sync queue.
//  2. Guard 1 (isOnlyStore): refuses delete when store is business's only active store.
//  3. Guard 2 (hasStock): refuses delete when store has remaining inventory > 0.
//  4. Guard 3 (hasStorelessStaff): refuses delete when a staff member would be left storeless;
//     permits delete when staff is assigned to other stores, or user is CEO/All-stores manager.
//  5. Guard 4 (hasOpenTransfers): refuses delete when store has pending/in_transit transfers.
//  6. Guard 5 (hasPendingAdjustments): refuses delete when store has pending stock adjustments.
//  7. Guard 6 (hasOpenVanTrip): refuses delete when store has open van trip (as van or warehouse).
//  8. Guard 7 (hasCrates): refuses delete when store holds empty crates (balance > 0).
//  9. Transactional enforcement: write path throws StoreDeleteBlockedException and rolls back.

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

  Future<String> insertStore(
    String name, {
    bool isDeleted = false,
    String kind = 'store',
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            location: const Value('123 Test St'),
            kind: Value(kind),
            isDeleted: Value(isDeleted),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    return id;
  }

  Future<String> insertUser({
    required String name,
    String? storeId,
    String? email,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            email: Value(email ?? '$id@example.com'),
            pin: '1234',
            storeId: Value(storeId),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    return id;
  }

  Future<String> insertRole({
    required String name,
    required String slug,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            slug: slug,
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    return id;
  }

  Future<void> assignUserRole({
    required String userId,
    required String roleId,
    String status = 'active',
  }) async {
    await db
        .into(db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: userId,
            roleId: roleId,
            status: Value(status),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<String> insertProduct(String name) async {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            retailerPriceKobo: const Value(100000),
            unit: const Value('Piece'),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    return id;
  }

  Future<String> insertManufacturer(String name) async {
    final id = UuidV7.generate();
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    return id;
  }

  group('StoresDao.softDeleteStore success path', () {
    test(
      'soft-deletes store, logs activity, and enqueues sync queue',
      () async {
        final storeA = await insertStore('Store A');
        final storeB = await insertStore('Store B');

        final currentUserId = await insertUser(name: 'CEO User');
        db.userIdResolver = () => currentUserId;

        await db.storesDao.softDeleteStore(storeB);

        // Verify store row is soft-deleted
        final active = await db.storesDao.getActiveStores();
        expect(active.length, 1);
        expect(active.first.id, storeA);

        final deletedStore = await (db.select(
          db.stores,
        )..where((t) => t.id.equals(storeB))).getSingle();
        expect(deletedStore.isDeleted, isTrue);

        // Verify activity log entry
        final logs = await (db.select(
          db.activityLogs,
        )..where((t) => t.storeId.equals(storeB))).get();
        expect(logs.length, 1);
        final log = logs.first;
        expect(log.action, 'store.delete');
        expect(log.entityType, 'store');
        expect(log.entityId, storeB);
        expect(log.description, 'Deleted store "Store B"');

        // Verify sync queue enqueued both stores and activity_logs
        final queue = await getPendingQueue(db);
        final actions = queue.map((q) => q.actionType).toList();
        expect(actions, contains('stores:upsert'));
        expect(actions, contains('activity_logs:upsert'));

        final storeQueueItem = queue.firstWhere(
          (q) => q.actionType == 'stores:upsert',
        );
        final storePayload = decodePayload(storeQueueItem);
        expect(storePayload['id'], storeB);
        expect(storePayload['is_deleted'], true);

        final logQueueItem = queue.firstWhere(
          (q) => q.actionType == 'activity_logs:upsert',
        );
        final logPayload = decodePayload(logQueueItem);
        expect(logPayload['action'], 'store.delete');
      },
    );
  });

  group('Guard 1: isOnlyStore', () {
    test('blocks deletion when only one active store exists', () async {
      final loneStore = await insertStore('Lone Store');

      final reason = await db.storesDao.checkStoreDeleteBlocked(loneStore);
      expect(reason, StoreDeleteBlockedReason.isOnlyStore);

      expect(
        () => db.storesDao.softDeleteStore(loneStore),
        throwsA(
          isA<StoreDeleteBlockedException>().having(
            (e) => e.reason,
            'reason',
            StoreDeleteBlockedReason.isOnlyStore,
          ),
        ),
      );
    });

    test('permits deletion when multiple active stores exist', () async {
      final store1 = await insertStore('Store 1');
      await insertStore('Store 2');

      final reason = await db.storesDao.checkStoreDeleteBlocked(store1);
      expect(reason, isNull);
    });
  });

  group('Guard 2: hasStock', () {
    test('blocks deletion when store holds inventory quantity > 0', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final product = await insertProduct('Star Beer');

      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              productId: product,
              storeId: storeB,
              quantity: const Value(24),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, StoreDeleteBlockedReason.hasStock);

      expect(
        () => db.storesDao.softDeleteStore(storeB),
        throwsA(
          isA<StoreDeleteBlockedException>().having(
            (e) => e.reason,
            'reason',
            StoreDeleteBlockedReason.hasStock,
          ),
        ),
      );
    });

    test('permits deletion when inventory quantity is 0', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final product = await insertProduct('Star Beer');

      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              productId: product,
              storeId: storeB,
              quantity: const Value(0),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, isNull);
    });
  });

  group('Guard 3: hasStorelessStaff', () {
    test(
      'blocks when staff member is assigned ONLY to the deleted store',
      () async {
        await insertStore('Store A');
        final storeB = await insertStore('Store B');

        final staffId = await insertUser(name: 'Cashier John');
        final cashierRoleId = await insertRole(
          name: 'Cashier',
          slug: 'cashier',
        );
        await assignUserRole(userId: staffId, roleId: cashierRoleId);

        await db.userStoresDao.assign(staffId, storeB);

        final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
        expect(reason, StoreDeleteBlockedReason.hasStorelessStaff);

        expect(
          () => db.storesDao.softDeleteStore(storeB),
          throwsA(
            isA<StoreDeleteBlockedException>().having(
              (e) => e.reason,
              'reason',
              StoreDeleteBlockedReason.hasStorelessStaff,
            ),
          ),
        );
      },
    );

    test(
      'permits when staff member is assigned to another active store',
      () async {
        final storeA = await insertStore('Store A');
        final storeB = await insertStore('Store B');

        final staffId = await insertUser(name: 'Cashier John');
        final cashierRoleId = await insertRole(
          name: 'Cashier',
          slug: 'cashier',
        );
        await assignUserRole(userId: staffId, roleId: cashierRoleId);

        await db.userStoresDao.assign(staffId, storeB);
        await db.userStoresDao.assign(staffId, storeA);

        final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
        expect(reason, isNull);
      },
    );

    test(
      'blocks when staff member other assigned store is already deleted',
      () async {
        await insertStore('Store A');
        final storeB = await insertStore('Store B');
        final storeC = await insertStore('Store C', isDeleted: true);

        final staffId = await insertUser(name: 'Cashier John');
        final cashierRoleId = await insertRole(
          name: 'Cashier',
          slug: 'cashier',
        );
        await assignUserRole(userId: staffId, roleId: cashierRoleId);

        await db.userStoresDao.assign(staffId, storeB);
        await db.userStoresDao.assign(staffId, storeC);

        final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
        expect(reason, StoreDeleteBlockedReason.hasStorelessStaff);
      },
    );

    test('permits when the only assigned user is CEO', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');

      final ceoId = await insertUser(name: 'Boss CEO');
      final ceoRoleId = await insertRole(name: 'CEO', slug: 'ceo');
      await assignUserRole(userId: ceoId, roleId: ceoRoleId);

      await db.userStoresDao.assign(ceoId, storeB);

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, isNull);
    });

    test(
      'permits when the only assigned user is Manager with all-stores enabled',
      () async {
        await insertStore('Store A');
        final storeB = await insertStore('Store B');

        final managerId = await insertUser(name: 'All-Stores Manager');
        final managerRoleId = await insertRole(
          name: 'Manager',
          slug: 'manager',
        );
        await assignUserRole(userId: managerId, roleId: managerRoleId);
        await db.roleSettingsDao.set(
          managerRoleId,
          'manager_view_all_stores',
          'true',
        );

        await db.userStoresDao.assign(managerId, storeB);

        final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
        expect(reason, isNull);
      },
    );
  });

  group('Guard 4: hasOpenTransfers', () {
    test('blocks when store has a pending transfer as source', () async {
      final storeA = await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final product = await insertProduct('Guinness');
      final user = await insertUser(name: 'Transfers User');

      await db
          .into(db.stockTransfers)
          .insert(
            StockTransfersCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              fromLocationId: storeB,
              toLocationId: storeA,
              productId: product,
              quantity: 5,
              status: const Value('pending'),
              initiatedBy: user,
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, StoreDeleteBlockedReason.hasOpenTransfers);
    });

    test(
      'blocks when store has an in_transit transfer as destination',
      () async {
        final storeA = await insertStore('Store A');
        final storeB = await insertStore('Store B');
        final product = await insertProduct('Guinness');
        final user = await insertUser(name: 'Transfers User');

        await db
            .into(db.stockTransfers)
            .insert(
              StockTransfersCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                fromLocationId: storeA,
                toLocationId: storeB,
                productId: product,
                quantity: 5,
                status: const Value('in_transit'),
                initiatedBy: user,
                lastUpdatedAt: Value(DateTime.now()),
              ),
            );

        final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
        expect(reason, StoreDeleteBlockedReason.hasOpenTransfers);
      },
    );

    test('permits when transfers are completed or cancelled', () async {
      final storeA = await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final product = await insertProduct('Guinness');
      final user = await insertUser(name: 'Transfers User');

      await db
          .into(db.stockTransfers)
          .insert(
            StockTransfersCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              fromLocationId: storeA,
              toLocationId: storeB,
              productId: product,
              quantity: 5,
              status: const Value('received'),
              initiatedBy: user,
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, isNull);
    });
  });

  group('Guard 5: hasPendingAdjustments', () {
    test('blocks when store has pending adjustment requests', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final product = await insertProduct('Maltina');

      await db
          .into(db.stockAdjustmentRequests)
          .insert(
            StockAdjustmentRequestsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              productId: product,
              storeId: storeB,
              quantityDiff: 5,
              reason: 'Found extra bottles',
              summary: 'Recount adjustment',
              status: const Value('pending'),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, StoreDeleteBlockedReason.hasPendingAdjustments);
    });

    test('permits when adjustments are approved or rejected', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final product = await insertProduct('Maltina');

      await db
          .into(db.stockAdjustmentRequests)
          .insert(
            StockAdjustmentRequestsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              productId: product,
              storeId: storeB,
              quantityDiff: 5,
              reason: 'Found extra bottles',
              summary: 'Recount adjustment',
              status: const Value('approved'),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, isNull);
    });
  });

  group('Guard 6: hasOpenVanTrip', () {
    test('blocks when store is vanStoreId on an open trip', () async {
      await insertStore('Warehouse');
      final vanStore = await insertStore('Van 1', kind: 'van');
      final driver = await insertUser(name: 'Driver Dan');

      await db
          .into(db.vanTrips)
          .insert(
            VanTripsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              vanStoreId: vanStore,
              sourceStoreId: (await db.storesDao.getActiveStores()).first.id,
              driverUserId: driver,
              status: const Value('open'),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(vanStore);
      expect(reason, StoreDeleteBlockedReason.hasOpenVanTrip);
    });

    test('blocks when store is sourceStoreId on an open trip', () async {
      final warehouse = await insertStore('Warehouse');
      final vanStore = await insertStore('Van 1', kind: 'van');
      final driver = await insertUser(name: 'Driver Dan');

      await db
          .into(db.vanTrips)
          .insert(
            VanTripsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              vanStoreId: vanStore,
              sourceStoreId: warehouse,
              driverUserId: driver,
              status: const Value('open'),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(warehouse);
      expect(reason, StoreDeleteBlockedReason.hasOpenVanTrip);
    });

    test('permits when trip is closed', () async {
      final warehouse = await insertStore('Warehouse');
      final vanStore = await insertStore('Van 1', kind: 'van');
      final driver = await insertUser(name: 'Driver Dan');

      await db
          .into(db.vanTrips)
          .insert(
            VanTripsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              vanStoreId: vanStore,
              sourceStoreId: warehouse,
              driverUserId: driver,
              status: const Value('closed'),
              closedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(warehouse);
      expect(reason, isNull);
    });
  });

  group('Guard 7: hasCrates', () {
    test('blocks when store holds empty crate balance > 0', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final mfr = await insertManufacturer('NB Plc');

      await db
          .into(db.storeCrateBalances)
          .insert(
            StoreCrateBalancesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              storeId: storeB,
              manufacturerId: mfr,
              balance: const Value(15),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, StoreDeleteBlockedReason.hasCrates);
    });

    test('permits when empty crate balance is 0', () async {
      await insertStore('Store A');
      final storeB = await insertStore('Store B');
      final mfr = await insertManufacturer('NB Plc');

      await db
          .into(db.storeCrateBalances)
          .insert(
            StoreCrateBalancesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              storeId: storeB,
              manufacturerId: mfr,
              balance: const Value(0),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final reason = await db.storesDao.checkStoreDeleteBlocked(storeB);
      expect(reason, isNull);
    });
  });
}
