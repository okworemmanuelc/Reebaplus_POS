/// Old payroll rows → new payroll rows (#672). Pure: no files, no database.
library;

import 'dart:convert';
import 'dart:io';

import '../../legacy_import/src/export_reader.dart';
import '../../legacy_import/src/mapping.dart' show lagosDay;
import 'payroll_config.dart';
import 'payroll_ids.dart';

/// The old tables this import reads. Nothing else in the export is opened.
const List<String> kPayrollOldTables = [
  'Staff',
  'StaffPayrollEntry',
  'StaffLoanEntry',
  'StaffPayrollStatement',
];

/// The old payroll tables, read from `<export>/data/*.jsonl`.
class PayrollExport {
  final Map<String, List<Row>> tables;

  const PayrollExport(this.tables);

  List<Row> rows(String table) => tables[table] ?? const [];

  static PayrollExport load(String directory) => PayrollExport({
    for (final table in kPayrollOldTables)
      table: [
        for (final line in File(
          '$directory/data/$table.jsonl',
        ).readAsLinesSync())
          if (line.trim().isNotEmpty)
            Row(jsonDecode(line) as Map<String, Object?>),
      ],
  });
}

class PlannedWorker {
  final String id;
  final String legacyId;
  final String storeId;
  final String name;
  final int monthlySalaryKobo;
  final DateTime createdAt;

  const PlannedWorker({
    required this.id,
    required this.legacyId,
    required this.storeId,
    required this.name,
    required this.monthlySalaryKobo,
    required this.createdAt,
  });
}

class PlannedEntry {
  final String id;
  final String legacyId;
  final String workerId;
  final String oldStaffId;
  final String storeId;
  final String type;
  final int amountKobo;
  final String entryDate;
  final String? salaryMonth;
  final String paymentMethod;
  final String? note;
  final String? correctsEntryId;

  /// Old `Profile.id` of whoever recorded it; the SQL maps it to a user only
  /// when the main import created that user in this business.
  final String? recordedByProfileId;
  final DateTime createdAt;

  /// Where [entryDate] came from, for the report: 'entry', 'note', 'config'.
  final String dateSource;

  const PlannedEntry({
    required this.id,
    required this.legacyId,
    required this.workerId,
    required this.oldStaffId,
    required this.storeId,
    required this.type,
    required this.amountKobo,
    required this.entryDate,
    required this.salaryMonth,
    required this.paymentMethod,
    required this.note,
    required this.correctsEntryId,
    required this.recordedByProfileId,
    required this.createdAt,
    this.dateSource = 'entry',
  });
}

class PlannedStatement {
  final String id;
  final String legacyId;
  final String workerId;
  final String storeId;
  final String salaryMonth;
  final int salaryKobo;
  final int allowancesKobo;
  final int bonusesKobo;
  final int advancesKobo;
  final int loanRepaidKobo;
  final int cashPaidKobo;
  final int totalPayKobo;
  final String salaryEntryId;
  final String? workerSignaturePng;
  final String? payerSignaturePng;
  final String? signedByProfileId;
  final DateTime? signedAt;
  final DateTime createdAt;

  const PlannedStatement({
    required this.id,
    required this.legacyId,
    required this.workerId,
    required this.storeId,
    required this.salaryMonth,
    required this.salaryKobo,
    required this.allowancesKobo,
    required this.bonusesKobo,
    required this.advancesKobo,
    required this.loanRepaidKobo,
    required this.cashPaidKobo,
    required this.totalPayKobo,
    required this.salaryEntryId,
    required this.workerSignaturePng,
    required this.payerSignaturePng,
    required this.signedByProfileId,
    required this.signedAt,
    required this.createdAt,
  });
}

/// One combined, nameless line (staff_pay_totals), as the app derives it.
class PlannedPayTotal {
  final String id;
  final String storeId;
  final String kind;
  final String totalDate;
  final int amountKobo;
  final int cashKobo;

  const PlannedPayTotal({
    required this.id,
    required this.storeId,
    required this.kind,
    required this.totalDate,
    required this.amountKobo,
    required this.cashKobo,
  });
}

class PayrollPlan {
  final String businessId;
  final List<PlannedWorker> workers;

  /// Originals first, then corrections (a correction's foreign key needs the
  /// entry it corrects).
  final List<PlannedEntry> entries;
  final List<PlannedStatement> statements;
  final List<PlannedPayTotal> payTotals;

