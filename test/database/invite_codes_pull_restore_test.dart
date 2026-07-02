// invite_codes_pull_restore_test.dart
//
// invite_codes was added cloud-side in 0042 and PUSHes from the client (it's
// in `_syncedTenantTables`), but the PULL path (pos_pull_snapshot + _pullOrder
// + _restoreTableData) omitted it (deferred in 0048), so a code created on one
// device never reached the Staff Management → Invites tab on any other device.
// 0053 + the client pull-path change complete the round-trip.
//
// This test feeds a snake_case "cloud" payload (exactly the shape PostgREST /
// pos_pull_snapshot return: snake_case keys, native bools, ISO-8601 UTC
// timestamps) through SupabaseSyncService._restoreTableData (via the
// @visibleForTesting seam) and asserts the row lands in the local Drift DB and
// surfaces in InviteCodesDao.watchActive() (which drives the Invites tab).
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
  late String inviteId;

  final ts = DateTime.utc(2026, 5, 28, 12).toIso8601String();
  // Future expiry so watchActive() (filters on expires_at > now) returns it.
  final futureExpiry = DateTime.utc(2030, 1, 1).toIso8601String();

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
    inviteId = UuidV7.generate();

    // InviteCodesDao.watchActive() is business-scoped (whereBusiness ->
    // requireBusinessId), so bind the resolver the way AuthService does at
    // login. Without it the query throws StateError outside a session.
    db.businessIdResolver = () => businessId;

    // FK parents (foreign_keys = ON in the test DB): business → store → user,
    // plus the role the invite_codes row references.
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
    await db.into(db.roles).insert(
          RolesCompanion.insert(
            id: Value(roleId),
            businessId: businessId,
            name: 'Cashier',
            slug: 'cashier',
          ),
        );
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test('restores an invite_codes row locally and surfaces it in watchActive()',
      () async {
    await sync.restoreTableDataForTesting('invite_codes', [
      {
        'id': inviteId,
        'business_id': businessId,
        'role_id': roleId,
        'code': 'K7M2QXP9',
        'email': 'newstaff@example.com',
        'store_id': storeId,
        'generated_by_user_id': userId,
        'expires_at': futureExpiry,
        'used_by_user_id': null,
        'used_at': null,
        'revoked_at': null,
        'is_deleted': false,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    final rows = await db.select(db.inviteCodes).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, inviteId);
    expect(rows.single.code, 'K7M2QXP9');
    expect(rows.single.email, 'newstaff@example.com');
    expect(rows.single.roleId, roleId);
    expect(rows.single.storeId, storeId);
    expect(rows.single.generatedByUserId, userId);
    expect(rows.single.isDeleted, isFalse);

    // The Invites tab reads watchActive() — a pulled-from-another-device code
    // must show up there, which is the whole point of the round-trip.
    final active = await db.inviteCodesDao.watchActive().first;
    expect(active, hasLength(1));
    expect(active.single.code, 'K7M2QXP9');
  });

  test('used / revoked / expired codes are filtered out of watchActive()',
      () async {
    final pastExpiry = DateTime.utc(2020, 1, 1).toIso8601String();
    Map<String, dynamic> base(String id, String code) => {
          'id': id,
          'business_id': businessId,
          'role_id': roleId,
          'code': code,
          'email': 'x@example.com',
          'store_id': storeId,
          'generated_by_user_id': userId,
          'expires_at': futureExpiry,
          'used_by_user_id': null,
          'used_at': null,
          'revoked_at': null,
          'is_deleted': false,
          'created_at': ts,
          'last_updated_at': ts,
        };

    await sync.restoreTableDataForTesting('invite_codes', [
      base(UuidV7.generate(), 'ACTIVE01'),
      base(UuidV7.generate(), 'USEDCODE')
        ..['used_at'] = ts
        ..['used_by_user_id'] = userId,
      base(UuidV7.generate(), 'REVOKED1')..['revoked_at'] = ts,
      base(UuidV7.generate(), 'EXPIRED1')..['expires_at'] = pastExpiry,
      base(UuidV7.generate(), 'DELETED1')..['is_deleted'] = true,
    ]);

    // All five land in the table (full set pulled)...
    expect(await db.select(db.inviteCodes).get(), hasLength(5));
    // ...but only the active one drives the tab.
    final active = await db.inviteCodesDao.watchActive().first;
    expect(active.map((e) => e.code), ['ACTIVE01']);
  });

  test('restore is idempotent (re-applying the same snapshot is a no-op)',
      () async {
    final row = {
      'id': inviteId,
      'business_id': businessId,
      'role_id': roleId,
      'code': 'K7M2QXP9',
      'email': 'newstaff@example.com',
      'store_id': storeId,
      'generated_by_user_id': userId,
      'expires_at': futureExpiry,
      'used_by_user_id': null,
      'used_at': null,
      'revoked_at': null,
      'is_deleted': false,
      'created_at': ts,
      'last_updated_at': ts,
    };
    await sync.restoreTableDataForTesting('invite_codes', [row]);
    await sync.restoreTableDataForTesting('invite_codes', [row]);

    final rows = await db.select(db.inviteCodes).get();
    expect(rows, hasLength(1), reason: 'upsert keyed on PK id — no dup');
  });
}
