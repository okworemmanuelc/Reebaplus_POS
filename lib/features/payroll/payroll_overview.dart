import 'dart:math' as math;

import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

// #723 — what the Payroll screens show, worked out from the raw entries. Pure,
// so phone and tablet layouts share one set of figures and tests need no
// widgets. Nothing here writes; the rules still live in the DAO.

// ─── Small labels ────────────────────────────────────────────────────────────

/// 'YYYY-MM-DD' → DateTime, or null when it is not a date.
DateTime? payrollDay(String day) => DateTime.tryParse(day);

/// "27 Nov".
String payrollShortDay(String day) {
  final d = payrollDay(day);
  return d == null ? day : DateFormat('d MMM').format(d);
}

/// "27 Nov 2026".
String payrollMediumDay(String day) {
  final d = payrollDay(day);
  return d == null ? day : DateFormat('d MMM y').format(d);
}

/// "Friday 27 November".
String payrollLongDay(String day) {
  final d = payrollDay(day);
  return d == null ? day : DateFormat('EEEE d MMMM').format(d);
}

/// 28 → "28th", 1 → "1st", 22 → "22nd".
String payrollOrdinal(int n) {
  final tens = n % 100;
  if (tens >= 11 && tens <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// 'YYYY-MM' moved by [delta] calendar months.
String payrollShiftMonth(String month, int delta) {
  final parts = month.split('-');
  final d = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta);
  return payrollMonthKey(d);
}

/// "November" from 'YYYY-MM'.
String payrollMonthName(String month) =>
    payrollMonthLabel(month).split(' ').first;

/// The worker's usual payday inside [month] ('YYYY-MM'): their day clamped to
/// the month's length; no day set = the last day. Returns 'YYYY-MM-DD'.
String payrollPaydayIn(PayrollWorkerData worker, String month) {
  final parts = month.split('-');
  final y = int.parse(parts[0]);
  final m = int.parse(parts[1]);
  final last = DateTime(y, m + 1, 0).day;
  final day = math.min(worker.paydayDay ?? last, last);
  return payrollDayKey(DateTime(y, m, day));
}

/// "pays on the 28th" / "pays on the last day".
String payrollPaydayPhrase(PayrollWorkerData worker) => worker.paydayDay == null
    ? 'last day'
    : 'the ${payrollOrdinal(worker.paydayDay!)}';

/// The line under a worker's name: their job, else the store.
String payrollWorkerRole(PayrollWorkerData worker, String storeName) {
  final job = worker.jobTitle?.trim() ?? '';
  return job.isEmpty ? storeName : job;
}

/// "MI" from "Musa Ibrahim".
String payrollInitials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  String letter(String s) => String.fromCharCode(s.runes.first);
  final last = parts.length > 1 ? letter(parts.last) : '';
  return '${letter(parts.first)}$last'.toUpperCase();
}

// ─── Bonus reasons ───────────────────────────────────────────────────────────

/// The Reason chips on a Bonus. "Other" saves no reason.
const List<String> kPayrollBonusReasons = ['Offloading', 'Extra work'];

/// The note saved for a bonus: "Offloading: Heineken truck", "Offloading", or
/// just the typed note for Other.
String? payrollBonusNote(String? reason, String? note) {
  final n = note?.trim() ?? '';
  if (reason == null) return n.isEmpty ? null : n;
  return n.isEmpty ? reason : '$reason: $n';
}

/// Splits a saved bonus note back into its reason and the typed detail.
({String? reason, String? detail}) payrollParseBonusNote(String? note) {
  final n = note?.trim() ?? '';
  for (final r in kPayrollBonusReasons) {
    if (n == r) return (reason: r, detail: null);
    if (n.startsWith('$r: ')) {
      return (reason: r, detail: n.substring(r.length + 2));
    }
  }
  return (reason: null, detail: n.isEmpty ? null : n);
}

// ─── Loans ───────────────────────────────────────────────────────────────────

