part of 'daos.dart';

// ---------------------------------------------------------------------------
// #671 — Payday: the salary payment, both signatures, Total Pay and the
// combined "Salaries" line (PRD #666, ADR 0034).
//
// Kept apart from the other Payroll files (an extension on PayrollDao) so the
// slices never edit the same lines.
//
// THE RULES (owner, 2026-11-03)
//   * One salary payment per worker per Salary Month (the calendar month
//     worked). #696: any unpaid month, the current one included, may be paid
//     — the old "month must have ended" rule is gone. The statement id ([payrollStatementId]) and
//     the salary entry id ([payrollSalaryEntryId]) are deterministic, so two
//     phones paying the same month offline land as ONE row in the cloud.
//   * The full monthly salary by default; a different amount for that one
//     month needs a reason. The worker's normal salary never changes here.
//   * Cash = salary − that month's APPROVED advances − the loan repayment
//     chosen on the day. Never below zero. A waiting advance for the month
//     must be decided first. The repayment is a `loan_repaid` entry.
//   * Total Pay = salary + that month's approved Daily Allowances + approved
//     Bonuses. Advances and loans are never added.
//   * Payday defaults to today; any earlier day may be picked freely, never
//     a future one.
//   * Both the worker and the payer sign before anything is saved.
//   * Goes straight through (no approval). The CEO is told when someone else
//     paid (name only).
//   * Every phone sees ONE combined "Salaries" line per store per payday
//     ([StaffPayTotals], kind 'salaries') with no worker named: the salary as
//     the cost, and the cash handed over from the till as cash.
//   * Activity Logs and notifications never carry an amount.
// ---------------------------------------------------------------------------

/// The deterministic id of [workerId]'s salary payment entry for
/// [salaryMonth] ('YYYY-MM') — one per worker per month on every phone.
String payrollSalaryEntryId(String workerId, String salaryMonth) =>
    UuidV7.deterministic('payroll_salary:$workerId:$salaryMonth');

/// The deterministic id of the loan repayment taken out of [workerId]'s
/// [salaryMonth] salary.
String payrollSalaryRepaymentId(String workerId, String salaryMonth) =>
    UuidV7.deterministic('payroll_salary_repayment:$workerId:$salaryMonth');

/// 'YYYY-MM' of [d].
String payrollMonthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// The Salary Months a payday on [payday] can settle, newest first:
/// [payday]'s own month and the [count] − 1 calendar months before it (#696:
/// the current month may be paid before it ends).
List<String> payrollPayableMonths(DateTime payday, {int count = 12}) => [
  for (var i = 0; i < count; i++)
    payrollMonthKey(DateTime(payday.year, payday.month - i)),
];

/// The figures of one worker's payday for one Salary Month. Pure, so the
/// screen and the write boundary always agree.
class PaydayFigures {
  const PaydayFigures({
    required this.salaryMonth,
    required this.normalSalaryKobo,
    required this.salaryKobo,
    required this.allowancesKobo,
    required this.bonusesKobo,
    required this.advancesKobo,
    required this.pendingAdvancesKobo,
    required this.loanOwedKobo,
    required this.loanRepaymentKobo,
  });

  final String salaryMonth;

  /// The worker's normal monthly salary.
  final int normalSalaryKobo;

  /// The salary paid for this month (the normal one unless typed).
  final int salaryKobo;
  final int allowancesKobo;
  final int bonusesKobo;

  /// Approved advances against this month.
  final int advancesKobo;

  /// Advances against this month still waiting for the CEO.
  final int pendingAdvancesKobo;

  /// What the worker still owes on staff loans.
  final int loanOwedKobo;
  final int loanRepaymentKobo;

  /// Whether the salary differs from the normal one (a reason is needed).
  bool get salaryChanged => salaryKobo != normalSalaryKobo;

  /// What is left of the salary after this month's advances (never < 0).
  int get afterAdvancesKobo {
    final left = salaryKobo - advancesKobo;
    return left < 0 ? 0 : left;
  }

  /// The most that may be repaid today: what is owed, and no more than what
  /// is left of the salary after advances.
  int get maxRepaymentKobo {
    final owed = loanOwedKobo < 0 ? 0 : loanOwedKobo;
    return owed < afterAdvancesKobo ? owed : afterAdvancesKobo;
  }

  /// The money handed over on payday.
  int get cashPaidKobo => salaryKobo - advancesKobo - loanRepaymentKobo;

  /// Salary + Daily Allowances + Bonuses. Advances and loans are not added.
  int get totalPayKobo => salaryKobo + allowancesKobo + bonusesKobo;

