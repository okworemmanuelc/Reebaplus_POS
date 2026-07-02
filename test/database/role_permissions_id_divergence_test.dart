// role_permissions_id_divergence_test.dart
//
// Regression net for SqliteException(2067) "UNIQUE constraint failed:
// role_permissions.role_id, role_permissions.permission_key".
//
// role_permissions rows carry a random per-grant `id` (PK), but their LOGICAL
// identity is (role_id, permission_key) — enforced by a second UNIQUE
// constraint. A grant→revoke→re-grant cycle, or two devices granting the same
// permission, mint different ids for the SAME pair. The old code upserted on
// `id` everywhere, so when the restore path met a cloud row whose id differed
// from the local row for that pair, the id-keyed insertOnConflictUpdate tripped
// UNIQUE(role_id, permission_key) and crashed the app (the user hit this
// toggling Activity Logs access for Manager).
//
// Two fixes are pinned here:
//   (A) RolePermissionsDao.grant is idempotent on (role_id, permission_key) —
//       a blind insert with a fresh UUID would itself throw 2067.
//   (B) _restoreTableData('role_permissions', ...) drops any local row with the
//       same logical key but a different id before applying the incoming row,
//       so a divergent cloud id converges instead of crashing.

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

  const permKey = 'activity_logs.view';
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

  test('grant is idempotent on (role_id, permission_key) — no 2067', () async {
    await db.rolePermissionsDao.grant(roleId, permKey);
    // Second grant for the same pair must NOT throw and must NOT duplicate.
    await db.rolePermissionsDao.grant(roleId, permKey);

    final rows = await db.select(db.rolePermissions).get();
    expect(rows, hasLength(1));
    expect(rows.single.permissionKey, permKey);

    // Only the first grant enqueued an upsert; the second was a no-op.
    final pending = await getPendingQueue(db);
    expect(pending.where((p) => p.actionType == 'role_permissions:upsert'),
        hasLength(1));
  });

  test('restore converges a divergent cloud id instead of crashing', () async {
    // Local grant mints its own id (the "local" id).
    await db.rolePermissionsDao.grant(roleId, permKey);
    final localId = (await db.select(db.rolePermissions).get()).single.id;

    // The cloud holds the SAME pair under a DIFFERENT id (e.g. an earlier
    // session / another device). Pre-fix, this insertOnConflictUpdate(cloudId)
    // threw SqliteException(2067) on UNIQUE(role_id, permission_key).
    final cloudId = UuidV7.generate();
    expect(cloudId == localId, isFalse);

    await sync.restoreTableDataForTesting('role_permissions', [
      {
        'id': cloudId,
        'business_id': businessId,
        'role_id': roleId,
        'permission_key': permKey,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    final rows = await db.select(db.rolePermissions).get();
    expect(rows, hasLength(1), reason: 'no duplicate for the same pair');
    expect(rows.single.id, cloudId,
        reason: 'device converges on the cloud id');
  });

  test('restore with the same id stays idempotent', () async {
    final row = {
      'id': UuidV7.generate(),
      'business_id': businessId,
      'role_id': roleId,
      'permission_key': permKey,
      'created_at': ts,
      'last_updated_at': ts,
    };
    await sync.restoreTableDataForTesting('role_permissions', [row]);
    await sync.restoreTableDataForTesting('role_permissions', [row]);
    expect(await db.select(db.rolePermissions).get(), hasLength(1));
  });
}
