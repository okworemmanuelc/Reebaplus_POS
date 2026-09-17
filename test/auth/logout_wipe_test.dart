// logout_wipe_test.dart
//
// DAO-level coverage for the logout flow. A device is used by one user at a
// time, so logout always wipes it (the service-level check lives in
// lock_screen_test.dart):
//
//   (a) Offline-with-pending: countPending > 0 while offline means logout
//       should be blocked (the caller throws LogoutWipeException).
//
//   (b) Clean: countPending == 0 (or online) → clearAllData wipes every user +
//       membership row, including other staff who had a PIN here.
//
//   (c) countDeviceStaffForBusiness (drives the email screen's "Login with PIN"
//       link) correctly distinguishes device-authenticated users (pinHash !=
//       null + active membership) from users who only have an OTP-level row
//       (pinHash == null).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

void main() {
  late AppDatabase db;
  late String biz;
  late String ceoRoleId;
  late String cashierRoleId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());

    biz = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Shared Till'));

    ceoRoleId = UuidV7.generate();
    cashierRoleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(ceoRoleId), businessId: biz, name: 'CEO', slug: 'ceo'));
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(cashierRoleId),
        businessId: biz,
        name: 'Cashier',
        slug: 'cashier'));
  });

  tearDown(() => db.close());

  Future<String> addUser(String name, {String? pinHash}) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(id),
          businessId: biz,
          name: name,
          pin: pinHash != null ? '__HASHED__' : '__INIT__',
          pinHash: Value(pinHash),
          pinSalt: pinHash != null ? const Value('salt') : const Value(null),
          pinIterations:
              pinHash != null ? const Value(120000) : const Value(null),
        ));
    return id;
  }

  Future<void> addMembership(String userId, String roleId,
      {String status = 'active'}) async {
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz,
          userId: userId,
          roleId: roleId,
          status: Value(status),
        ));
  }

  Future<void> enqueuePending() async {
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          businessId: biz,
          actionType: 'orders:upsert',
          payload: '{"id":"fake"}',
        ));
  }

  // ── (a) Offline with pending sync → should block ────────────────────────

  test(
      '(a) pending sync changes: countPending > 0 signals the caller to abort '
      '(throw LogoutWipeException)', () async {
    final alice = await addUser('Alice', pinHash: 'aliceHash');
    await addMembership(alice, ceoRoleId);

    // Enqueue an unsynced change.
    await enqueuePending();

    // The service reads this count and — when offline — throws LogoutWipeException.
    db.businessIdResolver = () => biz;
    final pending = await db.syncDao.countPending(businessId: biz);
    expect(pending, greaterThan(0));

    // Verify the exception shape itself (pure Dart, no platform dependency).
    const ex = LogoutWipeException('test');
    expect(ex.message, 'test');
    expect(ex.toString(), 'test');
  });

  // ── (b) Clean → clearAllData wipes everything ───────────────────────────

  test(
      '(b) no pending changes: clearAllData removes all users and memberships, '
      'other PIN holders included (device-wipe path)', () async {
    final alice = await addUser('Alice', pinHash: 'aliceHash');
    final bob = await addUser('Bob', pinHash: 'bobHash');
    await addMembership(alice, ceoRoleId);
    await addMembership(bob, cashierRoleId);

    expect(await db.userBusinessesDao.countDeviceStaffForBusiness(biz), 2);

    // No pending sync queue items for this business.
    db.businessIdResolver = () => biz;
    expect(await db.syncDao.countPending(businessId: biz), 0);

    // Simulate the logout wipe path.
    await db.clearAllData();

    expect(await db.select(db.users).get(), isEmpty);
    expect(await db.select(db.userBusinesses).get(), isEmpty);
    expect(await db.select(db.businesses).get(), isEmpty);
  });

  // ── (c) countDeviceStaffForBusiness excludes non-PIN users ──────────────

  test(
      '(c) countDeviceStaffForBusiness counts only users with pinHash AND '
      'an active membership', () async {
    // Alice: has PIN + active → counted.
    final alice = await addUser('Alice', pinHash: 'hash1');
    await addMembership(alice, ceoRoleId);

    // Bob: OTP-only (no PIN) + active → NOT counted.
    final bob = await addUser('Bob');
    await addMembership(bob, cashierRoleId);

    // Carol: has PIN + suspended → NOT counted.
    final carol = await addUser('Carol', pinHash: 'hash3');
    await addMembership(carol, cashierRoleId, status: 'suspended');

    expect(await db.userBusinessesDao.countDeviceStaffForBusiness(biz), 1);

    // Setting Bob's PIN promotes him to device-authenticated.
    await (db.update(db.users)..where((u) => u.id.equals(bob))).write(
      const UsersCompanion(
        pin: Value('__HASHED__'),
        pinHash: Value('bobHash'),
        pinSalt: Value('salt'),
        pinIterations: Value(120000),
      ),
    );
    expect(await db.userBusinessesDao.countDeviceStaffForBusiness(biz), 2);
  });
}
