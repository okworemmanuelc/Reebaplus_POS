import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_payslip_screen.dart';
import 'package:reebaplus_pos/features/payroll/widgets/signature_pad.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Keys for tests.
class PaydayKeys {
  static const monthField = Key('payday-month');
  static const dateField = Key('payday-date');
  static const salaryField = Key('payday-salary');
  static const reasonField = Key('payday-reason');
  static const repaymentField = Key('payday-repayment');
  static const cashPaid = Key('payday-cash-paid');
  static const totalPay = Key('payday-total-pay');
  static const saveButton = Key('payday-save');
  static Key open(String workerId) => Key('payroll-open-payday-$workerId');
}

/// Pay one worker's salary for a Salary Month (#671): the figures, the
/// different-amount reason, the loan repayment, how it was paid, the payday
/// date, and both signatures. Nothing saves until both people have signed.
class PayrollPaydayScreen extends ConsumerStatefulWidget {
  const PayrollPaydayScreen({super.key, required this.workerId});

  final String workerId;

  @override
  ConsumerState<PayrollPaydayScreen> createState() =>
      _PayrollPaydayScreenState();
}

class _PayrollPaydayScreenState extends ConsumerState<PayrollPaydayScreen> {
  final _salary = TextEditingController();
  final _reason = TextEditingController();
  final _repayment = TextEditingController(text: '0');
  final _workerSig = SignaturePadController();
  final _payerSig = SignaturePadController();
  DateTime _payday = DateTime.now();
  String? _month;
  String _method = 'cash';
  bool _salarySeeded = false;

  @override
  void dispose() {
    _salary.dispose();
    _reason.dispose();
    _repayment.dispose();
    _workerSig.dispose();
    _payerSig.dispose();
    super.dispose();
  }

