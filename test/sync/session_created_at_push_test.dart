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

  // Regression for the Sync Issues `sessions:upsert` churn: re-auth on the same
  // device used to mint a fresh session id each time, defeating enqueueUpsert's
  // coalescing (keyed on payload.id) and piling up one outbox row per login.
  // createSession now reuses the existing active session for the same
  // device+user, so repeat calls collapse to a single row + single queue entry.
  test('createSession reuses the active session for the same device+user '
      '(one row, one coalesced queue entry)', () async {
    final boot = await bootstrapTestDb();
    try {
      final userId = UuidV7.generate();
      await boot.db.into(boot.db.users).insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: boot.businessId,
              name: 'Till User',
              pin: '0000',
            ),
          );

      const deviceId = 'device-abc';
      final firstId = await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
        deviceId: deviceId,
      );
      final secondId = await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
        deviceId: deviceId,
      );

      expect(secondId, firstId,
          reason: 'a re-auth on the same device must reuse the session id');

      final rows = await boot.db.select(boot.db.sessions).get();
      expect(rows.length, 1,
          reason: 'reuse must not create a second sessions row');

      final pending = await getPendingQueue(boot.db);
      final sessionPushes =
          pending.where((r) => r.actionType == 'sessions:upsert').toList();
      expect(sessionPushes.length, 1,
          reason: 'the re-enqueue must coalesce into one pending push');
    } finally {
      await boot.db.close();
    }
  });

  // A revoked (kicked / logged-out) session must NOT be reused — a real
  // re-login after a kick legitimately starts a fresh session.
  test('createSession mints a fresh session when the prior one is revoked',
      () async {
    final boot = await bootstrapTestDb();
    try {
      final userId = UuidV7.generate();
      await boot.db.into(boot.db.users).insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: boot.businessId,
              name: 'Till User',
              pin: '0000',
            ),
          );

      const deviceId = 'device-abc';
      final firstId = await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
        deviceId: deviceId,
      );
      await boot.db.sessionsDao.revokeSession(firstId);

      final secondId = await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
        deviceId: deviceId,
      );

      expect(secondId, isNot(firstId),
          reason: 'a revoked session must not be reused');
      final rows = await boot.db.select(boot.db.sessions).get();
      expect(rows.length, 2, reason: 'the fresh login is a new session row');
    } finally {
      await boot.db.close();
    }
  });

  test('multiple sessions can coexist concurrently for the same user on different devices', () async {
    final boot = await bootstrapTestDb();
    try {
      final userId = UuidV7.generate();
      await boot.db.into(boot.db.users).insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: boot.businessId,
              name: 'Till User',
              pin: '0000',
            ),
          );

      final firstId = await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
        deviceId: 'device-1',
      );
      final secondId = await boot.db.sessionsDao.createSession(
        userId: userId,
        ttl: const Duration(days: 30),
        deviceId: 'device-2',
      );

      expect(firstId, isNot(secondId),
          reason: 'sessions on different devices must have unique IDs');

      final active1 = await boot.db.sessionsDao.findActiveSession(firstId);
      final active2 = await boot.db.sessionsDao.findActiveSession(secondId);

      expect(active1, isNotNull, reason: 'first device session must still be active');
      expect(active2, isNotNull, reason: 'second device session must be active');

      final rows = await boot.db.select(boot.db.sessions).get();
      expect(rows.length, 2, reason: 'two distinct active sessions should exist in local DB');
    } finally {
      await boot.db.close();
    }
  });
}
