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
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Keys for tests.
class PayrollMoneyKeys {
  static const amountField = Key('payroll-money-amount');
  static const saveButton = Key('payroll-money-save');
  static Key entryRow(String id) => Key('payroll-money-entry-$id');
  static Key approve(String id) => Key('payroll-money-approve-$id');
  static Key reject(String id) => Key('payroll-money-reject-$id');
}

String _title(String type) => switch (type) {
  'bonus' => 'Bonus',
  'advance' => 'Advance',
  'loan_given' => 'Loan given',
  'loan_repaid' => 'Loan repaid',
  _ => 'Entry',
};

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
      payrollPaymentMethodLabel(e.paymentMethod),
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

/// Corrects an approved bonus, advance or loan: typed as the right amount; the
/// difference is saved as a new entry dated today and the old one is kept.
Future<void> showPayrollCorrection(
  BuildContext context, {
  required PayrollEntryData entry,
  required int currentKobo,
}) => showDialog<void>(
  context: context,
  builder: (_) => _CorrectionDialog(entry: entry, currentKobo: currentKobo),
);

class _CorrectionDialog extends ConsumerStatefulWidget {
  const _CorrectionDialog({required this.entry, required this.currentKobo});

  final PayrollEntryData entry;
  final int currentKobo;

  @override
  ConsumerState<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends ConsumerState<_CorrectionDialog> {
  late final _amount = TextEditingController(
    text: koboToInputText(widget.currentKobo),
  );
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final typed = (parseCurrency(_amount.text.trim()) * 100).round();
    final difference = typed - widget.currentKobo;
    if (difference == 0 || typed < 0) {
      AppNotification.showError(context, 'Enter a different amount.');
      return;
    }
    try {
      await ref
          .read(databaseProvider)
          .payrollDao
          .recordMoneyEntry(
            workerId: widget.entry.workerId,
            type: widget.entry.type,
            amountKobo: difference,
            paymentMethod: widget.entry.paymentMethod,
            note: _note.text,
            correctsEntryId: widget.entry.id,
          );
      if (mounted) Navigator.pop(context);
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
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return AlertDialog(
      scrollable: true,
      title: Text('Correct ${_title(widget.entry.type).toLowerCase()}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInput(
            key: PayrollMoneyKeys.amountField,
            controller: _amount,
            labelText: 'Right amount',
            prefixText: '$activeCurrencySymbol ',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            'The difference is saved as a new entry dated today. The old '
            'entry is kept.',
            style: context.regularStyle(12).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
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