  int _kobo(TextEditingController c) =>
      (parseCurrency(c.text.trim()) * 100).round();

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _payday,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _payday = picked;
      final months = payrollPayableMonths(picked);
      if (_month != null && !months.contains(_month)) _month = null;
    });
  }

  Future<void> _save(PayrollWorkerData worker, PaydayFigures f) async {
    if (f.salaryChanged && _reason.text.trim().isEmpty) {
      AppNotification.showError(
        context,
        'Give a reason for paying a different amount this month.',
      );
      return;
    }
    if (_workerSig.isEmpty || _payerSig.isEmpty) {
      AppNotification.showError(
        context,
        'Both the worker and the payer must sign before saving.',
      );
      return;
    }
    try {
      final workerPng = await _workerSig.toPngBase64();
      final payerPng = await _payerSig.toPngBase64();
      final statement = await ref
          .read(databaseProvider)
          .payrollDao
          .paySalary(
            workerId: worker.id,
            salaryMonth: f.salaryMonth,
            salaryKobo: f.salaryKobo,
            reason: _reason.text,
            loanRepaymentKobo: f.loanRepaymentKobo,
            paymentMethod: _method,
            paydayDate: payrollDayKey(_payday),
            workerSignaturePng: workerPng,
            payerSignaturePng: payerPng,
          );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Salary paid.');
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PayrollPayslipScreen(
            workerId: worker.id,
            statementId: statement.id,
          ),
        ),
      );
    } on PayrollRuleViolation catch (e) {
      if (mounted) AppNotification.showError(context, e.message);
    } catch (_) {
      if (mounted) {
        AppNotification.showError(context, 'Could not save. Please try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Gates.managePayroll.allows(ref)) {
      return const GlassyScaffold(
        title: 'Payroll',
        body: Center(child: Text('You no longer have access to Payroll.')),
      );
    }
    final worker = (ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        .where((w) => w.id == widget.workerId)
        .firstOrNull;
    if (worker == null) {
      return const GlassyScaffold(
        title: 'Pay salary',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_salarySeeded) {
      _salarySeeded = true;
      _salary.text = koboToInputText(worker.monthlySalaryKobo);
    }
    final entries =
        ref.watch(payrollWorkerEntriesProvider(worker.id)).valueOrNull ??
        const <PayrollEntryData>[];
    final paid = {
      for (final s
          in ref
                  .watch(payrollWorkerStatementsProvider(worker.id))
                  .valueOrNull ??
              const <PayrollStatementData>[])
        s.salaryMonth,
    };
    final months = payrollPayableMonths(
      _payday,
    ).where((m) => !paid.contains(m)).toList();
    final month = months.contains(_month)
        ? _month!
        : (months.isEmpty ? null : months.first);

    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final pad = context.getRSize(16);

    if (month == null) {
      return GlassyScaffold(
        title: 'Pay salary',
        subtitle: toNameCase(worker.name),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: const Text('Every month before this payday is paid.'),
          ),
        ),
      );
    }

    final f = PaydayFigures.from(
      worker: worker,
      entries: entries,
      salaryMonth: month,
      salaryKobo: _kobo(_salary),
      loanRepaymentKobo: _kobo(_repayment),
    );

    Widget figure(
      String label,
      int kobo, {
      Key? key,
      bool strong = false,
    }) => Padding(
      key: key,
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong ? context.boldStyle(14) : context.regularStyle(14),
            ),
          ),
          Text(
            kobo < 0
                ? '−${formatCurrency(-kobo / 100)}'
                : formatCurrency(kobo / 100),
            style: strong ? context.boldStyle(15) : context.regularStyle(14),
          ),
        ],
      ),
    );

    Widget card(List<Widget> children) => Material(
      color: t.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );

    final gap = SizedBox(height: context.getRSize(12));

    return GlassyScaffold(
      title: 'Pay salary',
      subtitle: toNameCase(worker.name),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          pad,
          pad,
          pad,
          pad + context.deviceBottomPadding,
        ),
        children: [
          AppDropdown<String>(
            key: PaydayKeys.monthField,
            value: month,
            labelText: 'Salary month (the month worked)',
            items: [
              for (final m in months)
                DropdownMenuItem(value: m, child: Text(payrollMonthLabel(m))),
            ],
            onChanged: (v) => setState(() => _month = v ?? _month),
          ),
          gap,
          InkWell(
            key: PaydayKeys.dateField,
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Payday',
                suffixIcon: Icon(Icons.calendar_today, size: 18),
              ),
              child: Text(payrollDayKey(_payday)),
            ),
          ),
          gap,
          AppInput(
            key: PaydayKeys.salaryField,
            controller: _salary,
            labelText: 'Salary for ${payrollMonthLabel(month)}',
            prefixText: '$activeCurrencySymbol ',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
            onChanged: (_) => setState(() {}),
          ),
          if (f.salaryChanged) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              'Normal salary ${formatCurrency(f.normalSalaryKobo / 100)}. '
              'It stays the same; only this month changes.',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(8)),
            AppInput(
              key: PaydayKeys.reasonField,
              controller: _reason,
              labelText: 'Reason (required)',
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
          gap,
          if (f.loanOwedKobo > 0) ...[
            AppInput(
              key: PaydayKeys.repaymentField,
              controller: _repayment,
              labelText: 'Loan repayment today',
              prefixText: '$activeCurrencySymbol ',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter()],
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              'Loan still owed ${formatCurrency(f.loanOwedKobo / 100)}. '
              'Up to ${formatCurrency(f.maxRepaymentKobo / 100)} can be '
              'taken today.',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
            gap,
          ],
          AppDropdown<String>(
            value: _method,
            labelText: 'How it was paid',
            items: [
              for (final m in kPayrollPaymentMethods)
                DropdownMenuItem(
                  value: m,
                  child: Text(payrollPaymentMethodLabel(m)),
                ),
            ],
            onChanged: (v) => setState(() => _method = v ?? _method),
          ),
          gap,
          card([
            figure('Salary', f.salaryKobo),
            if (f.advancesKobo != 0) figure('Less advances', -f.advancesKobo),
            if (f.loanRepaymentKobo != 0)
              figure('Less loan repayment', -f.loanRepaymentKobo),
            const Divider(),
            figure(
              'Paid on payday',
              f.cashPaidKobo,
              key: PaydayKeys.cashPaid,
              strong: true,
            ),
            if (f.pendingAdvancesKobo > 0) ...[
              SizedBox(height: context.getRSize(6)),
              Text(
                'An advance for ${payrollMonthLabel(month)} is waiting for '
                'CEO approval. It must be decided before payday.',
                style: context
                    .boldStyle(12)
                    .copyWith(color: t.colorScheme.error),
              ),
            ],
            if (f.cashPaidKobo < 0) ...[
              SizedBox(height: context.getRSize(6)),
              Text(
                'Deductions cannot be more than the salary.',
                style: context
                    .boldStyle(12)
                    .copyWith(color: t.colorScheme.error),
              ),
            ],
          ]),
          gap,
          card([
            figure('Salary', f.salaryKobo),
            figure('Daily allowances', f.allowancesKobo),
            figure('Bonuses', f.bonusesKobo),
            const Divider(),
            figure(
              'Total Pay for ${payrollMonthLabel(month)}',
              f.totalPayKobo,
              key: PaydayKeys.totalPay,
              strong: true,
            ),
            SizedBox(height: context.getRSize(4)),
            Text(
              'Advances are part of the salary and loans are owed back, so '
              'neither is added.',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
          ]),
          SizedBox(height: context.getRSize(20)),
          SignaturePad(
            controller: _workerSig,
            label: '${toNameCase(worker.name)} signs',
          ),
          gap,
          SignaturePad(controller: _payerSig, label: 'Payer signs'),
          SizedBox(height: context.getRSize(20)),
          AppButton(
            key: PaydayKeys.saveButton,
            text: 'Save payment',
            onAsyncPressed: () => _save(worker, f),
          ),
        ],
      ),
    );
  }
}