  /// Old rows deliberately left behind, with the reason (report only).
  final List<String> leftOut;

  const PayrollPlan({
    required this.businessId,
    required this.workers,
    required this.entries,
    required this.statements,
    required this.payTotals,
    required this.leftOut,
  });

  Iterable<String> get storeIds => workers.map((w) => w.storeId).toSet();

  Iterable<String> get profileIds => {
    for (final e in entries)
      if (e.recordedByProfileId != null) e.recordedByProfileId!,
    for (final s in statements)
      if (s.signedByProfileId != null) s.signedByProfileId!,
  };
}

/// Thrown when the old data holds something this import has no faithful
/// mapping for. It stops the build rather than guess with money.
class PayrollImportError implements Exception {
  final String message;
  const PayrollImportError(this.message);
  @override
  String toString() => 'PayrollImportError: $message';
}

/// A date written in a loan note as dd/mm/yy or dd/mm/yyyy, as 'YYYY-MM-DD'.
/// Null when the note holds no such date.
String? dateFromNote(String? note) {
  if (note == null) return null;
  final m = RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})\b').firstMatch(note);
  if (m == null) return null;
  final day = int.parse(m[1]!);
  final month = int.parse(m[2]!);
  var year = int.parse(m[3]!);
  if (m[3]!.length == 2) year += 2000;
  final parsed = DateTime.utc(year, month, day);
  if (parsed.month != month || parsed.day != day) return null;
  return '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

/// The Salary Month a payday settles by default: the month before it.
String salaryMonthBefore(String payday) {
  final year = int.parse(payday.substring(0, 4));
  final month = int.parse(payday.substring(5, 7));
  final before = DateTime.utc(year, month - 1);
  return '${before.year.toString().padLeft(4, '0')}-'
      '${before.month.toString().padLeft(2, '0')}';
}

