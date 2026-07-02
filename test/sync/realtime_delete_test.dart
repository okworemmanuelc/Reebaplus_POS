// realtime_delete_test.dart
//
// Regression net for the dropped realtime-DELETE bug.
//
// SupabaseSyncService.startRealtimeSync subscribed to PostgresChangeEvent.all
// but only ever processed `payload.newRecord` (INSERT/UPDATE upserts via
// _restoreTableData). A DELETE event carries the row in `oldRecord` and an
// EMPTY `newRecord`, so realtime DELETEs were silently dropped — the local row
// was never removed. Symptom: a CEO revokes a role permission (hard-delete via
// enqueueDelete), the cloud deletes it, but the local row lingers — and a stale
// INSERT echo of the prior grant resurrects it permanently. The toggle would
// not "disable back".
//
// The three hard-delete tables (the only `enqueueDelete` call sites) are
// role_permissions, saved_carts, notifications. These tests pin that an
// incoming DELETE is now applied locally for each, that the resurrection race
// converges to "deleted", and that an unhandled table is a safe no-op.
//
// Like roles_pull_restore_test, the delete path only touches the local DB, so a
// bare (unauthenticated) SupabaseClient is sufficient — no network is exercised.

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
  late String roleId;

  final ts = DateTime.utc(2026, 5, 31, 12).toIso8601String();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));

    businessId = UuidV7.generate();
    roleId = UuidV7.generate();

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
        );
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

  test('realtime DELETE removes a role_permission row locally', () async {
    final permId = UuidV7.generate();
    // Mirror a cloud grant arriving via realtime/pull (INSERT echo).
    await sync.restoreTableDataForTesting('role_permissions', [
      {
        'id': permId,
        'business_id': businessId,
        'role_id': roleId,
        'permission_key': 'settings.manage',
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);
    expect(await db.select(db.rolePermissions).get(), hasLength(1));

    // The revoke's DELETE echo must now actually remove the local row.
    await sync.deleteLocalRowByIdForTesting('role_permissions', permId);
    expect(await db.select(db.rolePermissions).get(), isEmpty,
        reason: 'realtime DELETE must remove the local row');
  });

  test('resurrection race converges to deleted (stale INSERT echo, then DELETE)',
      () async {
    final permId = UuidV7.generate();
    final row = {
      'id': permId,
      'business_id': businessId,
      'role_id': roleId,
      'permission_key': 'settings.manage',
      'created_at': ts,
      'last_updated_at': ts,
    };

    // 1) grant → local insert (simulated), 2) revoke → local delete,
    // 3) STALE INSERT echo of the grant resurrects the row,
    // 4) DELETE echo of the revoke must clean it up. Final state: deleted.
    await sync.restoreTableDataForTesting('role_permissions', [row]); // insert
    await sync.deleteLocalRowByIdForTesting('role_permissions', permId); // revoke
    await sync.restoreTableDataForTesting('role_permissions', [row]); // stale echo
    expect(await db.select(db.rolePermissions).get(), hasLength(1),
        reason: 'stale INSERT echo resurrects the row (pre-fix end state)');

    await sync.deleteLocalRowByIdForTesting('role_permissions', permId);
    expect(await db.select(db.rolePermissions).get(), isEmpty,
        reason: 'DELETE echo converges local state to the cloud (deleted)');
  });

  test('realtime DELETE removes a saved_cart row locally', () async {
    final cartId = UuidV7.generate();
    await db.into(db.savedCarts).insert(
          SavedCartsCompanion.insert(
            id: Value(cartId),
            businessId: businessId,
            name: 'Held cart',
            cartData: '[]',
          ),
        );
    expect(await db.select(db.savedCarts).get(), hasLength(1));

    await sync.deleteLocalRowByIdForTesting('saved_carts', cartId);
    expect(await db.select(db.savedCarts).get(), isEmpty);
  });

  test('realtime DELETE removes a notification row locally', () async {
    final notifId = UuidV7.generate();
    await db.into(db.notifications).insert(
          NotificationsCompanion.insert(
            id: Value(notifId),
            businessId: businessId,
            type: 'low_stock',
            message: 'Running low',
          ),
        );
    expect(await db.select(db.notifications).get(), hasLength(1));

    await sync.deleteLocalRowByIdForTesting('notifications', notifId);
    expect(await db.select(db.notifications).get(), isEmpty);
  });

  test('realtime DELETE removes a user_stores row locally', () async {
    // §9.5 staff store-assignment: un-assign hard-deletes the junction row
    // (enqueueDelete), so the DELETE echo must remove it on other devices.
    final storeId = UuidV7.generate();
    final userId = UuidV7.generate();
    final assignId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Store 1',
          ),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Cashier',
            pin: 'hash',
          ),
        );
    await db.into(db.userStores).insert(
          UserStoresCompanion.insert(
            id: Value(assignId),
            businessId: businessId,
            userId: userId,
            storeId: storeId,
          ),
        );
    expect(await db.select(db.userStores).get(), hasLength(1));

    await sync.deleteLocalRowByIdForTesting('user_stores', assignId);
    expect(await db.select(db.userStores).get(), isEmpty,
        reason: 'realtime DELETE must remove the local user_stores row');
  });

  test('realtime DELETE on an unhandled table is a safe no-op', () async {
    // Soft-delete tables never emit a true DELETE; if one ever did, the handler
    // must not throw. (roles is not a hard-delete table.)
    await sync.deleteLocalRowByIdForTesting('roles', roleId);
    expect(await db.select(db.roles).get(), hasLength(1),
        reason: 'unhandled table is logged, not applied');
  });
}
