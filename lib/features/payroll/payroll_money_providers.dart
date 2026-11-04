import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';

/// One worker's Payroll Entries, newest first (#670). Empty on a phone without
/// `payroll.manage`: those rows never sync there (ADR 0034).
final payrollWorkerEntriesProvider =
    businessScopedStreamFamily<List<PayrollEntryData>, String>(
      (ref, db, businessId, workerId) =>
          db.payrollDao.watchEntriesForWorker(workerId),
      whenAbsent: const [],
    );

/// Every bonus, advance or loan waiting for the CEO, oldest first.
final payrollPendingEntriesProvider =
    businessScopedStream<List<PayrollEntryData>>(
      (ref, db, businessId) => db.payrollDao.watchPendingEntries(),
      whenAbsent: const [],
    );

/// Whether the signed-in user approves waiting Payroll Entries (the CEO). The
/// DAO re-checks on every decision.
final payrollIsApproverProvider = Provider<bool>(
  (ref) => ref.watch(currentUserRoleProvider)?.slug == 'ceo',
);

/// One worker's signed salary statements, newest month first (#671). Empty on
/// a phone without `payroll.manage` (ADR 0034).
final payrollWorkerStatementsProvider =
    businessScopedStreamFamily<List<PayrollStatementData>, String>(
      (ref, db, businessId, workerId) =>
          db.payrollDao.watchStatementsForWorker(workerId),
      whenAbsent: const [],
    );

/// #723: every Payroll Entry of the business, any status. The Overview and
/// History work out their figures from these. Empty without `payroll.manage`.
final payrollAllEntriesProvider = businessScopedStream<List<PayrollEntryData>>(
  (ref, db, businessId) => db.payrollDao.watchAllEntries(),
  whenAbsent: const [],
);

/// #723: the signed statements of one Salary Month ('YYYY-MM').
final payrollMonthStatementsProvider =
    businessScopedStreamFamily<List<PayrollStatementData>, String>(
      (ref, db, businessId, month) =>
          db.payrollDao.watchStatementsForMonth(month),
      whenAbsent: const [],
    );

/// #723: the Overview of one Salary Month.
final payrollMonthViewProvider = Provider.family<PayrollMonthView, String>(
  (ref, month) => PayrollMonthView.build(
    workers: ref.watch(payrollWorkersProvider).valueOrNull ?? const [],
    entries: ref.watch(payrollAllEntriesProvider).valueOrNull ?? const [],
    statements:
        ref.watch(payrollMonthStatementsProvider(month)).valueOrNull ??
        const [],
    month: month,
    today: DateTime.now(),
  ),
);
