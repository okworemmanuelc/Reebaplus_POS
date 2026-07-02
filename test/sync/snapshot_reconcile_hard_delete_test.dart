// snapshot_reconcile_hard_delete_test.dart
//
// Regression net for the "phantom revoked permission" bug.
//
// Realtime delivers DELETEs only to a live-subscribed device — Supabase never
// replays a missed DELETE — and the pull/snapshot restore path is UPSERT-ONLY
// (an incoming row absent locally is kept, never deleted). So a device that
// missed a live DELETE (offline, backgrounded, or on a pre-fix build) keeps a
// phantom hard-delete row that nothing self-heals: e.g. a CEO revokes a role
// permission (hard-delete via enqueueDelete), but the second device keeps the
// granted-permission row forever.
//
// FIX: on a FULL snapshot pull (since == null), `pullInitialData` runs a
// delete-aware reconcile for the three hard-delete tables only
// (role_permissions, saved_carts, notifications): any local row whose id is not
// in the snapshot's id set for that table is removed (business-scoped,
// LOCAL-ONLY — never enqueued, §5 exception #1).
//
// CRITICAL: reconcile is valid ONLY on a complete snapshot. On an incremental
// delta (since != null) "absent" means "unchanged", not "deleted", so reconcile
// must NOT run — the upsert-only restore path is used there and leaves absent
// rows alone. These tests pin:
//   (1) a full snapshot that omits a previously-present role_permissions row
//       removes it locally;
//   (2) rows for OTHER businesses are untouched;
//   (3) a soft-delete table (roles) is NOT reconcile-deleted;
//   (4) the incremental/upsert restore path does NOT delete absent rows;
//   (5) a table absent from the snapshot payload entirely is left alone.
//
// Like the other restore tests, the reconcile path only touches the local DB, so
// a bare (unauthenticated) SupabaseClient is sufficient — no network is run.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;
  late String roleId;

  final ts = DateTime.utc(2026, 5, 31, 12).toIso8601String();

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));

    roleId = UuidV7.generate();
    await db.into(db.roles).insert(
          RolesCompanion.insert(
            id: Value(roleId),
            businessId: businessId,
            name: 'Manager',
            slug: 'manager',
          ),
        );
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  Map<String, dynamic> permRow(String id, String key) => {
        'id': id,
        'business_id': businessId,
        'role_id': roleId,
        'permission_key': key,
        'created_at': ts,
        'last_updated_at': ts,
      };

  test('full snapshot omitting a role_permissions row removes it locally',
      () async {
    final keptId = UuidV7.generate();
    final revokedId = UuidV7.generate();
    // Both grants present locally (e.g. mirrored from an earlier pull).
    await sync.restoreTableDataForTesting('role_permissions', [
      permRow(keptId, 'settings.manage'),
      permRow(revokedId, 'activity_logs.view'),
    ]);
    expect(await db.select(db.rolePermissions).get(), hasLength(2));

    // The cloud snapshot now holds only the kept grant — the other was revoked
    // (hard-delete) while this device wasn't subscribed.
    await sync.reconcileHardDeletesForTesting(businessId, {
      'role_permissions': [permRow(keptId, 'settings.manage')],
    });

    final rows = await db.select(db.rolePermissions).get();
    expect(rows, hasLength(1),
        reason: 'the revoked grant must be reconciled away');
    expect(rows.single.id, keptId);
  });

  test('reconcile leaves OTHER businesses untouched', () async {
    // A second business with its own role + grant lives on the same device.
    final otherBiz = UuidV7.generate();
    final otherRole = UuidV7.generate();
    final otherPermId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other Biz'),
        );
    await db.into(db.roles).insert(
          RolesCompanion.insert(
            id: Value(otherRole),
            businessId: otherBiz,
            name: 'Manager',
            slug: 'manager',
          ),
        );
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(otherPermId),
            roleId: otherRole,
            permissionKey: 'sales.make',
            businessId: otherBiz,
          ),
        );

    // A grant for OUR business that the snapshot will omit.
    final ourPermId = UuidV7.generate();
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(ourPermId, 'settings.manage')]);
    expect(await db.select(db.rolePermissions).get(), hasLength(2));

    // Empty snapshot slice for OUR business → delete all OUR grants only.
    await sync.reconcileHardDeletesForTesting(businessId, {
      'role_permissions': <dynamic>[],
    });

    final rows = await db.select(db.rolePermissions).get();
    expect(rows, hasLength(1), reason: 'only our business is reconciled');
    expect(rows.single.id, otherPermId,
        reason: 'the other business\'s grant is untouched');
  });

  test('a soft-delete table (roles) is NOT reconcile-deleted', () async {
    // `roles` is a soft-delete table, never a hard-delete reconcile target.
    // Even though the snapshot omits the local role's id, it must survive.
    await sync.reconcileHardDeletesForTesting(businessId, {
      'role_permissions': <dynamic>[],
      'roles': <dynamic>[], // present but omits roleId — must NOT delete it
    });

    final roles = await db.select(db.roles).get();
    expect(roles, hasLength(1),
        reason: 'soft-delete tables are never hard-removed by reconcile');
    expect(roles.single.id, roleId);
  });

  test('incremental/upsert restore path does NOT delete absent rows', () async {
    // The incremental pull (since != null) feeds rows through the upsert-only
    // restore path and never calls reconcile. Pin that the upsert path itself
    // leaves a pre-existing row alone when a later (unrelated) row arrives —
    // i.e. "absent from this delta" never means "delete".
    final existingId = UuidV7.generate();
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(existingId, 'settings.manage')]);
    expect(await db.select(db.rolePermissions).get(), hasLength(1));

    // A delta carrying only a DIFFERENT grant — the existing one is absent.
    final deltaId = UuidV7.generate();
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(deltaId, 'reports.view')]);

    final rows = await db.select(db.rolePermissions).get();
    expect(rows, hasLength(2),
        reason: 'upsert restore must not delete rows absent from the delta');
  });

  test('a table absent from the snapshot payload entirely is left alone',
      () async {
    final permId = UuidV7.generate();
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(permId, 'settings.manage')]);
    expect(await db.select(db.rolePermissions).get(), hasLength(1));

    // Partial/failed snapshot: role_permissions key never arrived. Reconcile
    // must NOT wipe on the strength of a slice that simply didn't come.
    await sync.reconcileHardDeletesForTesting(businessId, {
      'notifications': <dynamic>[],
    });

    expect(await db.select(db.rolePermissions).get(), hasLength(1),
        reason: 'absent table key ⇒ no reconcile ⇒ no wipe');
  });
}
