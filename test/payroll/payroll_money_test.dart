// payroll_money_test.dart — #670 (PRD #666): Bonus, Advance and Staff Loan.
// Against an in-memory Drift DB:
//   * an advance cannot be more than what is left of that month's salary;
//   * the outstanding loan, and a repayment cannot be more than is owed;
//   * a Manager above their expense limit waits for the CEO, and the CEO's
//     approval (or rejection) decides it; the CEO never waits;
//   * a correction is a new entry, never an edit;
//   * Activity Logs never carry an amount;
//   * no permission → nothing written; only the CEO approves.
// Fixture names are made up — never real pay data (the repo is public).

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String ceoId;
  late String managerId;
  late String cashierId;
  late String managerRoleId;
  late String workerId;
  String? signedIn;

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

  Future<void> setManagerLimit(int kobo) => db
      .into(db.roleSettings)
      .insertOnConflictUpdate(
        RoleSettingsCompanion.insert(
          businessId: businessId,
          roleId: managerRoleId,
          settingKey: 'max_expense_approval_kobo',
          settingValue: Value('$kobo'),
        ),
      );

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
    final cashierRole = await addRole('Cashier', 'cashier');
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
    cashierId = await addUser('Test Cashier', cashierRole);
    await setManagerLimit(5000000); // ₦50,000
    signedIn = ceoId;
    workerId = await db.payrollDao.addWorker(
      storeId: storeId,
      name: 'Ada Example',
      monthlySalaryKobo: 10000000, // ₦100,000
    );
  });

  tearDown(() => db.close());

  Future<PayrollEntryData> give(
    String type,
    int kobo, {
    String? month,
    String? corrects,
    String? date,
  }) => db.payrollDao.recordMoneyEntry(
    workerId: workerId,
    type: type,
    amountKobo: kobo,
    paymentMethod: 'cash',
    salaryMonth: month,
    correctsEntryId: corrects,
    entryDate: date,
  );

  Future<List<PayrollEntryData>> entries() =>
      db.payrollDao.entriesForWorker(workerId);

  group('advance cap', () {
    test('#704: an advance for a month not started yet is refused', () async {
      final n = DateTime.now();
      final next = DateTime(n.year, n.month + 1);
      final key = '${next.year}-${next.month.toString().padLeft(2, '0')}';
      await expectLater(
        give('advance', 100000, month: key),
        throwsA(isA<PayrollRuleViolation>()),
      );
      await give('advance', 100000); // this month is fine
    });

    test('an advance up to what is left of the month is allowed', () async {
      await give('advance', 6000000, month: '2026-10');
      await give('advance', 4000000, month: '2026-10');
      expect(
        PayrollMoneyPosition.advanceRoomKobo(
          salaryKobo: 10000000,
          entries: await entries(),
          salaryMonth: '2026-10',
        ),
        0,
      );
    });

    test('more than what is left is refused and suggests a loan', () async {
      await give('advance', 6000000, month: '2026-10');
      await expectLater(
        give('advance', 4000001, month: '2026-10'),
        throwsA(
          isA<PayrollRuleViolation>().having(
            (e) => e.message,
            'message',
            allOf(contains('October 2026'), contains('loan')),
          ),
        ),
      );
      // Another month has its own room.
      await give('advance', 9000000, month: '2026-11');
    });

    test('a waiting advance still uses up the month', () async {
      signedIn = managerId;
      final first = await give('advance', 6000000, month: '2026-10');
      expect(first.status, 'pending');
      await expectLater(
        give('advance', 5000000, month: '2026-10'),
        throwsA(isA<PayrollRuleViolation>()),
      );
    });

    test('a rejected advance frees the month again', () async {
      signedIn = managerId;
      final first = await give('advance', 6000000, month: '2026-10');
      signedIn = ceoId;
      await db.payrollDao.rejectEntry(first.id, reason: 'Not this month');
      await give('advance', 10000000, month: '2026-10');
    });

    test('defaults to this month', () async {
      final e = await give('advance', 100000);
      expect(e.salaryMonth, PayrollMoneyEntries.payrollThisMonth());
    });
  });

  group('staff loan', () {
    test('outstanding = loans given − repayments', () async {
      await give('loan_given', 20000000);
      await give('loan_repaid', 5000000);
      expect(
        PayrollMoneyPosition.outstandingLoanKobo(await entries()),
        15000000,
      );
    });

    test('a repayment cannot be more than is owed', () async {
      await give('loan_given', 20000000);
      await expectLater(
        give('loan_repaid', 20000001),
        throwsA(isA<PayrollRuleViolation>()),
      );
      await give('loan_repaid', 20000000);
      expect(PayrollMoneyPosition.outstandingLoanKobo(await entries()), 0);
    });

    test('a waiting loan is not owed yet', () async {
      signedIn = managerId;
      await give('loan_given', 6000000);
      expect(PayrollMoneyPosition.outstandingLoanKobo(await entries()), 0);
      expect(PayrollMoneyPosition.pendingLoanKobo(await entries()), 6000000);
      await expectLater(
        give('loan_repaid', 100),
        throwsA(isA<PayrollRuleViolation>()),
      );
    });
  });

  group('approval', () {
    test('a Manager within the limit goes straight through', () async {
      signedIn = managerId;
      final e = await give('bonus', 5000000);
      expect(e.status, 'approved');
      expect(e.approvedBy, managerId);
    });

    test(
      'a Manager above the limit waits; the CEO approval posts it',
      () async {
        signedIn = managerId;
        final e = await give('loan_given', 5000001);
        expect(e.status, 'pending');
        expect(e.approvedBy, isNull);
        final notes = await db.select(db.notifications).get();
        expect(notes.single.recipientUserId, ceoId);
        expect(notes.single.type, 'payroll.pending_approval');

        // A Manager cannot approve.
        await expectLater(
          db.payrollDao.approveEntry(e.id),
          throwsA(isA<PayrollApprovalDenied>()),
        );

        signedIn = ceoId;
        await db.payrollDao.approveEntry(e.id);
        final after = (await entries()).single;
        expect(after.status, 'approved');
        expect(after.approvedBy, ceoId);
        expect(
          PayrollMoneyPosition.outstandingLoanKobo(await entries()),
          5000001,
        );
        // The decision is queued for upload (the outbox folds both upserts of
        // the one row together, latest content wins).
        final queued = await db
            .customSelect(
              'SELECT payload FROM sync_queue WHERE action_type = ?',
              variables: [Variable.withString('payroll_entries:upsert')],
            )
            .get();
        expect(
          queued.map((r) => r.read<String>('payload')).last,
          contains('"status":"approved"'),
        );
        // Approving twice is a no-op.
        await db.payrollDao.approveEntry(e.id);
      },
    );

    test('no limit stored means every Manager entry waits', () async {
      await db.delete(db.roleSettings).go();
      signedIn = managerId;
      expect((await give('bonus', 100)).status, 'pending');
    });

    test('a repayment never waits', () async {
      await give('loan_given', 20000000);
      signedIn = managerId;
      expect((await give('loan_repaid', 9000000)).status, 'approved');
    });

    test('the CEO goes straight through at any amount', () async {
      final e = await give('bonus', 900000000);
      expect(e.status, 'approved');
      expect(await db.select(db.notifications).get(), isEmpty);
    });
  });

  group('corrections', () {
    test('a correction is a new entry carrying the difference', () async {
      final bonus = await give('bonus', 300000);
      final fix = await give('bonus', -100000, corrects: bonus.id);
      final all = await entries();
      expect(all, hasLength(2));
      expect(all.firstWhere((e) => e.id == bonus.id).amountKobo, 300000);
      expect(fix.correctsEntryId, bonus.id);
      expect(PayrollMoneyPosition.correctedAmountKobo(bonus, all), 200000);
      await expectLater(
        give('bonus', -200001, corrects: bonus.id),
        throwsA(isA<PayrollRuleViolation>()),
      );
    });
  });

  test('Activity Logs name the worker but never an amount', () async {
    await give('bonus', 1234500);
    await give('advance', 2345600, month: '2026-10');
    final loan = await give('loan_given', 3456700);
    await give('loan_repaid', 456700);
    await give('loan_given', -100000, corrects: loan.id);
    signedIn = managerId;
    final waiting = await give('bonus', 5678900);
    signedIn = ceoId;
    await db.payrollDao.rejectEntry(waiting.id, reason: 'Paid 56,789 already');
    final logs = await (db.select(
      db.activityLogs,
    )..where((l) => l.action.like('payroll_entry_%'))).get();
    expect(logs, hasLength(7));
    for (final l in logs) {
      expect(l.description, contains('Ada Example'));
      expect(l.description, isNot(matches(RegExp(r'\d'))));
    }
    for (final n in await db.select(db.notifications).get()) {
      expect(n.message, isNot(matches(RegExp(r'\d'))));
    }
  });

  test('without the Payroll permission nothing is written', () async {
    signedIn = cashierId;
    await expectLater(give('bonus', 1000), throwsA(isA<PayrollAccessDenied>()));
    expect(await entries(), isEmpty);
    final queued = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM sync_queue WHERE action_type = ?',
          variables: [Variable.withString('payroll_entries:upsert')],
        )
        .getSingle();
    expect(queued.read<int>('c'), 0);
  });

  group('entry date (#688)', () {
    String iso(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    test('defaults to today', () async {
      final e = await give('bonus', 1000);
      expect(e.entryDate, PayrollDao.payrollToday());
    });

    test('an earlier date is saved, for every manual type', () async {
      const d = '2026-01-15';
      await give('bonus', 1000, date: d);
      final loan = await give('loan_given', 5000, date: d);
      final repaid = await give('loan_repaid', 2000, date: d);
      final adv = await give('advance', 3000, month: '2026-01', date: d);
      for (final e in [loan, repaid, adv]) {
        expect(e.entryDate, d);
      }
      // Caps still hold with backdated entries.
      await expectLater(
        give('loan_repaid', 3001, date: d),
        throwsA(isA<PayrollRuleViolation>()),
      );
      await expectLater(
        give('advance', 10000000, month: '2026-01', date: d),
        throwsA(isA<PayrollRuleViolation>()),
      );
    });

    test('a future date is rejected and nothing is written', () async {
      final tomorrow = iso(DateTime.now().add(const Duration(days: 1)));
      await expectLater(
        give('bonus', 1000, date: tomorrow),
        throwsA(isA<PayrollRuleViolation>()),
      );
      expect(await entries(), isEmpty);
    });
  });

  group('salary change alert (#688)', () {
    Future<void> setSalary(int kobo) => db.payrollDao.updateWorker(
      workerId: workerId,
      storeId: storeId,
      monthlySalaryKobo: kobo,
      dailyAllowanceKobo: 0,
    );

    test('a Manager changing the salary notifies the CEO, no amount', () async {
      signedIn = managerId;
      await setSalary(12345600);
      final notes = await db.select(db.notifications).get();
      expect(notes, hasLength(1));
      expect(notes.single.recipientUserId, ceoId);
      expect(notes.single.message, contains('Ada Example'));
      expect(notes.single.message, isNot(matches(RegExp(r'\d'))));
    });

    test('the CEO changing it notifies nobody', () async {
      signedIn = ceoId;
      await setSalary(12345600);
      expect(await db.select(db.notifications).get(), isEmpty);
    });

    test('an unchanged salary notifies nobody', () async {
      signedIn = managerId;
      await setSalary(10000000);
      expect(await db.select(db.notifications).get(), isEmpty);
    });
  });
}
