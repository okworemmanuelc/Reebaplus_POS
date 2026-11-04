import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_add_record_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_allowances_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_pay_salary_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_payslip_screen.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_entry_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_dialog.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

String _money(int kobo) => formatCurrency(kobo / 100);

/// Opens the worker's Pay Salary page for [month].
void openPaySalary(BuildContext context, String workerId, String month) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PayrollPaySalaryScreen(workerId: workerId, month: month),
    ),
  );
}

/// Opens Add Pay Record, with [workerId] already chosen when given.
void openAddPayRecord(BuildContext context, {String? workerId}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PayrollAddRecordScreen(workerId: workerId),
    ),
  );
}

/// Opens the add / edit worker form.
Future<void> openWorkerForm(
  BuildContext context, {
  PayrollWorkerData? worker,
}) => showDialog<void>(
  context: context,
  builder: (_) => PayrollWorkerDialog(worker: worker),
);

/// A tap on a History line: the payslip for a salary, the decision for a
/// waiting entry, a correction for an approved bonus, advance or loan, and the
/// day's allowances for an allowance.
void openPayrollRow(
  BuildContext context,
  WidgetRef ref,
  PayrollHistoryRow row,
) {
  final entry = row.entry;
  if (row.kind == PayrollKind.salary) {
    final statementId = row.statementId;
    if (statementId == null || row.workerId == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PayrollPayslipScreen(
          workerId: row.workerId!,
          statementId: statementId,
        ),
      ),
    );
    return;
  }
  if (row.kind == PayrollKind.allowance) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PayrollAllowancesScreen()),
    );
    return;
  }
  if (entry == null) return;
  if (row.isWaiting) {
    final isApprover = ref.read(payrollIsApproverProvider);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(sheet.getRSize(16)),
          child: PayrollEntryTile(
            entry: entry,
            canDecide: isApprover,
            workerName: row.workerName,
          ),
        ),
      ),
    );
    return;
  }
  showPayrollCorrection(context, entry: entry, currentKobo: row.amountKobo);
}

/// The month's salary: the lines, then the amount to pay or that was paid.
/// [actions] sit under it on a phone; a tablet has them in the header.
class PayrollSalaryCard extends StatelessWidget {
  const PayrollSalaryCard({super.key, required this.row, this.actions = false});

  final PayrollWorkerMonth row;
  final bool actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final month = payrollMonthName(row.month);
    final worker = row.worker;
    final salary = row.statement?.salaryKobo ?? row.figures.salaryKobo;
    final repayment = row.repaymentKobo;
    final part = row.loan.partNumber(row.repaidAfterMonthKobo);
    return PayrollCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('$month salary', style: context.boldStyle(18)),
              ),
              PayrollStatusPill(paid: row.isPaid),
            ],
          ),
          SizedBox(height: context.getRSize(8)),
          PayrollLine(label: 'Monthly salary', value: _money(salary)),
          for (final a in row.advances)
            PayrollLine(
              label: 'Advance taken ${payrollShortDay(a.entryDate)}',
              value: '-${_money(a.amountKobo)}',
            ),
          if (repayment > 0)
            PayrollLine(
              label: row.loan.hasPlan
                  ? 'Loan repayment, part $part of ${row.loan.totalParts}'
                  : 'Loan repayment',
              value: '-${_money(repayment)}',
            ),
          SizedBox(height: context.getRSize(8)),
          const PayrollDashedRule(),
          SizedBox(height: context.getRSize(12)),
          Row(
            children: [
              Expanded(
                child: Text(
                  row.isPaid
                      ? 'Paid on ${payrollShortDay(row.paidOn ?? '')}'
                      : 'To pay on '
                            '${payrollShortDay(payrollPaydayIn(worker, row.month))}',
                  style: context.boldStyle(16),
                ),
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _money(row.cashKobo),
                    style: context
                        .boldStyle(28)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                ),
              ),
            ],
          ),
          if (actions) ...[
            SizedBox(height: context.getRSize(16)),
            PayrollWorkerActions(row: row),
          ],
        ],
      ),
    );
  }
}