/// One worker's staff loans, all time.
class PayrollLoanSummary {
  const PayrollLoanSummary({
    required this.lentKobo,
    required this.owedKobo,
    required this.monthlyKobo,
    required this.takenOn,
  });

  /// Approved loans, corrections included.
  final int lentKobo;
  final int owedKobo;

  /// The plan on the newest approved loan. Null = no plan.
  final int? monthlyKobo;

  /// The newest approved loan's date.
  final String? takenOn;

  bool get hasLoan => owedKobo > 0;
  bool get hasPlan => monthlyKobo != null && monthlyKobo! > 0;
  int get repaidKobo => lentKobo - owedKobo;

  /// How many monthly parts the whole loan takes.
  int get totalParts => hasPlan ? (lentKobo / monthlyKobo!).ceil() : 0;

  /// This payday's planned repayment: the plan, capped by what is owed and by
  /// [roomKobo] (what is left of the salary).
  int plannedKobo(int roomKobo) {
    if (!hasPlan || !hasLoan) return 0;
    return math.min(monthlyKobo!, math.min(owedKobo, math.max(roomKobo, 0)));
  }

  /// The part number once [repaidAfterKobo] has been paid back in all.
  int partNumber(int repaidAfterKobo) {
    if (!hasPlan) return 0;
    return math.min((repaidAfterKobo / monthlyKobo!).ceil(), totalParts);
  }

  /// The month the last part falls in, when [owedAfterKobo] is still owed
  /// after [month]'s repayment. Null without a plan.
  String? lastRepaymentMonth(String month, int owedAfterKobo) {
    if (!hasPlan) return null;
    return payrollShiftMonth(month, (owedAfterKobo / monthlyKobo!).ceil());
  }

  factory PayrollLoanSummary.from(Iterable<PayrollEntryData> entries) {
    final approved = entries
        .where((e) => e.type == 'loan_given' && e.status == 'approved')
        .toList();
    final originals = approved.where((e) => e.correctsEntryId == null).toList()
      ..sort((a, b) => a.entryDate.compareTo(b.entryDate));
    final planned = originals.where((e) => e.monthlyRepaymentKobo != null);
    return PayrollLoanSummary(
      lentKobo: approved.fold(0, (s, e) => s + e.amountKobo),
      owedKobo: PayrollMoneyPosition.outstandingLoanKobo(entries),
      monthlyKobo: planned.isEmpty ? null : planned.last.monthlyRepaymentKobo,
      takenOn: originals.isEmpty ? null : originals.last.entryDate,
    );
  }
}

// ─── One worker, one month ───────────────────────────────────────────────────

/// One worker's pay for one Salary Month.
class PayrollWorkerMonth {
  const PayrollWorkerMonth({
    required this.worker,
    required this.month,
    required this.figures,
    required this.statement,
    required this.salaryEntry,
    required this.advances,
    required this.loan,
    required this.allowanceDays,
    required this.bonusCount,
  });

  final PayrollWorkerData worker;
  final String month;

  /// The month's figures. Unpaid: the planned repayment is filled in. Paid:
  /// read from the signed statement.
  final PaydayFigures figures;
  final PayrollStatementData? statement;
  final PayrollEntryData? salaryEntry;

  /// This month's approved advances, oldest first.
  final List<PayrollEntryData> advances;
  final PayrollLoanSummary loan;
  final int allowanceDays;
  final int bonusCount;

  bool get isPaid => statement != null;

  /// The day the salary was paid.
  String? get paidOn => salaryEntry?.entryDate;

  /// The cash due (unpaid) or handed over (paid).
  int get cashKobo => statement?.cashPaidKobo ?? figures.cashPaidKobo;

  int get repaymentKobo =>
      statement?.loanRepaidKobo ?? figures.loanRepaymentKobo;

  int get advancesKobo => statement?.advancesKobo ?? figures.advancesKobo;

