import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Keys for tests.
class PayrollKeys {
  static const addButton = Key('payroll-add');
  static const addWorker = Key('payroll-add-worker');
  static const addRecord = Key('payroll-add-record');
  static const showRemoved = Key('payroll-show-removed');
  static const pickStaff = Key('payroll-pick-staff');
  static const nameField = Key('payroll-name');
  static const jobField = Key('payroll-job');
  static const paydayField = Key('payroll-payday');
  static const salaryField = Key('payroll-salary');
  static const allowanceField = Key('payroll-allowance');
  static const saveButton = Key('payroll-save');
  static const removeButton = Key('payroll-remove');
  static const editWorker = Key('payroll-edit-worker');
  static const tabOverview = Key('payroll-tab-overview');
  static const tabHistory = Key('payroll-tab-history');
  static const previousMonth = Key('payroll-previous-month');
  static const nextMonth = Key('payroll-next-month');
  static const changeAllowances = Key('payroll-change-allowances');
  static const paySalary = Key('payroll-pay-salary');
  static const addMoney = Key('payroll-add-money');
  static Key staffOption(String userId) => Key('payroll-staff-$userId');
  static Key workerRow(String id) => Key('payroll-worker-$id');
}

/// Add (worker == null) or edit a worker. Saves inside the dialog and stays
/// open on failure.
class PayrollWorkerDialog extends ConsumerStatefulWidget {
  const PayrollWorkerDialog({super.key, this.worker});

  final PayrollWorkerData? worker;

  @override
  ConsumerState<PayrollWorkerDialog> createState() =>
      _PayrollWorkerDialogState();
}

class _PayrollWorkerDialogState extends ConsumerState<PayrollWorkerDialog> {
  late final TextEditingController _name;
  late final TextEditingController _salary;
  late final TextEditingController _allowance;
  late final TextEditingController _job;
  int? _paydayDay;
  String? _storeId;
  String? _userId;

  bool get _isEdit => widget.worker != null;

  @override
  void initState() {
    super.initState();
    final w = widget.worker;
    _name = TextEditingController(text: w == null ? '' : toNameCase(w.name));
    _salary = TextEditingController(
      text: w == null || w.monthlySalaryKobo == 0
          ? ''
          : koboToInputText(w.monthlySalaryKobo),
    );
    _allowance = TextEditingController(
      text: w == null || w.dailyAllowanceKobo == 0
          ? ''
          : koboToInputText(w.dailyAllowanceKobo),
    );
    _job = TextEditingController(text: w?.jobTitle ?? '');
    _paydayDay = w?.paydayDay;
    _storeId = w?.storeId;
    _userId = w?.userId;
  }

  @override
  void dispose() {
    _name.dispose();
    _salary.dispose();
    _allowance.dispose();
    _job.dispose();
    super.dispose();
  }

  int _kobo(TextEditingController c) =>
      (parseCurrency(c.text.trim()) * 100).round();

