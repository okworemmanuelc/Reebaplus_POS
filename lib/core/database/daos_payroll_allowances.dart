part of 'daos.dart';

// ---------------------------------------------------------------------------
// #669 — the automatic Daily Allowance (PRD #666, ADR 0034).
//
// Kept apart from daos_payroll.dart so the other Payroll slices (#670, #671)
// can grow PayrollDao without touching this file.
//
// THE RULES (owner, 2026-11-03)
//   * Posted automatically Monday to Saturday (never Sunday) for every worker
//     with a daily amount > 0, from `allowance_start_date` (never before it)
//     up to and including the day the worker was removed.
//   * Only a phone holding `payroll.manage` posts. A day no such phone was open
//     is filled in later under its own date ([PayrollAllowances.runDailyAllowances]
//     runs on open, on resume, on a timer and after every pull). The
//     deterministic id ([payrollAllowanceId]) makes it one row however many
//     phones or runs post it.
//   * Till cash from the worker's store.
//   * A change or cancel for one worker on one day: before the day's allowance
//     is posted, it IS the posted row (same deterministic id, so the automatic
//     run finds the day done and never overwrites it); after, a NEW correcting
//     entry dated the day of the change, `corrects_entry_id` → the original,
//     carrying the difference (a cancel brings the day to zero). The cloud's
//     one-allowance-per-day index exempts corrections.
//   * Every phone sees ONE combined "Daily allowances" line per store per day
//     ([StaffPayTotals]) with no worker named.
// ---------------------------------------------------------------------------

