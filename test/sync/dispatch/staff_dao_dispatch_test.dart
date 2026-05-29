import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

/// PIVOT_PLAN step 8A — the new staff-management DAO writes are single-table
/// writes under the normal sync contract (CLAUDE.md §5). These tests lock in
/// that revoke / setStatus / setRole each reach the cloud via enqueueUpsert.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String userId;
  late String ceoRoleId;
  late String cashierRoleId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;

    // FK prerequisites for invite_codes / user_businesses.
    storeId = UuidV7.generate();
    userId = UuidV7.generate();
    ceoRoleId = UuidV7.generate();
    cashierRoleId = UuidV7.generate();

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
            email: const Value('ceo@test.local'),
            pin: '__HASHED__',
          ),
        );
    await db.into(db.roles).insert(
          RolesCompanion.insert(
            id: Value(ceoRoleId),
            businessId: businessId,
            name: 'CEO',
            slug: 'ceo',
          ),
        );
    await db.into(db.roles).insert(
          RolesCompanion.insert(
            id: Value(cashierRoleId),
            businessId: businessId,
            name: 'Cashier',
            slug: 'cashier',
          ),
        );
  });

  tearDown(() => db.close());

  group('InviteCodesDao.revoke', () {
    test('soft-revokes and enqueues an invite_codes:upsert', () async {
      final inviteId = UuidV7.generate();
      await db.inviteCodesDao.insertInvite(
        InviteCodesCompanion.insert(
          id: Value(inviteId),
          businessId: businessId,
          roleId: cashierRoleId,
          code: 'ABCD1234',
          email: 'new@test.local',
          storeId: storeId,
          generatedByUserId: userId,
          expiresAt: DateTime.now().add(const Duration(days: 7)),
        ),
      );
      // Drain the insert upsert so we only observe the revoke.
      await db.delete(db.syncQueue).go();

      await db.inviteCodesDao.revoke(inviteId);

      // Local row carries revokedAt and drops out of watchActive.
      final row = await (db.select(db.inviteCodes)
            ..where((t) => t.id.equals(inviteId)))
          .getSingle();
      expect(row.revokedAt, isNotNull);
      expect(await db.inviteCodesDao.watchActive().first, isEmpty);

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'invite_codes:upsert');
      final payload = decodePayload(pending.first);
      expect(payload['id'], inviteId);
      expect(payload['business_id'], businessId);
      expect(payload['revoked_at'], isNotNull);
    });
  });

  group('UserBusinessesDao', () {
    Future<String> seedMembership() async {
      final membershipId = UuidV7.generate();
      await db.userBusinessesDao.insertMembership(
        UserBusinessesCompanion.insert(
          id: Value(membershipId),
          businessId: businessId,
          userId: userId,
          roleId: ceoRoleId,
        ),
      );
      await db.delete(db.syncQueue).go();
      return membershipId;
    }

    test('setStatus updates status and enqueues a user_businesses:upsert',
        () async {
      final membershipId = await seedMembership();

      await db.userBusinessesDao.setStatus(membershipId, 'suspended');

      final row = await (db.select(db.userBusinesses)
            ..where((t) => t.id.equals(membershipId)))
          .getSingle();
      expect(row.status, 'suspended');

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'user_businesses:upsert');
      final payload = decodePayload(pending.first);
      expect(payload['id'], membershipId);
      expect(payload['business_id'], businessId);
      expect(payload['status'], 'suspended');
    });

    test('setRole updates roleId and enqueues a user_businesses:upsert',
        () async {
      final membershipId = await seedMembership();

      await db.userBusinessesDao.setRole(membershipId, cashierRoleId);

      final row = await (db.select(db.userBusinesses)
            ..where((t) => t.id.equals(membershipId)))
          .getSingle();
      expect(row.roleId, cashierRoleId);

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'user_businesses:upsert');
      final payload = decodePayload(pending.first);
      expect(payload['id'], membershipId);
      expect(payload['business_id'], businessId);
      expect(payload['role_id'], cashierRoleId);
    });
  });
}