  /// What is still owed once this month's repayment is taken.
  int get owedAfterMonthKobo => isPaid
      ? loan.owedKobo
      : math.max(loan.owedKobo - figures.loanRepaymentKobo, 0);

  /// Paid back so far, this month's repayment included.
  int get repaidAfterMonthKobo => loan.lentKobo - owedAfterMonthKobo;

  /// Daily Allowances + Bonuses received on the day this month.
  int get receivedOnTheDayKobo => figures.allowancesKobo + figures.bonusesKobo;

  factory PayrollWorkerMonth.from({
    required PayrollWorkerData worker,
    required List<PayrollEntryData> entries,
    required String month,
    PayrollStatementData? statement,
  }) {
    final base = PaydayFigures.from(
      worker: worker,
      entries: entries,
      salaryMonth: month,
    );
    final loan = PayrollLoanSummary.from(entries);
    final figures = statement != null
        ? base
        : PaydayFigures.from(
            worker: worker,
            entries: entries,
            salaryMonth: month,
            loanRepaymentKobo: loan.plannedKobo(base.afterAdvancesKobo),
          );
    final approved = entries.where((e) => e.status == 'approved').toList();
    final salaryEntry = approved
        .where(
          (e) =>
              e.type == 'salary_payment' &&
              e.salaryMonth == month &&
              e.correctsEntryId == null,
        )
        .firstOrNull;
    final advances =
        approved
            .where(
              (e) =>
                  e.type == 'advance' &&
                  e.salaryMonth == month &&
                  e.correctsEntryId == null,
            )
            .toList()
          ..sort((a, b) => a.entryDate.compareTo(b.entryDate));
    bool isOriginalIn(PayrollEntryData e, String type) =>
        e.type == type &&
        e.correctsEntryId == null &&
        e.entryDate.startsWith('$month-');
    final allowanceDays = approved
        .where(
          (e) =>
              isOriginalIn(e, 'allowance') &&
              PayrollMoneyPosition.correctedAmountKobo(e, approved) > 0,
        )
        .length;
    final bonusCount = approved.where((e) => isOriginalIn(e, 'bonus')).length;
    return PayrollWorkerMonth(
      worker: worker,
      month: month,
      figures: figures,
      statement: statement,
      salaryEntry: salaryEntry,
      advances: advances,
      loan: loan,
      allowanceDays: allowanceDays,
      bonusCount: bonusCount,
    );
  }
}

// ─── The whole month ─────────────────────────────────────────────────────────

/// Everything the Overview shows for one month.
class PayrollMonthView {
  const PayrollMonthView({
    required this.month,
    required this.rows,
    required this.todayAllowanceStaff,
    required this.todayAllowanceKobo,
  });

  final String month;

  /// Unpaid first, then by name.
  final List<PayrollWorkerMonth> rows;
  final int todayAllowanceStaff;
  final int todayAllowanceKobo;

  int _sum(int Function(PayrollWorkerMonth r) of) =>
      rows.fold(0, (s, r) => s + of(r));

  /// The month's whole cash bill: paid + still to pay.
  int get totalKobo => _sum((r) => r.cashKobo);
  int get paidKobo => _sum((r) => r.isPaid ? r.cashKobo : 0);
  int get leftKobo => _sum((r) => r.isPaid ? 0 : r.cashKobo);
  int get advancesKobo => _sum((r) => r.advancesKobo);
  int get repaymentsKobo => _sum((r) => r.repaymentKobo);
  int get allowancesKobo => _sum((r) => r.figures.allowancesKobo);
  int get allowanceDays => _sum((r) => r.allowanceDays);
  int get bonusesKobo => _sum((r) => r.figures.bonusesKobo);
  int get bonusCount => _sum((r) => r.bonusCount);
  int get loansOwedKobo => _sum((r) => math.max(r.loan.owedKobo, 0));
  int get loanStaff => rows.where((r) => r.loan.hasLoan).length;
  int get unpaidCount => rows.where((r) => !r.isPaid).length;
  int get paidCount => rows.where((r) => r.isPaid).length;

