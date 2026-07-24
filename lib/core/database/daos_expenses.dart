part of 'daos.dart';

@DriftAccessor(
  tables: [Expenses, ExpenseCategories, ActivityLogs, PaymentTransactions],
)
class ExpensesDao extends DatabaseAccessor<AppDatabase>
    with _$ExpensesDaoMixin, BusinessScopedDao<AppDatabase> {
  ExpensesDao(super.db);

  Stream<List<ExpenseWithCategory>> watchAll({String? storeId}) {
    final query = select(expenses).join([
      leftOuterJoin(
        expenseCategories,
        expenseCategories.id.equalsExp(expenses.categoryId),
      ),
    ]);

    query.where(whereBusiness(expenses) & expenses.isDeleted.not());
    if (storeId != null) {
      query.where(expenses.storeId.equals(storeId));
    }
    query.orderBy([OrderingTerm.desc(expenses.createdAt)]);

    return query.watch().map((rows) {
      return rows.map((row) {
        return ExpenseWithCategory(
          expense: row.readTable(expenses),
          category: row.readTableOrNull(expenseCategories),
        );
      }).toList();
    });
  }

  Stream<List<ExpenseCategoryData>> watchAllCategories() {
    return (select(expenseCategories)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  Future<String> resolveCategoryId(String name) async {
    final normalized = name.trim();

    final existing =
        await (select(expenseCategories)
              ..where((t) => whereBusiness(t) & t.name.equals(normalized))
              ..limit(1))
            .getSingleOrNull();

    if (existing != null) return existing.id;

    final id = UuidV7.generate();
    final catComp = ExpenseCategoriesCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      name: normalized,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(expenseCategories).insert(catComp);
    await db.syncDao.enqueueUpsert('expense_categories', catComp);
    return id;
  }

  /// Records an expense (§20). [status] is computed by the caller from the
  /// recorder's role + approval limit: 'approved' for a CEO or a Manager within
  /// their limit; 'pending' for a Manager over limit. The payment method is
  /// recorded for reporting; an expense no longer posts to any account balance
  /// (Funds Register removed, §23).
  Future<void> addExpense({
    required String categoryName,
    required int amountKobo,
    required String description,
    String? paymentMethod,
    String? reference,
    String? storeId,
    required String recordedBy,
    DateTime? expenseDate,
    String? receiptPath,
    String status = 'approved',
  }) async {
    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.record_expense',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    // Match v1's existing behavior: a payment_transactions row is always
    // recorded (defaulting to 'other' when the caller didn't specify a
    // method). Keeps analytics/reporting parity across the flag flip.
    final effectivePaymentMethod = paymentMethod ?? 'other';
    final pickedDate = expenseDate ?? DateTime.now();

    await transaction(() async {
      final categoryId = await resolveCategoryId(categoryName);
      final expenseId = UuidV7.generate();
      final activityLogId = UuidV7.generate();
      final paymentId = UuidV7.generate();
      final now = DateTime.now();
      final approved = status == 'approved';

      // 1. Insert Expense locally (UI-immediate).
      final expComp = ExpensesCompanion.insert(
        id: Value(expenseId),
        businessId: requireBusinessId(),
        categoryId: Value(categoryId),
        amountKobo: amountKobo,
        description: description,
        paymentMethod: Value(paymentMethod),
        recordedBy: Value(recordedBy),
        reference: Value(reference),
        storeId: Value(storeId),
        status: Value(status),
        expenseDate: Value(pickedDate),
        receiptPath: Value(receiptPath),
        approvedBy: approved ? Value(recordedBy) : const Value.absent(),
        approvedAt: approved ? Value(now) : const Value.absent(),
        lastUpdatedAt: Value(now),
      );
      await into(expenses).insert(expComp);

      // 2. Insert Activity Log locally (inlined — we need the id for the
      // v2 envelope and ActivityLogDao.log generates ids internally).
      final activityComp = ActivityLogsCompanion.insert(
        id: Value(activityLogId),
        businessId: requireBusinessId(),
        userId: Value(recordedBy),
        action: 'expense_created',
        description: 'Recorded expense: $description ($categoryName)',
        entityType: const Value('expense'),
        entityId: Value(expenseId),
        storeId: Value(storeId),
        lastUpdatedAt: Value(now),
      );
      await into(db.activityLogs).insert(activityComp);

      // 3. Insert Payment Transaction locally.
      final payComp = PaymentTransactionsCompanion.insert(
        id: Value(paymentId),
        businessId: requireBusinessId(),
        // #169: stamp the expense's store on this new payment row (nullable;
        // unread by reports yet, so behavior-preserving).
        storeId: Value(storeId),
        amountKobo: amountKobo,
        method: effectivePaymentMethod,
        type: 'expense',
        expenseId: Value(expenseId),
        performedBy: Value(recordedBy),
        lastUpdatedAt: Value(now),
      );
      await into(db.paymentTransactions).insert(payComp);

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': recordedBy,
          'p_expense_id': expenseId,
          'p_payment_id': paymentId,
          'p_activity_log_id': activityLogId,
          'p_amount_kobo': amountKobo,
          'p_description': description,
          'p_category_id': categoryId,
          'p_payment_method': effectivePaymentMethod,
          'p_status': status,
          'p_expense_date': pickedDate.toIso8601String(),
          if (reference != null) 'p_reference': reference,
          if (storeId != null) 'p_store_id': storeId,
          if (receiptPath != null) 'p_receipt_path': receiptPath,
        };
        await db.syncDao.enqueue(
          'domain:pos_record_expense',
          jsonEncode(payload),
        );
      } else {
        await db.syncDao.enqueueUpsert('expenses', expComp);
        await db.syncDao.enqueueUpsert('activity_logs', activityComp);
        await db.syncDao.enqueueUpsert('payment_transactions', payComp);
      }

      // 4. §20.4 / §26.4 — a Manager's over-limit expense lands Pending; alert
      // the CEO(s) so the approval surfaces on their notification bell (the
      // §20.1 "pending approval" badge). Fired inside the txn so it rolls back
      // with the insert.
      if (!approved) {
        final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs([
          'ceo',
        ]);
        for (final uid in ceoIds) {
          await db.notificationsDao.fireNotification(
            type: 'expense.pending_approval',
            message: 'Expense awaiting your approval: $description',
            severity: 'warning',
            linkedRecordId: expenseId,
            recipientUserId: uid,
          );
        }
      }
    });
  }

  /// Count of expenses awaiting CEO approval (§20.1 bell badge / pending
  /// section). Business-scoped, non-deleted.
  Stream<int> watchPendingCount() {
    final query = selectOnly(expenses)
      ..addColumns([expenses.id.count()])
      ..where(
        whereBusiness(expenses) &
            expenses.isDeleted.not() &
            expenses.status.equals('pending'),
      );
    return query.watchSingleOrNull().map(
      (row) => row?.read(expenses.id.count()) ?? 0,
    );
  }

  /// CEO approves a pending expense (§20.4). Sets status + approver and notifies
  /// the recorder. (An approved expense no longer posts to any account balance —
  /// Funds Register removed, §23.)
  Future<void> approveExpense({
    required String expenseId,
    required String approverId,
  }) async {
    // The status read+guard MUST live inside the transaction. Drift serializes
    // transactions on one connection, so a concurrent/double-tap approve sees
    // the already-committed 'approved' status and no-ops. The conditional UPDATE
    // (status == 'pending') + affected-row check is the belt-and-suspenders.
    String? recordedBy;
    String? description;
    var didApprove = false;

    await transaction(() async {
      final exp =
          await (select(expenses)
                ..where((t) => t.id.equals(expenseId) & whereBusiness(t)))
              .getSingleOrNull();
      if (exp == null || exp.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(expenses)..where(
                (t) =>
                    t.id.equals(expenseId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                ExpensesCompanion(
                  status: const Value('approved'),
                  approvedBy: Value(approverId),
                  approvedAt: Value(now),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return; // lost the race — already approved
      didApprove = true;
      recordedBy = exp.recordedBy;
      description = exp.description;

      final row = await (select(
        expenses,
      )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));

      await db.activityLogDao.log(
        action: 'expense_approved',
        description: 'Approved expense: ${exp.description}',
        staffId: approverId,
        storeId: exp.storeId,
        expenseId: expenseId,
      );
    });

    if (didApprove && recordedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'expense.approved',
        message: 'Your expense "$description" was approved.',
        severity: 'info',
        linkedRecordId: expenseId,
        recipientUserId: recordedBy,
      );
    }
  }

  /// CEO rejects a pending expense with a reason (§20.4). No funds movement.
  /// Notifies the recorder.
  Future<void> rejectExpense({
    required String expenseId,
    required String approverId,
    required String reason,
  }) async {
    // In-transaction guard (same reasoning as approveExpense) so a double-tap
    // reject doesn't re-fire / re-notify.
    String? recordedBy;
    String? description;
    var didReject = false;

    await transaction(() async {
      final exp =
          await (select(expenses)
                ..where((t) => t.id.equals(expenseId) & whereBusiness(t)))
              .getSingleOrNull();
      if (exp == null || exp.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(expenses)..where(
                (t) =>
                    t.id.equals(expenseId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                ExpensesCompanion(
                  status: const Value('rejected'),
                  rejectionReason: Value(reason),
                  approvedBy: Value(approverId),
                  approvedAt: Value(now),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;
      didReject = true;
      recordedBy = exp.recordedBy;
      description = exp.description;

      final row = await (select(
        expenses,
      )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));

      await db.activityLogDao.log(
        action: 'expense_rejected',
        description: 'Rejected expense: ${exp.description} — $reason',
        staffId: approverId,
        storeId: exp.storeId,
        expenseId: expenseId,
      );
    });

    if (didReject && recordedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'expense.rejected',
        message: 'Your expense "$description" was rejected: $reason',
        severity: 'warning',
        linkedRecordId: expenseId,
        recipientUserId: recordedBy,
      );
    }
  }

  /// Edits the descriptive fields of an expense (§20.3 Edit). Amount and payment
  /// method are immutable after creation — a wrong amount is corrected by
  /// soft-delete + re-create. The 24h / role gate is enforced by the caller.
  Future<void> updateExpense({
    required String expenseId,
    required String performedBy,
    required String categoryName,
    required String description,
    String? reference,
    DateTime? expenseDate,
    String? receiptPath,
  }) async {
    final categoryId = await resolveCategoryId(categoryName);
    final now = DateTime.now();
    await (update(
      expenses,
    )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).write(
      ExpensesCompanion(
        categoryId: Value(categoryId),
        description: Value(description),
        reference: Value(reference),
        expenseDate: expenseDate != null
            ? Value(expenseDate)
            : const Value.absent(),
        receiptPath: Value(receiptPath),
        lastUpdatedAt: Value(now),
      ),
    );
    final row = await (select(
      expenses,
    )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
    await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));

    await db.activityLogDao.log(
      action: 'expense_updated',
      description: 'Edited expense: ${row.description}',
      staffId: performedBy,
      storeId: row.storeId,
      expenseId: expenseId,
    );
  }

  /// Soft-deletes an expense (§20.3, CEO only, hard rule #9 — enqueueUpsert, not
  /// delete). The 24h / role gate is enforced by the caller. (Funds Register was
  /// removed, §23, so a delete no longer reverses any account balance.)
  Future<void> softDeleteExpense({
    required String expenseId,
    required String performedBy,
  }) async {
    // Read + delete-guard live inside the transaction (Drift serializes txns),
    // and the UPDATE is conditional on is_deleted = false, so a double-tap
    // delete is idempotent.
    String? description;
    String? storeIdForLog;
    var didDelete = false;

    await transaction(() async {
      final exp =
          await (select(expenses)
                ..where((t) => t.id.equals(expenseId) & whereBusiness(t)))
              .getSingleOrNull();
      if (exp == null || exp.isDeleted) return;
      final now = DateTime.now();
      final affected =
          await (update(expenses)..where(
                (t) =>
                    t.id.equals(expenseId) &
                    whereBusiness(t) &
                    t.isDeleted.equals(false),
              ))
              .write(
                ExpensesCompanion(
                  isDeleted: const Value(true),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return; // lost the race — already deleted
      didDelete = true;
      description = exp.description;
      storeIdForLog = exp.storeId;

      final row = await (select(
        expenses,
      )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));
    });

    if (didDelete) {
      await db.activityLogDao.log(
        action: 'expense_deleted',
        description: 'Deleted expense: $description',
        staffId: performedBy,
        storeId: storeIdForLog,
        expenseId: expenseId,
      );
    }
  }

  Stream<int> watchTotalThisMonth() {
    return db.settingsDao.watchTimezone().switchMap((timezoneName) {
      final location = tz.getLocation(timezoneName);
      final now = tz.TZDateTime.now(location);
      final startOfMonth = tz.TZDateTime(location, now.year, now.month, 1);
      final nextMonth = tz.TZDateTime(location, now.year, now.month + 1, 1);

      final query = selectOnly(expenses)
        ..addColumns([expenses.amountKobo.sum()])
        ..where(
          whereBusiness(expenses) &
              expenses.isDeleted.not() &
              expenses.createdAt.isBiggerOrEqualValue(startOfMonth) &
              expenses.createdAt.isSmallerThanValue(nextMonth),
        );

      return query.watchSingleOrNull().map(
        (row) => row?.read(expenses.amountKobo.sum()) ?? 0,
      );
    });
  }
}

class ExpenseWithCategory {
  final ExpenseData expense;
  final ExpenseCategoryData? category;
  ExpenseWithCategory({required this.expense, this.category});
}

/// §20.1/§20.3 monthly budget goal. One live row per (business, store-or-null):
/// a null store_id row is the business-wide goal; a store_id row is that store's
/// goal. Routed through enqueueUpsert per the §5 sync contract.

@DriftAccessor(tables: [ExpenseBudgets])
class ExpenseBudgetsDao extends DatabaseAccessor<AppDatabase>
    with _$ExpenseBudgetsDaoMixin, BusinessScopedDao<AppDatabase> {
  ExpenseBudgetsDao(super.db);

  /// All live budgets for the business (the business-wide row has null
  /// store_id). The provider layer resolves the goal for a given store scope.
  Stream<List<ExpenseBudgetData>> watchAll() {
    return (select(
      expenseBudgets,
    )..where((t) => whereBusiness(t) & t.isDeleted.not())).watch();
  }

  /// Sets the monthly goal for (business, [storeId]-or-null). storeId null sets
  /// the business-wide goal. Updates the existing live row for the scope, else
  /// inserts a fresh one — one live row per scope (the partial unique indexes
  /// guard against races). enqueueUpsert syncs it (§5).
  Future<void> setBudget({String? storeId, required int amountKobo}) async {
    final existing =
        await (select(expenseBudgets)
              ..where((t) {
                final base = whereBusiness(t) & t.isDeleted.not();
                return storeId == null
                    ? base & t.storeId.isNull()
                    : base & t.storeId.equals(storeId);
              })
              ..limit(1))
            .getSingleOrNull();
    final now = DateTime.now();
    if (existing != null) {
      await (update(
        expenseBudgets,
      )..where((t) => t.id.equals(existing.id) & whereBusiness(t))).write(
        ExpenseBudgetsCompanion(
          amountKobo: Value(amountKobo),
          lastUpdatedAt: Value(now),
        ),
      );
      final row = await (select(
        expenseBudgets,
      )..where((t) => t.id.equals(existing.id) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expense_budgets', row.toCompanion(true));
    } else {
      final comp = ExpenseBudgetsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        storeId: Value(storeId),
        amountKobo: amountKobo,
        lastUpdatedAt: Value(now),
      );
      await into(expenseBudgets).insert(comp);
      await db.syncDao.enqueueUpsert('expense_budgets', comp);
    }
  }
}
