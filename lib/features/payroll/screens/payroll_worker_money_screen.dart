import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Keys for tests.
class PayrollMoneyKeys {
  static const amountField = Key('payroll-money-amount');
  static const noteField = Key('payroll-money-note');
  static const saveButton = Key('payroll-money-save');
  static const loanOwed = Key('payroll-money-loan-owed');
  static const advanceLeft = Key('payroll-money-advance-left');
  static Key action(String type) => Key('payroll-money-action-$type');
  static Key entryRow(String id) => Key('payroll-money-entry-$id');
  static Key approve(String id) => Key('payroll-money-approve-$id');
  static Key reject(String id) => Key('payroll-money-reject-$id');
  static Key openMoney(String workerId) => Key('payroll-open-money-$workerId');
}

const _kPaymentMethodLabels = {
  'cash': 'Cash',
  'transfer': 'Transfer',
  'other': 'Other',
};

String _title(String type) => switch (type) {
  'bonus' => 'Bonus',
  'advance' => 'Advance',
  'loan_given' => 'Loan given',
  'loan_repaid' => 'Loan repaid',
  _ => 'Entry',
};

String _monthBefore(String month) {
  final y = int.parse(month.substring(0, 4));
  final m = int.parse(month.substring(5, 7));
  final prev = m == 1 ? DateTime(y - 1, 12) : DateTime(y, m - 1);
  return '${prev.year}-${prev.month.toString().padLeft(2, '0')}';
}

/// A worker's Bonus, Advance and Staff Loan (#670, PRD #666): what is still
/// owed on loans, what is left of this month's salary for an advance, the
/// entries themselves, and the CEO's approve / reject for waiting ones.
class PayrollWorkerMoneyScreen extends ConsumerWidget {
  const PayrollWorkerMoneyScreen({super.key, required this.workerId});