/// 'YYYY-MM-DD' for [d]'s calendar day.
String payrollDayKey(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// The calendar day 'YYYY-MM-DD' names, at local midnight; null when malformed.
DateTime? payrollParseDay(String day) {
  final parts = day.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

/// Whether [worker] is owed a Daily Allowance on [day] (a calendar day):
/// a daily amount is set, [day] is Monday to Saturday, on or after the start
/// date, and not after the day they were removed. The removal day itself
/// counts — the worker worked it, and the answer must not depend on whether a
/// phone happened to run before the removal.
bool isAllowanceDay(PayrollWorkerData worker, DateTime day) {
  if (worker.dailyAllowanceKobo <= 0) return false;
  final start = worker.allowanceStartDate == null
      ? null
      : payrollParseDay(worker.allowanceStartDate!);
  if (start == null) return false;
  final d = DateTime(day.year, day.month, day.day);
  if (d.weekday == DateTime.sunday) return false;
  if (d.isBefore(start)) return false;
  final removedAt = worker.removedAt;
  if (worker.isRemoved && removedAt != null) {
    final r = removedAt.toLocal();
    if (d.isAfter(DateTime(r.year, r.month, r.day))) return false;
  }
  return true;
}

/// Every day from [worker]'s start date to [today] (inclusive) that is owed an
/// allowance ([isAllowanceDay]), oldest first, as 'YYYY-MM-DD'.
List<String> allowanceDueDays(PayrollWorkerData worker, DateTime today) {
  final start = worker.allowanceStartDate == null
      ? null
      : payrollParseDay(worker.allowanceStartDate!);
  if (start == null || worker.dailyAllowanceKobo <= 0) return const [];
  final end = DateTime(today.year, today.month, today.day);
  final out = <String>[];
  // Calendar-day steps (DateTime(y, m, d + 1)) so a DST shift never skips or
  // repeats a day.
  for (
    var d = start;
    !d.isAfter(end);
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    if (isAllowanceDay(worker, d)) out.add(payrollDayKey(d));
  }
  return out;
}

/// Reads of the combined pay lines (#669). Business-wide, NOT
/// permission-gated: every phone receives these rows (ADR 0034), and they name
/// no worker.
@DriftAccessor(tables: [StaffPayTotals])
class StaffPayTotalsDao extends DatabaseAccessor<AppDatabase>
    with _$StaffPayTotalsDaoMixin, BusinessScopedDao<AppDatabase> {
  StaffPayTotalsDao(super.db);

  /// Every combined pay line of the bound business, newest day first.
  Stream<List<StaffPayTotalData>> watchAll() =>
      (select(staffPayTotals)
            ..where((t) => whereBusiness(t))
            ..orderBy([(t) => OrderingTerm.desc(t.totalDate)]))
          .watch();
}

/// The automatic Daily Allowance and its per-day change / cancel (#669).
extension PayrollAllowances on PayrollDao {
  /// Every allowance entry (originals and corrections) of the bound business.
  Stream<List<PayrollEntryData>> watchAllowanceEntries() =>
      (select(payrollEntries)
            ..where(
              (e) =>
                  whereBusiness(e) &
                  e.type.equals('allowance') &
                  e.status.equals('approved'),
            )
            ..orderBy([(e) => OrderingTerm.asc(e.createdAt)]))
          .watch();

  /// Posts every Daily Allowance owed up to today that this phone does not
  /// already hold — today's and any missed day, each under its own date — then
  /// brings the combined store lines up to date. A silent no-op (returns 0)
  /// without the Payroll permission or a bound business; idempotent, so it is
  /// safe to run on every open, resume and pull. Returns how many it posted.
  Future<int> runDailyAllowances({DateTime? now}) async {
    final businessId = currentBusinessId;
    if (businessId == null) return 0;
    if (!await currentUserHoldsPayroll()) return 0;
    final today = now ?? DateTime.now();
    return transaction(() async {
      final workers =
          await (select(payrollWorkers)..where(
                (w) =>
                    w.businessId.equals(businessId) &
                    w.dailyAllowanceKobo.isBiggerThanValue(0) &
                    w.allowanceStartDate.isNotNull(),
              ))
              .get();
      final held = {
        for (final e in await _allowanceOriginals(businessId))
          '${e.workerId}|${e.entryDate}',
      };
      final at = DateTime.now();
      var posted = 0;
      for (final w in workers) {
        for (final day in allowanceDueDays(w, today)) {
          if (held.contains('${w.id}|$day')) continue;
          final row = PayrollEntriesCompanion.insert(
            id: Value(payrollAllowanceId(w.id, day)),
            businessId: businessId,
            workerId: w.id,
            storeId: w.storeId,
            type: 'allowance',
            amountKobo: w.dailyAllowanceKobo,
            entryDate: day,
            paymentMethod: const Value('cash'),
            status: const Value('approved'),
            recordedBy: Value(currentUserId),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          );
          await into(payrollEntries).insert(row);
          await db.syncDao.enqueueUpsert('payroll_entries', row);
          held.add('${w.id}|$day');
          posted++;
        }
      }
      await _refreshAllowanceTotals(businessId);
      return posted;
    });
  }

  /// What [workerId]'s allowance for [entryDate] ('YYYY-MM-DD') stands at:
  /// the posted original (null when not yet posted) and the day's net after
  /// every correction pointing at it.
  Future<({PayrollEntryData? original, int netKobo})> allowanceForDay(
    String workerId,
    String entryDate,
  ) async {
    final businessId = requireBusinessId();
    final original = await _allowanceOriginal(businessId, workerId, entryDate);
    if (original == null) return (original: null, netKobo: 0);
    return (
      original: original,
      netKobo: original.amountKobo + await _correctionsSum(original.id),
    );
  }

  /// Sets [workerId]'s Daily Allowance for [entryDate] ('YYYY-MM-DD') to
  /// [amountKobo]; 0 cancels it. Throws [PayrollAccessDenied] without the
  /// permission and [ArgumentError] for a day the worker is not owed an
  /// allowance (a Sunday, before the start date, after removal, or in the
  /// future). Returns false when the day already stands at [amountKobo].
  ///
  /// Not yet posted → posts it now at [amountKobo] under the deterministic id,
  /// so the automatic run finds the day done and never overwrites the change.
  /// Already posted → a new correcting entry dated today with the difference.
  Future<bool> setAllowanceForDay({
    required String workerId,
    required String entryDate,
    required int amountKobo,
    DateTime? now,
  }) async {
    if (amountKobo < 0) {
      throw ArgumentError.value(amountKobo, 'amountKobo', 'must not be < 0');
    }
    final businessId = await _requireAccess();
    final today = now ?? DateTime.now();
    final day = payrollParseDay(entryDate);
    if (day == null) throw ArgumentError.value(entryDate, 'entryDate');
    return transaction(() async {
      final worker =
          await (select(payrollWorkers)..where(
                (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
              ))
              .getSingle();
      if (day.isAfter(DateTime(today.year, today.month, today.day)) ||
          !isAllowanceDay(worker, day)) {
        throw ArgumentError.value(
          entryDate,
          'entryDate',
          'no Daily Allowance is due on this day',
        );
      }
      final cancel = amountKobo == 0;
      final at = DateTime.now();
      final original = await _allowanceOriginal(
        businessId,
        workerId,
        entryDate,
      );
      if (original == null) {
        final row = PayrollEntriesCompanion.insert(
          id: Value(payrollAllowanceId(workerId, entryDate)),
          businessId: businessId,
          workerId: workerId,
          storeId: worker.storeId,
          type: 'allowance',
          amountKobo: amountKobo,
          entryDate: entryDate,
          paymentMethod: const Value('cash'),
          status: const Value('approved'),
          note: Value(cancel ? 'Cancelled' : 'Changed'),
          recordedBy: Value(currentUserId),
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        );
        await into(payrollEntries).insert(row);
        await db.syncDao.enqueueUpsert('payroll_entries', row);
      } else {
        final net = original.amountKobo + await _correctionsSum(original.id);
        final delta = amountKobo - net;
        if (delta == 0) return false;
        final row = PayrollEntriesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          workerId: workerId,
          // The same till the original came out of, so the store line nets.
          storeId: original.storeId,
          type: 'allowance',
          amountKobo: delta,
          entryDate: payrollDayKey(today),
          paymentMethod: const Value('cash'),
          status: const Value('approved'),
          note: Value(cancel ? 'Cancelled $entryDate' : 'Changed $entryDate'),
          correctsEntryId: Value(original.id),
          recordedBy: Value(currentUserId),
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        );
        await into(payrollEntries).insert(row);
        await db.syncDao.enqueueUpsert('payroll_entries', row);
      }
      // Worker name and day only — activity logs reach every phone, so never
      // an amount (ADR 0034).
      await db.activityLogDao.log(
        action: cancel
            ? 'payroll_allowance_cancelled'
            : 'payroll_allowance_changed',
        description:
            '${cancel ? 'Cancelled' : 'Changed'} daily allowance: '
            '${worker.name} for $entryDate',
        staffId: currentUserId,
        storeId: worker.storeId,
      );
      await _refreshAllowanceTotals(businessId);
      return true;
    });
  }

  /// Rewrites the combined "Daily allowances" lines from this phone's
  /// allowance entries. A silent no-op without the permission. Runs after
  /// every pull, so a line another phone wrote from fewer entries converges.
  Future<void> refreshAllowanceTotals() async {
    final businessId = currentBusinessId;
    if (businessId == null) return;
    if (!await currentUserHoldsPayroll()) return;
    await transaction(() => _refreshAllowanceTotals(businessId));
  }

  Future<List<PayrollEntryData>> _allowanceOriginals(String businessId) =>
      (select(payrollEntries)..where(
            (e) =>
                e.businessId.equals(businessId) &
                e.type.equals('allowance') &
                e.correctsEntryId.isNull(),
          ))
          .get();

  Future<PayrollEntryData?> _allowanceOriginal(
    String businessId,
    String workerId,
    String entryDate,
  ) async {
    final rows =
        await (select(payrollEntries)
              ..where(
                (e) =>
                    e.businessId.equals(businessId) &
                    (e.id.equals(payrollAllowanceId(workerId, entryDate)) |
                        (e.workerId.equals(workerId) &
                            e.entryDate.equals(entryDate) &
                            e.type.equals('allowance') &
                            e.correctsEntryId.isNull())),
              )
              ..limit(1))
            .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> _correctionsSum(String originalId) async {
    final sum = payrollEntries.amountKobo.sum();
    final row =
        await (selectOnly(payrollEntries)
              ..addColumns([sum])
              ..where(
                payrollEntries.correctsEntryId.equals(originalId) &
                    payrollEntries.status.equals('approved'),
              ))
            .getSingle();
    return row.read(sum) ?? 0;
  }

  /// One combined line per store and day: the sum of that store's allowance
  /// entries dated that day (a late correction counts on the day it was made).
  /// Only lines whose figure moved are written and queued.
  Future<void> _refreshAllowanceTotals(String businessId) async {
    final sums = await customSelect(
      'SELECT store_id, entry_date, SUM(amount_kobo) AS total '
      'FROM payroll_entries '
      "WHERE business_id = ? AND type = 'allowance' AND status = 'approved' "
      'GROUP BY store_id, entry_date',
      variables: [Variable.withString(businessId)],
      readsFrom: {payrollEntries},
    ).get();
    final existing = {
      for (final t
          in await (select(db.staffPayTotals)..where(
                (t) =>
                    t.businessId.equals(businessId) &
                    t.kind.equals(kStaffPayKindDailyAllowances),
              ))
              .get())
        t.id: t,
    };
    final at = DateTime.now();
    for (final s in sums) {
      final storeId = s.read<String>('store_id');
      final day = s.read<String>('entry_date');
      final total = s.read<int>('total');
      final id = staffPayTotalId(
        businessId,
        storeId,
        kStaffPayKindDailyAllowances,
        day,
      );
      final current = existing[id];
      if (current == null && total == 0) continue;
      if (current != null &&
          current.amountKobo == total &&
          current.cashKobo == total) {
        continue;
      }
      final row = StaffPayTotalsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        storeId: storeId,
        kind: kStaffPayKindDailyAllowances,
        totalDate: day,
        amountKobo: Value(total),
        // Every Daily Allowance is till cash.
        cashKobo: Value(total),
        createdAt: Value(current?.createdAt ?? at),
        lastUpdatedAt: Value(at),
      );
      await into(db.staffPayTotals).insertOnConflictUpdate(row);
      await db.syncDao.enqueueUpsert('staff_pay_totals', row);
    }
  }
}
