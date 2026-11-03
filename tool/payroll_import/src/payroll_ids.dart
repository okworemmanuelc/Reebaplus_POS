import 'package:uuid/uuid.dart';

import '../../legacy_import/src/ids.dart';

/// Ids the app itself derives. They must match it exactly, or a phone paying,
/// correcting or refreshing the same row would write a second one (and the
/// unique indexes would jam its outbox). Copies of `UuidV7.deterministic` and
/// the seeds in app_database.dart / daos_payroll_payday.dart; a test compares
/// them with the app's own functions.
String _appDeterministic(String seed) =>
    const Uuid().v5(Namespace.url.value, seed);

String appPayrollStatementId(String workerId, String salaryMonth) =>
    _appDeterministic('payroll_statement:$workerId:$salaryMonth');

String appPayrollSalaryEntryId(String workerId, String salaryMonth) =>
    _appDeterministic('payroll_salary:$workerId:$salaryMonth');

String appPayrollSalaryRepaymentId(String workerId, String salaryMonth) =>
    _appDeterministic('payroll_salary_repayment:$workerId:$salaryMonth');

String appStaffPayTotalId(
  String businessId,
  String storeId,
  String kind,
  String totalDate,
) => _appDeterministic('staff_pay_total:$businessId:$storeId:$kind:$totalDate');

/// Ids the import alone derives, in the main importer's namespace, so a
/// re-run maps every old row to the same new id.
String importWorkerId(String oldStaffId) =>
    legacyId('PayrollWorker', oldStaffId);

String importPayrollEntryId(String oldEntryId) =>
    legacyId('PayrollEntry', oldEntryId);

String importLoanEntryId(String oldLoanEntryId) =>
    legacyId('PayrollLoanEntry', oldLoanEntryId);

/// The store and user ids the main import (#623) gave the old rows.
String importStoreId(String oldStoreId) => legacyId('Store', oldStoreId);

String importUserId(String oldProfileId) => legacyId('User', oldProfileId);
