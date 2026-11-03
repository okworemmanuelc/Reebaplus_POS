import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart'
    show payrollStatementId, staffPayTotalId;
import 'package:reebaplus_pos/core/database/daos.dart'
    show payrollSalaryEntryId, payrollSalaryRepaymentId;

import '../../../tool/legacy_import/src/export_reader.dart';
import '../../../tool/payroll_import/src/payroll_config.dart';
import '../../../tool/payroll_import/src/payroll_ids.dart';
import '../../../tool/payroll_import/src/payroll_plan.dart';
import '../../../tool/payroll_import/src/payroll_sql.dart';

// Invented data only: the repo is public.
const _biz = '11111111-1111-4111-8111-111111111111';
const _store = 'store-a';
const _manager = 'profile-manager';

Row _staff(String id, String name, int salaryKobo) => Row({
  'id': id,
  'storeId': _store,
  'name': name,
  'role': 'Helper',
  'monthlySalaryCents': '$salaryKobo',
  'isActive': true,
  'createdAt': '2026-01-05T08:00:00.000Z',
});

Row _pay(
  String id,
  String staffId,
  String type,
  int amount,
  String at, {
  String? cancelledAt,
  String? statementId,
  String? note,
}) => Row({
  'id': id,
  'staffId': staffId,
  'type': type,
  'amountCents': '$amount',
  'note': note,
  'createdAt': at,
  'createdByProfileId': _manager,
  'cancelledAt': cancelledAt,
  'statementId': statementId,
});

Row _loan(String id, String staffId, String type, int amount, String? note) =>
    Row({
      'id': id,
      'staffId': staffId,
      'type': type,
      'amountCents': '$amount',
      'note': note,
      'createdAt': '2026-03-20T10:00:00.000Z',
      'createdByProfileId': _manager,
      'cancelledAt': null,
    });

Row _statement(String id, String staffId) => Row({
  'id': id,
  'staffId': staffId,
  'storeId': _store,
  'employeeSignatureDataUrl': 'data:image/png;base64,AAAA',
  'managerSignatureDataUrl': 'data:image/png;base64,BBBB',
  'managerSignedAt': '2026-03-02T09:00:00.000Z',
  'managerSignedByProfileId': _manager,
  'createdAt': '2026-03-02T09:00:00.000Z',
  'cancelledAt': null,
});

PayrollExport _export() => PayrollExport({
  'Staff': [
    _staff('s-ada', 'Ada Test', 100000),
    _staff('s-ben', 'Ben Test', 50000),
    _staff('s-skip', 'Left Out', 10000),
  ],
  'StaffPayrollEntry': [
    _pay(
      'p-ada',
      's-ada',
      'SETTLEMENT',
      100000,
      '2026-03-02T09:00:00.000Z',
      statementId: 'st-ada',
    ),
    _pay(
      'p-ben',
      's-ben',
      'SETTLEMENT',
      50000,
      '2026-03-02T09:00:00.000Z',
      statementId: 'st-ben',
    ),
    // An advance cancelled at once, offset by an ADJUSTMENT.
    _pay(
      'p-adv',
      's-ada',
      'ADVANCE',
      20000,
      '2026-03-20T10:00:00.000Z',
      cancelledAt: '2026-03-20T10:01:00.000Z',
    ),
    _pay(
      'p-adj',
      's-ada',
      'ADJUSTMENT',
      -20000,
      '2026-03-20T10:01:00.050Z',
      note: 'Cancelled',
    ),
    _pay('p-skip', 's-skip', 'SETTLEMENT', 10000, '2026-03-02T09:00:00.000Z'),
  ],
  'StaffLoanEntry': [
    _loan('l-open', 's-ada', 'DISBURSED', 30000, 'Opening loan balance'),
    _loan('l-given', 's-ben', 'DISBURSED', 40000, '15/01/26'),
    _loan('l-paid', 's-ben', 'REPAYMENT', -10000, '02/03/26'),
    _loan('l-vague', 's-ben', 'DISBURSED', 5000, 'Sometime in February'),
  ],
  'StaffPayrollStatement': [
    _statement('st-ada', 's-ada'),
    _statement('st-ben', 's-ben'),
  ],
});