/// Pay Salary (or View Payslip once paid) and Add Bonus, Advance or Loan.
class PayrollWorkerActions extends StatelessWidget {
  const PayrollWorkerActions({
    super.key,
    required this.row,
    this.vertical = true,
  });

  final PayrollWorkerMonth row;

  /// Stacked on a phone; side by side, secondary first, on a tablet.
  final bool vertical;

  void _primary(BuildContext context) {
    final statement = row.statement;
    if (statement == null) {
      openPaySalary(context, row.worker.id, row.month);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PayrollPayslipScreen(
          workerId: row.worker.id,
          statementId: statement.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pay = AppButton(
      key: const ValueKey('payroll-pay-salary'),
      text: row.isPaid ? 'View Payslip' : 'Pay Salary',
      isFullWidth: vertical,
      onPressed: () => _primary(context),
    );
    final add = AppButton(
      key: const ValueKey('payroll-add-money'),
      text: 'Add Bonus, Advance or Loan',
      variant: AppButtonVariant.secondary,
      isFullWidth: vertical,
      onPressed: () => openAddPayRecord(context, workerId: row.worker.id),
    );
    if (vertical) {
      return Column(
        children: [
          pay,
          SizedBox(height: context.getRSize(10)),
          add,
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        add,
        SizedBox(width: context.getRSize(12)),
        pay,
      ],
    );
  }
}

/// Paid on the day this month: allowances and bonuses, on top of salary.
class PayrollOnTheDayCard extends StatelessWidget {
  const PayrollOnTheDayCard({
    super.key,
    required this.row,
    this.tablet = false,
  });

  final PayrollWorkerMonth row;
  final bool tablet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = payrollMuted(context);
    final days = row.allowanceDays;
    final bonuses = row.bonusCount;
    Widget line(PayrollKind kind, String title, String detail, int kobo) =>
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(12)),
          child: Row(
            children: [
              if (!tablet) ...[
                PayrollKindIcon(kind: kind),
                SizedBox(width: context.getRSize(12)),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.boldStyle(15)),
                    Text(
                      detail,
                      style: context.regularStyle(13).copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              Text(_money(kobo), style: context.boldStyle(15)),
            ],
          ),
        );
    return PayrollCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tablet ? 'Paid on the day' : 'Paid on the day this month',
            style: context.boldStyle(18),
          ),
          line(
            PayrollKind.allowance,
            'Daily allowances',
            '$days ${days == 1 ? 'day' : 'days'} worked',
            row.figures.allowancesKobo,
          ),
          line(
            PayrollKind.bonus,
            'Bonuses',
            '$bonuses ${bonuses == 1 ? 'bonus' : 'bonuses'}',
            row.figures.bonusesKobo,
          ),
          if (tablet) ...[
            SizedBox(height: context.getRSize(12)),
            Divider(color: t.dividerColor, height: 1),
            SizedBox(height: context.getRSize(12)),
            Text(
              'Received so far in ${payrollMonthName(row.month)}, salary not '
              'included: ${_money(row.receivedOnTheDayKobo + row.advancesKobo)}.',
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// The worker's loan. Null-safe for no loan: [showEmpty] keeps the card (the
/// tablet's three-across row) with a short message.
class PayrollLoanCard extends StatelessWidget {
  const PayrollLoanCard({super.key, required this.row, this.showEmpty = false});

  final PayrollWorkerMonth row;
  final bool showEmpty;

  @override
  Widget build(BuildContext context) {
    final loan = row.loan;
    if (!loan.hasLoan && !showEmpty) return const SizedBox.shrink();
    final muted = payrollMuted(context);
    final small = context.regularStyle(13).copyWith(color: muted);
    final owedAfter = row.owedAfterMonthKobo;
    final lastMonth = loan.lastRepaymentMonth(row.month, owedAfter);
    return PayrollCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Loan', style: context.boldStyle(18))),
              if (loan.takenOn != null && loan.hasLoan)
                Text('Taken ${payrollMediumDay(loan.takenOn!)}', style: small),
            ],
          ),
          if (!loan.hasLoan) ...[
            SizedBox(height: context.getRSize(12)),
            Text('No loan to pay back.', style: small),
          ] else ...[
            SizedBox(height: context.getRSize(12)),
            Row(
              children: [
                Expanded(
                  child: Text('Still owed after this month', style: small),
                ),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _money(owedAfter),
                      style: context.boldStyle(24),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),
            PayrollProgressBar(
              value: loan.lentKobo == 0
                  ? 0
                  : row.repaidAfterMonthKobo / loan.lentKobo,
            ),
            SizedBox(height: context.getRSize(10)),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_money(row.repaidAfterMonthKobo)} of '
                    '${_money(loan.lentKobo)} paid back',
                    style: small,
                  ),
                ),
                if (loan.hasPlan)
                  Text('${_money(loan.monthlyKobo!)} a month', style: small),
              ],
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              lastMonth == null
                  ? 'Paid back as agreed. Choose the amount on each payday.'
                  : 'Last repayment in ${payrollMonthLabel(lastMonth)}.',
              style: small,
            ),
          ],
        ],
      ),
    );
  }
}

