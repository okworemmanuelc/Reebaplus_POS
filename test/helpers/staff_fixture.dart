// Sample data for the Staff tests and goldens (#440): business "Stallion
// Global", store "Abuja HQ", made-up people. Every date is a fixed value
// (never relative to now) so goldens do not drift.

import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import 'screen_harness.dart';

/// Grants a CEO holds on the Staff screens.
const staffGrants = {
  'staff.invite',
  'staff.change_role',
  'staff.suspend',
  'staff.remove',
  'staff.assign_stores',
  'settings.manage',
};

class StaffFixture {
  StaffFixture({
    required this.roleIds,
    required this.membershipIds,
    required this.userIds,
    required this.cashierRole,
    required this.cashierUser,
    required this.inviteId,
  });

  /// slug -> role id.
  final Map<String, String> roleIds;

  /// first name -> membership id.
  final Map<String, String> membershipIds;
  final Map<String, String> userIds;
  final RoleData cashierRole;
  final UserData cashierUser;
  final String inviteId;
}

/// Seeds the four system roles, four people (the signed-in CEO "Chioma Eze"
/// has the harness's `test-user-id`), memberships with fixed last-login
/// dates, a store assignment and one pending invite.
Future<StaffFixture> seedStaff(ScreenTestEnvironment env) async {
  final db = env.db;
  await db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
  );
  final roleIds = <String, String>{};
  final roles = <String, RoleData>{};
  for (final (slug, name) in const [
    ('ceo', 'CEO'),
    ('manager', 'Manager'),
    ('cashier', 'Cashier'),
    ('stock_keeper', 'Stock keeper'),
  ]) {
    final id = UuidV7.generate();
    roleIds[slug] = id;
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            slug: slug,
          ),
        );
    roles[slug] = await (db.select(
      db.roles,
    )..where((r) => r.id.equals(id))).getSingle();
  }

  final userIds = <String, String>{};
  final membershipIds = <String, String>{};
  UserData? cashierUser;
  for (final (first, full, slug, email, phone, status, login) in [
    (
      'Chioma',
      'Chioma Eze',
      'ceo',
      'chioma@stallion.example',
      '0803 000 0001',
      'active',
      DateTime(2026, 10, 12, 9, 30),
    ),
    (
      'Tunde',
      'Tunde Bello',
      'manager',
      'tunde@stallion.example',
      '0803 000 0002',
      'active',
      DateTime(2026, 10, 11, 17, 5),
    ),
    (
      'Ngozi',
      'Ngozi Adeyemi',
      'cashier',
      'ngozi@stallion.example',
      '0803 000 0003',
      'active',
      null,
    ),
    (
      'Emeka',
      'Emeka Obi',
      'stock_keeper',
      'emeka@stallion.example',
      null,
      'suspended',
      DateTime(2026, 9, 28, 8, 15),
    ),
  ]) {
    final uid = first == 'Chioma' ? 'test-user-id' : UuidV7.generate();
    userIds[first] = uid;
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(uid),
            businessId: env.businessId,
            name: full,
            pin: '1234',
            email: Value(email),
            phone: Value(phone),
          ),
        );
    final mid = UuidV7.generate();
    membershipIds[first] = mid;
    await db
        .into(db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            id: Value(mid),
            businessId: env.businessId,
            userId: uid,
            roleId: roleIds[slug]!,
            status: Value(status),
            lastLoginAt: Value(login),
          ),
        );
    if (first == 'Ngozi') {
      cashierUser = await (db.select(
        db.users,
      )..where((u) => u.id.equals(uid))).getSingle();
    }
  }
  await db
      .into(db.userStores)
      .insert(
        UserStoresCompanion.insert(
          businessId: env.businessId,
          userId: userIds['Ngozi']!,
          storeId: env.storeId,
        ),
      );

  final inviteId = UuidV7.generate();
  await db
      .into(db.inviteCodes)
      .insert(
        InviteCodesCompanion.insert(
          id: Value(inviteId),
          businessId: env.businessId,
          roleId: roleIds['cashier']!,
          code: 'K7M2QXP9',
          email: 'bisi@stallion.example',
          storeId: env.storeId,
          generatedByUserId: 'test-user-id',
          expiresAt: DateTime(2099, 1, 1),
        ),
      );

  return StaffFixture(
    roleIds: roleIds,
    membershipIds: membershipIds,
    userIds: userIds,
    cashierRole: roles['cashier']!,
    cashierUser: cashierUser!,
    inviteId: inviteId,
  );
}
