// roles_pull_restore_test.dart
//
// Task A (PIVOT_PLAN step 5): the 5 role/membership tenant tables
// (roles, role_permissions, role_settings, user_businesses, user_stores)
// were added cloud-side in v13/0042 and PUSH from the client, but the PULL
// path (pos_pull_snapshot + _pullOrder + _restoreTableData) omitted them, so
// a fresh device never received them locally.
//
// This test feeds a snake_case "cloud" payload (exactly the shape PostgREST /
// pos_pull_snapshot return: snake_case keys, native bools, ISO-8601 UTC
// timestamps) through SupabaseSyncService._restoreTableData (via the
// @visibleForTesting seam) and asserts each table lands in the local Drift DB.
//
// The restore path only touches the local DB, so a bare (unauthenticated)
// SupabaseClient is sufficient — no network is exercised.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;

  late String businessId;
  late String storeId;
  late String userId;
  late String roleId;

  final ts = DateTime.utc(2026, 5, 28, 12).toIso8601String();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // Bare client — restore never calls it, but the constructor requires one.
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));

    businessId = UuidV7.generate();
    storeId = UuidV7.generate();
    userId = UuidV7.generate();
    roleId = UuidV7.generate();

    // FK parents (foreign_keys = ON in the test DB): business → store → user.
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'CEO',
            email: const Value('ceo@example.com'),
            pin: kSetupRequiredPin,
          ),
        );
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test('restores roles → role_settings/role_permissions → user_* locally',
      () async {
    // FK-safe order, same as _pullOrder: roles first, then its dependents.
    await sync.restoreTableDataForTesting('roles', [
      {
        'id': roleId,
        'business_id': businessId,
        'name': 'CEO',
        'slug': 'ceo',
        'is_system_default': true,
        'is_deleted': false,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    await sync.restoreTableDataForTesting('role_permissions', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'role_id': roleId,
        'permission_key': 'sales.make',
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    await sync.restoreTableDataForTesting('role_settings', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'role_id': roleId,
        'setting_key': 'max_discount_percent',
        'setting_value': '100',
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    await sync.restoreTableDataForTesting('user_businesses', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'user_id': userId,
        'role_id': roleId,
        'status': 'active',
        'last_login_at': null,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    await sync.restoreTableDataForTesting('user_stores', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'user_id': userId,
        'store_id': storeId,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    final roles = await db.select(db.roles).get();
    expect(roles, hasLength(1));
    expect(roles.single.slug, 'ceo');
    expect(roles.single.isSystemDefault, isTrue);

    final perms = await db.select(db.rolePermissions).get();
    expect(perms, hasLength(1));
    expect(perms.single.roleId, roleId);
    expect(perms.single.permissionKey, 'sales.make');

    final settings = await db.select(db.roleSettings).get();
    expect(settings, hasLength(1));
    expect(settings.single.settingKey, 'max_discount_percent');
    expect(settings.single.settingValue, '100');

    final memberships = await db.select(db.userBusinesses).get();
    expect(memberships, hasLength(1));
    expect(memberships.single.userId, userId);
    expect(memberships.single.roleId, roleId);
    expect(memberships.single.status, 'active');

    final userStores = await db.select(db.userStores).get();
    expect(userStores, hasLength(1));
    expect(userStores.single.userId, userId);
    expect(userStores.single.storeId, storeId);
  });

  test('restore is idempotent (re-applying the same snapshot is a no-op)',
      () async {
    final roleRow = {
      'id': roleId,
      'business_id': businessId,
      'name': 'Manager',
      'slug': 'manager',
      'is_system_default': true,
      'is_deleted': false,
      'created_at': ts,
      'last_updated_at': ts,
    };
    await sync.restoreTableDataForTesting('roles', [roleRow]);
    await sync.restoreTableDataForTesting('roles', [roleRow]);

    final roles = await db.select(db.roles).get();
    expect(roles, hasLength(1), reason: 'upsert keyed on PK id — no dup');
    expect(roles.single.slug, 'manager');
  });
}
