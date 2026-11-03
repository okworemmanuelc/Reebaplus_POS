// payroll_test.dart — #667 (PRD #666, ADR 0034): the Payroll tables are the
// first PERMISSION-GATED synced tables. Covers, against an in-memory Drift DB:
//   * the local permission check mirrors the cloud `caller_has_permission`;
//   * a user without `payroll.manage` cannot write or queue payroll rows;
//   * a Daily Allowance written twice for the same worker and day lands ONCE,
//     both through the DAO and through the sync apply (two phones);
//   * losing the permission drops the local rows, except rows still waiting
//     to upload (invariant #12).
// Fixture names are made up — never real pay data (the repo is public).

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String ceoId;
  late String managerId;
  late String cashierId;
  late String managerRoleId;
  late String cashierRoleId;
  String? signedIn;

  Future<String> addUser(String name, String roleId) async {
    final id = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            pin: kSetupRequiredPin,
          ),
        );
    await db
        .into(db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            businessId: businessId,
            userId: id,
            roleId: roleId,
          ),
        );
    return id;
  }

  Future<String> addRole(String name, String slug) async {
    final id = UuidV7.generate();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            slug: slug,
          ),
        );
    return id;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    storeId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    db.userIdResolver = () => signedIn;
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Shop'),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    final ceoRole = await addRole('CEO', 'ceo');
    managerRoleId = await addRole('Manager', 'manager');
    cashierRoleId = await addRole('Cashier', 'cashier');
    await db
        .into(db.rolePermissions)
        .insert(
          RolePermissionsCompanion.insert(
            businessId: businessId,
            roleId: managerRoleId,
            permissionKey: kPayrollPermissionKey,
          ),
        );
    ceoId = await addUser('Test Owner', ceoRole);
    managerId = await addUser('Test Manager', managerRoleId);
    cashierId = await addUser('Test Cashier', cashierRoleId);
    signedIn = managerId;
  });

  tearDown(() => db.close());

  Future<bool> holds(String userId) => db.permissionsDao.userHolds(
    userId: userId,
    businessId: businessId,
    permissionKey: kPayrollPermissionKey,
  );

  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
          .read<int>('c');

  Future<int> queued(String table) async =>
      (await db
              .customSelect(
                'SELECT COUNT(*) AS c FROM sync_queue WHERE action_type = ?',
                variables: [Variable.withString('$table:upsert')],
              )
              .getSingle())
          .read<int>('c');

  test('the catalogue carries payroll.manage in its own category', () async {
    final perm = await db.permissionsDao.getByKey(kPayrollPermissionKey);
    expect(perm?.category, 'Payroll');
  });

  group('userHolds mirrors caller_has_permission', () {
    test('CEO all-on, Manager by grant, Cashier denied', () async {
      expect(await holds(ceoId), isTrue);
      expect(await holds(managerId), isTrue);
      expect(await holds(cashierId), isFalse);
    });

    test(
      'a user override grants or revokes; suspended members are denied',
      () async {
        await db
            .into(db.userPermissionOverrides)
            .insert(
              UserPermissionOverridesCompanion.insert(
                businessId: businessId,
                userId: cashierId,
                permissionKey: kPayrollPermissionKey,
                isGranted: true,
              ),
            );
        await db
            .into(db.userPermissionOverrides)
            .insert(
              UserPermissionOverridesCompanion.insert(
                businessId: businessId,
                userId: managerId,
                permissionKey: kPayrollPermissionKey,
                isGranted: false,
              ),
            );
        expect(await holds(cashierId), isTrue);
        expect(await holds(managerId), isFalse);

        await (db.update(db.userBusinesses)
              ..where((m) => m.userId.equals(ceoId)))
            .write(const UserBusinessesCompanion(status: Value('suspended')));
        expect(await holds(ceoId), isFalse);
      },
    );
  });

  group('a phone without the permission', () {
    test('cannot write a worker, and nothing is queued', () async {
      signedIn = cashierId;
      await expectLater(
        db.payrollDao.addWorker(storeId: storeId, name: 'Test Worker'),
        throwsA(isA<PayrollAccessDenied>()),
      );
      expect(await count('payroll_workers'), 0);
      expect(await queued('payroll_workers'), 0);
    });

    test('is refused at the enqueue boundary too', () async {
      signedIn = cashierId;
      await expectLater(
        db.syncDao.enqueueUpsert(
          'payroll_workers',
          PayrollWorkersCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            storeId: storeId,
            name: 'Test Worker',
          ),
        ),
        throwsStateError,
      );
      expect(await queued('payroll_workers'), 0);
    });
  });

  group('a Daily Allowance posts once per worker per day', () {
    late String workerId;

    setUp(() async {
      workerId = await db.payrollDao.addWorker(
        storeId: storeId,
        name: 'Test Worker',
        monthlySalaryKobo: 100000,
        dailyAllowanceKobo: 5000,
        allowanceStartDate: '2026-11-02',
      );
    });

    test('written twice on one phone: one row, one upload', () async {
      expect(
        await db.payrollDao.postAllowance(
          workerId: workerId,
          entryDate: '2026-11-03',
        ),
        isTrue,
      );
      expect(
        await db.payrollDao.postAllowance(
          workerId: workerId,
          entryDate: '2026-11-03',
        ),
        isFalse,
      );
      final entries = await db.payrollDao.entriesForWorker(workerId);
      expect(entries, hasLength(1));
      expect(entries.single.id, payrollAllowanceId(workerId, '2026-11-03'));
      expect(entries.single.amountKobo, 5000);
      expect(await queued('payroll_entries'), 1);
      // A different day is a different row.
      await db.payrollDao.postAllowance(
        workerId: workerId,
        entryDate: '2026-11-04',
      );
      expect(await db.payrollDao.entriesForWorker(workerId), hasLength(2));
    });

    test('posted on two phones: the sync apply lands one row', () async {
      final supabase = SupabaseClient(
        'https://placeholder.supabase.co',
        'placeholder',
      );
      addTearDown(supabase.dispose);
      final sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
      final id = payrollAllowanceId(workerId, '2026-11-03');
      Map<String, dynamic> cloudRow(String ts) => {
        'id': id,
        'business_id': businessId,
        'worker_id': workerId,
        'store_id': storeId,
        'type': 'allowance',
        'amount_kobo': 5000,
        'entry_date': '2026-11-03',
        'salary_month': null,
        'payment_method': 'cash',
        'note': null,
        'corrects_entry_id': null,
        'recorded_by': null,
        'legacy_id': null,
        'created_at': ts,
        'last_updated_at': ts,
      };
      // Another phone's allowance arrives first, then the cloud re-announces
      // it after this phone's replay (0243 freezes content, bumps the time).
      await sync.restoreTableDataForTesting('payroll_entries', [
        cloudRow('2026-11-03T08:00:00Z'),
      ]);
      await sync.restoreTableDataForTesting('payroll_entries', [
        cloudRow('2026-11-03T08:05:00Z'),
      ]);
      expect(await count('payroll_entries'), 1);
      // This phone then tries to post the same day: nothing new lands.
      expect(
        await db.payrollDao.postAllowance(
          workerId: workerId,
          entryDate: '2026-11-03',
        ),
        isFalse,
      );
      expect(await count('payroll_entries'), 1);
      expect(await queued('payroll_entries'), 0);
    });
  });

  group('losing the permission', () {
    test('drops the local rows but keeps rows waiting to upload', () async {
      final workerId = await db.payrollDao.addWorker(
        storeId: storeId,
        name: 'Test Worker',
      );
      await db.payrollDao.postAllowance(
        workerId: workerId,
        entryDate: '2026-11-03',
      );
      // Both rows are still queued: sacred, so nothing goes.
      expect(await db.payrollDao.purgeForLostAccess(businessId), 0);
      // Once uploaded (queue confirmed), they can go.
      await db.customStatement("UPDATE sync_queue SET status = 'completed'");
      expect(await db.payrollDao.purgeForLostAccess(businessId), 2);
      expect(await count('payroll_workers'), 0);
      expect(await count('payroll_entries'), 0);
    });

    test('the sync check removes rows once the grant is revoked', () async {
      final supabase = SupabaseClient(
        'https://placeholder.supabase.co',
        'placeholder',
      );
      addTearDown(supabase.dispose);
      final sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
      await db.payrollDao.addWorker(storeId: storeId, name: 'Test Worker');
      await db.customStatement("UPDATE sync_queue SET status = 'completed'");
      // Record "already caught up" so the check does not try the network.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SupabaseSyncService.permissionGatedAccessKey(businessId),
        kPayrollPermissionKey,
      );
      await sync.enforcePermissionGatedAccessForTesting(businessId);
      expect(await count('payroll_workers'), 1);

      await (db.delete(
        db.rolePermissions,
      )..where((g) => g.roleId.equals(managerRoleId))).go();
      await sync.enforcePermissionGatedAccessForTesting(businessId);
      expect(await count('payroll_workers'), 0);
      expect(
        prefs.getString(
          SupabaseSyncService.permissionGatedAccessKey(businessId),
        ),
        isEmpty,
      );
    });
  });
}
