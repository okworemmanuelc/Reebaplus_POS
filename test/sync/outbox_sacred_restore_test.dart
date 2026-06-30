// outbox_sacred_restore_test.dart
//
// Invariant #12 enforcement at the restore/reconcile seams.
//
//   Vector C (clobber prevention): a local row that still has a pending outbox
//   entry must NOT be overwritten by an incoming cloud row, regardless of
//   `last_updated_at`. Non-pending rows still follow timestamp-LWW.
//
//   Vector B (reconcile exclusion): a full-snapshot reconcile that omits a
//   local row must NOT delete it if the row has a pending outbox entry; a
//   genuinely cloud-deleted row (no pending entry) is still removed; a
//   truncated/deferred slice (incompleteTables) does NOT trigger deletions.
//
// Like the sibling reconcile test, only the local DB is touched — a bare
// (unauthenticated) SupabaseClient is enough; no network runs.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;
  late String roleId;

  final oldTs = DateTime.utc(2026, 5, 1, 12).toIso8601String();
  final newTs = DateTime.utc(2026, 6, 1, 12).toIso8601String();

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, supabase);

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

  Map<String, dynamic> permRow(String id, String key, String ts) => {
        'id': id,
        'business_id': businessId,
        'role_id': roleId,
        'permission_key': key,
        'created_at': oldTs,
        'last_updated_at': ts,
      };

  Future<void> markPending(String table, String rowId) async {
    await db.into(db.syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            actionType: '$table:upsert',
            payload: jsonEncode({'id': rowId, 'business_id': businessId}),
          ),
        );
  }

  // ── Vector C: clobber prevention ───────────────────────────────────────────

  test('a pending local row survives an incoming NEWER cloud row', () async {
    final id = UuidV7.generate();
    // Local grant, then an offline edit not yet pushed (pending outbox entry).
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(id, 'sales.make', oldTs)]);
    await markPending('role_permissions', id);

    // The cloud sends a strictly NEWER version of the same row. Without the
    // Invariant #12 guard, timestamp-LWW would overwrite the local pending edit.
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(id, 'sales.void', newTs)]);

    final row = await (db.select(db.rolePermissions)
          ..where((t) => t.id.equals(id)))
        .getSingle();
    expect(row.permissionKey, 'sales.make',
        reason: 'pending row is sacred — never clobbered by the cloud');
  });

  test('a NON-pending local row still follows timestamp-LWW (cloud-newer wins)',
      () async {
    final id = UuidV7.generate();
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(id, 'sales.make', oldTs)]);
    // No pending entry — ordinary cross-device convergence.

    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(id, 'sales.void', newTs)]);

    final row = await (db.select(db.rolePermissions)
          ..where((t) => t.id.equals(id)))
        .getSingle();
    expect(row.permissionKey, 'sales.void',
        reason: 'non-pending rows still take the newer cloud value');
  });

  // ── Vector B: reconcile exclusion ──────────────────────────────────────────

  test('reconcile preserves a pending local row the snapshot omits', () async {
    final keptId = UuidV7.generate();
    final pendingId = UuidV7.generate();
    await sync.restoreTableDataForTesting('role_permissions', [
      permRow(keptId, 'settings.manage', oldTs),
      permRow(pendingId, 'sales.make', oldTs),
    ]);
    // The pending row was created offline and hasn't reached the cloud yet, so
    // the cloud snapshot legitimately omits it — but it must NOT be deleted.
    await markPending('role_permissions', pendingId);

    await sync.reconcileHardDeletesForTesting(businessId, {
      'role_permissions': [permRow(keptId, 'settings.manage', oldTs)],
    });

    final ids =
        (await db.select(db.rolePermissions).get()).map((r) => r.id).toSet();
    expect(ids, contains(keptId));
    expect(ids, contains(pendingId),
        reason: 'a pending (un-pushed) row is never reconciled away');
  });

  test('reconcile still removes a genuinely cloud-deleted (non-pending) row',
      () async {
    final keptId = UuidV7.generate();
    final revokedId = UuidV7.generate();
    await sync.restoreTableDataForTesting('role_permissions', [
      permRow(keptId, 'settings.manage', oldTs),
      permRow(revokedId, 'sales.make', oldTs),
    ]);
    // No pending entry for revokedId → it is genuine cloud truth that it's gone.

    await sync.reconcileHardDeletesForTesting(businessId, {
      'role_permissions': [permRow(keptId, 'settings.manage', oldTs)],
    });

    final ids =
        (await db.select(db.rolePermissions).get()).map((r) => r.id).toSet();
    expect(ids, contains(keptId));
    expect(ids, isNot(contains(revokedId)),
        reason: 'a non-pending absent row is still reconciled away');
  });

  test('a truncated/deferred slice does NOT trigger deletions', () async {
    final id = UuidV7.generate();
    await sync.restoreTableDataForTesting(
        'role_permissions', [permRow(id, 'settings.manage', oldTs)]);

    // The cloud slice arrived EMPTY because the fetch deferred/failed — passing
    // it as `incompleteTables` must make reconcile leave the table alone rather
    // than read the short slice as "everything was deleted".
    await sync.reconcileHardDeletesForTesting(
      businessId,
      {'role_permissions': <dynamic>[]},
      incompleteTables: {'role_permissions'},
    );

    expect(await db.select(db.rolePermissions).get(), hasLength(1),
        reason: 'an incomplete slice must never be read as deletions');
  });
}