  /// Works out the figures from [entries] (one worker's, any status).
  factory PaydayFigures.from({
    required PayrollWorkerData worker,
    required Iterable<PayrollEntryData> entries,
    required String salaryMonth,
    int? salaryKobo,
    int loanRepaymentKobo = 0,
  }) {
    final approved = entries.where((e) => e.status == 'approved').toList();
    final originals = {
      for (final e in approved)
        if (e.correctsEntryId == null) e.id: e,
    };
    // A correction counts in the month of the entry it corrects.
    bool inMonth(PayrollEntryData e) {
      final date = e.correctsEntryId == null
          ? e.entryDate
          : (originals[e.correctsEntryId]?.entryDate ?? e.entryDate);
      return date.startsWith('$salaryMonth-');
    }

    int sumOf(String type) => approved
        .where((e) => e.type == type && inMonth(e))
        .fold(0, (s, e) => s + e.amountKobo);

    return PaydayFigures(
      salaryMonth: salaryMonth,
      normalSalaryKobo: worker.monthlySalaryKobo,
      salaryKobo: salaryKobo ?? worker.monthlySalaryKobo,
      allowancesKobo: sumOf('allowance'),
      bonusesKobo: sumOf('bonus'),
      advancesKobo: approved
          .where((e) => e.type == 'advance' && e.salaryMonth == salaryMonth)
          .fold(0, (s, e) => s + e.amountKobo),
      pendingAdvancesKobo: entries
          .where(
            (e) =>
                e.type == 'advance' &&
                e.status == 'pending' &&
                e.salaryMonth == salaryMonth,
          )
          .fold(0, (s, e) => s + e.amountKobo),
      loanOwedKobo: PayrollMoneyPosition.outstandingLoanKobo(entries),
      loanRepaymentKobo: loanRepaymentKobo,
    );
  }
}

/// Payday (#671).
extension PayrollPayday on PayrollDao {
  /// The payday figures for [workerId] and [salaryMonth] as they stand.
  Future<PaydayFigures> paydayFigures({
    required String workerId,
    required String salaryMonth,
    int? salaryKobo,
    int loanRepaymentKobo = 0,
  }) async {
    final businessId = requireBusinessId();
    final worker =
        await (select(payrollWorkers)..where(
              (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
            ))
            .getSingle();
    final entries = await entriesForWorker(workerId);
    return PaydayFigures.from(
      worker: worker,
      entries: entries,
      salaryMonth: salaryMonth,
      salaryKobo: salaryKobo,
      loanRepaymentKobo: loanRepaymentKobo,
    );
  }

  /// Pays [workerId]'s salary for [salaryMonth] ('YYYY-MM') and saves the
  /// signed statement. [salaryKobo] null = the normal monthly salary; any
  /// other amount needs [reason]. [paydayDate] ('YYYY-MM-DD') defaults to
  /// today and may not be in the future. Both signatures (base64 PNG) are
  /// required. Throws [PayrollAccessDenied] without the permission and
  /// [PayrollRuleViolation] (message for the screen) when a rule is broken.
  Future<PayrollStatementData> paySalary({
    required String workerId,
    required String salaryMonth,
    int? salaryKobo,
    String? reason,
    int loanRepaymentKobo = 0,
    required String paymentMethod,
    String? paydayDate,
    required String? workerSignaturePng,
    required String? payerSignaturePng,
    DateTime? now,
  }) async {
    if (!kPayrollPaymentMethods.contains(paymentMethod)) {
      throw ArgumentError.value(paymentMethod, 'paymentMethod');
    }
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(salaryMonth)) {
      throw ArgumentError.value(salaryMonth, 'salaryMonth', 'not YYYY-MM');
    }
    final businessId = await _requireAccess();
    if ((workerSignaturePng ?? '').isEmpty ||
        (payerSignaturePng ?? '').isEmpty) {
      throw const PayrollRuleViolation(
        'Both the worker and the payer must sign before saving.',
      );
    }
    final today = payrollDayKey(now ?? DateTime.now());
    final payday = paydayDate ?? today;
    final paydayDay = payrollParseDay(payday);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(payday) || paydayDay == null) {
      throw ArgumentError.value(paydayDate, 'paydayDate', 'not YYYY-MM-DD');
    }
    if (payday.compareTo(today) > 0) {
      throw const PayrollRuleViolation('The payday cannot be in the future.');
    }
    // #696/#704: the payday's own month may be paid before it ends; a month
    // that has not started yet on the chosen payday is refused.
    if (salaryMonth.compareTo(payrollMonthKey(paydayDay)) > 0) {
      throw PayrollRuleViolation(
        '${payrollMonthLabel(salaryMonth)} has not started yet.',
      );
    }
    if (salaryKobo != null && salaryKobo < 0) {
      throw const PayrollRuleViolation('Enter a salary amount.');
    }
    if (loanRepaymentKobo < 0) {
      throw const PayrollRuleViolation('Enter a loan repayment of 0 or more.');
    }
    final trimmedReason = reason?.trim() ?? '';

