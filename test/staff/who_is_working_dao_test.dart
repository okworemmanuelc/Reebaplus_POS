// who_is_working_dao_test.dart
//
// Covers UserBusinessesDao.watchActiveStaffForBusiness (master plan §8 — the
// Who Is Working picker query). The method is deliberately unscoped (it runs
// before sign-in, when there's no current business), so these assertions key
// off the explicit businessId argument:
//   * only ACTIVE memberships are returned (suspended excluded, §8.3);
//   * only memberships of the requested business are returned;
//   * the user + role rows are joined onto each entry.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String biz1;
  late String biz2;
  late String ceoRoleId;
  late String cashierRoleId;
  late String biz2RoleId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());

    biz1 = UuidV7.generate();
    biz2 = UuidV7.generate();
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(biz1), name: 'Biz 1'));
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(biz2), name: 'Biz 2'));

    ceoRoleId = UuidV7.generate();
    cashierRoleId = UuidV7.generate();
    biz2RoleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(ceoRoleId), businessId: biz1, name: 'CEO', slug: 'ceo'));
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(cashierRoleId),
        businessId: biz1,
        name: 'Cashier',
        slug: 'cashier'));
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(biz2RoleId), businessId: biz2, name: 'CEO', slug: 'ceo'));
  });

  tearDown(() => db.close());

  Future<String> addUser(String businessId, String name, {String? pinHash}) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: name,
          pin: '__HASHED__',
          pinHash: Value(pinHash),
        ));
    return id;
  }

  Future<void> addMembership(
    String businessId,
    String userId,
    String roleId, {
    String status = 'active',
  }) async {
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          userId: userId,
          roleId: roleId,
          status: Value(status),
        ));
  }

  test('returns only active staff of the given business, role joined',
      () async {
    final alice = await addUser(biz1, 'Alice');
    final bob = await addUser(biz1, 'Bob');
    final carol = await addUser(biz1, 'Carol'); // suspended
    final dave = await addUser(biz2, 'Dave'); // other business

    await addMembership(biz1, alice, ceoRoleId);
    await addMembership(biz1, bob, cashierRoleId);
    await addMembership(biz1, carol, ceoRoleId, status: 'suspended');
    await addMembership(biz2, dave, biz2RoleId);

    final entries =
        await db.userBusinessesDao.watchActiveStaffForBusiness(biz1).first;

    // Suspended (Carol) and other-business (Dave) excluded; ordered by name.
    expect(entries.map((e) => e.user.name).toList(), ['Alice', 'Bob']);

    final byName = {for (final e in entries) e.user.name: e};
    expect(byName['Alice']!.role!.slug, 'ceo');
    expect(byName['Bob']!.role!.slug, 'cashier');
  });

  test('returns empty when the business has no active staff', () async {
    final eve = await addUser(biz1, 'Eve');
    await addMembership(biz1, eve, ceoRoleId, status: 'suspended');

    final entries =
        await db.userBusinessesDao.watchActiveStaffForBusiness(biz1).first;
    expect(entries, isEmpty);
  });

  test('watchDeviceStaffForBusiness/countDeviceStaffForBusiness returns only staff with pinHash configured', () async {
    final alice = await addUser(biz1, 'Alice', pinHash: 'hash1');
    final bob = await addUser(biz1, 'Bob'); // no pinHash
    final carol = await addUser(biz1, 'Carol', pinHash: 'hash3'); // suspended
    final dave = await addUser(biz2, 'Dave', pinHash: 'hash4'); // other business

    await addMembership(biz1, alice, ceoRoleId);
    await addMembership(biz1, bob, cashierRoleId);
    await addMembership(biz1, carol, ceoRoleId, status: 'suspended');
    await addMembership(biz2, dave, biz2RoleId);

    final deviceStaff = await db.userBusinessesDao.watchDeviceStaffForBusiness(biz1).first;
    expect(deviceStaff.map((e) => e.user.name).toList(), ['Alice']);

    final count = await db.userBusinessesDao.countDeviceStaffForBusiness(biz1);
    expect(count, 1);
  });
}