  Future<void> _pickStaff() async {
    final users = ref.read(usersByBusinessProvider).valueOrNull ?? const {};
    final onPayroll = {
      for (final w in ref.read(payrollWorkersProvider).valueOrNull ?? const [])
        if (!w.isRemoved && w.userId != null) w.userId!,
    };
    final people = users.values.where((u) => !onPayroll.contains(u.id)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final picked = await showDialog<UserData>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Pick from Staff Management'),
        children: people.isEmpty
            ? const [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Everyone is already on Payroll.'),
                ),
              ]
            : [
                for (final u in people)
                  SimpleDialogOption(
                    key: PayrollKeys.staffOption(u.id),
                    onPressed: () => Navigator.pop(ctx, u),
                    child: Text(toNameCase(u.name)),
                  ),
              ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _name.text = toNameCase(picked.name);
      _userId = picked.id;
    });
  }

  Future<void> _save() async {
    final name = toNameCase(_name.text);
    final storeId = _storeId;
    if (name.isEmpty) {
      AppNotification.showError(context, 'Enter the worker’s name.');
      return;
    }
    if (storeId == null) {
      AppNotification.showError(context, 'Choose a store.');
      return;
    }
    final dao = ref.read(databaseProvider).payrollDao;
    try {
      final w = widget.worker;
      if (w == null) {
        final allowance = _kobo(_allowance);
        await dao.addWorker(
          storeId: storeId,
          name: name,
          userId: _userId,
          monthlySalaryKobo: _kobo(_salary),
          dailyAllowanceKobo: allowance,
          // The day the amount is set; never backdated.
          allowanceStartDate: allowance > 0 ? PayrollDao.payrollToday() : null,
          jobTitle: _job.text,
          paydayDay: _paydayDay,
        );
      } else {
        await dao.updateWorker(
          workerId: w.id,
          storeId: storeId,
          monthlySalaryKobo: _kobo(_salary),
          dailyAllowanceKobo: _kobo(_allowance),
          jobTitle: Value(_job.text),
          paydayDay: Value(_paydayDay),
        );
      }
      if (!mounted) return;
      Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not save the worker. Please try again.',
        );
      }
    }
  }

  Future<void> _remove() async {
    final w = widget.worker!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Remove worker?'),
        content: Text(
          '${toNameCase(w.name)} stops getting allowances. Their history is '
          'kept.',
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Remove',
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(databaseProvider).payrollDao.removeWorker(w.id);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not remove the worker. Please try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stores = ref.watch(selectableStoresProvider);
    // Keep the staff list warm so Pick from Staff Management opens filled.
    ref.watch(usersByBusinessProvider);
    // Default to the active store (nav.lockedStoreId) when adding.
    _storeId ??= () {
      final locked = ref.read(navigationProvider).lockedStoreId.value;
      if (locked != null && stores.any((s) => s.id == locked)) return locked;
      return stores.isEmpty ? null : stores.first.id;
    }();
    final hasCurrent = stores.any((s) => s.id == _storeId);
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    return AlertDialog(
      scrollable: true,
      title: Text(_isEdit ? 'Edit worker' : 'Add worker'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInput(
            key: PayrollKeys.nameField,
            controller: _name,
            labelText: 'Name',
            textCapitalization: TextCapitalization.words,
            // Typing a different name makes this a typed worker again.
            onChanged: (_) {
              if (!_isEdit) _userId = null;
            },
          ),
          if (!_isEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: PayrollKeys.pickStaff,
                onPressed: _pickStaff,
                icon: const Icon(AppIcons.staff, size: 18),
                label: const Text('Pick from Staff Management'),
              ),
            ),
          SizedBox(height: context.getRSize(8)),
          AppInput(
            key: PayrollKeys.jobField,
            controller: _job,
            labelText: 'Job (optional)',
            hintText: 'For example, Driver',
            textCapitalization: TextCapitalization.words,
          ),
          SizedBox(height: context.getRSize(12)),
          AppDropdown<String>(
            value: hasCurrent ? _storeId : null,
            labelText: 'Store',
            items: [
              for (final s in stores)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _storeId = v),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: PayrollKeys.salaryField,
            controller: _salary,
            labelText: 'Monthly salary',
            prefixText: '$activeCurrencySymbol ',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: PayrollKeys.allowanceField,
            controller: _allowance,
            labelText: 'Daily allowance',
            prefixText: '$activeCurrencySymbol ',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          SizedBox(height: context.getRSize(12)),
          AppDropdown<int>(
            key: PayrollKeys.paydayField,
            // 0 stands for "last day" (a dropdown value cannot be null here).
            value: _paydayDay ?? 0,
            labelText: 'Usual payday',
            items: [
              const DropdownMenuItem(
                value: 0,
                child: Text('Last day of month'),
              ),
              for (var d = 1; d <= 31; d++)
                DropdownMenuItem(value: d, child: Text(payrollOrdinal(d))),
            ],
            onChanged: (v) =>
                setState(() => _paydayDay = v == null || v == 0 ? null : v),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            'An allowance starts the day you set it and is never backdated.',
            style: context.regularStyle(12).copyWith(color: muted),
          ),
        ],
      ),
      actions: [
        if (_isEdit)
          AppButton(
            key: PayrollKeys.removeButton,
            text: 'Remove',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: _remove,
          ),
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.small,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: PayrollKeys.saveButton,
          text: 'Save',
          size: AppButtonSize.small,
          onAsyncPressed: _save,
        ),
      ],
    );
  }
}