  /// 0–1. The share of the bill already paid.
  double get paidShare => totalKobo == 0 ? 0 : paidKobo / totalKobo;

  factory PayrollMonthView.build({
    required List<PayrollWorkerData> workers,
    required List<PayrollEntryData> entries,
    required List<PayrollStatementData> statements,
    required String month,
    required DateTime today,
  }) {
    final byWorker = <String, List<PayrollEntryData>>{};
    for (final e in entries) {
      (byWorker[e.workerId] ??= []).add(e);
    }
    final statementOf = {
      for (final s in statements)
        if (s.salaryMonth == month) s.workerId: s,
    };
    final rows = <PayrollWorkerMonth>[];
    for (final w in workers) {
      final statement = statementOf[w.id];
      final joined = payrollMonthKey(w.createdAt).compareTo(month) <= 0;
      if (statement == null && (w.isRemoved || !joined)) continue;
      rows.add(
        PayrollWorkerMonth.from(
          worker: w,
          entries: byWorker[w.id] ?? const [],
          month: month,
          statement: statement,
        ),
      );
    }
    rows.sort((a, b) {
      if (a.isPaid != b.isPaid) return a.isPaid ? 1 : -1;
      return a.worker.name.toLowerCase().compareTo(b.worker.name.toLowerCase());
    });

    final todayKey = payrollDayKey(today);
    var staff = 0;
    var kobo = 0;
    final allowances = entries
        .where((e) => e.type == 'allowance' && e.status == 'approved')
        .toList();
    for (final e in allowances) {
      if (e.correctsEntryId != null || e.entryDate != todayKey) continue;
      final net = PayrollMoneyPosition.correctedAmountKobo(e, allowances);
      if (net <= 0) continue;
      staff++;
      kobo += net;
    }
    return PayrollMonthView(
      month: month,
      rows: rows,
      todayAllowanceStaff: staff,
      todayAllowanceKobo: kobo,
    );
  }
}

// ─── History ─────────────────────────────────────────────────────────────────

/// The History type filter. [all] shows everything.
enum PayrollKind { all, salary, allowance, bonus, advance, loan }

/// "Salary", "Allowance", ...
String payrollKindLabel(PayrollKind kind) => switch (kind) {
  PayrollKind.all => 'All',
  PayrollKind.salary => 'Salary',
  PayrollKind.allowance => 'Allowance',
  PayrollKind.bonus => 'Bonus',
  PayrollKind.advance => 'Advance',
  PayrollKind.loan => 'Loan',
};

/// One line of History. A line with [staffCount] > 1 stands for several
/// workers on one day (Daily Allowances, or the same bonus).
class PayrollHistoryRow {
  const PayrollHistoryRow({
    required this.date,
    required this.kind,
    required this.amountKobo,
    required this.title,
    required this.details,
    required this.method,
    this.workerId,
    this.workerName,
    this.staffCount = 1,
    this.entry,
    this.statementId,
    this.isMoneyIn = false,
    this.isWaiting = false,
  });

  final String date;
  final PayrollKind kind;
  final int amountKobo;

  /// What it was: "Daily allowance", "Offloading bonus", "Salary".
  final String title;

  /// The detail: "Heineken truck", "From November salary".
  final String? details;

  /// 'cash', 'transfer' or 'other'.
  final String method;
  final String? workerId;
  final String? workerName;
  final int staffCount;

  /// The entry behind a one-worker line (to correct or decide it).
  final PayrollEntryData? entry;

  /// The signed statement behind a salary line (to open the payslip).
  final String? statementId;

  /// A loan repayment: money coming back, not paid out.
  final bool isMoneyIn;

  /// Waiting for the CEO; counts for nothing yet.
  final bool isWaiting;

  /// "Musa Ibrahim" or "5 staff".
  String get staffLabel =>
      staffCount > 1 ? '$staffCount staff' : (workerName ?? 'Staff');
}

