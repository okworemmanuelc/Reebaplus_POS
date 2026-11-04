import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_payslip_screen.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/signature_pad.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Keys for tests.
class PaySalaryKeys {
  static const amountField = Key('pay-salary-amount');
  static const reasonField = Key('pay-salary-reason');
  static const dateField = Key('pay-salary-date');
  static const noteField = Key('pay-salary-note');
  static const salaryDue = Key('pay-salary-due');
  static const confirm = Key('pay-salary-confirm');
  static const printAfter = Key('pay-salary-print-after');
  static const saveSigned = Key('pay-salary-save-signed');
  static const repaymentField = Key('pay-salary-repayment');
}

/// Pay Salary (#723, from the owner's mockup): the month's statement, the
/// amount, the date actually paid and how. One payment settles the month; the
/// worker and the payer sign before anything is saved.
class PayrollPaySalaryScreen extends ConsumerStatefulWidget {
  const PayrollPaySalaryScreen({
    super.key,
    required this.workerId,
    required this.month,
  });

  final String workerId;

  /// 'YYYY-MM'.
  final String month;

  @override
  ConsumerState<PayrollPaySalaryScreen> createState() =>
      _PayrollPaySalaryScreenState();
}

class _PayrollPaySalaryScreenState
    extends ConsumerState<PayrollPaySalaryScreen> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  final _note = TextEditingController();
  late DateTime _date = _defaultDate();
  String _method = 'cash';
  bool _printAfter = false;
  bool _seeded = false;

  /// The repayment chosen on the day. Null = the loan plan's.
  int? _repaymentKobo;

  /// Today, or the month's last day when paying a month already over.
  DateTime _defaultDate() {
    final now = DateTime.now();
    final parts = widget.month.split('-');
    final monthEnd = DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
    return monthEnd.isBefore(now) ? monthEnd : now;
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    _note.dispose();
    super.dispose();
  }

  int _kobo(TextEditingController c) =>
      (parseCurrency(c.text.trim()) * 100).round();

  PaydayFigures _figures(
    PayrollWorkerData worker,
    List<PayrollEntryData> entries,
    PayrollWorkerMonth row,
  ) {
    final repayment = _repaymentKobo ?? row.figures.loanRepaymentKobo;
    // The cash typed + what was already taken out = the month's salary.
    final salary = _seeded
        ? _kobo(_amount) + row.figures.advancesKobo + repayment
        : row.figures.salaryKobo;
    return PaydayFigures.from(
      worker: worker,
      entries: entries,
      salaryMonth: widget.month,
      salaryKobo: salary,
      loanRepaymentKobo: repayment,
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Future<void> _editRepayment(PaydayFigures f) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) => _RepaymentDialog(
        currentKobo: f.loanRepaymentKobo,
        maxKobo: f.maxRepaymentKobo,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final oldRepayment = f.loanRepaymentKobo;
      _repaymentKobo = picked;
      // Keeps the salary as it was: the cash moves by the difference.
      final cash = math.max(_kobo(_amount) + oldRepayment - picked, 0);
      _amount.text = koboToInputText(cash);
    });
  }

  Future<void> _confirm(PayrollWorkerData worker, PaydayFigures f) async {
    // Advances may have used up the whole salary; the month still settles.
    if (f.salaryKobo <= 0) {
      AppNotification.showError(context, 'Enter the amount you are paying.');
      return;
    }
    if (f.salaryChanged && _reason.text.trim().isEmpty) {
      AppNotification.showError(
        context,
        'Give a reason for paying a different amount this month.',
      );
      return;
    }
    final signatures = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      builder: (_) => _SignatureSheet(workerName: toNameCase(worker.name)),
    );
    if (signatures == null || !mounted) return;
    try {
      final statement = await ref
          .read(databaseProvider)
          .payrollDao
          .paySalary(
            workerId: worker.id,
            salaryMonth: widget.month,
            salaryKobo: f.salaryKobo,
            reason: _reason.text,
            loanRepaymentKobo: f.loanRepaymentKobo,
            paymentMethod: _method,
            paydayDate: payrollDayKey(_date),
            note: _note.text,
            workerSignaturePng: signatures.$1,
            payerSignaturePng: signatures.$2,
          );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Salary paid.');
      if (_printAfter) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => PayrollPayslipScreen(
              workerId: worker.id,
              statementId: statement.id,
              autoPrint: true,
            ),
          ),
        );
      } else {
        Navigator.of(context).pop();
      }
    } on PayrollRuleViolation catch (e) {
      if (mounted) AppNotification.showError(context, e.message);
    } catch (_) {
      if (mounted) {
        AppNotification.showError(context, 'Could not save. Please try again.');
      }
    }
  }

  PreferredSizeWidget _topBar(BuildContext context, String subtitle) =>
      PayrollTopBar(
        height: payrollTopBarHeight(context),
        child: PayrollFormHeader(
          title: 'Pay Salary',
          subtitle: subtitle,
          icon: AppIcons.arrowBack,
        ),
      );

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final monthLabel = payrollMonthLabel(widget.month);
    Widget page(String subtitle, Widget body, {Widget? bottom}) => DecoratedBox(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _topBar(context, subtitle),
        body: body,
        bottomNavigationBar: bottom,
      ),
    );

    if (!Gates.managePayroll.allows(ref)) {
      return page(
        monthLabel,
        const Center(child: Text('You no longer have access to Payroll.')),
      );
    }
    final worker = (ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        .where((w) => w.id == widget.workerId)
        .firstOrNull;
    if (worker == null) {
      return page(monthLabel, const Center(child: CircularProgressIndicator()));
    }
    final name = toNameCase(worker.name);
    final subtitle = '$name, $monthLabel';
    final entriesAsync = ref.watch(payrollWorkerEntriesProvider(worker.id));
    final statementsAsync = ref.watch(
      payrollMonthStatementsProvider(widget.month),
    );
    // The amount is filled in once, so wait for the advances and loans: an
    // early fill would show the full salary and read as a changed salary.
    if (!entriesAsync.hasValue || !statementsAsync.hasValue) {
      return page(subtitle, const Center(child: CircularProgressIndicator()));
    }
    final entries = entriesAsync.value ?? const <PayrollEntryData>[];
    final statement = (statementsAsync.value ?? const <PayrollStatementData>[])
        .where((s) => s.workerId == worker.id)
        .firstOrNull;
    final row = PayrollWorkerMonth.from(
      worker: worker,
      entries: entries,
      month: widget.month,
      statement: statement,
    );
    if (row.isPaid) {
      return page(
        subtitle,
        Center(
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(24)),
            child: Text(
              '$name has already been paid for $monthLabel.',
              textAlign: TextAlign.center,
              style: context.semiBoldStyle(16),
            ),
          ),
        ),
      );
    }
    if (!_seeded) {
      _seeded = true;
      _amount.text = koboToInputText(row.cashKobo);
    }
    final f = _figures(worker, entries, row);
    final firstName = name.split(' ').first;
    final due = row.figures.salaryKobo - f.advancesKobo - f.loanRepaymentKobo;
    final muted = payrollMuted(context);
    final t = Theme.of(context);
    final gap = SizedBox(height: context.getRSize(16));
    final amountText = formatCurrency(f.cashPaidKobo / 100);
    final partLabel = row.loan.hasPlan
        ? 'Loan repayment, part '
              '${row.loan.partNumber(row.loan.repaidKobo + f.loanRepaymentKobo)}'
              ' of ${row.loan.totalParts}'
        : 'Loan repayment';

    return page(
      subtitle,
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kPayrollColumnMaxWidth),
          child: ListView(
            padding: EdgeInsets.all(context.getRSize(16)),
            children: [
              PayrollCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PayrollLine(
                      label: 'Monthly salary',
                      value: formatCurrency(worker.monthlySalaryKobo / 100),
                    ),
                    for (final a in row.advances)
                      PayrollLine(
                        label: 'Advance, ${payrollShortDay(a.entryDate)}',
                        value: '-${formatCurrency(a.amountKobo / 100)}',
                      ),
                    if (row.loan.hasLoan)
                      PayrollLine(
                        key: PaySalaryKeys.repaymentField,
                        label: partLabel,
                        value: '-${formatCurrency(f.loanRepaymentKobo / 100)}',
                        onTap: () => _editRepayment(f),
                      ),
                    SizedBox(height: context.getRSize(8)),
                    const PayrollDashedRule(),
                    SizedBox(height: context.getRSize(12)),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Salary due',
                            style: context.boldStyle(16),
                          ),
                        ),
                        Text(
                          formatCurrency(due / 100),
                          key: PaySalaryKeys.salaryDue,
                          style: context
                              .boldStyle(28)
                              .copyWith(color: t.colorScheme.primary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              gap,
              const PayrollFieldLabel('Amount paying now'),
              AppInput(
                key: PaySalaryKeys.amountField,
                controller: _amount,
                prefixText: '$activeCurrencySymbol ',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
                style: context.boldStyle(22),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: context.getRSize(6)),
              Text(
                'One payment settles the month. Money before payday is an '
                'advance.',
                style: context.regularStyle(13).copyWith(color: muted),
              ),
              if (f.salaryChanged) ...[
                gap,
                AppInput(
                  key: PaySalaryKeys.reasonField,
                  controller: _reason,
                  labelText: 'Why is it different this month?',
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
              gap,
              const PayrollFieldLabel('Payment date'),
              PayrollPickerField(
                key: PaySalaryKeys.dateField,
                value: DateFormat('EEEE d MMM y').format(_date),
                onTap: _pickDate,
              ),
              SizedBox(height: context.getRSize(6)),
              Text(
                'Usual payday is ${payrollPaydayPhrase(worker)}. Pick any '
                'date you actually paid.',
                style: context.regularStyle(13).copyWith(color: muted),
              ),
              gap,
              const PayrollFieldLabel('Paid by'),
              PayrollMethodChips(
                value: _method,
                onChanged: (m) => setState(() => _method = m),
              ),
              gap,
              const PayrollFieldLabel('Note (optional)'),
              AppInput(
                key: PaySalaryKeys.noteField,
                controller: _note,
                hintText: 'For example, transfer reference',
                textCapitalization: TextCapitalization.sentences,
              ),
              gap,
              PayrollCard(
                padding: 14,
                child: Row(
                  children: [
                    Container(
                      width: context.getRSize(36),
                      height: context.getRSize(36),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            t.inputDecorationTheme.fillColor ?? t.dividerColor,
                      ),
                      child: Icon(
                        AppIcons.check,
                        size: context.getRSize(20),
                        color: t.colorScheme.primary,
                      ),
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Text(
                        'After this, nothing is left to pay $firstName for '
                        '${payrollMonthName(widget.month)}.',
                        style: context.regularStyle(15),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottom: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kPayrollColumnMaxWidth),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(16),
                context.getRSize(8),
                context.getRSize(16),
                context.getRSize(4),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppButton(
                    key: PaySalaryKeys.confirm,
                    text: 'Confirm Payment of $amountText',
                    onAsyncPressed: () => _confirm(worker, f),
                  ),
                  TextButton.icon(
                    key: PaySalaryKeys.printAfter,
                    onPressed: () => setState(() => _printAfter = !_printAfter),
                    icon: Icon(
                      _printAfter ? AppIcons.check : AppIcons.print,
                      size: context.getRSize(18),
                    ),
                    label: Text(
                      'Print Payslip After Saving',
                      style: context.boldStyle(15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Changes this payday's loan repayment.
class _RepaymentDialog extends StatefulWidget {
  const _RepaymentDialog({required this.currentKobo, required this.maxKobo});

  final int currentKobo;
  final int maxKobo;

  @override
  State<_RepaymentDialog> createState() => _RepaymentDialogState();
}

class _RepaymentDialogState extends State<_RepaymentDialog> {
  late final _amount = TextEditingController(
    text: koboToInputText(widget.currentKobo),
  );

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _save() {
    final kobo = (parseCurrency(_amount.text.trim()) * 100).round();
    if (kobo < 0 || kobo > widget.maxKobo) {
      AppNotification.showError(
        context,
        'The most you can take this payday is '
        '${formatCurrency(widget.maxKobo / 100)}.',
      );
      return;
    }
    Navigator.pop(context, kobo);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Loan repayment this payday'),
    content: AppInput(
      controller: _amount,
      labelText: 'Amount',
      prefixText: '$activeCurrencySymbol ',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [CurrencyInputFormatter()],
    ),
    actions: [
      AppButton(
        text: 'Cancel',
        variant: AppButtonVariant.ghost,
        size: AppButtonSize.small,
        isFullWidth: false,
        onPressed: () => Navigator.pop(context),
      ),
      AppButton(
        text: 'Save',
        size: AppButtonSize.small,
        isFullWidth: false,
        onPressed: _save,
      ),
    ],
  );
}

/// The two signatures, taken after Confirm Payment. Pops (worker, payer) as
/// base64 PNGs; nothing is saved until both have signed.
class _SignatureSheet extends StatefulWidget {
  const _SignatureSheet({required this.workerName});

  final String workerName;

  @override
  State<_SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<_SignatureSheet> {
  final _worker = SignaturePadController();
  final _payer = SignaturePadController();

  @override
  void dispose() {
    _worker.dispose();
    _payer.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_worker.isEmpty || _payer.isEmpty) {
      AppNotification.showError(
        context,
        'Both the worker and the payer must sign before saving.',
      );
      return;
    }
    final workerPng = await _worker.toPngBase64();
    final payerPng = await _payer.toPngBase64();
    if (!mounted || workerPng == null || payerPng == null) return;
    Navigator.pop(context, (workerPng, payerPng));
  }

  @override
  Widget build(BuildContext context) {
    final pad = context.getRSize(16);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sign to confirm', style: context.boldStyle(18)),
            SizedBox(height: context.getRSize(12)),
            SignaturePad(
              controller: _worker,
              label: '${widget.workerName} signs',
            ),
            SizedBox(height: context.getRSize(12)),
            SignaturePad(controller: _payer, label: 'Payer signs'),
            SizedBox(height: pad),
            AppButton(
              key: PaySalaryKeys.saveSigned,
              text: 'Save Payment',
              onAsyncPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}
