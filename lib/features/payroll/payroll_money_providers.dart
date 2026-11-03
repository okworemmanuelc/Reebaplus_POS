import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

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