/// The totals over a set of History lines (only money paid out and decided).
class PayrollHistoryTotals {
  const PayrollHistoryTotals({
    required this.salariesKobo,
    required this.allowancesKobo,
    required this.bonusesKobo,
    required this.advancesKobo,
    required this.loansKobo,
  });

  final int salariesKobo;
  final int allowancesKobo;
  final int bonusesKobo;
  final int advancesKobo;
  final int loansKobo;

  int get totalKobo =>
      salariesKobo + allowancesKobo + bonusesKobo + advancesKobo + loansKobo;

  /// "Salaries ₦225,000, allowances ₦186,000, ...". Empty kinds are left out.
  String get breakdown {
    String money(int kobo) => formatCurrency(kobo / 100);
    return [
      if (salariesKobo != 0) 'Salaries ${money(salariesKobo)}',
      if (allowancesKobo != 0) 'allowances ${money(allowancesKobo)}',
      if (bonusesKobo != 0) 'bonuses ${money(bonusesKobo)}',
      if (advancesKobo != 0) 'advances ${money(advancesKobo)}',
      if (loansKobo != 0) 'loans ${money(loansKobo)}',
    ].join(', ');
  }

  factory PayrollHistoryTotals.of(Iterable<PayrollHistoryRow> rows) {
    int sum(PayrollKind kind) => rows
        .where((r) => r.kind == kind && !r.isMoneyIn && !r.isWaiting)
        .fold(0, (s, r) => s + r.amountKobo);
    return PayrollHistoryTotals(
      salariesKobo: sum(PayrollKind.salary),
      allowancesKobo: sum(PayrollKind.allowance),
      bonusesKobo: sum(PayrollKind.bonus),
      advancesKobo: sum(PayrollKind.advance),
      loansKobo: sum(PayrollKind.loan),
    );
  }
}

int _kindOrder(PayrollKind k) => switch (k) {
  PayrollKind.salary => 0,
  PayrollKind.bonus => 1,
  PayrollKind.advance => 2,
  PayrollKind.loan => 3,
  PayrollKind.allowance => 4,
  PayrollKind.all => 5,
};