  final String workerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Gates.managePayroll.allows(ref)) {
      return const GlassyScaffold(
        title: 'Payroll',
        body: Center(child: Text('You no longer have access to Payroll.')),
      );
    }
    final worker = (ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        .where((w) => w.id == workerId)
        .firstOrNull;
    if (worker == null) {
      return const GlassyScaffold(
        title: 'Payroll',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final entries =
        ref.watch(payrollWorkerEntriesProvider(workerId)).valueOrNull ??
        const <PayrollEntryData>[];
    final money = entries
        .where((e) => kPayrollManualEntryTypes.contains(e.type))
        .toList();
    final thisMonth = PayrollMoneyEntries.payrollThisMonth();
    final owed = PayrollMoneyPosition.outstandingLoanKobo(entries);
    final loanWaiting = PayrollMoneyPosition.pendingLoanKobo(entries);
    final left = PayrollMoneyPosition.advanceRoomKobo(
      salaryKobo: worker.monthlySalaryKobo,
      entries: entries,
      salaryMonth: thisMonth,
    );
    final isApprover = ref.watch(payrollIsApproverProvider);
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final types = worker.isRemoved
        ? const ['loan_repaid']
        : const ['bonus', 'advance', 'loan_given', 'loan_repaid'];

    return GlassyScaffold(
      title: toNameCase(worker.name),
      subtitle: 'Bonus, advance and loans',
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16) + context.deviceBottomPadding,
        ),
        children: [
          _Figure(
            key: PayrollMoneyKeys.loanOwed,
            label: 'Loan still owed',
            value: formatCurrency(owed / 100),
            note: loanWaiting > 0
                ? '${formatCurrency(loanWaiting / 100)} more waiting for '
                      'CEO approval'
                : null,
          ),
          SizedBox(height: context.getRSize(10)),
          _Figure(
            key: PayrollMoneyKeys.advanceLeft,
            label: 'Left of ${payrollMonthLabel(thisMonth)} salary',
            value: formatCurrency(left / 100),
            note: 'An advance cannot be more than this. Give a loan instead.',
          ),
          SizedBox(height: context.getRSize(16)),
          Wrap(
            spacing: context.getRSize(8),
            runSpacing: context.getRSize(8),
            children: [
              for (final type in types)
                AppButton(
                  key: PayrollMoneyKeys.action(type),
                  text: _title(type),
                  isFullWidth: false,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.outline,
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        _MoneyEntryDialog(worker: worker, type: type),
                  ),
                ),
            ],
          ),
          SizedBox(height: context.getRSize(20)),
          Text('History', style: context.boldStyle(15)),
          SizedBox(height: context.getRSize(8)),
          if (money.isEmpty)
            Text(
              'No bonus, advance or loan yet.',
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          for (final e in money)
            Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(8)),
              child: PayrollEntryTile(
                entry: e,
                canDecide: isApprover,
                onCorrect:
                    e.status == 'approved' &&
                        e.correctsEntryId == null &&
                        !worker.isRemoved
                    ? () => showDialog<void>(
                        context: context,
                        builder: (_) => _MoneyEntryDialog(
                          worker: worker,
                          type: e.type,
                          correcting: e,
                          currentKobo: PayrollMoneyPosition.correctedAmountKobo(
                            e,
                            entries,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    super.key,
    required this.label,
    required this.value,
    this.note,
  });

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Material(
      color: t.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: context.regularStyle(12).copyWith(color: muted)),
            SizedBox(height: context.getRSize(4)),
            Text(value, style: context.boldStyle(18)),
            if (note != null) ...[
              SizedBox(height: context.getRSize(4)),
              Text(
                note!,
                style: context.regularStyle(12).copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One bonus, advance or loan entry. A waiting entry shows Approve / Reject
/// to the CEO ([canDecide]); an approved one can be corrected ([onCorrect]).
class PayrollEntryTile extends ConsumerWidget {
  const PayrollEntryTile({
    super.key,
    required this.entry,
    required this.canDecide,
    this.onCorrect,
    this.workerName,
  });

  final PayrollEntryData entry;
  final bool canDecide;
  final VoidCallback? onCorrect;

  /// Shown first when the tile is listed outside the worker's own screen.
  final String? workerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final isFix = e.correctsEntryId != null;
    final heading = [
      if (workerName != null) workerName!,
      isFix ? 'Correction to ${_title(e.type).toLowerCase()}' : _title(e.type),
    ].join(' • ');
    final details = [
      e.entryDate,
      _kPaymentMethodLabels[e.paymentMethod] ?? e.paymentMethod,
      if (e.salaryMonth != null) 'for ${payrollMonthLabel(e.salaryMonth!)}',
    ].join('  •  ');
    final status = switch (e.status) {
      'pending' => 'Waiting for CEO approval',
      'rejected' =>
        e.rejectionReason == null
            ? 'Rejected'
            : 'Rejected: ${e.rejectionReason}',
      _ => null,
    };
    final amount = formatCurrency(e.amountKobo.abs() / 100);

    return Material(
      key: PayrollMoneyKeys.entryRow(e.id),
      color: t.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onCorrect,
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(heading, style: context.boldStyle(14))),
                  Text(
                    e.amountKobo < 0 ? '−$amount' : amount,
                    style: context.boldStyle(14),
                  ),
                ],
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                details,
                style: context.regularStyle(12).copyWith(color: muted),
              ),
              if (e.note != null) ...[
                SizedBox(height: context.getRSize(4)),
                Text(e.note!, style: context.regularStyle(12)),
              ],
              if (status != null) ...[
                SizedBox(height: context.getRSize(4)),
                Text(
                  status,
                  style: context
                      .boldStyle(12)
                      .copyWith(
                        color: e.status == 'rejected'
                            ? t.colorScheme.error
                            : t.colorScheme.primary,
                      ),
                ),
              ],
              if (onCorrect != null) ...[
                SizedBox(height: context.getRSize(4)),
                Text(
                  'Tap to correct',
                  style: context.regularStyle(11).copyWith(color: muted),
                ),
              ],
              if (canDecide && e.status == 'pending') ...[
                SizedBox(height: context.getRSize(8)),
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        key: PayrollMoneyKeys.reject(e.id),
                        text: 'Reject',
                        variant: AppButtonVariant.ghost,
                        size: AppButtonSize.small,
                        onAsyncPressed: () => _reject(context, ref),
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Expanded(
                      child: AppButton(
                        key: PayrollMoneyKeys.approve(e.id),
                        text: 'Approve',
                        size: AppButtonSize.small,
                        onAsyncPressed: () => _approve(context, ref),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(databaseProvider).payrollDao.approveEntry(entry.id);
    } catch (_) {
      if (context.mounted) {
        AppNotification.showError(context, 'Could not approve. Try again.');
      }
    }
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RejectDialog(),
    );
    if (reason == null) return;
    try {
      await ref
          .read(databaseProvider)
          .payrollDao
          .rejectEntry(entry.id, reason: reason);
    } catch (_) {
      if (context.mounted) {
        AppNotification.showError(context, 'Could not reject. Try again.');
      }
    }
  }
}

class _RejectDialog extends StatefulWidget {
  const _RejectDialog();

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Reject this entry?'),
      content: AppInput(
        controller: _reason,
        labelText: 'Reason (optional)',
        textCapitalization: TextCapitalization.sentences,
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
          text: 'Reject',
          variant: AppButtonVariant.danger,
          size: AppButtonSize.small,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context, _reason.text),
        ),
      ],
    );
  }
}

