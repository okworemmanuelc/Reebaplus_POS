// session_created_at_push_test.dart
//
// Regression for the `sessions:upsert` 23502 seen in Sync Issues after an
// offline→online cycle: SessionsDao.createSession enqueued a companion that
// never set `createdAt`. The column fills locally from its SQL default, but the
// *pushed* payload then omitted `created_at`, so the cloud's NOT NULL constraint
// rejected the upsert ("null value in column created_at"). The fix sets
// createdAt explicitly so it rides into the enqueued payload.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  test('createSession enqueues a sessions:upsert payload that includes '
      'created_at', () async {
    final boot = await bootstrapTestDb();
    try {
      // A session FK-references a user, so seed one.
      final userId = UuidV7.generate();
      await boot.db.into(boot.db.users).insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: boot.businessId,
              name: 'Till User',
              pin: '0000',
            ),
          );

      await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
      );

      final pending = await getPendingQueue(boot.db);
      final sessionRow = pending.firstWhere(
        (r) => r.actionType == 'sessions:upsert',
      );
      final payload = jsonDecode(sessionRow.payload) as Map<String, dynamic>;

      expect(payload.containsKey('created_at'), isTrue,
          reason: 'pushed sessions payload must carry created_at');
      expect(payload['created_at'], isNotNull,
          reason: 'created_at must be non-null or the cloud rejects it (23502)');
    } finally {
      await boot.db.close();
    }
  });
}
