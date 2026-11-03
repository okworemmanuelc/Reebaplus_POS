import 'package:reebaplus_pos/core/database/app_database.dart';

/// Where one worker's Daily Allowance stands on one day (#669).
enum AllowanceDayStatus {
  /// Owed but not posted yet on this phone; it posts automatically.
  due,

  /// Posted at the worker's amount.
  posted,

  /// Posted at a different amount (changed before or after posting).
  changed,

  /// Brought to zero.
  cancelled,
}

/// One row of the "Daily allowances" day view.
class AllowanceDayRow {
  const AllowanceDayRow({
    required this.worker,
    required this.original,
    required this.amountKobo,
    required this.status,
  });

  final PayrollWorkerData worker;

  /// The day's posted entry (deterministic id), or null when not yet posted.
  final PayrollEntryData? original;

  /// What the day stands at: the posted amount net of every correction, or
  /// the worker's daily amount when not yet posted.
  final int amountKobo;
  final AllowanceDayStatus status;
}

/// Every worker owed a Daily Allowance on [day], with where it stands, in
/// worker-list order. Pure: [entries] are the allowance entries
/// (`payrollAllowanceEntriesProvider`).
List<AllowanceDayRow> allowanceDayRows({
  required Iterable<PayrollWorkerData> workers,
  required Iterable<PayrollEntryData> entries,
  required DateTime day,
}) {
  final key = payrollDayKey(day);
  final originals = <String, PayrollEntryData>{};
  final corrections = <String, List<PayrollEntryData>>{};
  for (final e in entries) {
    // Only approved entries count (#670); allowances are never pending.
    if (e.type != 'allowance' || e.status != 'approved') continue;
    final target = e.correctsEntryId;
    if (target == null) {
      if (e.entryDate == key) originals[e.workerId] = e;
    } else {
      (corrections[target] ??= []).add(e);
    }
  }
  final rows = <AllowanceDayRow>[];
  for (final w in workers) {
    final original = originals[w.id];
    if (original == null) {
      if (!isAllowanceDay(w, day)) continue;
      rows.add(
        AllowanceDayRow(
          worker: w,
          original: null,
          amountKobo: w.dailyAllowanceKobo,
          status: AllowanceDayStatus.due,
        ),
      );
      continue;
    }
    final fixes = corrections[original.id] ?? const <PayrollEntryData>[];
    final net = fixes.fold<int>(
      original.amountKobo,
      (s, c) => s + c.amountKobo,
    );
    final status = net == 0
        ? AllowanceDayStatus.cancelled
        : (fixes.isNotEmpty || original.note != null)
        ? AllowanceDayStatus.changed
        : AllowanceDayStatus.posted;
    rows.add(
      AllowanceDayRow(
        worker: w,
        original: original,
        amountKobo: net,
        status: status,
      ),
    );
  }
  return rows;
}
