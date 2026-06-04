// login_logout_isolation_test.dart
//
// Guards the multi-user / multi-business isolation fixes for the shared till
// (master plan §7.2a / §7.6):
//   • getUserByEmail binds the row for the authenticated business, not the
//     most-recently-updated cross-business row (issue #5 / #6).
//   • countActiveStaffForBusiness drives cold-start routing — picker vs PIN.
//   • clearAllData (fresh-onboarding wipe) empties users even with append-only
//     ledger rows + FK references present (the BEFORE DELETE ledger triggers
//     used to abort the whole wipe transaction).

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<String> insertBusiness(String name) async {
    final id = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(id: Value(id), name: name));
    return id;
  }

  Future<String> insertRole(String businessId, String slug) async {
    final id = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: slug,
          slug: slug,
        ));
    return id;
  }

  Future<String> insertUser(String businessId, String name, String email) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: name,
          email: Value(email),
          pin: '__INIT__',
        ));
    return id;
  }

  Future<void> insertMembership(
    String businessId,
    String userId,
    String roleId, {
    String status = 'active',
  }) async {
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          businessId: businessId,
          userId: userId,
          roleId: roleId,
          status: Value(status),
        ));
  }

  test(
      'getUserByEmail binds the row for the authenticated business, not the '
      'most-recently-updated cross-business row (issue #5/#6)', () async {
    final bizA = await insertBusiness('Biz A');
    final bizB = await insertBusiness('Biz B');
    final userA = await insertUser(bizA, 'Manager', 'shared@x.com');
    // bizB's row is inserted second → most-recently-updated, so an unscoped
    // lookup would prefer it. The preferredBusinessId must override that.
    final userB = await insertUser(bizB, 'Stock keeper', 'shared@x.com');

    final resolvedA = await db.storesDao
        .getUserByEmail('shared@x.com', preferredBusinessId: bizA);
    expect(resolvedA?.id, userA);

    final resolvedB = await db.storesDao
        .getUserByEmail('shared@x.com', preferredBusinessId: bizB);
    expect(resolvedB?.id, userB);

    // No hint → ambiguous: it returns SOME matching row (tie-broken by
    // last-updated, non-deterministic when timestamps tie). We don't assert
    // which — that ambiguity is exactly why the OTP path now passes the
    // authenticated business instead of relying on this fallback.
    final resolvedNone = await db.storesDao.getUserByEmail('shared@x.com');
    expect([userA, userB], contains(resolvedNone?.id));
  });

  test(
      'countActiveStaffForBusiness counts only active staff of that business '
      '(drives cold-start picker vs PIN, §7.2)', () async {
    final bizA = await insertBusiness('Biz A');
    final bizB = await insertBusiness('Biz B');
    final roleA = await insertRole(bizA, 'manager');
    final roleB = await insertRole(bizB, 'cashier');

    final u1 = await insertUser(bizA, 'Ada', 'ada@x.com');
    final u2 = await insertUser(bizA, 'Ben', 'ben@x.com');
    final u3 = await insertUser(bizA, 'Cid', 'cid@x.com');
    final other = await insertUser(bizB, 'Zoe', 'zoe@x.com');

    await insertMembership(bizA, u1, roleA);
    await insertMembership(bizA, u2, roleA);
    await insertMembership(bizA, u3, roleA, status: 'suspended');
    await insertMembership(bizB, other, roleB);

    // bizA has 2 active (u1, u2); u3 suspended is excluded; bizB's staff don't
    // count → multi-staff (>1) → cold start routes to the Who Is Working picker.
    expect(await db.userBusinessesDao.countActiveStaffForBusiness(bizA), 2);
    // bizB has a single active staffer → cold start goes straight to PIN.
    expect(await db.userBusinessesDao.countActiveStaffForBusiness(bizB), 1);
  });

  test(
      'clearAllData (fresh-onboarding wipe) removes the users row INCLUDING '
      'its PIN hash', () async {
    final biz = await insertBusiness('Biz');
    final uid = await insertUser(biz, 'Manager', 'm@x.com');
    // Simulate a set PIN: write the local-only hash columns directly.
    await (db.update(db.users)..where((u) => u.id.equals(uid))).write(
      const UsersCompanion(
        pin: Value('__HASHED__'),
        pinHash: Value('deadbeefhash'),
        pinSalt: Value('saltvalue'),
        pinIterations: Value(120000),
      ),
    );
    expect((await db.select(db.users).get()).single.pinHash, 'deadbeefhash');

    await db.clearAllData();

    expect(await db.select(db.users).get(), isEmpty);
  });

  test(
      'clearAllData empties users even with append-only LEDGER rows + FK refs '
      '(reproduces the "users table NOT empty" failure: BEFORE DELETE triggers '
      'on ledger tables were aborting the whole wipe transaction)', () async {
    final biz = await insertBusiness('Biz');
    final role = await insertRole(biz, 'manager');
    final uid = await insertUser(biz, 'Manager', 'm@x.com');
    // user_businesses.userId → users(id): a real device always has this, plus
    // user_stores, sessions, orders.staffId, etc. Deleting users with these
    // present is the case the empty in-memory test missed.
    await insertMembership(biz, uid, role);
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeId),
          businessId: biz,
          name: 'Store 1',
        ));
    await db.into(db.userStores).insert(UserStoresCompanion.insert(
          businessId: biz,
          userId: uid,
          storeId: storeId,
        ));
    // A row in an APPEND-ONLY LEDGER table (activity_logs) — every real till
    // has these. Its BEFORE DELETE _no_delete trigger RAISE(ABORT)s, which is
    // what rolled back the whole wipe transaction on-device, leaving the
    // users/PIN row behind. This is the row the in-memory tests were missing.
    await db.into(db.activityLogs).insert(ActivityLogsCompanion.insert(
          businessId: biz,
          action: 'login',
          description: 'signed in',
        ));

    await db.clearAllData();

    expect(await db.select(db.users).get(), isEmpty,
        reason: 'users must be wiped despite FK references');
    expect(await db.select(db.userBusinesses).get(), isEmpty);
    expect(await db.select(db.userStores).get(), isEmpty);
    expect(await db.select(db.activityLogs).get(), isEmpty);

    // The append-only protection must be RESTORED after the wipe — the wipe
    // drops the _no_delete guards temporarily, so verify a fresh ledger row
    // still can't be deleted.
    final biz2 = await insertBusiness('Biz2');
    await db.into(db.activityLogs).insert(ActivityLogsCompanion.insert(
          businessId: biz2,
          action: 'login',
          description: 'after wipe',
        ));
    await expectLater(
      (db.delete(db.activityLogs)..where((t) => t.businessId.equals(biz2))).go(),
      throwsA(anything),
      reason: 'the _no_delete trigger must be recreated after clearAllData',
    );
  });
}
