part of 'daos.dart';

/// Thrown when a phone whose user lacks [kPayrollPermissionKey] tries to write
/// Payroll data (ADR 0034). Nothing is written and nothing is queued.
class PayrollAccessDenied implements Exception {
  const PayrollAccessDenied();
  @override
  String toString() => 'PayrollAccessDenied: this user cannot manage payroll';
}

/// Payroll data (#667, PRD #666, ADR 0034) — the first permission-gated synced
/// tables. Every write checks [kPayrollPermissionKey] first and throws
/// [PayrollAccessDenied] without touching Drift or the outbox; `SyncDao`
/// re-checks at the enqueue boundary. Entries and statements are append-only:
/// this DAO only ever inserts them (a correction is a new entry).
///
/// The screens (from #668) gate on `Gates.managePayroll`, which names the same
/// key; this DAO checks the key itself so the database layer never imports the
/// widget-facing registry.
@DriftAccessor(tables: [PayrollWorkers, PayrollEntries, PayrollStatements])
class PayrollDao extends DatabaseAccessor<AppDatabase>
    with _$PayrollDaoMixin, BusinessScopedDao<AppDatabase> {
  PayrollDao(super.db);

  /// The permission-gated tables, children first — the order rows must be
  /// removed in so a delete never strands a row something still references.
  static const List<String> _tablesChildrenFirst = [
    'payroll_statements',
    'payroll_entries',
    'payroll_workers',
  ];

  /// Whether the signed-in user holds Payroll in the bound business.
  Future<bool> currentUserHoldsPayroll() async {
    final userId = currentUserId;
    final businessId = currentBusinessId;
    if (userId == null || businessId == null) return false;
    return db.permissionsDao.userHolds(
      userId: userId,
      businessId: businessId,
      permissionKey: kPayrollPermissionKey,
    );
  }

  Future<String> _requireAccess() async {
    final businessId = requireBusinessId();
    if (!await currentUserHoldsPayroll()) throw const PayrollAccessDenied();
    return businessId;
  }

  /// Adds a worker to Payroll. [name] is saved as given (callers apply name
  /// case). Returns the new worker id.
  Future<String> addWorker({
    required String storeId,
    required String name,
    String? userId,
    int monthlySalaryKobo = 0,
    int dailyAllowanceKobo = 0,
    String? allowanceStartDate,
  }) async {
    final businessId = await _requireAccess();
    final id = UuidV7.generate();
    final now = DateTime.now();
    final row = PayrollWorkersCompanion.insert(
      id: Value(id),
      businessId: businessId,
      storeId: storeId,
      userId: Value(userId),
      name: name,
      monthlySalaryKobo: Value(monthlySalaryKobo),
      dailyAllowanceKobo: Value(dailyAllowanceKobo),
      allowanceStartDate: Value(allowanceStartDate),
      isRemoved: const Value(false),
      createdBy: Value(currentUserId),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await transaction(() async {
      await into(payrollWorkers).insert(row);
      await db.syncDao.enqueueUpsert('payroll_workers', row);
      await db.activityLogDao.log(
        action: 'payroll_worker_added',
        description: 'Added payroll worker: $name',
        staffId: currentUserId,
        storeId: storeId,
      );
    });
    return id;
  }

  /// Every worker the business has put on Payroll, removed ones included
  /// (the screen hides them by default), oldest first.
  Stream<List<PayrollWorkerData>> watchWorkers() =>
      (select(payrollWorkers)
            ..where((w) => whereBusiness(w))
            ..orderBy([(w) => OrderingTerm.asc(w.createdAt)]))
          .watch();

  /// Changes a worker's store, salary and allowance. The allowance start date
  /// is set to today only when the worker had none (an allowance that
  /// already runs keeps its start, and it is never backdated). Throws
  /// [PayrollAccessDenied] without the permission.
  Future<void> updateWorker({
    required String workerId,
    required String storeId,
    required int monthlySalaryKobo,
    required int dailyAllowanceKobo,
  }) async {
    final businessId = await _requireAccess();
    await transaction(() async {
      final worker =
          await (select(payrollWorkers)..where(
                (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
              ))
              .getSingle();
      final startDate =
          worker.allowanceStartDate ??
          (dailyAllowanceKobo > 0 ? payrollToday() : null);
      await (update(payrollWorkers)..where((w) => w.id.equals(workerId))).write(
        PayrollWorkersCompanion(
          storeId: Value(storeId),
          monthlySalaryKobo: Value(monthlySalaryKobo),
          dailyAllowanceKobo: Value(dailyAllowanceKobo),
          allowanceStartDate: Value(startDate),
          lastUpdatedAt: Value(DateTime.now()),
        ),
      );
      final row = await (select(
        payrollWorkers,
      )..where((w) => w.id.equals(workerId))).getSingle();
      await db.syncDao.enqueueUpsert('payroll_workers', row.toCompanion(true));
      await db.activityLogDao.log(
        action: 'payroll_worker_edited',
        description: 'Edited payroll worker: ${worker.name}',
        staffId: currentUserId,
        storeId: storeId,
      );
    });
  }

  /// Takes a worker off Payroll: no further allowances, every entry and
  /// statement kept. There is no hard delete.
  Future<void> removeWorker(String workerId) async {
    final businessId = await _requireAccess();
    await transaction(() async {
      final worker =
          await (select(payrollWorkers)..where(
                (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
              ))
              .getSingle();
      final now = DateTime.now();
      await (update(payrollWorkers)..where((w) => w.id.equals(workerId))).write(
        PayrollWorkersCompanion(
          isRemoved: const Value(true),
          removedAt: Value(now),
          lastUpdatedAt: Value(now),
        ),
      );
      final row = await (select(
        payrollWorkers,
      )..where((w) => w.id.equals(workerId))).getSingle();
      await db.syncDao.enqueueUpsert('payroll_workers', row.toCompanion(true));
      await db.activityLogDao.log(
        action: 'payroll_worker_removed',
        description: 'Removed payroll worker: ${worker.name}',
        staffId: currentUserId,
        storeId: worker.storeId,
      );
    });
  }

  /// Today as 'YYYY-MM-DD' (the phone's calendar day).
  static String payrollToday() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}';
  }

  /// Posts [workerId]'s Daily Allowance for [entryDate] ('YYYY-MM-DD') under
  /// the deterministic [payrollAllowanceId], so the same worker and day is ONE
  /// row however many phones (or retries) post it. [amountKobo] defaults to
  /// the worker's daily amount. Returns false (and queues nothing) when that
  /// day's allowance is already on this phone.
  Future<bool> postAllowance({
    required String workerId,
    required String entryDate,
    int? amountKobo,
  }) async {
    final businessId = await _requireAccess();
    final id = payrollAllowanceId(workerId, entryDate);
    return transaction(() async {
      final worker =
          await (select(payrollWorkers)..where(
                (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
              ))
              .getSingle();
      // Already on this phone (posted here, or pulled from another phone):
      // the same worker and day is one row, so there is nothing to add.
      final existing =
          await (select(payrollEntries)..where(
                (e) =>
                    e.id.equals(id) |
                    (e.workerId.equals(workerId) &
                        e.entryDate.equals(entryDate) &
                        e.type.equals('allowance') &
                        e.correctsEntryId.isNull()),
              ))
              .get();
      if (existing.isNotEmpty) return false;
      final now = DateTime.now();
      final row = PayrollEntriesCompanion.insert(
        id: Value(id),
        businessId: businessId,
        workerId: workerId,
        storeId: worker.storeId,
        type: 'allowance',
        amountKobo: amountKobo ?? worker.dailyAllowanceKobo,
        entryDate: entryDate,
        paymentMethod: const Value('cash'),
        recordedBy: Value(currentUserId),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(payrollEntries).insert(row);
      await db.syncDao.enqueueUpsert('payroll_entries', row);
      return true;
    });
  }

  /// Appends one Payroll Entry of [type] ([kPayrollEntryTypes]). Never edits:
  /// a correction is a new entry with [correctsEntryId]. Returns its id.
  Future<String> recordEntry({
    required String workerId,
    required String type,
    required int amountKobo,
    required String entryDate,
    String? salaryMonth,
    String paymentMethod = 'cash',
    String? note,
    String? correctsEntryId,
  }) async {
    if (!kPayrollEntryTypes.contains(type)) {
      throw ArgumentError.value(type, 'type', 'not a Payroll Entry type');
    }
    if (!kPayrollPaymentMethods.contains(paymentMethod)) {
      throw ArgumentError.value(paymentMethod, 'paymentMethod');
    }
    if (type == 'allowance' && correctsEntryId == null) {
      throw ArgumentError.value(
        type,
        'type',
        'a Daily Allowance is posted with postAllowance (one per worker per day)',
      );
    }
    final businessId = await _requireAccess();
    final id = UuidV7.generate();
    return transaction(() async {
      final worker =
          await (select(payrollWorkers)..where(
                (w) => w.id.equals(workerId) & w.businessId.equals(businessId),
              ))
              .getSingle();
      final now = DateTime.now();
      final row = PayrollEntriesCompanion.insert(
        id: Value(id),
        businessId: businessId,
        workerId: workerId,
        storeId: worker.storeId,
        type: type,
        amountKobo: amountKobo,
        entryDate: entryDate,
        salaryMonth: Value(salaryMonth),
        paymentMethod: Value(paymentMethod),
        note: Value(note),
        correctsEntryId: Value(correctsEntryId),
        recordedBy: Value(currentUserId),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(payrollEntries).insert(row);
      await db.syncDao.enqueueUpsert('payroll_entries', row);
      return id;
    });
  }

  /// The worker's entries, oldest first.
  Future<List<PayrollEntryData>> entriesForWorker(String workerId) =>
      (select(payrollEntries)
            ..where((e) => e.workerId.equals(workerId) & whereBusiness(e))
            ..orderBy([
              (e) => OrderingTerm.asc(e.entryDate),
              (e) => OrderingTerm.asc(e.createdAt),
            ]))
          .get();

  /// Removes this phone's Payroll rows for [businessId] after its user lost
  /// [kPayrollPermissionKey] (ADR 0034). LOCAL-ONLY (never enqueued): the
  /// cloud keeps every row. A row still waiting to upload is kept (the outbox
  /// is sacred, invariant #12) — it stays visible in Sync Issues and the cloud
  /// refuses it — and so is any row such a row still references. Returns the
  /// number of rows removed.
  Future<int> purgeForLostAccess(String businessId) async {
    return transaction(() async {
      // Cheap exit for the common case (a phone that never held Payroll): this
      // runs after every pull.
      final any = await customSelect(
        'SELECT EXISTS (SELECT 1 FROM payroll_workers WHERE business_id = ?1) '
        'OR EXISTS (SELECT 1 FROM payroll_entries WHERE business_id = ?1) '
        'OR EXISTS (SELECT 1 FROM payroll_statements WHERE business_id = ?1) '
        'AS has_rows',
        variables: [Variable.withString(businessId)],
      ).getSingle();
      if (!any.read<bool>('has_rows')) return 0;
      final pending = <String>{
        for (final t in _tablesChildrenFirst)
          ...await db.syncDao.pendingRowIds(t, businessId: businessId),
      };
      final keep = pending.toList();
      final placeholders = List.filled(keep.length, '?').join(',');
      final notPending = keep.isEmpty ? '' : 'AND id NOT IN ($placeholders)';
      final vars = [
        Variable.withString(businessId),
        for (final id in keep) Variable.withString(id),
      ];
      var removed = 0;
      removed += await customUpdate(
        'DELETE FROM payroll_statements WHERE business_id = ? $notPending',
        variables: vars,
        updates: {payrollStatements},
        updateKind: UpdateKind.delete,
      );
      removed += await customUpdate(
        'DELETE FROM payroll_entries WHERE business_id = ? $notPending '
        'AND id NOT IN (SELECT salary_entry_id FROM payroll_statements '
        '  WHERE salary_entry_id IS NOT NULL)',
        variables: vars,
        updates: {payrollEntries},
        updateKind: UpdateKind.delete,
      );
      removed += await customUpdate(
        'DELETE FROM payroll_workers WHERE business_id = ? $notPending '
        'AND id NOT IN (SELECT worker_id FROM payroll_entries) '
        'AND id NOT IN (SELECT worker_id FROM payroll_statements)',
        variables: vars,
        updates: {payrollWorkers},
        updateKind: UpdateKind.delete,
      );
      return removed;
    });
  }
}
