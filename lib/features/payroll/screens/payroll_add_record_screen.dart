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
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Keys for tests.
class AddPayRecordKeys {
  static const staffField = Key('add-pay-record-staff');
  static const amountField = Key('add-pay-record-amount');
  static const planField = Key('add-pay-record-plan');
  static const noteField = Key('add-pay-record-note');
  static const dateField = Key('add-pay-record-date');
  static const saveButton = Key('add-pay-record-save');
  static Key type(PayRecordType t) => Key('add-pay-record-type-${t.name}');
  static Key staffOption(String id) => Key('add-pay-record-staff-$id');
}

enum PayRecordType { allowance, bonus, advance, loan }

const _kTypeLabels = {
  PayRecordType.allowance: 'Allowance',
  PayRecordType.bonus: 'Bonus',
  PayRecordType.advance: 'Advance',
  PayRecordType.loan: 'Loan',
};

const _kLoanNew = 'New loan';
const _kLoanBack = 'Paid back';
const _kOther = 'Other';

/// Add Pay Record (#723, from the owner's mockup): one place to record an
/// allowance, bonus, advance or loan for a worker. Dated today unless another
/// day is picked; never a future one. "Allowance" sets one worker's Daily
/// Allowance for that day (the run itself stays automatic).
class PayrollAddRecordScreen extends ConsumerStatefulWidget {
  const PayrollAddRecordScreen({super.key, this.workerId});

  /// Chosen up front when opened from a worker.
  final String? workerId;

  @override
  ConsumerState<PayrollAddRecordScreen> createState() =>
      _PayrollAddRecordScreenState();
}

