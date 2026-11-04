part of 'daos.dart';

// #670 (PRD #666): Bonus, Advance and Staff Loan entries, their caps, and CEO
// approval. Kept apart from `daos_payroll.dart` (an extension on PayrollDao)
// so the allowance work (#669) and this slice never edit the same lines.
//
// Rules (CONTEXT.md → Payroll):
//  * Every entry records today's date, how it was paid (Cash / Transfer /
//    Other) and an optional note. A correction is a NEW entry carrying the
//    difference (`corrects_entry_id`), never an edit.
//  * An Advance belongs to a Salary Month and cannot be more than what is left
//    of that month's salary (salary − that month's advances, pending ones
//    included so two waiting advances cannot overspend it). Anything larger
//    must be a Staff Loan.
//  * Outstanding loan = approved loans given − repayments. A repayment cannot
//    be more than is owed.
//  * A Manager's bonus, advance or loan given above their expense limit
//    (`role_settings.max_expense_approval_kobo`, the Expenses limit) lands
//    'pending' until the CEO approves or rejects it. The CEO never waits. A
//    repayment brings money back, so it never waits.
//  * Activity Logs and notifications reach every phone: they may name the
//    worker but NEVER carry an amount.

/// The entry types a person records by hand on this screen.
const Set<String> kPayrollManualEntryTypes = {
  'bonus',
  'advance',
  'loan_given',
  'loan_repaid',
};

/// The types a Manager above their expense limit must send to the CEO.
const Set<String> kPayrollApprovalEntryTypes = {
  'bonus',
  'advance',
  'loan_given',
};

/// A plain-language label for an entry type ("bonus", "advance", ...).
String payrollEntryLabel(String type) => switch (type) {
  'bonus' => 'bonus',
  'advance' => 'salary advance',
  'loan_given' => 'staff loan',
  'loan_repaid' => 'loan repayment',
  'allowance' => 'daily allowance',
  'salary_payment' => 'salary payment',
  _ => 'payroll entry',
};

