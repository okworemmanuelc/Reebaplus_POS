// staff_removal_test.dart
//
// Staff offboarding — core (#107). Client-side behaviour of the terminal
// `removed` membership status. The removal itself is a server-authoritative RPC
// (remove_staff_member); these assertions cover what the client is responsible
// for once that RPC has confirmed:
//
//   * the widened user_businesses.status CHECK admits `removed` (fresh onCreate
//     builds the 3-value constraint from customConstraints);
//   * UserBusinessesDao.watchForCurrentBusiness excludes `removed` staff while
//     keeping `active` + `suspended` (they still surface in Staff Management);
//   * UserBusinessesDao.markRemovedLocal mirrors the confirmed `removed` status
//     WITHOUT enqueuing (sync-exempt — the RPC owns the cloud write), and leaves
//     the users row intact as an attribution stub (name / email / phone kept).

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String biz;
  late String ceoRoleId;
  late String cashierRoleId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    biz = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(biz), name: 'Biz'),
        );
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

  Future<String> addUser(
    String name, {
    String? email,
    String? phone,
  }) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(id),
          businessId: biz,
          name: name,
          pin: '__HASHED__',
          email: Value(email),
          phone: Value(phone),
        ));
    return id;
  }

  Future<String> addMembership(
    String userId,
    String roleId, {
    String status = 'active',
  }) async {
    final id = UuidV7.generate();
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(id),
          businessId: biz,
          userId: userId,
          roleId: roleId,
          status: Value(status),
        ));
    return id;
  }

  test('the widened status CHECK admits `removed` (and rejects bogus values)',
      () async {
    final u = await addUser('Removed Rita');
    // Accepts the new terminal state on a fresh (onCreate) schema.
    await addMembership(u, cashierRoleId, status: 'removed');
    final row = await (db.select(db.userBusinesses)
          ..where((t) => t.userId.equals(u)))
        .getSingle();
    expect(row.status, 'removed');

    // A value outside {active, suspended, removed} is still rejected.
    await expectLater(
      addMembership(await addUser('Bad Status'), cashierRoleId,
          status: 'archived'),
      throwsA(isA<Exception>()),
    );
  });

  test('watchForCurrentBusiness excludes `removed`, keeps active + suspended',
      () async {
    db.businessIdResolver = () => biz;

    final active = await addUser('Active Amara');
    final suspended = await addUser('Suspended Sade');
    final removed = await addUser('Removed Rita');
    await addMembership(active, ceoRoleId);
    await addMembership(suspended, cashierRoleId, status: 'suspended');
    await addMembership(removed, cashierRoleId, status: 'removed');

    final rows = await db.userBusinessesDao.watchForCurrentBusiness().first;
    final userIds = rows.map((r) => r.userId).toSet();

    expect(userIds, containsAll(<String>[active, suspended]));
    expect(userIds.contains(removed), isFalse,
        reason: 'removed staff must not appear in the active staff list');
    expect(rows, hasLength(2));
  });

  test(
      'markRemovedLocal sets `removed`, keeps the users attribution stub, and '
      'does NOT enqueue (sync-exempt)', () async {
    final u = await addUser('Removed Rita',
        email: 'rita@example.com', phone: '08030000000');
    final membershipId = await addMembership(u, cashierRoleId);

    // A raw insert does not enqueue, so the outbox starts empty.
    expect(await _syncQueueCount(db), 0);

    await db.userBusinessesDao.markRemovedLocal(membershipId);

    final membership = await (db.select(db.userBusinesses)
          ..where((t) => t.id.equals(membershipId)))
        .getSingle();
    expect(membership.status, 'removed');

    // Attribution stub: the users row is retained with name / email / phone.
    final user =
        await (db.select(db.users)..where((t) => t.id.equals(u))).getSingle();
    expect(user.name, 'Removed Rita');
    expect(user.email, 'rita@example.com');
    expect(user.phone, '08030000000');

    // Sync-exempt: the RPC is the authoritative writer, so nothing is queued.
    expect(await _syncQueueCount(db), 0,
        reason: 'markRemovedLocal must not enqueue a sync_queue row');
  });
}

Future<int> _syncQueueCount(AppDatabase db) async {
  final r = await db
      .customSelect('SELECT COUNT(*) c FROM sync_queue')
      .getSingle();
  return r.read<int>('c');
}
