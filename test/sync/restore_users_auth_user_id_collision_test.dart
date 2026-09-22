// restore_users_auth_user_id_collision_test.dart
//
// #285 part C — the 2067 itself.
//
// A Supabase login outlives the businesses it belonged to, so the same
// `auth_user_id` can be reused by a new business. When the phone still holds
// the OLD business's `users` row (which carries that login), the incoming row
// for the NEW business has a different id, so `_restoreUsers` inserts it — and
// the local `UNIQUE (auth_user_id)` index rejects it:
//
//   SqliteException(2067): UNIQUE constraint failed: users.auth_user_id
//
// That exception aborts the whole `syncMinimumLogin` pull, which is what the
// user sees as "Signed in, but we could not load your account".
//
// The fix unhooks the login from the stale row rather than failing. The stale
// row itself stays: local history (orders, ledgers, activity logs) points at it.

import 'package:drift/drift.dart' hide isNull, isNotNull;
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

  late String oldBusinessId;
  late String newBusinessId;
  late String staleUserId;

  const authUserId = 'a1b2c3d4-0000-4000-8000-000000000001';
  const email = 'okworchimezie@gmail.com';
  final ts = DateTime.utc(2026, 9, 19, 12).toIso8601String();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));

    oldBusinessId = UuidV7.generate();
    newBusinessId = UuidV7.generate();
    staleUserId = UuidV7.generate();

    for (final id in [oldBusinessId, newBusinessId]) {
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(id: Value(id), name: 'Biz $id'),
          );
    }

    // The phone's leftover row from the older business, still holding the login.
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(staleUserId),
            businessId: oldBusinessId,
            authUserId: const Value(authUserId),
            name: 'Owner',
            email: const Value(email),
            pin: '__HASHED__',
            lastUpdatedAt: Value(DateTime.utc(2026, 9, 19, 12)),
          ),
        );
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test(
    'an incoming row whose login a stale local row holds completes the pull, '
    'and the stale row keeps its id with auth_user_id null',
    () async {
      final incomingUserId = UuidV7.generate();

      await sync.restoreTableDataForTesting('users', [
        {
          'id': incomingUserId,
          'business_id': newBusinessId,
          'auth_user_id': authUserId,
          'name': 'Owner',
          'email': email,
          'store_id': null,
          'created_at': ts,
          'last_updated_at': ts,
        },
      ]);

      final incoming = await (db.select(
        db.users,
      )..where((u) => u.id.equals(incomingUserId))).getSingleOrNull();
      expect(
        incoming,
        isNotNull,
        reason: 'the incoming row must land — this is the 2067 that used to '
            'abort the whole minimum-login pull',
      );
      expect(incoming!.authUserId, authUserId);
      expect(incoming.businessId, newBusinessId);

      final stale = await (db.select(
        db.users,
      )..where((u) => u.id.equals(staleUserId))).getSingleOrNull();
      expect(
        stale,
        isNotNull,
        reason: 'the stale row is kept — local history points at it',
      );
      expect(stale!.authUserId, isNull);
      expect(stale.businessId, oldBusinessId);
    },
  );

  test('re-pulling the same row is a no-op on its own auth_user_id', () async {
    // Newer than the seeded row so it clears the LWW guard and the unhook
    // actually runs — the point of the test is that it skips the row itself.
    final newer = DateTime.utc(2026, 9, 20, 12).toIso8601String();
    final row = {
      'id': staleUserId,
      'business_id': oldBusinessId,
      'auth_user_id': authUserId,
      'name': 'Owner',
      'email': email,
      'store_id': null,
      'created_at': ts,
      'last_updated_at': newer,
    };

    await sync.restoreTableDataForTesting('users', [row]);

    final stale = await (db.select(
      db.users,
    )..where((u) => u.id.equals(staleUserId))).getSingle();
    expect(
      stale.authUserId,
      authUserId,
      reason: 'the unhook must exclude the incoming row itself',
    );
  });
}
