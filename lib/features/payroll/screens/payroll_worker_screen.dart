import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_history_view.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_dialog.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_parts.dart';

/// A worker's Pay Profile on a phone (#723, from the owner's mockup): their
/// pay at a glance, the month's salary, what they got on the day, their loan
/// and recent payments. A tablet shows the same cards beside the staff list.
class PayrollWorkerScreen extends ConsumerWidget {
  const PayrollWorkerScreen({
    super.key,
    required this.workerId,
    required this.month,
  });

  final String workerId;

  /// 'YYYY-MM'.
  final String month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currencySymbolProvider);
    final row = payrollWorkerMonth(ref, workerId, month);
    final worker = row?.worker;
    return DecoratedBox(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: PayrollTopBar(
          height: payrollTopBarHeight(context),
          child: PayrollFormHeader(
            title: worker == null ? 'Payroll' : payrollName(worker),
            subtitle: 'Pay profile',
            icon: AppIcons.arrowBack,
            trailing: worker == null || worker.isRemoved
                ? null
                : IconButton(
                    key: PayrollKeys.editWorker,
                    tooltip: 'Edit',
                    icon: Icon(AppIcons.edit, size: context.getRSize(24)),
                    onPressed: () => openWorkerForm(context, worker: worker),
                  ),
          ),
        ),
        body: !payrollAllowed(ref)
            ? const Center(child: Text('You no longer have access to Payroll.'))
            : row == null
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kPayrollColumnMaxWidth,
                  ),
                  child: _Profile(row: row),
                ),
              ),
      ),
    );
  }
}

class _Profile extends ConsumerWidget {
  const _Profile({required this.row});

  final PayrollWorkerMonth row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worker = row.worker;
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final store =
        stores.where((s) => s.id == worker.storeId).firstOrNull?.name ?? '';
    final since = DateFormat('MMMM y').format(worker.createdAt);
    final gap = SizedBox(height: context.getRSize(14));
    final recent = payrollWorkerHistory(ref, worker).take(5).toList();
    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16) + context.deviceBottomPadding,
      ),
      children: [
        PayrollCard(
          child: Column(
            children: [
              Row(
                children: [
                  PayrollAvatar(name: worker.name, size: 64, strong: true),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(payrollName(worker), style: context.boldStyle(20)),
                        Text(
                          '${payrollWorkerRole(worker, store)}, on payroll '
                          'since $since',
                          style: context
                              .regularStyle(14)
                              .copyWith(color: payrollMuted(context)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.getRSize(14)),
              Row(
                children: [
                  _Fact(
                    label: 'Salary',
                    value: formatCurrency(worker.monthlySalaryKobo / 100),
                    unit: 'monthly',
                  ),
                  SizedBox(width: context.getRSize(8)),
                  _Fact(
                    label: 'Allowance',
                    value: formatCurrency(worker.dailyAllowanceKobo / 100),
                    unit: 'per day',
                  ),
                  SizedBox(width: context.getRSize(8)),
                  _Fact(
                    label: 'Payday',
                    value: worker.paydayDay == null
                        ? 'Last day'
                        : payrollOrdinal(worker.paydayDay!),
                    unit: 'each month',
                  ),
                ],
              ),
            ],
          ),
        ),
        gap,
        PayrollSalaryCard(row: row, actions: true),
        gap,
        PayrollOnTheDayCard(row: row),
        if (row.loan.hasLoan) ...[gap, PayrollLoanCard(row: row)],
        gap,
        Row(
          children: [
            Expanded(
              child: Text('Recent payments', style: context.boldStyle(18)),
            ),
            TextButton(
              key: const ValueKey('payroll-see-all'),
              onPressed: () => openWorkerHistory(context, worker),
              child: Text('See all', style: context.boldStyle(15)),
            ),
          ],
        ),
        if (recent.isEmpty)
          Text(
            'No payments yet.',
            style: context
                .regularStyle(14)
                .copyWith(color: payrollMuted(context)),
          ),
        for (final r in recent)
          Padding(
            padding: EdgeInsets.only(bottom: context.getRSize(10)),
            child: PayrollPaymentTile(row: r),
          ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = payrollMuted(context);
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(context.getRSize(10)),
        decoration: BoxDecoration(
          color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: context.regularStyle(12).copyWith(color: muted)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: context.boldStyle(15)),
            ),
            Text(unit, style: context.regularStyle(12).copyWith(color: muted)),
          ],
        ),
      ),
    );
  }
}
