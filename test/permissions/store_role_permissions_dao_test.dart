import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// `StoreRolePermissionsDao` — the per-store role permission overrides behind
/// the §10.2.1 Store scope (Item D). A row forces a permission on/off for a
/// (store, role); absence inherits the business default. Same hard-delete +
/// tombstone contract as `user_permission_overrides` (0090), so a cleared
/// override propagates live to other devices.
void main() {
  late AppDatabase db;
  late String businessId;
  const storeA = 'store-aaaa';
  const storeB = 'store-bbbb';
  const roleCashier = 'role-cashier';

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    for (final s in const [(storeA, 'Main'), (storeB, 'Branch')]) {
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(s.$1),
              businessId: businessId,
              name: s.$2,
            ),
          );
    }
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: const Value(roleCashier),
            businessId: businessId,
            name: 'Cashier',
            slug: 'cashier',
          ),
        );
  });

  tearDown(() async => db.close());

  test('setOverride inserts a row and enqueues an upsert', () async {
    final dao = db.storeRolePermissionsDao;
    await dao.setOverride(storeA, roleCashier, 'cost.view', false);

    final rows = await dao.getFor(storeA, roleCashier);
    expect(rows.length, 1);
    expect(rows.first.isGranted, isFalse);

    final upserts = (await getPendingQueue(
      db,
    )).where((q) => q.actionType == 'store_role_permissions:upsert').toList();
    expect(upserts.length, 1);
  });

  test('setOverride(null) clears the row and tombstones it', () async {
    final dao = db.storeRolePermissionsDao;
    // Seed directly (as if pulled / already synced) so the clear is a clean
    // tombstone with no pending upsert to coalesce away.
    await db
        .into(db.storeRolePermissions)
        .insert(
          StoreRolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            storeId: storeA,
            roleId: roleCashier,
            permissionKey: 'cost.view',
            isGranted: false,
          ),
        );

    await dao.setOverride(storeA, roleCashier, 'cost.view', null);

    expect(await dao.getFor(storeA, roleCashier), isEmpty);
    final deletes = (await getPendingQueue(
      db,
    )).where((q) => q.actionType == 'store_role_permissions:delete').toList();
    expect(
      deletes.length,
      1,
      reason:
          'clearing an override hard-deletes + tombstones so the removal '
          'propagates live to other devices',
    );
  });

  test(
    'overrides are scoped per (store, role) — store B is untouched',
    () async {
      final dao = db.storeRolePermissionsDao;
      await dao.setOverride(storeA, roleCashier, 'cost.view', false);
      await dao.setOverride(storeB, roleCashier, 'cost.view', true);

      final a = await dao.getFor(storeA, roleCashier);
      final b = await dao.getFor(storeB, roleCashier);
      expect(a.single.isGranted, isFalse);
      expect(
        b.single.isGranted,
        isTrue,
        reason: 'a different store keeps its own override',
      );
    },
  );

  test('setOverride is idempotent on the logical (store, role, key)', () async {
    final dao = db.storeRolePermissionsDao;
    await dao.setOverride(storeA, roleCashier, 'cost.view', false);
    // Same value again → no duplicate row, no UNIQUE trip.
    await dao.setOverride(storeA, roleCashier, 'cost.view', false);
    expect((await dao.getFor(storeA, roleCashier)).length, 1);

    // Flip the value → updates the existing row in place.
    await dao.setOverride(storeA, roleCashier, 'cost.view', true);
    final rows = await dao.getFor(storeA, roleCashier);
    expect(rows.length, 1);
    expect(rows.first.isGranted, isTrue);
  });

  test(
    'clearAllForStoreRole removes only that store+role and counts them',
    () async {
      final dao = db.storeRolePermissionsDao;
      await dao.setOverride(storeA, roleCashier, 'cost.view', false);
      await dao.setOverride(storeA, roleCashier, 'sales.discount', false);
      await dao.setOverride(storeB, roleCashier, 'cost.view', true);

      final cleared = await dao.clearAllForStoreRole(storeA, roleCashier);

      expect(cleared, 2);
      expect(await dao.getFor(storeA, roleCashier), isEmpty);
      expect(
        (await dao.getFor(storeB, roleCashier)).length,
        1,
        reason: 'another store\'s overrides are untouched',
      );
    },
  );
}