/// "Daily allowance" + "Cash", "Offloading bonus" + "Heineken truck, cash".
String payrollRowSubtitle(PayrollHistoryRow r) {
  final method = payrollPaymentMethodLabel(r.method);
  final detail = r.details;
  if (detail == null || detail.isEmpty || r.kind == PayrollKind.allowance) {
    return method;
  }
  return '$detail, ${method.toLowerCase()}';
}

String payrollRowAmount(PayrollHistoryRow r) =>
    r.isMoneyIn ? '+${_money(r.amountKobo)}' : _money(r.amountKobo);

/// One line of the phone's Recent payments: a date tile, what it was and how
/// much.
class PayrollPaymentTile extends ConsumerWidget {
  const PayrollPaymentTile({super.key, required this.row});

  final PayrollHistoryRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = payrollMuted(context);
    final d = payrollDay(row.date);
    return PayrollCard(
      padding: 12,
      onTap: () => openPayrollRow(context, ref, row),
      child: Row(
        children: [
          SizedBox(
            width: context.getRSize(52),
            child: Column(
              children: [
                Text('${d?.day ?? ''}', style: context.boldStyle(20)),
                Text(
                  payrollShortDay(row.date).split(' ').last,
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.title, style: context.boldStyle(15)),
                Text(
                  row.isWaiting
                      ? 'Waiting for CEO approval'
                      : payrollRowSubtitle(row),
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
              ],
            ),
          ),
          Text(payrollRowAmount(row), style: context.boldStyle(15)),
        ],
      ),
    );
  }
}

/// A worker's whole History, every month, for the worker pages.
List<PayrollHistoryRow> payrollWorkerHistory(
  WidgetRef ref,
  PayrollWorkerData worker,
) => payrollHistoryRows(
  workers: [worker],
  entries:
      ref.watch(payrollWorkerEntriesProvider(worker.id)).valueOrNull ??
      const [],
  statements:
      ref.watch(payrollWorkerStatementsProvider(worker.id)).valueOrNull ??
      const [],
  workerId: worker.id,
);

/// The body guard shared by the worker pages.
bool payrollAllowed(WidgetRef ref) => Gates.managePayroll.allows(ref);

/// The worker's month, read live.
PayrollWorkerMonth? payrollWorkerMonth(
  WidgetRef ref,
  String workerId,
  String month,
) {
  final workers = ref.watch(payrollWorkersProvider).valueOrNull ?? const [];
  final worker = workers.where((w) => w.id == workerId).firstOrNull;
  if (worker == null) return null;
  return PayrollWorkerMonth.from(
    worker: worker,
    entries:
        ref.watch(payrollWorkerEntriesProvider(workerId)).valueOrNull ??
        const [],
    month: month,
    statement:
        (ref.watch(payrollMonthStatementsProvider(month)).valueOrNull ??
                const <PayrollStatementData>[])
            .where((s) => s.workerId == workerId)
            .firstOrNull,
  );
}

/// The worker's display name.
String payrollName(PayrollWorkerData w) => toNameCase(w.name);