/// Records a Bonus, Advance, Loan given or Loan repaid — or, with
/// [correcting], a correction of one (typed as the right amount; the
/// difference is saved as a new entry). Stays open on a broken rule.
class _MoneyEntryDialog extends ConsumerStatefulWidget {
  const _MoneyEntryDialog({
    required this.worker,
    required this.type,
    this.correcting,
    this.currentKobo,
  });

  final PayrollWorkerData worker;
  final String type;
  final PayrollEntryData? correcting;
  final int? currentKobo;

  @override
  ConsumerState<_MoneyEntryDialog> createState() => _MoneyEntryDialogState();
}

class _MoneyEntryDialogState extends ConsumerState<_MoneyEntryDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _method = 'cash';
  late String _month;
  late final List<String> _months;

  bool get _isFix => widget.correcting != null;

  @override
  void initState() {
    super.initState();
    final thisMonth = PayrollMoneyEntries.payrollThisMonth();
    _months = [thisMonth, _monthBefore(thisMonth)];
    _month = widget.correcting?.salaryMonth ?? thisMonth;
    if (_isFix) {
      _method = widget.correcting!.paymentMethod;
      _amount.text = koboToInputText(widget.currentKobo ?? 0);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final typed = (parseCurrency(_amount.text.trim()) * 100).round();
    final amount = _isFix ? typed - (widget.currentKobo ?? 0) : typed;
    if (amount == 0 || typed < 0) {
      AppNotification.showError(
        context,
        _isFix ? 'Enter a different amount.' : 'Enter an amount.',
      );
      return;
    }
    try {
      final saved = await ref
          .read(databaseProvider)
          .payrollDao
          .recordMoneyEntry(
            workerId: widget.worker.id,
            type: widget.type,
            amountKobo: amount,
            paymentMethod: _method,
            salaryMonth: widget.type == 'advance' ? _month : null,
            note: _note.text,
            correctsEntryId: widget.correcting?.id,
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
    } catch (_) {
      if (mounted) {
        AppNotification.showError(context, 'Could not save. Please try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _isFix
        ? 'Correct ${_title(widget.type).toLowerCase()}'
        : _title(widget.type);
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            toNameCase(widget.worker.name),
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: PayrollMoneyKeys.amountField,
            controller: _amount,
            labelText: _isFix ? 'Right amount' : 'Amount',
            prefixText: '$activeCurrencySymbol ',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          if (_isFix) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              'The difference is saved as a new entry dated today. The old '
              'entry is kept.',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
          ],
          SizedBox(height: context.getRSize(12)),
          AppDropdown<String>(
            value: _method,
            labelText: 'How it was paid',
            items: [
              for (final m in _kPaymentMethodLabels.entries)
                DropdownMenuItem(value: m.key, child: Text(m.value)),
            ],
            onChanged: (v) => setState(() => _method = v ?? _method),
          ),
          if (widget.type == 'advance' && !_isFix) ...[
            SizedBox(height: context.getRSize(12)),
            AppDropdown<String>(
              value: _month,
              labelText: 'Salary month',
              items: [
                for (final m in _months)
                  DropdownMenuItem(value: m, child: Text(payrollMonthLabel(m))),
              ],
              onChanged: (v) => setState(() => _month = v ?? _month),
            ),
          ],
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: PayrollMoneyKeys.noteField,
            controller: _note,
            labelText: 'Note (optional)',
            textCapitalization: TextCapitalization.sentences,
          ),
        ],
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
          key: PayrollMoneyKeys.saveButton,
          text: 'Save',
          size: AppButtonSize.small,
          isFullWidth: false,
          onAsyncPressed: _save,
        ),
      ],
    );
  }
}

/// The CEO's (and everyone's) view of bonus, advance and loan entries waiting
/// for approval, shown above the worker list. Hidden when none wait.
class PayrollPendingApprovalsCard extends ConsumerWidget {
  const PayrollPendingApprovalsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(payrollPendingEntriesProvider).valueOrNull ?? [];
    if (pending.isEmpty) return const SizedBox.shrink();
    final names = {
      for (final w in ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        w.id: toNameCase(w.name),
    };
    final isApprover = ref.watch(payrollIsApproverProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(AppIcons.payroll, size: 18),
              SizedBox(width: context.getRSize(6)),
              Text(
                isApprover
                    ? 'Waiting for your approval (${pending.length})'
                    : 'Waiting for CEO approval (${pending.length})',
                style: context.boldStyle(14),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(8)),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: context.getRSize(260)),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final e in pending)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.getRSize(8)),
                    child: PayrollEntryTile(
                      entry: e,
                      canDecide: isApprover,
                      workerName: names[e.workerId],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