class _PayrollAddRecordScreenState
    extends ConsumerState<PayrollAddRecordScreen> {
  final _amount = TextEditingController();
  final _plan = TextEditingController();
  final _note = TextEditingController();
  late String? _workerId = widget.workerId;
  PayRecordType _type = PayRecordType.bonus;
  String _bonusReason = kPayrollBonusReasons.first;
  String _loanAction = _kLoanNew;
  String _method = 'cash';
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _plan.dispose();
    _note.dispose();
    super.dispose();
  }

  int _kobo(TextEditingController c) =>
      (parseCurrency(c.text.trim()) * 100).round();

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Future<void> _pickStaff(List<PayrollWorkerData> workers) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: context.sheetMaxHeight(0.7)),
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.all(context.getRSize(8)),
          children: [
            for (final w in workers)
              ListTile(
                key: AddPayRecordKeys.staffOption(w.id),
                leading: PayrollAvatar(name: w.name, size: 40),
                title: Text(toNameCase(w.name)),
                onTap: () => Navigator.pop(sheet, w.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _workerId = picked);
  }

  void _chooseType(PayRecordType type, PayrollWorkerData? worker) {
    setState(() {
      _type = type;
      if (type == PayRecordType.allowance && worker != null) {
        _amount.text = koboToInputText(worker.dailyAllowanceKobo);
      }
    });
  }

  Future<void> _save(PayrollWorkerData? worker) async {
    if (worker == null) {
      AppNotification.showError(context, 'Choose a staff member.');
      return;
    }
    final amount = _kobo(_amount);
    final isAllowance = _type == PayRecordType.allowance;
    if (amount <= 0 && !isAllowance) {
      AppNotification.showError(context, 'Enter an amount.');
      return;
    }
    final isNewLoan = _type == PayRecordType.loan && _loanAction == _kLoanNew;
    final plan = _kobo(_plan);
    if (isNewLoan && plan <= 0) {
      AppNotification.showError(context, 'Enter how much to pay back a month.');
      return;
    }
    final dao = ref.read(databaseProvider).payrollDao;
    final day = payrollDayKey(_date);
    try {
      if (isAllowance) {
        await dao.setAllowanceForDay(
          workerId: worker.id,
          entryDate: day,
          amountKobo: amount,
        );
        if (!mounted) return;
        Navigator.pop(context);
        return;
      }
      final saved = await dao.recordMoneyEntry(
        workerId: worker.id,
        type: switch (_type) {
          PayRecordType.bonus => 'bonus',
          PayRecordType.advance => 'advance',
          _ => isNewLoan ? 'loan_given' : 'loan_repaid',
        },
        amountKobo: amount,
        paymentMethod: _method,
        salaryMonth: _type == PayRecordType.advance
            ? day.substring(0, 7)
            : null,
        note: _type == PayRecordType.bonus
            ? payrollBonusNote(
                _bonusReason == _kOther ? null : _bonusReason,
                _note.text,
              )
            : _note.text,
        entryDate: day,
        monthlyRepaymentKobo: isNewLoan ? plan : null,
      );
      if (!mounted) return;
      Navigator.pop(context);
      if (saved.status == 'pending') {
        AppNotification.showInfo(
          context,
          'This is above your limit, so it is waiting for CEO approval.',
        );
      }
    } on PayrollRuleViolation catch (e) {
      if (mounted) AppNotification.showError(context, e.message);
    } on ArgumentError {
      if (mounted) {
        AppNotification.showError(
          context,
          'No allowance is due for ${toNameCase(worker.name)} on that day.',
        );
      }
    } catch (_) {
      if (mounted) {
        AppNotification.showError(context, 'Could not save. Please try again.');
      }
    }
  }

  String get _saveLabel => switch (_type) {
    PayRecordType.allowance => 'Save Allowance',
    PayRecordType.bonus => 'Save Bonus',
    PayRecordType.advance => 'Save Advance',
    PayRecordType.loan =>
      _loanAction == _kLoanNew ? 'Save Loan' : 'Save Repayment',
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final topBar = PayrollTopBar(
      height: payrollTopBarHeight(context),
      child: const PayrollFormHeader(
        title: 'Add Pay Record',
        subtitle: 'Allowance, bonus, advance or loan',
        icon: AppIcons.close,
      ),
    );
    Widget page(Widget body, {Widget? bottom}) => DecoratedBox(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: topBar,
        body: body,
        bottomNavigationBar: bottom,
      ),
    );
    if (!Gates.managePayroll.allows(ref)) {
      return page(
        const Center(child: Text('You no longer have access to Payroll.')),
      );
    }

    final workers = (ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        .where((w) => !w.isRemoved)
        .toList();
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final worker = workers.where((w) => w.id == _workerId).firstOrNull;
    final storeName =
        stores.where((s) => s.id == worker?.storeId).firstOrNull?.name ?? '';
    final gap = SizedBox(height: context.getRSize(16));
    final chips = switch (_type) {
      PayRecordType.bonus => [...kPayrollBonusReasons, _kOther],
      PayRecordType.loan => const [_kLoanNew, _kLoanBack],
      _ => const <String>[],
    };
    final chosenChip = _type == PayRecordType.bonus
        ? _bonusReason
        : _loanAction;
    final isNewLoan = _type == PayRecordType.loan && _loanAction == _kLoanNew;
    final isAllowance = _type == PayRecordType.allowance;

    return page(
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kPayrollColumnMaxWidth),
          child: ListView(
            padding: EdgeInsets.all(context.getRSize(16)),
            children: [
              const PayrollFieldLabel('Staff'),
              _StaffField(
                worker: worker,
                role: worker == null
                    ? null
                    : payrollWorkerRole(worker, storeName),
                onTap: () => _pickStaff(workers),
              ),
              gap,
              const PayrollFieldLabel('What are you recording?'),
              AppSegmented<PayRecordType>(
                value: _type,
                items: _kTypeLabels,
                solid: true,
                onChanged: (t) => _chooseType(t, worker),
                keyOf: AddPayRecordKeys.type,
              ),
              if (chips.isNotEmpty) ...[
                gap,
                PayrollFieldLabel(
                  _type == PayRecordType.bonus ? 'Reason' : 'Type of loan',
                ),
                Wrap(
                  spacing: context.getRSize(8),
                  children: [
                    for (final c in chips)
                      PayrollPillChip(
                        key: ValueKey('add-pay-record-chip-$c'),
                        label: c,
                        selected: chosenChip == c,
                        onTap: () => setState(() {
                          if (_type == PayRecordType.bonus) {
                            _bonusReason = c;
                          } else {
                            _loanAction = c;
                          }
                        }),
                      ),
                  ],
                ),
              ],
              gap,
              const PayrollFieldLabel('Date'),
              PayrollPickerField(
                key: AddPayRecordKeys.dateField,
                value: DateFormat('EEEE d MMM y').format(_date),
                onTap: _pickDate,
              ),
              gap,
              const PayrollFieldLabel('Amount'),
              AppInput(
                key: AddPayRecordKeys.amountField,
                controller: _amount,
                prefixText: '$activeCurrencySymbol ',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
                style: context.boldStyle(18),
              ),
              if (isAllowance) ...[
                SizedBox(height: context.getRSize(6)),
                Text(
                  'Changes this worker\'s allowance for that day. Enter 0 to '
                  'cancel it.',
                  style: context
                      .regularStyle(13)
                      .copyWith(color: payrollMuted(context)),
                ),
              ],
              if (isNewLoan) ...[
                gap,
                const PayrollFieldLabel('Pay back a month'),
                AppInput(
                  key: AddPayRecordKeys.planField,
                  controller: _plan,
                  prefixText: '$activeCurrencySymbol ',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [CurrencyInputFormatter()],
                ),
              ],
              if (!isAllowance) ...[
                gap,
                const PayrollFieldLabel('Paid by'),
                PayrollMethodChips(
                  value: _method,
                  onChanged: (m) => setState(() => _method = m),
                ),
                gap,
                const PayrollFieldLabel('Note (optional)'),
                AppInput(
                  key: AddPayRecordKeys.noteField,
                  controller: _note,
                  hintText: _type == PayRecordType.bonus
                      ? 'For example, Heineken truck'
                      : null,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
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
              padding: EdgeInsets.all(context.getRSize(16)),
              child: AppButton(
                key: AddPayRecordKeys.saveButton,
                text: _saveLabel,
                onAsyncPressed: () => _save(worker),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StaffField extends StatelessWidget {
  const _StaffField({
    required this.worker,
    required this.role,
    required this.onTap,
  });

  final PayrollWorkerData? worker;
  final String? role;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final w = worker;
    return Material(
      color: t.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.dividerColor),
      ),
      child: InkWell(
        key: AddPayRecordKeys.staffField,
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(12)),
          child: Row(
            children: [
              if (w != null) ...[
                PayrollAvatar(name: w.name, size: 44),
                SizedBox(width: context.getRSize(12)),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w == null ? 'Choose staff' : toNameCase(w.name),
                      style: context.boldStyle(16),
                    ),
                    if (role != null && role!.isNotEmpty)
                      Text(
                        role!,
                        style: context
                            .regularStyle(14)
                            .copyWith(color: payrollMuted(context)),
                      ),
                  ],
                ),
              ),
              Icon(
                AppIcons.chevronDown,
                size: context.getRSize(24),
                color: payrollMuted(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