/// The History lines, newest day first. [month] null = every month; [workerId]
/// null = every worker. With every worker, each day's allowances collapse into
/// one line and a bonus paid to several workers (same day, reason and detail)
/// does too. A correction never shows as its own line: it moves the entry it
/// corrects. Rejected entries are left out.
List<PayrollHistoryRow> payrollHistoryRows({
  required List<PayrollWorkerData> workers,
  required List<PayrollEntryData> entries,
  required List<PayrollStatementData> statements,
  String? month,
  String? workerId,
}) {
  final nameOf = {for (final w in workers) w.id: toNameCase(w.name)};
  final counted = entries.where((e) => e.status != 'rejected').toList();
  bool inScope(PayrollEntryData e) =>
      (workerId == null || e.workerId == workerId) &&
      (month == null || e.entryDate.startsWith('$month-'));
  final statementOf = {for (final s in statements) s.salaryEntryId: s};

  final rows = <PayrollHistoryRow>[];
  final allowanceDays = <String, List<(PayrollEntryData, int)>>{};
  final bonusGroups = <String, List<(PayrollEntryData, int)>>{};

  for (final e in counted) {
    if (e.correctsEntryId != null || !inScope(e)) continue;
    final amount = PayrollMoneyPosition.correctedAmountKobo(e, counted);
    if (amount == 0 && e.type != 'salary_payment') continue;
    final waiting = e.status == 'pending';
    final name = nameOf[e.workerId];
    switch (e.type) {
      case 'salary_payment':
        final s = statementOf[e.id];
        final advance = s?.advancesKobo ?? 0;
        rows.add(
          PayrollHistoryRow(
            date: e.entryDate,
            kind: PayrollKind.salary,
            amountKobo: s?.cashPaidKobo ?? e.amountKobo,
            title: 'Salary',
            details: advance > 0
                ? 'After ${formatCurrency(advance / 100)} advance'
                : '${payrollMonthLabel(e.salaryMonth ?? '').split(' ').first} '
                      'salary',
            method: e.paymentMethod,
            workerId: e.workerId,
            workerName: name,
            entry: e,
            statementId: s?.id,
          ),
        );
      case 'allowance':
        (allowanceDays[e.entryDate] ??= []).add((e, amount));
      case 'bonus' when workerId == null && !waiting:
        (bonusGroups['${e.entryDate}|${e.note ?? ''}'] ??= []).add((e, amount));
      case 'bonus':
        rows.add(_bonusRow(e, amount, [e.workerId], nameOf));
      case 'advance':
        rows.add(
          PayrollHistoryRow(
            date: e.entryDate,
            kind: PayrollKind.advance,
            amountKobo: amount,
            title: 'Advance',
            details: e.salaryMonth == null
                ? e.note
                : 'From ${payrollMonthName(e.salaryMonth!)} salary',
            method: e.paymentMethod,
            workerId: e.workerId,
            workerName: name,
            entry: e,
            isWaiting: waiting,
          ),
        );
      case 'loan_given':
        final plan = e.monthlyRepaymentKobo;
        final parts = plan == null || plan <= 0 ? null : (amount / plan).ceil();
        rows.add(
          PayrollHistoryRow(
            date: e.entryDate,
            kind: PayrollKind.loan,
            amountKobo: amount,
            title: 'Loan given',
            details: plan == null
                ? e.note
                : '${formatCurrency(plan / 100)} a month for $parts '
                      '${parts == 1 ? 'month' : 'months'}',
            method: e.paymentMethod,
            workerId: e.workerId,
            workerName: name,
            entry: e,
            isWaiting: waiting,
          ),
        );
      case 'loan_repaid':
        rows.add(
          PayrollHistoryRow(
            date: e.entryDate,
            kind: PayrollKind.loan,
            amountKobo: amount,
            title: 'Loan repayment',
            details: e.note,
            method: e.paymentMethod,
            workerId: e.workerId,
            workerName: name,
            entry: e,
            isMoneyIn: true,
          ),
        );
    }
  }

  allowanceDays.forEach((day, list) {
    final total = list.fold(0, (s, x) => s + x.$2);
    if (total == 0) return;
    final single = list.length == 1 ? list.single.$1 : null;
    rows.add(
      PayrollHistoryRow(
        date: day,
        kind: PayrollKind.allowance,
        amountKobo: total,
        title: list.length > 1 ? 'Daily allowances' : 'Daily allowance',
        details: 'Daily allowance',
        method: 'cash',
        workerId: single?.workerId,
        workerName: single == null ? null : nameOf[single.workerId],
        staffCount: list.length,
        entry: single,
      ),
    );
  });

  bonusGroups.forEach((_, list) {
    rows.add(
      _bonusRow(list.first.$1, list.fold(0, (s, x) => s + x.$2), [
        for (final x in list) x.$1.workerId,
      ], nameOf),
    );
  });

  rows.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    return _kindOrder(a.kind).compareTo(_kindOrder(b.kind));
  });
  return rows;
}

PayrollHistoryRow _bonusRow(
  PayrollEntryData first,
  int amountKobo,
  List<String> workerIds,
  Map<String, String> nameOf,
) {
  final note = payrollParseBonusNote(first.note);
  final single = workerIds.length == 1;
  return PayrollHistoryRow(
    date: first.entryDate,
    kind: PayrollKind.bonus,
    amountKobo: amountKobo,
    title: note.reason == null ? 'Bonus' : '${note.reason} bonus',
    details: note.detail,
    method: first.paymentMethod,
    workerId: single ? first.workerId : null,
    workerName: single ? nameOf[first.workerId] : null,
    staffCount: workerIds.length,
    entry: single ? first : null,
    isWaiting: first.status == 'pending',
  );
}
