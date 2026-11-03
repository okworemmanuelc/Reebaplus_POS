// payroll_overview_test.dart — #723: the figures behind the Payroll screens.
// Fixture names are made up (public repo).

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';

PayrollWorkerData worker({
  String id = 'w1',
  String name = 'Ada Example',
  int salary = 9000000,
  int? payday,
  bool removed = false,
  DateTime? created,
}) => PayrollWorkerData(
  id: id,
  businessId: 'b',
  storeId: 's',
  name: name,
  monthlySalaryKobo: salary,
  dailyAllowanceKobo: 0,
  paydayDay: payday,
  isRemoved: removed,
  createdAt: created ?? DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

var _n = 0;

PayrollEntryData entry(
  String type,
  int kobo,
  String date, {
  String workerId = 'w1',
  String? id,
  String? month,
  String method = 'cash',
  String status = 'approved',
  String? note,
  String? corrects,
  int? plan,
}) => PayrollEntryData(
  id: id ?? 'e${_n++}',
  businessId: 'b',
  workerId: workerId,
  storeId: 's',
  type: type,
  amountKobo: kobo,
  entryDate: date,
  salaryMonth: month,
  paymentMethod: method,
  note: note,
  correctsEntryId: corrects,
  status: status,
  monthlyRepaymentKobo: plan,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

PayrollStatementData statement({
  String workerId = 'w1',
  String month = '2026-11',
  int salary = 9000000,
  int advances = 0,
  int repaid = 0,
  int cash = 9000000,
  String? salaryEntryId,
}) => PayrollStatementData(
  id: 'st-$workerId-$month',
  businessId: 'b',
  workerId: workerId,
  storeId: 's',
  salaryMonth: month,
  salaryKobo: salary,
  allowancesKobo: 0,
  bonusesKobo: 0,
  advancesKobo: advances,
  loanRepaidKobo: repaid,
  cashPaidKobo: cash,
  totalPayKobo: salary,
  salaryEntryId: salaryEntryId,
  createdAt: DateTime(2026, 1, 1),
  lastUpdatedAt: DateTime(2026, 1, 1),
);

void main() {
  setUpAll(() => setActiveCurrencyCode('NGN'));

  group('labels', () {
    test('ordinals', () {
      expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 28, 31].map(payrollOrdinal), [
        '1st', '2nd', '3rd', '4th', '11th', '12th', //
        '13th', '21st', '22nd', '23rd', '28th', '31st',
      ]);
    });

    test('initials', () {
      expect(payrollInitials('Ada Example'), 'AE');
      expect(payrollInitials('Ada'), 'A');
      expect(payrollInitials('Ada Middle Example'), 'AE');
      expect(payrollInitials('  '), '?');
    });

    test('a payday falls inside the month; none means the last day', () {
      expect(payrollPaydayIn(worker(payday: 28), '2026-11'), '2026-11-28');
      expect(payrollPaydayIn(worker(payday: 31), '2026-02'), '2026-02-28');
      expect(payrollPaydayIn(worker(), '2026-11'), '2026-11-30');
    });

    test('month shifts cross the year', () {
      expect(payrollShiftMonth('2026-12', 1), '2027-01');
      expect(payrollShiftMonth('2026-01', -1), '2025-12');
    });

    test('bonus notes round-trip', () {
      expect(
        payrollBonusNote('Offloading', ' Test truck '),
        'Offloading: Test truck',
      );
      expect(payrollBonusNote('Extra work', ''), 'Extra work');
      expect(payrollBonusNote(null, 'Thanks'), 'Thanks');
      expect(payrollBonusNote(null, ''), isNull);
      final parsed = payrollParseBonusNote('Offloading: Test truck');
      expect(parsed.reason, 'Offloading');
      expect(parsed.detail, 'Test truck');
      expect(payrollParseBonusNote('Extra work').detail, isNull);
      expect(payrollParseBonusNote('Thanks').reason, isNull);
    });
  });

  group('loans', () {
    test('the mockup: part 2 of 6, last repayment March 2027', () {
      final entries = [
        entry('loan_given', 6000000, '2026-10-10', plan: 1000000),
        entry('loan_repaid', 1000000, '2026-10-28'),
      ];
      final row = PayrollWorkerMonth.from(
        worker: worker(),
        entries: entries,
        month: '2026-11',
      );
      expect(row.figures.loanRepaymentKobo, 1000000);
      expect(row.cashKobo, 8000000);
      expect(row.owedAfterMonthKobo, 4000000);
      expect(row.repaidAfterMonthKobo, 2000000);
      expect(row.loan.partNumber(row.repaidAfterMonthKobo), 2);
      expect(row.loan.totalParts, 6);
      expect(
        row.loan.lastRepaymentMonth('2026-11', row.owedAfterMonthKobo),
        '2027-03',
      );
    });

    test('the plan never takes more than what is owed', () {
      final row = PayrollWorkerMonth.from(
        worker: worker(),
        entries: [
          entry('loan_given', 6000000, '2026-01-10', plan: 1000000),
          entry('loan_repaid', 5500000, '2026-10-28'),
        ],
        month: '2026-11',
      );
      expect(row.figures.loanRepaymentKobo, 500000);
    });

    test('the plan never takes more than is left of the salary', () {
      final row = PayrollWorkerMonth.from(
        worker: worker(salary: 1200000),
        entries: [
          entry('loan_given', 6000000, '2026-10-10', plan: 1000000),
          entry('advance', 1000000, '2026-11-02', month: '2026-11'),
        ],
        month: '2026-11',
      );
      expect(row.figures.loanRepaymentKobo, 200000);
      expect(row.cashKobo, 0);
    });

    test('an old loan with no plan takes nothing automatically', () {
      final row = PayrollWorkerMonth.from(
        worker: worker(),
        entries: [entry('loan_given', 3000000, '2026-09-01')],
        month: '2026-11',
      );
      expect(row.loan.hasPlan, isFalse);
      expect(row.loan.hasLoan, isTrue);
      expect(row.figures.loanRepaymentKobo, 0);
      expect(row.cashKobo, 9000000);
      expect(row.loan.lastRepaymentMonth('2026-11', 3000000), isNull);
    });

    test('waiting and rejected loans are not owed', () {
      final loan = PayrollLoanSummary.from([
        entry('loan_given', 3000000, '2026-09-01', status: 'pending'),
        entry('loan_given', 1000000, '2026-09-02', status: 'rejected'),
      ]);
      expect(loan.hasLoan, isFalse);
      expect(loan.lentKobo, 0);
    });
  });

  group('the month', () {
    PayrollMonthView build(
      List<PayrollWorkerData> workers,
      List<PayrollEntryData> entries,
      List<PayrollStatementData> statements,
    ) => PayrollMonthView.build(
      workers: workers,
      entries: entries,
      statements: statements,
      month: '2026-11',
      today: DateTime(2026, 11, 27),
    );

    test('the bill is what is paid plus what is left, after deductions', () {
      final paidEntry = entry(
        'salary_payment',
        6000000,
        '2026-11-25',
        workerId: 'w2',
        month: '2026-11',
      );
      final view = build(
        [worker(), worker(id: 'w2', name: 'Ben Sample', salary: 6000000)],
        [entry('advance', 1500000, '2026-11-12', month: '2026-11'), paidEntry],
        [
          statement(
            workerId: 'w2',
            salary: 6000000,
            cash: 6000000,
            salaryEntryId: paidEntry.id,
          ),
        ],
      );
      expect(view.paidKobo, 6000000);
      expect(view.leftKobo, 7500000);
      expect(view.totalKobo, 13500000);
      expect(view.advancesKobo, 1500000);
      expect(view.paidCount, 1);
      expect(view.unpaidCount, 1);
      expect(view.paidShare, closeTo(0.444, 0.001));
    });

    test('unpaid workers come first', () {
      final paidEntry = entry(
        'salary_payment',
        9000000,
        '2026-11-25',
        workerId: 'a',
        month: '2026-11',
      );
      final view = build(
        [worker(id: 'a', name: 'Aaa'), worker(id: 'z', name: 'Zed')],
        [paidEntry],
        [statement(workerId: 'a', salaryEntryId: paidEntry.id)],
      );
      expect(view.rows.map((r) => r.worker.id), ['z', 'a']);
      expect(view.rows.last.paidOn, '2026-11-25');
    });

    test('a removed worker shows only in a month they were paid', () {
      final gone = worker(removed: true);
      expect(build([gone], const [], const []).rows, isEmpty);
      expect(build([gone], const [], [statement()]).rows, hasLength(1));
    });

    test('a worker added later is not on an earlier month', () {
      final late = worker(created: DateTime(2026, 12, 1));
      expect(build([late], const [], const []).rows, isEmpty);
    });

    test('today counts allowances net of a cancel', () {
      final a = entry('allowance', 150000, '2026-11-27', id: 'a1');
      final b = entry(
        'allowance',
        150000,
        '2026-11-27',
        id: 'b1',
        workerId: 'w2',
      );
      final view = build(
        [worker(), worker(id: 'w2', name: 'Ben Sample')],
        [
          a,
          b,
          entry(
            'allowance',
            -150000,
            '2026-11-27',
            corrects: 'b1',
            workerId: 'w2',
          ),
        ],
        const [],
      );
      expect(view.todayAllowanceStaff, 1);
      expect(view.todayAllowanceKobo, 150000);
    });

    test('allowance days leave out a cancelled day', () {
      final row = PayrollWorkerMonth.from(
        worker: worker(),
        entries: [
          entry('allowance', 150000, '2026-11-02', id: 'd1'),
          entry('allowance', 150000, '2026-11-03', id: 'd2'),
          entry('allowance', -150000, '2026-11-04', corrects: 'd2'),
        ],
        month: '2026-11',
      );
      expect(row.allowanceDays, 1);
      expect(row.figures.allowancesKobo, 150000);
    });
  });

  group('history', () {
    final workers = [
      worker(),
      worker(id: 'w2', name: 'Ben Sample'),
      worker(id: 'w3', name: 'Cal Test'),
    ];

    List<PayrollHistoryRow> rows(
      List<PayrollEntryData> entries, {
      List<PayrollStatementData> statements = const [],
      String? month = '2026-11',
      String? workerId,
    }) => payrollHistoryRows(
      workers: workers,
      entries: entries,
      statements: statements,
      month: month,
      workerId: workerId,
    );

    test("a day's allowances collapse into one line for all staff", () {
      final r = rows([
        entry('allowance', 150000, '2026-11-27'),
        entry('allowance', 150000, '2026-11-27', workerId: 'w2'),
        entry('allowance', 150000, '2026-11-26', workerId: 'w2'),
      ]);
      expect(r, hasLength(2));
      expect(r.first.staffCount, 2);
      expect(r.first.amountKobo, 300000);
      expect(r.first.title, 'Daily allowances');
      expect(r.first.staffLabel, '2 staff');
      expect(r.last.workerName, 'Ben Sample');
    });

    test('the same bonus collapses; a different note does not', () {
      final r = rows([
        entry('bonus', 200000, '2026-11-25', note: 'Offloading: Truck A'),
        entry(
          'bonus',
          200000,
          '2026-11-25',
          note: 'Offloading: Truck A',
          workerId: 'w2',
        ),
        entry(
          'bonus',
          200000,
          '2026-11-25',
          note: 'Offloading: Truck B',
          workerId: 'w3',
        ),
      ]);
      expect(r, hasLength(2));
      final group = r.firstWhere((x) => x.staffCount == 2);
      expect(group.amountKobo, 400000);
      expect(group.title, 'Offloading bonus');
      expect(group.details, 'Truck A');
      expect(group.entry, isNull);
    });

    test('one worker sees their own lines, never a group', () {
      final r = rows([
        entry('allowance', 150000, '2026-11-27'),
        entry('allowance', 150000, '2026-11-27', workerId: 'w2'),
        entry('bonus', 200000, '2026-11-25', note: 'Offloading'),
      ], workerId: 'w1');
      expect(r, hasLength(2));
      expect(r.every((x) => x.staffCount == 1), isTrue);
    });

    test('a correction moves its entry and never shows alone', () {
      final r = rows([
        entry('bonus', 200000, '2026-11-25', id: 'b1'),
        entry('bonus', -50000, '2026-11-27', corrects: 'b1'),
      ]);
      expect(r.single.amountKobo, 150000);
      expect(r.single.date, '2026-11-25');
    });

    test('a fully cancelled allowance day drops out', () {
      final r = rows([
        entry('allowance', 150000, '2026-11-26', id: 'a1'),
        entry('allowance', -150000, '2026-11-27', corrects: 'a1'),
      ]);
      expect(r, isEmpty);
    });

    test('a salary shows the cash and mentions the advance', () {
      final e = entry(
        'salary_payment',
        9000000,
        '2026-11-25',
        month: '2026-11',
      );
      final r = rows(
        [e],
        statements: [
          statement(advances: 1000000, cash: 8000000, salaryEntryId: e.id),
        ],
      );
      expect(r.single.amountKobo, 8000000);
      expect(r.single.details, 'After ₦10,000 advance');
      expect(r.single.statementId, isNotNull);
    });

    test('rejected entries are left out; waiting ones are not counted', () {
      final r = rows([
        entry('bonus', 100, '2026-11-25', status: 'rejected'),
        entry('bonus', 200, '2026-11-25', status: 'pending'),
        entry('bonus', 400, '2026-11-25'),
      ]);
      expect(r, hasLength(2));
      expect(PayrollHistoryTotals.of(r).totalKobo, 400);
    });

    test('a repayment is money in, not paid out', () {
      final r = rows([
        entry('loan_given', 1000000, '2026-11-02', plan: 100000),
        entry('loan_repaid', 100000, '2026-11-25'),
      ]);
      final totals = PayrollHistoryTotals.of(r);
      expect(totals.loansKobo, 1000000);
      expect(r.first.isMoneyIn, isTrue);
      expect(r.last.details, '₦1,000 a month for 10 months');
    });

    test('newest day first; salary before allowance on a day', () {
      final r = rows([
        entry('allowance', 1, '2026-11-25'),
        entry('salary_payment', 1, '2026-11-25', month: '2026-11'),
        entry('bonus', 1, '2026-11-27'),
      ]);
      expect(r.map((x) => x.kind), [
        PayrollKind.bonus,
        PayrollKind.salary,
        PayrollKind.allowance,
      ]);
    });

    test('the breakdown leaves empty kinds out', () {
      const t = PayrollHistoryTotals(
        salariesKobo: 22500000,
        allowancesKobo: 0,
        bonusesKobo: 3800000,
        advancesKobo: 0,
        loansKobo: 0,
      );
      expect(t.breakdown, 'Salaries ₦225,000, bonuses ₦38,000');
      expect(t.totalKobo, 26300000);
    });
  });
}
