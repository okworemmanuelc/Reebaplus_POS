// hidden_member_test.dart
//
// #622 — the Reebaplus support login is a full-rights CEO membership flagged
// `is_hidden`. It must be left out of every staff list / picker / count source
// in UserBusinessesDao, never be a notification audience, and be untouchable
// from the app — while its membership and users rows stay resolvable by id so
// history rows keep showing its name.

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String biz;
  late String ceoRoleId;
  late String cashierRoleId;
  late String realCeo;
  late String cashier;
  late String support;
  late String supportMembershipId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    biz = UuidV7.generate();
    db.businessIdResolver = () => biz;
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(biz), name: 'Biz'));
    ceoRoleId = UuidV7.generate();
    cashierRoleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(ceoRoleId), businessId: biz, name: 'CEO', slug: 'ceo'));
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(cashierRoleId),
        businessId: biz,
        name: 'Cashier',
        slug: 'cashier'));

    Future<String> user(String name) async {
      final id = UuidV7.generate();
      await db.into(db.users).insert(UsersCompanion.insert(
            id: Value(id),
            businessId: biz,
            name: name,
            pin: '__HASHED__',
            pinHash: const Value('h'),
          ));
      return id;
    }

    Future<String> member(
      String userId,
      String roleId, {
      bool hidden = false,
    }) async {
      final id = UuidV7.generate();
      await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
            id: Value(id),
            businessId: biz,
            userId: userId,
            roleId: roleId,
            isHidden: Value(hidden),
          ));
      return id;
    }

    realCeo = await user('Real Owner');
    cashier = await user('Cashier Chi');
    support = await user('Reebaplus Support');
    await member(realCeo, ceoRoleId);
    await member(cashier, cashierRoleId);
    supportMembershipId = await member(support, ceoRoleId, hidden: true);
  });

  tearDown(() => db.close());

  test('is_hidden defaults to false', () async {
    final rows = await db.select(db.userBusinesses).get();
    expect(rows.where((r) => !r.isHidden), hasLength(2));
  });

  test('staff list stream leaves the hidden member out', () async {
    final rows = await db.userBusinessesDao.watchForCurrentBusiness().first;
    expect(rows.map((r) => r.userId).toSet(), {realCeo, cashier});
  });

  test('active staff (checklist) and device-staff counts skip it', () async {
    final entries =
        await db.userBusinessesDao.watchActiveStaffForBusiness(biz).first;
    expect(entries.map((e) => e.user.name), ['Cashier Chi', 'Real Owner']);
    expect(await db.userBusinessesDao.countDeviceStaffForBusiness(biz), 2);
  });

  test('never a notification audience, never "the" CEO', () async {
    final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
    expect(ceoIds, [realCeo]);
    expect(await db.userBusinessesDao.getCeoUserId(), realCeo);
  });

  test('still resolvable by id: membership and users row (history names)',
      () async {
    final m = await db.userBusinessesDao.getForUserInBusiness(support, biz);
    expect(m, isNotNull);
    expect(m!.isHidden, isTrue);
    final u = await (db.select(db.users)..where((t) => t.id.equals(support)))
        .getSingle();
    expect(u.name, 'Reebaplus Support');
  });

  test('the app cannot change or suspend the hidden member', () async {
    await expectLater(
      db.userBusinessesDao.setStatus(supportMembershipId, 'suspended'),
      throwsStateError,
    );
    await expectLater(
      db.userBusinessesDao.setRole(supportMembershipId, cashierRoleId),
      throwsStateError,
    );
    final m = await db.userBusinessesDao.getForUserInBusiness(support, biz);
    expect(m!.status, 'active');
    expect(m.roleId, ceoRoleId);
  });
}
