// self_resign_test.dart
//
// Staff offboarding — self-resign & admin-removed device reaction (#117).
// Client-observable surfaces (the server RPC `resign_own_membership` is SQL and
// validated by review against 0149, not here):
//
//   * canSelfResign / isOwnerRole — the OWNER (CEO) has no resign path (sees
//     Delete Business instead); every other staff member can leave; neither
//     flashes while the role is still resolving (null).
//   * membershipStatusReaction — the pure mapping the main.dart live guard uses:
//     an admin-removed membership (`removed`) → offboard (gate → logout);
//     `suspended` → lockToPicker; everything else → none.
//   * the local `removed` flip (markRemovedLocal, as applied by a pull) drives
//     the offboard reaction — the admin-removed detection decision.
//   * the sole-member wipe gate's three branches, at the DAO-signal level that
//     resignOwnMembership / logOutCurrentUser decide on: retryable rows → block
//     (LogoutWipeException), orphans only → Resolve-unsynced-data
//     (LogoutBlockedByUnsyncedDataException), clean → proceed.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/auth/membership_status_reaction.dart';
import 'package:reebaplus_pos/features/profile/self_resign.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

RoleData _role(String slug) => RoleData(
      id: UuidV7.generate(),
      businessId: UuidV7.generate(),
      name: slug.toUpperCase(),
      slug: slug,
      isSystemDefault: true,
      isDeleted: false,
      createdAt: DateTime.now(),
      lastUpdatedAt: DateTime.now(),
    );

void main() {
  // ── Owner-exclusion predicates (AC: owner has no resign path) ────────────

  group('canSelfResign / isOwnerRole', () {
    test('the owner (CEO) cannot resign and is the Delete-Business role', () {
      final ceo = _role('ceo');
      expect(canSelfResign(ceo), isFalse);
      expect(isOwnerRole(ceo), isTrue);
    });

    test('every non-owner staff role can self-resign', () {
      for (final slug in ['manager', 'cashier', 'stock_keeper']) {
        expect(canSelfResign(_role(slug)), isTrue, reason: '$slug may resign');
        expect(isOwnerRole(_role(slug)), isFalse);
      }
    });

    test('an unresolved role (null) shows neither action', () {
      expect(canSelfResign(null), isFalse);
      expect(isOwnerRole(null), isFalse);
    });
  });

  // ── Membership-status reaction (AC: admin-removed → logout) ──────────────

  group('membershipStatusReaction', () {
    test('removed → offboard (admin-removed device reaction)', () {
      expect(membershipStatusReaction('removed'),
          MembershipStatusReaction.offboard);
    });

    test('suspended → lockToPicker', () {
      expect(membershipStatusReaction('suspended'),
          MembershipStatusReaction.lockToPicker);
    });

    test('active / null / unknown → none', () {
      expect(membershipStatusReaction('active'), MembershipStatusReaction.none);
      expect(membershipStatusReaction(null), MembershipStatusReaction.none);
      expect(membershipStatusReaction('whatever'),
          MembershipStatusReaction.none);
    });
  });

  // ── Admin-removed detection: a pulled `removed` flip drives offboard ──────

  group('admin-removed detection', () {
    late AppDatabase db;
    late String biz;
    late String cashierRoleId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      biz = UuidV7.generate();
      await db
          .into(db.businesses)
          .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Biz'));
      cashierRoleId = UuidV7.generate();
      await db.into(db.roles).insert(RolesCompanion.insert(
          id: Value(cashierRoleId),
          businessId: biz,
          name: 'Cashier',
          slug: 'cashier'));
    });

    tearDown(() => db.close());

    test(
        'markRemovedLocal (the pull-applied flip) yields a `removed` status '
        'whose reaction is offboard', () async {
      final userId = UuidV7.generate();
      await db.into(db.users).insert(UsersCompanion.insert(
            id: Value(userId),
            businessId: biz,
            name: 'Removed Rita',
            pin: '__HASHED__',
          ));
      final membershipId = UuidV7.generate();
      await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
            id: Value(membershipId),
            businessId: biz,
            userId: userId,
            roleId: cashierRoleId,
            status: const Value('active'),
          ));

      // Before removal: active → no reaction.
      var m = await (db.select(db.userBusinesses)
            ..where((t) => t.id.equals(membershipId)))
          .getSingle();
      expect(membershipStatusReaction(m.status),
          MembershipStatusReaction.none);

      // A pull applying the admin's `remove_staff_member` result flips the row.
      await db.userBusinessesDao.markRemovedLocal(membershipId);

      m = await (db.select(db.userBusinesses)
            ..where((t) => t.id.equals(membershipId)))
          .getSingle();
      expect(m.status, 'removed');
      expect(membershipStatusReaction(m.status),
          MembershipStatusReaction.offboard,
          reason: 'the removed device must run the offboarding gate → logout');
    });
  });

  // ── Sole-member wipe gate — three branches (DAO signals + exceptions) ─────

  group('sole-member wipe gate branches', () {
    late AppDatabase db;
    late String biz;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      biz = UuidV7.generate();
      await db
          .into(db.businesses)
          .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Biz'));
      db.businessIdResolver = () => biz;
    });

    tearDown(() => db.close());

    Future<void> enqueuePending() async {
      await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
            businessId: biz,
            actionType: 'orders:upsert',
            payload: '{"id":"fake"}',
          ));
    }

    Future<void> enqueueOrphan() async {
      await db.into(db.syncQueueOrphans).insert(
            SyncQueueOrphansCompanion.insert(
              originalId: UuidV7.generate(),
              actionType: 'orders:upsert',
              payload: '{"business_id":"$biz"}',
              reason: 'rls_denied',
            ),
          );
    }

    test('clean → proceed: both counts zero (safe to wipe)', () async {
      expect(await db.syncDao.countPending(businessId: biz), 0);
      expect(await db.syncDao.countOrphans(businessId: biz), 0);
    });

    test(
        'retryable → block: a pending row makes countPending > 0 (caller throws '
        'LogoutWipeException)', () async {
      await enqueuePending();
      expect(await db.syncDao.countPending(businessId: biz), greaterThan(0));

      // The gate raises LogoutWipeException when retryable rows remain.
      const ex = LogoutWipeException('You have 1 change not yet synced.');
      expect(ex.message, contains('not yet synced'));
      expect(ex.toString(), ex.message);
    });

    test(
        'orphans only → Resolve-unsynced-data: countOrphans > 0 while '
        'countPending == 0 (caller throws LogoutBlockedByUnsyncedDataException)',
        () async {
      await enqueueOrphan();
      await enqueueOrphan();
      expect(await db.syncDao.countPending(businessId: biz), 0);
      expect(await db.syncDao.countOrphans(businessId: biz), 2);

      // The gate raises the routing exception carrying the counts the Resolve
      // dialog renders.
      const ex = LogoutBlockedByUnsyncedDataException(
          pendingCount: 0, orphanCount: 2);
      expect(ex.pendingCount, 0);
      expect(ex.orphanCount, 2);
      expect(ex.totalCount, 2);
    });

    test('StaffResignException carries its plain-English message', () {
      const ex = StaffResignException('You must be online to leave.');
      expect(ex.message, 'You must be online to leave.');
      expect(ex.toString(), ex.message);
    });
  });
}