/// 'YYYY-MM' → "October 2026".
String payrollMonthLabel(String salaryMonth) {
  const names = [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final parts = salaryMonth.split('-');
  final m = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (m == null || m < 1 || m > 12) return salaryMonth;
  return '${names[m - 1]} ${parts[0]}';
}

/// A Payroll rule the entry broke. [message] is shown to the person as is (it
/// may hold an amount: it never reaches Activity Logs).
class PayrollRuleViolation implements Exception {
  const PayrollRuleViolation(this.message);
  final String message;
  @override
  String toString() => 'PayrollRuleViolation: $message';
}

/// Only the CEO approves or rejects a waiting Payroll Entry.
class PayrollApprovalDenied implements Exception {
  const PayrollApprovalDenied();
  @override
  String toString() => 'PayrollApprovalDenied: only the CEO can approve';
}

/// The money position of one worker, worked out from their entries. Pure: the
/// screen and the write boundary call the same functions so they never
/// disagree.
class PayrollMoneyPosition {
  const PayrollMoneyPosition._();

  /// A rejected entry counts for nothing.
  static bool counts(PayrollEntryData e) => e.status != 'rejected';

  /// Approved loans given minus every repayment. A loan still waiting for the
  /// CEO is not owed yet.
  static int outstandingLoanKobo(Iterable<PayrollEntryData> entries) {
    var owed = 0;
    for (final e in entries) {
      if (e.type == 'loan_given' && e.status == 'approved') {
        owed += e.amountKobo;
      }
      if (e.type == 'loan_repaid' && counts(e)) owed -= e.amountKobo;
    }
    return owed;
  }

  /// Loans waiting for the CEO.
  static int pendingLoanKobo(Iterable<PayrollEntryData> entries) => entries
      .where((e) => e.type == 'loan_given' && e.status == 'pending')
      .fold(0, (sum, e) => sum + e.amountKobo);

  /// Every advance against [salaryMonth], waiting ones included.
  static int advancesForMonthKobo(
    Iterable<PayrollEntryData> entries,
    String salaryMonth,
  ) => entries
      .where(
        (e) => e.type == 'advance' && e.salaryMonth == salaryMonth && counts(e),
      )
      .fold(0, (sum, e) => sum + e.amountKobo);

  /// What is left of [salaryKobo] for [salaryMonth] after its advances.
  static int advanceRoomKobo({
    required int salaryKobo,
    required Iterable<PayrollEntryData> entries,
    required String salaryMonth,
  }) {
    final left = salaryKobo - advancesForMonthKobo(entries, salaryMonth);
    return left < 0 ? 0 : left;
  }

  /// [original]'s amount after every counted correction of it.
  static int correctedAmountKobo(
    PayrollEntryData original,
    Iterable<PayrollEntryData> entries,
  ) =>
      original.amountKobo +
      entries
          .where((e) => e.correctsEntryId == original.id && counts(e))
          .fold(0, (sum, e) => sum + e.amountKobo);
}

extension PayrollMoneyEntries on PayrollDao {
  /// This month as 'YYYY-MM' (the phone's calendar).
  static String payrollThisMonth() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}';
  }

  /// The signed-in user's role slug in the bound business (null when none).
  Future<String?> _currentRoleRow(String businessId, {bool id = false}) async {
    final userId = currentUserId;
    if (userId == null) return null;
    final row = await customSelect(
      'SELECT ub.role_id AS role_id, r.slug AS slug '
      'FROM user_businesses ub JOIN roles r ON r.id = ub.role_id '
      "WHERE ub.user_id = ?1 AND ub.business_id = ?2 AND ub.status = 'active' "
      'ORDER BY ub.last_login_at IS NULL, ub.last_login_at DESC LIMIT 1',
      variables: [Variable.withString(userId), Variable.withString(businessId)],
    ).getSingleOrNull();
    return row?.read<String>(id ? 'role_id' : 'slug');
  }

  /// Whether the signed-in user is the CEO of the bound business.
  Future<bool> currentUserIsPayrollApprover() async {
    final businessId = currentBusinessId;
    if (businessId == null) return false;
    return await _currentRoleRow(businessId) == 'ceo';
  }

  /// The most the signed-in user may give without CEO approval, in kobo: the
  /// Expenses limit on their role. Null = no limit (the CEO). A role with no
  /// stored limit gets 0, so everything it gives waits (same as Expenses).
  Future<int?> currentUserPayrollLimitKobo() async {
    final businessId = requireBusinessId();
    if (await _currentRoleRow(businessId) == 'ceo') return null;
    final roleId = await _currentRoleRow(businessId, id: true);
    if (roleId == null) return 0;
    final row = await customSelect(
      'SELECT setting_value FROM role_settings '
      'WHERE business_id = ?1 AND role_id = ?2 AND setting_key = ?3 LIMIT 1',
      variables: [
        Variable.withString(businessId),
        Variable.withString(roleId),
        Variable.withString('max_expense_approval_kobo'),
      ],
    ).getSingleOrNull();
    return int.tryParse(row?.read<String?>('setting_value') ?? '') ?? 0;
  }

  Future<PayrollWorkerData> _worker(String workerId, String businessId) =>
      (select(payrollWorkers)..where(
            (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
          ))
          .getSingle();

  Future<bool> _monthPaid(String workerId, String salaryMonth) async {
    final row =
        await (select(payrollStatements)..where(
              (s) =>
                  s.workerId.equals(workerId) &
                  s.salaryMonth.equals(salaryMonth) &
                  whereBusiness(s),
            ))
            .getSingleOrNull();
    return row != null;
  }

  /// Whether [workerId]'s salary for [salaryMonth] has been paid (signed).
  Future<bool> isSalaryMonthPaid(String workerId, String salaryMonth) =>
      _monthPaid(workerId, salaryMonth);

  /// Records a Bonus, Advance, Loan given or Loan repaid for [workerId], dated
  /// today. With [correctsEntryId], [amountKobo] is the DIFFERENCE to that
  /// entry (negative lowers it) and its type and Salary Month are taken from
  /// it. Throws [PayrollAccessDenied] without the permission and
  /// [PayrollRuleViolation] when a cap is broken. Returns the new entry.
  Future<PayrollEntryData> recordMoneyEntry({
    required String workerId,
    required String type,
    required int amountKobo,
    required String paymentMethod,
    String? salaryMonth,
    String? note,
    String? correctsEntryId,
    String? entryDate,
    // #723: a new staff loan's plan — taken back each payday. Loans only.
    int? monthlyRepaymentKobo,
  }) async {
    if (!kPayrollManualEntryTypes.contains(type)) {
      throw ArgumentError.value(type, 'type', 'not a bonus, advance or loan');
    }
    if (!kPayrollPaymentMethods.contains(paymentMethod)) {
      throw ArgumentError.value(paymentMethod, 'paymentMethod');
    }
    final businessId = await _requireAccess();
    final isCorrection = correctsEntryId != null;
    // #688: today by default; any earlier day may be chosen, never a future one.
    final today = PayrollDao.payrollToday();
    final date = entryDate ?? today;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        DateTime.tryParse(date) == null) {
      throw ArgumentError.value(entryDate, 'entryDate', 'not YYYY-MM-DD');
    }
    if (date.compareTo(today) > 0) {
      throw const PayrollRuleViolation('The date cannot be in the future.');
    }
    if (amountKobo == 0 || (!isCorrection && amountKobo < 0)) {
      throw const PayrollRuleViolation('Enter an amount.');
    }
    if (monthlyRepaymentKobo != null) {
      if (type != 'loan_given' || isCorrection) {
        throw ArgumentError.value(
          monthlyRepaymentKobo,
          'monthlyRepaymentKobo',
          'only a new staff loan has a plan',
        );
      }
      if (monthlyRepaymentKobo <= 0) {
        throw const PayrollRuleViolation('Enter how much to pay back a month.');
      }
      if (monthlyRepaymentKobo > amountKobo) {
        throw const PayrollRuleViolation(
          'The monthly repayment cannot be more than the loan.',
        );
      }
    }
    final limit = await currentUserPayrollLimitKobo();
    final trimmedNote = note?.trim();

    return transaction(() async {
      final worker = await _worker(workerId, businessId);
      final entries = await (select(
        payrollEntries,
      )..where((e) => e.workerId.equals(workerId) & whereBusiness(e))).get();
      final label = payrollEntryLabel(type);

      var month = salaryMonth;
      if (isCorrection) {
        final original = entries
            .where((e) => e.id == correctsEntryId)
            .firstOrNull;
        if (original == null || original.type != type) {
          throw const PayrollRuleViolation('That entry cannot be corrected.');
        }
        if (original.status != 'approved' || original.correctsEntryId != null) {
          throw const PayrollRuleViolation(
            'Only an approved entry can be corrected.',
          );
        }
        if (PayrollMoneyPosition.correctedAmountKobo(original, entries) +
                amountKobo <
            0) {
          throw const PayrollRuleViolation(
            'A correction cannot take the entry below zero.',
          );
        }
        month = original.salaryMonth;
      } else if (worker.isRemoved && type != 'loan_repaid') {
        throw PayrollRuleViolation(
          '${worker.name} has been removed from Payroll.',
        );
      }

      if (type == 'advance') {
        month ??= PayrollMoneyEntries.payrollThisMonth();
        // #704: never against a month that has not started on the entry date.
        if (!isCorrection && month.compareTo(date.substring(0, 7)) > 0) {
          throw PayrollRuleViolation(
            '${payrollMonthLabel(month)} has not started yet.',
          );
        }
        if (await _monthPaid(workerId, month)) {
          throw PayrollRuleViolation(
            '${payrollMonthLabel(month)} salary is already paid. '
            'Give a loan instead.',
          );
        }
        final room = PayrollMoneyPosition.advanceRoomKobo(
          salaryKobo: worker.monthlySalaryKobo,
          entries: entries,
          salaryMonth: month,
        );
        if (amountKobo > room) {
          throw PayrollRuleViolation(
            'An advance cannot be more than what is left of '
            '${payrollMonthLabel(month)} salary '
            '(${formatCurrency(room / 100)} left). Give a staff loan instead.',
          );
        }
      } else {
        month = null;
      }

      final owed = PayrollMoneyPosition.outstandingLoanKobo(entries);
      if (type == 'loan_repaid' && amountKobo > owed) {
        throw PayrollRuleViolation(
          owed <= 0
              ? '${worker.name} does not owe anything.'
              : 'A repayment cannot be more than what is owed '
                    '(${formatCurrency(owed / 100)}).',
        );
      }
      if (type == 'loan_given' && amountKobo < 0 && owed + amountKobo < 0) {
        throw const PayrollRuleViolation(
          'That would make the loan smaller than what has been repaid.',
        );
      }

      final waits =
          kPayrollApprovalEntryTypes.contains(type) &&
          amountKobo > 0 &&
          limit != null &&
          amountKobo > limit;
      final now = DateTime.now();
      final id = UuidV7.generate();
      final row = PayrollEntriesCompanion.insert(
        id: Value(id),
        businessId: businessId,
        workerId: workerId,
        storeId: worker.storeId,
        type: type,
        amountKobo: amountKobo,
        entryDate: date,
        salaryMonth: Value(month),
        paymentMethod: Value(paymentMethod),
        note: Value(
          trimmedNote == null || trimmedNote.isEmpty ? null : trimmedNote,
        ),
        correctsEntryId: Value(correctsEntryId),
        monthlyRepaymentKobo: Value(monthlyRepaymentKobo),
        recordedBy: Value(currentUserId),
        status: Value(waits ? 'pending' : 'approved'),
        approvedBy: waits ? const Value.absent() : Value(currentUserId),
        approvedAt: waits ? const Value.absent() : Value(now),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(payrollEntries).insert(row);
      await db.syncDao.enqueueUpsert('payroll_entries', row);

      // Names only — Activity Logs reach every phone (ADR 0034).
      final what = isCorrection
          ? 'Corrected a $label for ${worker.name}'
          : switch (type) {
              'loan_given' => 'Gave a staff loan to ${worker.name}',
              'loan_repaid' => 'Recorded a loan repayment from ${worker.name}',
              _ => 'Recorded a $label for ${worker.name}',
            };
      await db.activityLogDao.log(
        action: waits
            ? 'payroll_entry_pending'
            : (isCorrection
                  ? 'payroll_entry_corrected'
                  : 'payroll_entry_recorded'),
        description: waits ? '$what (waiting for CEO approval)' : what,
        staffId: currentUserId,
        storeId: worker.storeId,
      );
      if (waits) {
        final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs([
          'ceo',
        ]);
        for (final uid in ceoIds) {
          await db.notificationsDao.fireNotification(
            type: 'payroll.pending_approval',
            message: 'A $label for ${worker.name} is waiting for your approval',
            severity: 'warning',
            linkedRecordId: id,
            recipientUserId: uid,
          );
        }
      }
      // #696 — the combined till-cash line for this kind and day.
      await _refreshMoneyTotals(businessId);
      return (select(
        payrollEntries,
      )..where((e) => e.id.equals(id))).getSingle();
    });
  }

  /// CEO approves a waiting entry. A no-op when it is no longer waiting.
  Future<void> approveEntry(String entryId) => _decide(entryId, approve: true);

  /// CEO rejects a waiting entry: it then counts for nothing. [reason] stays
  /// on the entry (Payroll only) and never reaches Activity Logs.
  Future<void> rejectEntry(String entryId, {required String reason}) =>
      _decide(entryId, approve: false, reason: reason.trim());

  Future<void> _decide(
    String entryId, {
    required bool approve,
    String? reason,
  }) async {
    final businessId = await _requireAccess();
    if (!await currentUserIsPayrollApprover()) {
      throw const PayrollApprovalDenied();
    }
    String? recordedBy;
    String? message;
    await transaction(() async {
      final entry =
          await (select(payrollEntries)..where(
                (e) => e.id.equals(entryId) & e.businessId.equals(businessId),
              ))
              .getSingleOrNull();
      if (entry == null || entry.status != 'pending') return;
      final worker = await _worker(entry.workerId, businessId);
      final now = DateTime.now();
      final affected =
          await (update(payrollEntries)..where(
                (e) => e.id.equals(entryId) & e.status.equals('pending'),
              ))
              .write(
                PayrollEntriesCompanion(
                  status: Value(approve ? 'approved' : 'rejected'),
                  approvedBy: Value(currentUserId),
                  approvedAt: Value(now),
                  rejectionReason: Value(
                    approve || reason == null || reason.isEmpty ? null : reason,
                  ),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;
      final row = await (select(
        payrollEntries,
      )..where((e) => e.id.equals(entryId))).getSingle();
      await db.syncDao.enqueueUpsert('payroll_entries', row.toCompanion(true));
      // #696 — an approved entry now counts in its combined line.
      await _refreshMoneyTotals(businessId);
      final label = payrollEntryLabel(entry.type);
      await db.activityLogDao.log(
        action: approve ? 'payroll_entry_approved' : 'payroll_entry_rejected',
        description:
            '${approve ? 'Approved' : 'Rejected'} a $label for ${worker.name}',
        staffId: currentUserId,
        storeId: entry.storeId,
      );
      recordedBy = entry.recordedBy;
      message =
          'Your $label for ${worker.name} was '
          '${approve ? 'approved' : 'rejected'}';
    });
    if (recordedBy != null && recordedBy != currentUserId) {
      await db.notificationsDao.fireNotification(
        type: approve ? 'payroll.approved' : 'payroll.rejected',
        message: message!,
        linkedRecordId: entryId,
        recipientUserId: recordedBy,
      );
    }
  }

  /// #696 — rewrites the combined bonus / advance / staff loan lines from this
  /// phone's entries. A silent no-op without the permission. Runs after every
  /// pull, so a line another phone wrote from fewer entries converges.
  Future<void> refreshMoneyTotals() async {
    final businessId = currentBusinessId;
    if (businessId == null) return;
    if (!await currentUserHoldsPayroll()) return;
    await transaction(() => _refreshMoneyTotals(businessId));
  }

  /// One combined line per store, day and kind (no worker named): amount =
  /// every APPROVED entry of that type dated that day (a correction counts on
  /// its own day), cash = the part paid in Cash. Pending and rejected entries
  /// never count. A loan repayment kept back from a salary on payday is not
  /// till money, so it is left out of `loans_repaid`. Only lines whose figures
  /// moved are written and queued.
  Future<void> _refreshMoneyTotals(String businessId) async {
    const kindOf = {
      'bonus': kStaffPayKindBonuses,
      'advance': kStaffPayKindAdvances,
      'loan_given': kStaffPayKindLoansGiven,
      'loan_repaid': kStaffPayKindLoansRepaid,
    };
    final entries =
        await (select(payrollEntries)..where(
              (e) =>
                  e.businessId.equals(businessId) &
                  e.status.equals('approved') &
                  e.type.isIn(kindOf.keys),
            ))
            .get();
    final paydayRepayments = {
      for (final s in await (select(
        payrollStatements,
      )..where((s) => s.businessId.equals(businessId))).get())
        payrollSalaryRepaymentId(s.workerId, s.salaryMonth),
    };
    final lines = <String, ({String kind, String storeId, String day})>{};
    final amounts = <String, int>{};
    final cash = <String, int>{};
    for (final e in entries) {
      if (e.type == 'loan_repaid' && paydayRepayments.contains(e.id)) continue;
      final kind = kindOf[e.type]!;
      final id = staffPayTotalId(businessId, e.storeId, kind, e.entryDate);
      lines[id] = (kind: kind, storeId: e.storeId, day: e.entryDate);
      amounts[id] = (amounts[id] ?? 0) + e.amountKobo;
      if (e.paymentMethod == 'cash') cash[id] = (cash[id] ?? 0) + e.amountKobo;
    }
    final existing = {
      for (final t
          in await (select(db.staffPayTotals)..where(
                (t) =>
                    t.businessId.equals(businessId) &
                    t.kind.isIn(kindOf.values),
              ))
              .get())
        t.id: t,
    };
    final at = DateTime.now();
    for (final MapEntry(key: id, value: line) in lines.entries) {
      final total = amounts[id] ?? 0;
      final cashTotal = cash[id] ?? 0;
      final current = existing[id];
      if (current == null && total == 0 && cashTotal == 0) continue;
      if (current != null &&
          current.amountKobo == total &&
          current.cashKobo == cashTotal) {
        continue;
      }
      final row = StaffPayTotalsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        storeId: line.storeId,
        kind: line.kind,
        totalDate: line.day,
        amountKobo: Value(total),
        cashKobo: Value(cashTotal),
        createdAt: Value(current?.createdAt ?? at),
        lastUpdatedAt: Value(at),
      );
      await into(db.staffPayTotals).insertOnConflictUpdate(row);
      await db.syncDao.enqueueUpsert('staff_pay_totals', row);
    }
  }

  /// [workerId]'s entries, newest first.
  /// #723: every entry of the business, any status (Overview and History work
  /// their figures out from these). Empty on a phone without the permission.
  Stream<List<PayrollEntryData>> watchAllEntries() =>
      (select(payrollEntries)..where((e) => whereBusiness(e))).watch();

  Stream<List<PayrollEntryData>> watchEntriesForWorker(String workerId) =>
      (select(payrollEntries)
            ..where((e) => e.workerId.equals(workerId) & whereBusiness(e))
            ..orderBy([
              (e) => OrderingTerm.desc(e.entryDate),
              (e) => OrderingTerm.desc(e.createdAt),
            ]))
          .watch();

  /// Every entry waiting for the CEO, oldest first.
  Stream<List<PayrollEntryData>> watchPendingEntries() =>
      (select(payrollEntries)
            ..where((e) => e.status.equals('pending') & whereBusiness(e))
            ..orderBy([(e) => OrderingTerm.asc(e.createdAt)]))
          .watch();
}
