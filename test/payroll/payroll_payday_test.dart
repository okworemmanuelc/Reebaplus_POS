// payroll_payday_test.dart — #671 (PRD #666): payday, signatures, Total Pay
// and the combined "Salaries" line. Against an in-memory Drift DB:
//   * one salary payment per worker per Salary Month;
//   * a different amount for the month needs a reason (normal salary kept);
//   * approved advances are deducted (a waiting one blocks payday);
//   * the loan repayment is capped by what is owed and by cash >= 0;
//   * only approved entries count; Total Pay = salary + allowances + bonuses;
//   * both signatures are required;
//   * one combined Salaries line per store per payday, no names; cash vs
//     transfer in the drawer; a backdated payday;
//   * Activity Logs and notifications never carry an amount.
// Fixture names are made up — never real pay data (the repo is public).

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/expenses/expense_summary.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

const _sig = 'iVBORw0KGgo='; // any non-empty base64 stands in for a PNG
final _now = DateTime(2026, 11, 3, 10);

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String store2Id;
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    storeId = UuidV7.generate();
    store2Id = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    db.userIdResolver = () => signedIn;
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Shop'),
        );
    for (final (id, name) in [(storeId, 'Main Store'), (store2Id, 'Annex')]) {
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: name,
            ),
          );
    }
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
    await db
        .into(db.roleSettings)
        .insertOnConflictUpdate(
          RoleSettingsCompanion.insert(
            businessId: businessId,
            roleId: managerRoleId,
            settingKey: 'max_expense_approval_kobo',
            settingValue: const Value('5000000'), // ₦50,000
          ),
        );
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
    String? date,
  }) => db.payrollDao.recordMoneyEntry(
    workerId: workerId,
    type: type,
    amountKobo: kobo,
    paymentMethod: 'cash',
    salaryMonth: month,
    entryDate: date,
  );

  Future<PayrollStatementData> pay({
    String? worker,
    String month = '2026-10',
    int? salary,
    String? reason,
    int repay = 0,
    String method = 'cash',
    String? payday,
    String? workerSig = _sig,
    String? payerSig = _sig,
  }) => db.payrollDao.paySalary(
    workerId: worker ?? workerId,
    salaryMonth: month,
    salaryKobo: salary,
    reason: reason,
    loanRepaymentKobo: repay,
    paymentMethod: method,
    paydayDate: payday,
    workerSignaturePng: workerSig,
    payerSignaturePng: payerSig,
    now: _now,
  );

  Future<List<StaffPayTotalData>> salaryLines() => (db.select(
    db.staffPayTotals,
  )..where((t) => t.kind.equals(kStaffPayKindSalaries))).get();

  Matcher violation([String? text]) => throwsA(
    text == null
        ? isA<PayrollRuleViolation>()
        : isA<PayrollRuleViolation>().having(
            (e) => e.message,
            'message',
            contains(text),
          ),
  );

  test(
    'pays the full salary by default and saves the signed statement',
    () async {
      final s = await pay();
      expect(s.id, payrollStatementId(workerId, '2026-10'));
      expect(s.salaryKobo, 10000000);
      expect(s.cashPaidKobo, 10000000);
      expect(s.totalPayKobo, 10000000);
      expect(s.workerSignaturePng, _sig);
      expect(s.payerSignaturePng, _sig);
      expect(s.signedBy, ceoId);
      final entry = (await db.payrollDao.entriesForWorker(
        workerId,
      )).singleWhere((e) => e.type == 'salary_payment');
      expect(entry.id, payrollSalaryEntryId(workerId, '2026-10'));
      expect(entry.id, s.salaryEntryId);
      expect(entry.salaryMonth, '2026-10');
      expect(entry.entryDate, '2026-11-03');
      expect(entry.status, 'approved');
    },
  );

  group('one per worker per month', () {
    test('a second payment for the same month is refused', () async {
      await pay();
      await expectLater(pay(), violation('already been paid'));
      // Another month is its own payment.
      await pay(month: '2026-09');
      expect(await db.select(db.payrollStatements).get(), hasLength(2));
    });

    test('a month that has not ended cannot be paid', () async {
      await expectLater(pay(month: '2026-11'), violation('after the month'));
    });

    test('payable months are the ones before payday, newest first', () {
      expect(payrollPayableMonths(DateTime(2026, 1, 5), count: 2), [
        '2025-12',
        '2025-11',
      ]);
    });
  });

  group('a different amount for the month', () {
    test('needs a reason', () async {
      await expectLater(pay(salary: 8000000), violation('reason'));
      await expectLater(
        pay(salary: 8000000, reason: '   '),
        violation('reason'),
      );
      expect(await db.select(db.payrollStatements).get(), isEmpty);
    });

    test('with a reason it is paid; the normal salary stays', () async {
      final s = await pay(salary: 8000000, reason: 'Away one week');
      expect(s.salaryKobo, 8000000);
      final worker = await db.select(db.payrollWorkers).getSingle();
      expect(worker.monthlySalaryKobo, 10000000);
      final entry = (await db.payrollDao.entriesForWorker(
        workerId,
      )).singleWhere((e) => e.type == 'salary_payment');
      expect(entry.amountKobo, 8000000);
      expect(entry.note, contains('Away one week'));
    });

    test('the normal amount typed in needs no reason', () async {
      await pay(salary: 10000000);
    });
  });

  group('advances', () {
    test('approved advances for the month are deducted', () async {
      await give('advance', 3000000, month: '2026-10', date: '2026-10-10');
      await give('advance', 1000000, month: '2026-09', date: '2026-09-10');
      final s = await pay();
      expect(s.advancesKobo, 3000000);
      expect(s.cashPaidKobo, 7000000);
      // Advances are part of the salary, never added to Total Pay.
      expect(s.totalPayKobo, 10000000);
    });

    test('a waiting advance blocks payday until it is decided', () async {
      signedIn = managerId;
      final waiting = await give(
        'advance',
        6000000,
        month: '2026-10',
        date: '2026-10-10',
      );
      expect(waiting.status, 'pending');
      await expectLater(pay(), violation('waiting'));
      signedIn = ceoId;
      await db.payrollDao.rejectEntry(waiting.id, reason: 'No');
      final s = await pay();
      expect(s.advancesKobo, 0);
      expect(s.cashPaidKobo, 10000000);
    });

    test('advances above a lower typed salary are refused', () async {
      await give('advance', 9000000, month: '2026-10', date: '2026-10-10');
      await expectLater(
        pay(salary: 5000000, reason: 'Half month'),
        violation('more than this salary'),
      );
    });
  });

  group('loan repayment on payday', () {
    setUp(() async {
      await give('loan_given', 5000000, date: '2026-10-01');
    });

    test('is recorded as a loan repayment and lowers what is owed', () async {
      final s = await pay(repay: 2000000);
      expect(s.loanRepaidKobo, 2000000);
      expect(s.cashPaidKobo, 8000000);
      final entries = await db.payrollDao.entriesForWorker(workerId);
      final repaid = entries.singleWhere((e) => e.type == 'loan_repaid');
      expect(repaid.id, payrollSalaryRepaymentId(workerId, '2026-10'));
      expect(repaid.amountKobo, 2000000);
      expect(PayrollMoneyPosition.outstandingLoanKobo(entries), 3000000);
    });

    test('cannot be more than is owed', () async {
      await expectLater(pay(repay: 5000001), violation('owed'));
    });

    test('cannot push the cash paid below zero', () async {
      await give('advance', 8000000, month: '2026-10', date: '2026-10-10');
      final f = await db.payrollDao.paydayFigures(
        workerId: workerId,
        salaryMonth: '2026-10',
      );
      expect(f.maxRepaymentKobo, 2000000);
      await expectLater(pay(repay: 3000000), violation('left of the salary'));
      final s = await pay(repay: 2000000);
      expect(s.cashPaidKobo, 0);
    });

    test('a negative repayment is refused', () async {
      await expectLater(pay(repay: -1), violation());
    });
  });

  group('Total Pay', () {
    test(
      'salary + approved allowances + approved bonuses that month',
      () async {
        await db.payrollDao.postAllowance(
          workerId: workerId,
          entryDate: '2026-10-05',
          amountKobo: 150000,
        );
        await db.payrollDao.postAllowance(
          workerId: workerId,
          entryDate: '2026-10-06',
          amountKobo: 150000,
        );
        // Another month's allowance does not count.
        await db.payrollDao.postAllowance(
          workerId: workerId,
          entryDate: '2026-09-30',
          amountKobo: 150000,
        );
        await give('bonus', 500000, date: '2026-10-20');
        // A Manager's bonus above the limit waits: it does not count.
        signedIn = managerId;
        final waiting = await give('bonus', 6000000, date: '2026-10-21');
        expect(waiting.status, 'pending');
        signedIn = ceoId;
        // Loans are never added.
        await give('loan_given', 2000000, date: '2026-10-02');
        await give('advance', 1000000, month: '2026-10', date: '2026-10-11');

        final s = await pay();
        expect(s.allowancesKobo, 300000);
        expect(s.bonusesKobo, 500000);
        expect(s.totalPayKobo, 10000000 + 300000 + 500000);
        expect(s.cashPaidKobo, 9000000);
      },
    );
  });

  group('signatures', () {
    test('both are required and nothing is saved without them', () async {
      await expectLater(pay(workerSig: null), violation('sign'));
      await expectLater(pay(payerSig: ''), violation('sign'));
      expect(await db.select(db.payrollStatements).get(), isEmpty);
      expect(
        (await db.payrollDao.entriesForWorker(
          workerId,
        )).where((e) => e.type == 'salary_payment'),
        isEmpty,
      );
    });
  });

  group('payday date', () {
    test('an earlier payday is allowed and dates the line', () async {
      final s = await pay(payday: '2026-11-01');
      expect(s.salaryMonth, '2026-10');
      expect((await salaryLines()).single.totalDate, '2026-11-01');
    });

    test('a future payday is refused', () async {
      await expectLater(pay(payday: '2026-11-04'), violation('future'));
    });
  });

  group('the combined Salaries line', () {
    test('one line per store per payday, no worker named', () async {
      final bayo = await db.payrollDao.addWorker(
        storeId: storeId,
        name: 'Bayo Example',
        monthlySalaryKobo: 6000000,
      );
      final chidi = await db.payrollDao.addWorker(
        storeId: store2Id,
        name: 'Chidi Example',
        monthlySalaryKobo: 4000000,
      );
      await pay();
      await pay(worker: bayo, method: 'transfer');
      await pay(worker: chidi);
      final lines = await salaryLines();
      expect(lines, hasLength(2));
      final main = lines.singleWhere((l) => l.storeId == storeId);
      expect(main.amountKobo, 16000000);
      // Only till cash reduces the drawer: the transfer is not in it.
      expect(main.cashKobo, 10000000);
      expect(
        main.id,
        staffPayTotalId(
          businessId,
          storeId,
          kStaffPayKindSalaries,
          '2026-11-03',
        ),
      );
      final annex = lines.singleWhere((l) => l.storeId == store2Id);
      expect(annex.amountKobo, 4000000);
      final payloads = await db
          .customSelect(
            'SELECT payload FROM sync_queue WHERE action_type = ?',
            variables: [Variable.withString('staff_pay_totals:upsert')],
          )
          .get();
      final text =
          '${lines.map((l) => l.toJson()).join()} '
          '${payloads.map((r) => r.read<String>('payload')).join()}';
      for (final secret in ['Ada', 'Bayo', 'Chidi', workerId, bayo, chidi]) {
        expect(text, isNot(contains(secret)));
      }
    });

    test('cash paid is net of advances and the repayment', () async {
      await give('advance', 3000000, month: '2026-10', date: '2026-10-10');
      await give('loan_given', 5000000, date: '2026-10-01');
      await pay(repay: 1000000);
      final line = (await salaryLines()).single;
      expect(line.amountKobo, 10000000);
      expect(line.cashKobo, 6000000);
    });

    test(
      'Daily Reconciliation: salary is a cost, only cash leaves the drawer',
      () {
        final line = StaffPayTotalData(
          id: 'x',
          businessId: 'b',
          storeId: 's',
          kind: kStaffPayKindSalaries,
          totalDate: '2026-11-03',
          amountKobo: 16000000,
          cashKobo: 10000000,
          createdAt: _now,
          lastUpdatedAt: _now,
        );
        ReconData recon(List<StaffPayTotalData> t, {String? scope}) =>
            reconDataFrom(
              ReconInputs(
                staffPayTotals: t,
                inScope: (s) => scope == null || s == scope,
                start: DateTime(2026, 11, 3),
                endExclusive: DateTime(2026, 11, 4),
              ),
            );
        final none = recon(const []);
        final d = recon([line]);
        expect(d.salariesKobo, 16000000);
        expect(d.cashSalariesKobo, 10000000);
        expect(d.netProfitKobo, none.netProfitKobo - 16000000);
        expect(d.periodNetResultKobo, none.periodNetResultKobo - 16000000);
        expect(d.cashOutKobo, none.cashOutKobo + 10000000);
        expect(d.dailyAllowancesKobo, 0);
        expect(d.isEmpty, isFalse);
        expect(recon([line], scope: 'other').salariesKobo, 0);
        // The next day does not see it.
        expect(
          reconDataFrom(
            ReconInputs(
              staffPayTotals: [line],
              start: DateTime(2026, 11, 4),
              endExclusive: DateTime(2026, 11, 5),
            ),
          ).salariesKobo,
          0,
        );
      },
    );

    test('Expenses: listed as "Salaries" and counted in spent', () {
      StaffPayTotalData l(String kind, String day, int kobo) =>
          StaffPayTotalData(
            id: '$kind$day',
            businessId: 'b',
            storeId: 's',
            kind: kind,
            totalDate: day,
            amountKobo: kobo,
            cashKobo: kobo,
            createdAt: _now,
            lastUpdatedAt: _now,
          );
      final lines = staffPayLinesInScope([
        l(kStaffPayKindSalaries, '2026-11-03', 16000000),
        l(kStaffPayKindDailyAllowances, '2026-11-03', 30000),
      ], 's');
      expect(lines, hasLength(2));
      expect(lines.map(staffPayLineTitle).toSet(), {
        'Salaries',
        'Daily allowances',
      });
      final s = summarizeExpenses(const [], now: _now, allowanceLines: lines);
      expect(s.spentTodayKobo, 16030000);
      expect(staffPayLinesInScope(lines, 'other'), isEmpty);
    });
  });

  group('logs and notifications', () {
    test('never carry an amount; the CEO hears when a Manager pays', () async {
      await give('loan_given', 5000000, date: '2026-10-01');
      signedIn = managerId;
      await pay(salary: 9876500, reason: 'Short month', repay: 123400);
      final notes = await (db.select(
        db.notifications,
      )..where((n) => n.type.equals('payroll.salary_paid'))).get();
      expect(notes, hasLength(1));
      expect(notes.single.recipientUserId, ceoId);
      expect(notes.single.message, contains('Ada Example'));
      final logs = await (db.select(
        db.activityLogs,
      )..where((l) => l.action.equals('payroll_salary_paid'))).get();
      expect(logs.single.description, contains('Ada Example'));
      for (final text in [
        ...notes.map((n) => n.message),
        ...logs.map((l) => l.description),
      ]) {
        // The month name ("October 2026") is the only number allowed.
        expect(
          text.replaceAll('October 2026', ''),
          isNot(matches(RegExp(r'\d'))),
        );
      }
    });

    test('the CEO paying notifies nobody', () async {
      await pay();
      expect(
        await (db.select(
          db.notifications,
        )..where((n) => n.type.equals('payroll.salary_paid'))).get(),
        isEmpty,
      );
    });
  });

  test('without the Payroll permission nothing is written', () async {
    signedIn = cashierId;
    await expectLater(pay(), throwsA(isA<PayrollAccessDenied>()));
    signedIn = ceoId;
    expect(await db.select(db.payrollStatements).get(), isEmpty);
  });

  test('the payslip prints Total Pay and fits the paper', () async {
    final s = await pay();
    final data = PayslipData.fromStatement(
      statement: s,
      businessName: 'Test Shop',
      workerName: 'ada example',
      storeName: 'Main Store',
      loanOwedKobo: 250000,
      payerName: 'Test Owner',
    );
    for (final size in ReceiptPaperSize.values) {
      final lines = buildPayslipLines(data, size);
      final plain = lines.map((l) => l.plain).toList();
      expect(plain.any((l) => l.startsWith('TOTAL PAY')), isTrue);
      expect(plain.any((l) => l.contains('Ada Example')), isTrue);
      expect(plain.any((l) => l.startsWith('Loan still owed')), isTrue);
      for (final l in plain) {
        expect(l.length, lessThanOrEqualTo(size.charsPerLine));
      }
    }
  });
}