/// The app's month label ("September 2026"), as in payrollMonthLabel.
String monthLabel(String salaryMonth) {
  const names = [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${names[int.parse(salaryMonth.substring(5, 7)) - 1]} '
      '${salaryMonth.substring(0, 4)}';
}

/// The raw base64 the app stores, from the old app's data URL.
String? signatureBase64(String? dataUrl) {
  if (dataUrl == null || dataUrl.isEmpty) return null;
  final comma = dataUrl.indexOf(',');
  if (dataUrl.startsWith('data:') && comma > 0) {
    return dataUrl.substring(comma + 1);
  }
  return dataUrl;
}

const Duration _cancelOffsetWindow = Duration(minutes: 5);

class PayrollPlanner {
  final PayrollExport export;
  final PayrollImportConfig config;
  final String businessId;

  PayrollPlanner({
    required this.export,
    required this.config,
    required this.businessId,
  });

  PayrollPlan build() {
    final leftOut = <String>[];
    final included = config.workerIds.toSet();
    final staffById = {for (final s in export.rows('Staff')) s.id: s};
    for (final id in config.workerIds) {
      if (!staffById.containsKey(id)) {
        throw PayrollImportError('config worker $id is not in Staff');
      }
    }

    // Workers.
    final workers = <PlannedWorker>[];
    final workerOf = <String, PlannedWorker>{};
    for (final id in config.workerIds) {
      final s = staffById[id]!;
      final name = (config.names[id] ?? s.text('name')).trim();
      final w = PlannedWorker(
        id: importWorkerId(id),
        legacyId: id,
        storeId: importStoreId(s.text('storeId')),
        name: name,
        monthlySalaryKobo: s.integer('monthlySalaryCents'),
        createdAt: s.time('createdAt'),
      );
      workers.add(w);
      workerOf[id] = w;
    }
    for (final s in export.rows('Staff')) {
      if (!included.contains(s.id)) {
        leftOut.add('Staff ${s.id}: not on the worker list (archived)');
      }
    }

    String method(String oldId, {String fallback = 'cash'}) =>
        config.paymentMethods[oldId] ?? fallback;

    // Payroll entries: salary payments, advances, and the old app's
    // ADJUSTMENT rows that offset a cancelled entry.
    final originals = <PlannedEntry>[];
    final corrections = <PlannedEntry>[];
    final payrollRows = [
      for (final r in export.rows('StaffPayrollEntry'))
        if (included.contains(r.text('staffId'))) r,
    ];
    for (final r in export.rows('StaffPayrollEntry')) {
      if (!included.contains(r.text('staffId'))) {
        leftOut.add('StaffPayrollEntry ${r.id}: worker not imported');
      }
    }
    final adjustments = [
      for (final r in payrollRows)
        if (r.text('type') == 'ADJUSTMENT') r,
    ];
    final usedAdjustments = <String>{};
    // Salary payment per old entry id: (worker, month, payday).
    final salaryOf = <String, ({String workerId, String month, String day})>{};

    for (final r in payrollRows) {
      final type = r.text('type');
      if (type == 'ADJUSTMENT') continue;
      final worker = workerOf[r.text('staffId')]!;
      final amount = r.integer('amountCents');
      final day = lagosDay(r.time('createdAt'));
      final cancelled = r.timeOrNull('cancelledAt') != null;
      switch (type) {
        case 'SETTLEMENT':
          if (cancelled) {
            throw PayrollImportError(
              'salary payment ${r.id} was cancelled: no faithful mapping',
            );
          }
          final month = config.salaryMonths[r.id] ?? salaryMonthBefore(day);
          if (month.compareTo(day.substring(0, 7)) > 0) {
            throw PayrollImportError(
              'salary payment ${r.id}: $month has not started on $day',
            );
          }
          final id = appPayrollSalaryEntryId(worker.id, month);
          if (originals.any((e) => e.id == id)) {
            throw PayrollImportError(
              'two salary payments for one worker in $month',
            );
          }
          salaryOf[r.id] = (workerId: worker.id, month: month, day: day);
          originals.add(
            PlannedEntry(
              id: id,
              legacyId: r.id,
              workerId: worker.id,
              oldStaffId: worker.legacyId,
              storeId: worker.storeId,
              type: 'salary_payment',
              amountKobo: amount,
              entryDate: day,
              salaryMonth: month,
              paymentMethod: method(r.id),
              note: r.textOrNull('note'),
              correctsEntryId: null,
              recordedByProfileId: r.textOrNull('createdByProfileId'),
              createdAt: r.time('createdAt'),
            ),
          );
        case 'ADVANCE':
          final month = day.substring(0, 7);
          final original = PlannedEntry(
            id: importPayrollEntryId(r.id),
            legacyId: r.id,
            workerId: worker.id,
            oldStaffId: worker.legacyId,
            storeId: worker.storeId,
            type: 'advance',
            amountKobo: amount,
            entryDate: day,
            salaryMonth: month,
            paymentMethod: method(r.id),
            note: r.textOrNull('note'),
            correctsEntryId: null,
            recordedByProfileId: r.textOrNull('createdByProfileId'),
            createdAt: r.time('createdAt'),
          );
          originals.add(original);
          if (cancelled) {
            final offset = _offsetFor(r, adjustments, usedAdjustments);
            usedAdjustments.add(offset.id);
            corrections.add(
              PlannedEntry(
                id: importPayrollEntryId(offset.id),
                legacyId: offset.id,
                workerId: worker.id,
                oldStaffId: worker.legacyId,
                storeId: worker.storeId,
                type: 'advance',
                amountKobo: offset.integer('amountCents'),
                entryDate: lagosDay(offset.time('createdAt')),
                salaryMonth: month,
                paymentMethod: original.paymentMethod,
                note: offset.textOrNull('note') ?? 'Cancelled',
                correctsEntryId: original.id,
                recordedByProfileId: offset.textOrNull('createdByProfileId'),
                createdAt: offset.time('createdAt'),
              ),
            );
          }
        default:
          throw PayrollImportError('payroll entry ${r.id}: unknown type $type');
      }
    }
    for (final a in adjustments) {
      if (!usedAdjustments.contains(a.id)) {
        throw PayrollImportError(
          'adjustment ${a.id} offsets no cancelled entry: no faithful mapping',
        );
      }
    }

    // Loans. A repayment dated on that worker's payday is the deduction taken
    // out of the salary (the app's deterministic repayment id, paid 'other').
    final paydayOf = <String, ({String month, String day})>{
      for (final s in salaryOf.values) s.workerId: (month: s.month, day: s.day),
    };
    final repaidOnPayday = <String, int>{};
    for (final r in export.rows('StaffLoanEntry')) {
      final staffId = r.text('staffId');
      if (!included.contains(staffId)) {
        leftOut.add('StaffLoanEntry ${r.id}: worker not imported');
        continue;
      }
      if (r.timeOrNull('cancelledAt') != null) {
        throw PayrollImportError(
          'loan entry ${r.id} was cancelled: no faithful mapping',
        );
      }
      final worker = workerOf[staffId]!;
      final note = r.textOrNull('note');
      final fromConfig = config.loanDates[r.id];
      final fromNote = dateFromNote(note);
      final day = fromConfig ?? fromNote ?? lagosDay(r.time('createdAt'));
      final source = fromConfig != null
          ? 'config'
          : (fromNote != null ? 'note' : 'entry');
      final amount = r.integer('amountCents').abs();
      final type = switch (r.text('type')) {
        'DISBURSED' => 'loan_given',
        'REPAYMENT' => 'loan_repaid',
        final other => throw PayrollImportError(
          'loan entry ${r.id}: unknown type $other',
        ),
      };
      final payday = paydayOf[worker.id];
      final isDeduction =
          type == 'loan_repaid' && payday != null && payday.day == day;
      if (isDeduction && repaidOnPayday.containsKey(worker.id)) {
        throw const PayrollImportError('two salary deductions for one worker');
      }
      if (isDeduction) repaidOnPayday[worker.id] = amount;
      originals.add(
        PlannedEntry(
          id: isDeduction
              ? appPayrollSalaryRepaymentId(worker.id, payday.month)
              : importLoanEntryId(r.id),
          legacyId: r.id,
          workerId: worker.id,
          oldStaffId: worker.legacyId,
          storeId: worker.storeId,
          type: type,
          amountKobo: amount,
          entryDate: day,
          salaryMonth: null,
          paymentMethod: isDeduction ? 'other' : method(r.id),
          note: isDeduction
              ? 'Taken from ${monthLabel(payday.month)} salary'
              : note,
          correctsEntryId: null,
          recordedByProfileId: r.textOrNull('createdByProfileId'),
          createdAt: r.time('createdAt'),
          dateSource: source,
        ),
      );
    }

    final entries = [...originals, ...corrections];

    // Statements: one per salary payment, with both signature images.
    final statementsByOldId = {
      for (final s in export.rows('StaffPayrollStatement')) s.id: s,
    };
    final statements = <PlannedStatement>[];
    final linked = <String>{};
    for (final r in payrollRows) {
      final salary = salaryOf[r.id];
      if (salary == null) continue;
      final oldStatementId = r.textOrNull('statementId');
      if (oldStatementId == null) {
        throw PayrollImportError('salary payment ${r.id} has no statement');
      }
      final s =
          statementsByOldId[oldStatementId] ??
          (throw PayrollImportError('statement $oldStatementId is missing'));
      if (s.timeOrNull('cancelledAt') != null) {
        throw PayrollImportError('statement ${s.id} was cancelled');
      }
      linked.add(s.id);
      final worker = workerOf[r.text('staffId')]!;
      final salaryKobo = r.integer('amountCents');
      final advances = entries
          .where(
            (e) =>
                e.workerId == worker.id &&
                e.type == 'advance' &&
                e.salaryMonth == salary.month,
          )
          .fold(0, (sum, e) => sum + e.amountKobo);
      final repaid = repaidOnPayday[worker.id] ?? 0;
      final cash = salaryKobo - advances - repaid;
      if (cash < 0) {
        throw PayrollImportError('statement ${s.id}: cash below zero');
      }
      statements.add(
        PlannedStatement(
          id: appPayrollStatementId(worker.id, salary.month),
          legacyId: s.id,
          workerId: worker.id,
          storeId: importStoreId(s.text('storeId')),
          salaryMonth: salary.month,
          salaryKobo: salaryKobo,
          allowancesKobo: 0,
          bonusesKobo: 0,
          advancesKobo: advances,
          loanRepaidKobo: repaid,
          cashPaidKobo: cash,
          totalPayKobo: salaryKobo,
          salaryEntryId: appPayrollSalaryEntryId(worker.id, salary.month),
          workerSignaturePng: signatureBase64(
            s.textOrNull('employeeSignatureDataUrl'),
          ),
          payerSignaturePng: signatureBase64(
            s.textOrNull('managerSignatureDataUrl'),
          ),
          signedByProfileId: s.textOrNull('managerSignedByProfileId'),
          signedAt: s.timeOrNull('managerSignedAt'),
          createdAt: s.time('createdAt'),
        ),
      );
    }
    for (final s in export.rows('StaffPayrollStatement')) {
      if (!linked.contains(s.id)) {
        leftOut.add('StaffPayrollStatement ${s.id}: archived');
      }
    }

    return PayrollPlan(
      businessId: businessId,
      workers: workers,
      entries: entries,
      statements: statements,
      payTotals: payTotalsFor(
        businessId: businessId,
        entries: entries,
        statements: statements,
      ),
      leftOut: leftOut,
    );
  }

  /// The old app cancelled an entry by stamping it and adding an ADJUSTMENT of
  /// the opposite amount the same moment. This finds that ADJUSTMENT.
  Row _offsetFor(Row cancelled, List<Row> adjustments, Set<String> used) {
    final at = cancelled.time('cancelledAt');
    final amount = cancelled.integer('amountCents');
    Row? best;
    Duration? bestGap;
    for (final a in adjustments) {
      if (used.contains(a.id) ||
          a.text('staffId') != cancelled.text('staffId') ||
          a.integer('amountCents') != -amount) {
        continue;
      }
      final gap = a.time('createdAt').difference(at).abs();
      if (gap > _cancelOffsetWindow) continue;
      if (bestGap == null || gap < bestGap) {
        best = a;
        bestGap = gap;
      }
    }
    return best ??
        (throw PayrollImportError(
          'cancelled entry ${cancelled.id} has no offsetting adjustment',
        ));
  }
}

/// The combined lines the app's `_refreshSalaryTotals` and
/// `_refreshMoneyTotals` would write from these rows: per store and payday a
/// 'salaries' line (amount = salaries, cash = cash handed over when the salary
/// was paid in cash); per store, kind and day a bonus / advance / loan line
/// (amount = every entry, cash = the cash ones), leaving out a repayment kept
/// back from a salary. Lines that come to zero are not written.
List<PlannedPayTotal> payTotalsFor({
  required String businessId,
  required List<PlannedEntry> entries,
  required List<PlannedStatement> statements,
}) {
  final amounts = <String, int>{};
  final cash = <String, int>{};
  final keys = <String, ({String storeId, String kind, String day})>{};
  void add(String storeId, String kind, String day, int amount, int cashPart) {
    final id = appStaffPayTotalId(businessId, storeId, kind, day);
    keys[id] = (storeId: storeId, kind: kind, day: day);
    amounts[id] = (amounts[id] ?? 0) + amount;
    cash[id] = (cash[id] ?? 0) + cashPart;
  }

  final entryById = {for (final e in entries) e.id: e};
  for (final s in statements) {
    final salary = entryById[s.salaryEntryId]!;
    add(
      s.storeId,
      'salaries',
      salary.entryDate,
      s.salaryKobo,
      salary.paymentMethod == 'cash' ? s.cashPaidKobo : 0,
    );
  }
  const kindOf = {
    'bonus': 'bonuses',
    'advance': 'advances',
    'loan_given': 'loans_given',
    'loan_repaid': 'loans_repaid',
  };
  final deductions = {
    for (final s in statements)
      appPayrollSalaryRepaymentId(s.workerId, s.salaryMonth),
  };
  for (final e in entries) {
    final kind = kindOf[e.type];
    if (kind == null) continue;
    if (e.type == 'loan_repaid' && deductions.contains(e.id)) continue;
    add(
      e.storeId,
      kind,
      e.entryDate,
      e.amountKobo,
      e.paymentMethod == 'cash' ? e.amountKobo : 0,
    );
  }
  return [
    for (final MapEntry(key: id, value: k) in keys.entries)
      if (amounts[id] != 0 || cash[id] != 0)
        PlannedPayTotal(
          id: id,
          storeId: k.storeId,
          kind: k.kind,
          totalDate: k.day,
          amountKobo: amounts[id]!,
          cashKobo: cash[id]!,
        ),
  ]..sort(
    (a, b) => '${a.totalDate}${a.kind}'.compareTo('${b.totalDate}${b.kind}'),
  );
}