    late PayrollStatementData saved;
    late PayrollWorkerData paidWorker;
    await transaction(() async {
      final worker =
          await (select(payrollWorkers)..where(
                (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
              ))
              .getSingle();
      paidWorker = worker;
      final statementId = payrollStatementId(workerId, salaryMonth);
      final salaryEntryId = payrollSalaryEntryId(workerId, salaryMonth);
      final alreadyPaid =
          await (select(payrollStatements)..where(
                (s) =>
                    s.businessId.equals(businessId) &
                    (s.id.equals(statementId) |
                        (s.workerId.equals(workerId) &
                            s.salaryMonth.equals(salaryMonth))),
              ))
              .get();
      final salaryEntries =
          await (select(payrollEntries)..where(
                (e) =>
                    e.businessId.equals(businessId) &
                    (e.id.equals(salaryEntryId) |
                        (e.workerId.equals(workerId) &
                            e.type.equals('salary_payment') &
                            e.salaryMonth.equals(salaryMonth) &
                            e.correctsEntryId.isNull())),
              ))
              .get();
      if (alreadyPaid.isNotEmpty || salaryEntries.isNotEmpty) {
        throw PayrollRuleViolation(
          '${worker.name} has already been paid for '
          '${payrollMonthLabel(salaryMonth)}.',
        );
      }

      final entries = await entriesForWorker(workerId);
      final f = PaydayFigures.from(
        worker: worker,
        entries: entries,
        salaryMonth: salaryMonth,
        salaryKobo: salaryKobo,
        loanRepaymentKobo: loanRepaymentKobo,
      );
      if (f.salaryChanged && trimmedReason.isEmpty) {
        throw const PayrollRuleViolation(
          'Give a reason for paying a different amount this month.',
        );
      }
      if (f.pendingAdvancesKobo > 0) {
        throw PayrollRuleViolation(
          'An advance for ${payrollMonthLabel(salaryMonth)} is waiting for '
          'CEO approval. Approve or reject it first.',
        );
      }
      if (f.advancesKobo > f.salaryKobo) {
        throw PayrollRuleViolation(
          'Advances for ${payrollMonthLabel(salaryMonth)} '
          '(${formatCurrency(f.advancesKobo / 100)}) are more than this '
          'salary.',
        );
      }
      if (loanRepaymentKobo > 0 && loanRepaymentKobo > f.loanOwedKobo) {
        throw PayrollRuleViolation(
          f.loanOwedKobo <= 0
              ? '${worker.name} does not owe anything.'
              : 'A repayment cannot be more than what is owed '
                    '(${formatCurrency(f.loanOwedKobo / 100)}).',
        );
      }
      if (f.cashPaidKobo < 0) {
        throw PayrollRuleViolation(
          'The loan repayment cannot be more than what is left of the salary '
          '(${formatCurrency(f.afterAdvancesKobo / 100)}).',
        );
      }

      final at = DateTime.now();
      final monthLabel = payrollMonthLabel(salaryMonth);
      final salaryRow = PayrollEntriesCompanion.insert(
        id: Value(salaryEntryId),
        businessId: businessId,
        workerId: workerId,
        storeId: worker.storeId,
        type: 'salary_payment',
        amountKobo: f.salaryKobo,
        entryDate: payday,
        salaryMonth: Value(salaryMonth),
        paymentMethod: Value(paymentMethod),
        note: Value(
          f.salaryChanged
              ? 'Different amount this month: $trimmedReason'
              : null,
        ),
        status: const Value('approved'),
        recordedBy: Value(currentUserId),
        approvedBy: Value(currentUserId),
        approvedAt: Value(at),
        createdAt: Value(at),
        lastUpdatedAt: Value(at),
      );
      await into(payrollEntries).insert(salaryRow);
      await db.syncDao.enqueueUpsert('payroll_entries', salaryRow);

      if (loanRepaymentKobo > 0) {
        // Kept back from the salary, not handed over at the till.
        final repayRow = PayrollEntriesCompanion.insert(
          id: Value(payrollSalaryRepaymentId(workerId, salaryMonth)),
          businessId: businessId,
          workerId: workerId,
          storeId: worker.storeId,
          type: 'loan_repaid',
          amountKobo: loanRepaymentKobo,
          entryDate: payday,
          paymentMethod: const Value('other'),
          note: Value('Taken from $monthLabel salary'),
          status: const Value('approved'),
          recordedBy: Value(currentUserId),
          approvedBy: Value(currentUserId),
          approvedAt: Value(at),
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        );
        await into(payrollEntries).insert(repayRow);
        await db.syncDao.enqueueUpsert('payroll_entries', repayRow);
      }

      final statement = PayrollStatementsCompanion.insert(
        id: Value(statementId),
        businessId: businessId,
        workerId: workerId,
        storeId: worker.storeId,
        salaryMonth: salaryMonth,
        salaryKobo: Value(f.salaryKobo),
        allowancesKobo: Value(f.allowancesKobo),
        bonusesKobo: Value(f.bonusesKobo),
        advancesKobo: Value(f.advancesKobo),
        loanRepaidKobo: Value(loanRepaymentKobo),
        cashPaidKobo: Value(f.cashPaidKobo),
        totalPayKobo: Value(f.totalPayKobo),
        salaryEntryId: Value(salaryEntryId),
        workerSignaturePng: Value(workerSignaturePng),
        payerSignaturePng: Value(payerSignaturePng),
        signedBy: Value(currentUserId),
        signedAt: Value(at),
        createdAt: Value(at),
        lastUpdatedAt: Value(at),
      );
      await into(payrollStatements).insert(statement);
      await db.syncDao.enqueueUpsert('payroll_statements', statement);

      // Worker name and month only — Activity Logs reach every phone.
      await db.activityLogDao.log(
        action: 'payroll_salary_paid',
        description: 'Paid $monthLabel salary: ${worker.name}',
        staffId: currentUserId,
        storeId: worker.storeId,
      );
      await _refreshSalaryTotals(businessId);
      saved = await (select(
        payrollStatements,
      )..where((s) => s.id.equals(statementId))).getSingle();
    });

    // The CEO hears when someone else paid (name only, never an amount).
    if (!await currentUserIsPayrollApprover()) {
      final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
      for (final uid in ceoIds) {
        if (uid == currentUserId) continue;
        await db.notificationsDao.fireNotification(
          type: 'payroll.salary_paid',
          message:
              "${paidWorker.name}'s ${payrollMonthLabel(salaryMonth)} salary "
              'was paid',
          linkedRecordId: saved.id,
          recipientUserId: uid,
        );
      }
    }
    return saved;
  }