PayrollImportConfig _config({Map<String, String> loanDates = const {}}) =>
    PayrollImportConfig(
      workerIds: const ['s-ada', 's-ben'],
      loanDates: loanDates,
      expected: const PayrollExpected(
        workers: 2,
        statements: 2,
        salaryKobo: 150000,
        cashOutKobo: 140000,
        loanEntries: 4,
        loansOwedKobo: {'s-ada': 30000, 's-ben': 35000},
      ),
    );

PayrollPlan _plan({Map<String, String> loanDates = const {}}) => PayrollPlanner(
  export: _export(),
  config: _config(loanDates: loanDates),
  businessId: _biz,
).build();

void main() {
  test('ids the app derives are minted exactly as the app does', () {
    expect(
      appPayrollStatementId('w', '2026-02'),
      payrollStatementId('w', '2026-02'),
    );
    expect(
      appPayrollSalaryEntryId('w', '2026-02'),
      payrollSalaryEntryId('w', '2026-02'),
    );
    expect(
      appPayrollSalaryRepaymentId('w', '2026-02'),
      payrollSalaryRepaymentId('w', '2026-02'),
    );
    expect(
      appStaffPayTotalId(_biz, 's', 'salaries', '2026-03-02'),
      staffPayTotalId(_biz, 's', 'salaries', '2026-03-02'),
    );
  });

  test('note dates and default Salary Month', () {
    expect(dateFromNote('27/08/26'), '2026-08-27');
    expect(dateFromNote('paid 1/9/2026'), '2026-09-01');
    expect(dateFromNote('31/02/26'), isNull);
    expect(dateFromNote('Sometime in September'), isNull);
    expect(dateFromNote(null), isNull);
    expect(salaryMonthBefore('2026-10-02'), '2026-09');
    expect(salaryMonthBefore('2026-01-03'), '2025-12');
    expect(signatureBase64('data:image/png;base64,QUJD'), 'QUJD');
  });

  test('only listed workers come over, with everything of theirs', () {
    final plan = _plan();
    expect(plan.workers.map((w) => w.name), ['Ada Test', 'Ben Test']);
    expect(
      plan.workers.every((w) => w.storeId == importStoreId(_store)),
      isTrue,
    );
    expect(plan.entries.any((e) => e.legacyId == 'p-skip'), isFalse);
    expect(plan.leftOut, contains(startsWith('Staff s-skip')));
  });

  test('salary payments land in the month before payday, app ids', () {
    final plan = _plan();
    final ada = plan.workers.first;
    final salary = plan.entries.firstWhere((e) => e.legacyId == 'p-ada');
    expect(salary.type, 'salary_payment');
    expect(salary.salaryMonth, '2026-02');
    expect(salary.entryDate, '2026-03-02');
    expect(salary.paymentMethod, 'cash');
    expect(salary.id, appPayrollSalaryEntryId(ada.id, '2026-02'));
  });

  test('a cancelled advance becomes an advance and its correction', () {
    final plan = _plan();
    final advance = plan.entries.firstWhere((e) => e.legacyId == 'p-adv');
    final offset = plan.entries.firstWhere((e) => e.legacyId == 'p-adj');
    expect(advance.amountKobo + offset.amountKobo, 0);
    expect(offset.type, 'advance');
    expect(offset.correctsEntryId, advance.id);
    expect(offset.salaryMonth, advance.salaryMonth);
    expect(plan.entries.last, same(offset), reason: 'corrections go last');
  });

  test('loans: note dates, payday deduction, money still owed', () {
    final plan = _plan(loanDates: {'l-vague': '2026-02-01'});
    PlannedEntry loan(String id) =>
        plan.entries.firstWhere((e) => e.legacyId == id);
    expect(loan('l-open').entryDate, '2026-03-20');
    expect(loan('l-given').entryDate, '2026-01-15');
    expect(loan('l-vague').entryDate, '2026-02-01');
    expect(loan('l-vague').dateSource, 'config');

    final ben = plan.workers[1];
    final deduction = loan('l-paid');
    expect(deduction.type, 'loan_repaid');
    expect(deduction.amountKobo, 10000);
    expect(deduction.paymentMethod, 'other');
    expect(deduction.id, appPayrollSalaryRepaymentId(ben.id, '2026-02'));
    expect(deduction.note, 'Taken from February 2026 salary');

    int owed(String workerId) => plan.entries
        .where((e) => e.workerId == workerId)
        .fold(
          0,
          (s, e) => switch (e.type) {
            'loan_given' => s + e.amountKobo,
            'loan_repaid' => s - e.amountKobo,
            _ => s,
          },
        );
    expect(owed(plan.workers[0].id), 30000);
    expect(owed(ben.id), 35000);
  });

  test('statements carry the payday figures and bare signatures', () {
    final plan = _plan();
    final ben = plan.statements.firstWhere((s) => s.legacyId == 'st-ben');
    expect(ben.id, appPayrollStatementId(plan.workers[1].id, '2026-02'));
    expect(ben.salaryKobo, 50000);
    expect(ben.loanRepaidKobo, 10000);
    expect(ben.cashPaidKobo, 40000);
    expect(ben.totalPayKobo, 50000);
    expect(ben.workerSignaturePng, 'AAAA');
    expect(ben.payerSignaturePng, 'BBBB');
    expect(
      plan.statements.fold(0, (s, x) => s + x.cashPaidKobo),
      _config().expected.cashOutKobo,
    );
  });

  test('combined lines match the app: deduction and zero lines left out', () {
    final plan = _plan(loanDates: {'l-vague': '2026-02-01'});
    final byKey = {
      for (final t in plan.payTotals) '${t.totalDate} ${t.kind}': t,
    };
    expect(byKey['2026-03-02 salaries']!.amountKobo, 150000);
    expect(byKey['2026-03-02 salaries']!.cashKobo, 140000);
    expect(byKey.containsKey('2026-03-02 loans_repaid'), isFalse);
    expect(byKey.containsKey('2026-03-20 advances'), isFalse);
    expect(byKey['2026-03-20 loans_given']!.cashKobo, 30000);
    expect(byKey['2026-01-15 loans_given']!.amountKobo, 40000);
  });

  test('stops instead of guessing', () {
    final orphan = PayrollExport({
      ..._export().tables,
      'StaffPayrollEntry': [
        _pay('p-adj', 's-ada', 'ADJUSTMENT', -500, '2026-03-20T10:00:00.000Z'),
      ],
    });
    expect(
      () => PayrollPlanner(
        export: orphan,
        config: _config(),
        businessId: _biz,
      ).build(),
      throwsA(isA<PayrollImportError>()),
    );
    expect(
      () => PayrollImportConfig.fromJson({
        'workers': ['s-ada'],
        'paymentMethods': {'x': 'card'},
        'expected': <String, Object?>{
          'workers': 1,
          'statements': 0,
          'salaryKobo': 0,
          'cashOutKobo': 0,
          'loanEntries': 0,
        },
      }),
      throwsFormatException,
    );
  });

  test('SQL is insert-only and safe to re-run', () {
    final plan = _plan();
    final sql = buildPayrollImportSql(plan: plan, userId: importUserId);
    expect(sql, isNot(contains(RegExp(r'\bUPDATE\b|\bDELETE\b'))));
    expect(
      RegExp('INSERT INTO').allMatches(sql).length,
      RegExp('ON CONFLICT DO NOTHING;').allMatches(sql).length,
    );
    expect(sql, contains("'AAAA'"));
    final checks = buildPayrollChecksSql(
      plan: plan,
      expected: _config().expected,
    );
    expect(checks, contains("'overall'"));
  });
}