  /// [workerId]'s signed salary statements, newest month first.
  Stream<List<PayrollStatementData>> watchStatementsForWorker(
    String workerId,
  ) =>
      (select(payrollStatements)
            ..where((s) => s.workerId.equals(workerId) & whereBusiness(s))
            ..orderBy([(s) => OrderingTerm.desc(s.salaryMonth)]))
          .watch();

  /// Rewrites the combined "Salaries" lines from this phone's statements. A
  /// silent no-op without the permission. Runs after every pull, so a line
  /// another phone wrote from fewer statements converges.
  Future<void> refreshSalaryTotals() async {
    final businessId = currentBusinessId;
    if (businessId == null) return;
    if (!await currentUserHoldsPayroll()) return;
    await transaction(() => _refreshSalaryTotals(businessId));
  }

  /// One combined line per store and payday: the salaries paid (the cost) and
  /// the part handed over in till cash. Only lines whose figures moved are
  /// written and queued. No worker is named.
  Future<void> _refreshSalaryTotals(String businessId) async {
    final sums = await customSelect(
      'SELECT s.store_id AS store_id, e.entry_date AS day, '
      'SUM(s.salary_kobo) AS total, '
      "SUM(CASE WHEN e.payment_method = 'cash' THEN s.cash_paid_kobo "
      'ELSE 0 END) AS cash '
      'FROM payroll_statements s '
      'JOIN payroll_entries e ON e.id = s.salary_entry_id '
      'WHERE s.business_id = ? '
      'GROUP BY s.store_id, e.entry_date',
      variables: [Variable.withString(businessId)],
      readsFrom: {payrollStatements, payrollEntries},
    ).get();
    final existing = {
      for (final t
          in await (select(db.staffPayTotals)..where(
                (t) =>
                    t.businessId.equals(businessId) &
                    t.kind.equals(kStaffPayKindSalaries),
              ))
              .get())
        t.id: t,
    };
    final at = DateTime.now();
    for (final s in sums) {
      final storeId = s.read<String>('store_id');
      final day = s.read<String>('day');
      final total = s.read<int>('total');
      final cash = s.read<int>('cash');
      final id = staffPayTotalId(
        businessId,
        storeId,
        kStaffPayKindSalaries,
        day,
      );
      final current = existing[id];
      if (current == null && total == 0 && cash == 0) continue;
      if (current != null &&
          current.amountKobo == total &&
          current.cashKobo == cash) {
        continue;
      }
      final row = StaffPayTotalsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        storeId: storeId,
        kind: kStaffPayKindSalaries,
        totalDate: day,
        amountKobo: Value(total),
        cashKobo: Value(cash),
        createdAt: Value(current?.createdAt ?? at),
        lastUpdatedAt: Value(at),
      );
      await into(db.staffPayTotals).insertOnConflictUpdate(row);
      await db.syncDao.enqueueUpsert('staff_pay_totals', row);
    }
  }
}
