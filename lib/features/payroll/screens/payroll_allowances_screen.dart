import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
import 'package:reebaplus_pos/features/payroll/allowance_day.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Keys for tests.
class PayrollAllowanceKeys {
  static const openButton = Key('payroll-open-allowances');
  static const previousDay = Key('payroll-allowance-prev-day');
  static const nextDay = Key('payroll-allowance-next-day');
  static const amountField = Key('payroll-allowance-amount');
  static const saveButton = Key('payroll-allowance-save');
  static const cancelAllowanceButton = Key('payroll-allowance-cancel');
  static Key row(String workerId) => Key('payroll-allowance-row-$workerId');
}

/// #669 — the Daily Allowances of one day (today by default): every worker
/// owed one, the amount and whether it is posted, changed or cancelled. A
/// CEO or Manager taps a worker to change or cancel that worker's allowance
/// for that day. Posting itself is automatic (no button).
class PayrollAllowancesScreen extends ConsumerStatefulWidget {
  const PayrollAllowancesScreen({super.key, this.now});

  /// Test seam for "today".
  final DateTime? now;

  @override
  ConsumerState<PayrollAllowancesScreen> createState() =>
      _PayrollAllowancesScreenState();
}

class _PayrollAllowancesScreenState
    extends ConsumerState<PayrollAllowancesScreen> {
  late DateTime _today;
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    final n = widget.now ?? DateTime.now();
    _today = DateTime(n.year, n.month, n.day);
    _day = _today;
  }

  void _shift(int days) {
    final next = DateTime(_day.year, _day.month, _day.day + days);
    if (next.isAfter(_today)) return;
    setState(() => _day = next);
  }

  String _dayLabel() {
    final diff = _today.difference(_day).inDays;
    final date = DateFormat('EEE d MMM').format(_day);
    if (diff == 0) return 'Today, $date';
    if (diff == 1) return 'Yesterday, $date';
    return date;
  }

  @override
  Widget build(BuildContext context) {
    if (!Gates.managePayroll.allows(ref)) {
      return const GlassyScaffold(
        title: 'Daily allowances',
        body: Center(child: Text('You no longer have access to Payroll.')),
      );
    }
    final workers = ref.watch(payrollWorkersProvider).valueOrNull ?? const [];
    final entries =
        ref.watch(payrollAllowanceEntriesProvider).valueOrNull ?? const [];
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final storeNames = {for (final s in stores) s.id: s.name};
    final rows = allowanceDayRows(
      workers: workers,
      entries: entries,
      day: _day,
    );
    final total = rows.fold<int>(0, (s, r) => s + r.amountKobo);
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final isSunday = _day.weekday == DateTime.sunday;

    return GlassyScaffold(
      title: 'Daily allowances',
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(8),
              context.getRSize(8),
              context.getRSize(8),
              0,
            ),
            child: Row(
              children: [
                IconButton(
                  key: PayrollAllowanceKeys.previousDay,
                  tooltip: 'Previous day',
                  onPressed: () => _shift(-1),
                  icon: const Icon(AppIcons.chevronLeft),
                ),
                Expanded(
                  child: Text(
                    _dayLabel(),
                    textAlign: TextAlign.center,
                    style: context.boldStyle(15),
                  ),
                ),
                IconButton(
                  key: PayrollAllowanceKeys.nextDay,
                  tooltip: 'Next day',
                  onPressed: _day.isBefore(_today) ? () => _shift(1) : null,
                  icon: const Icon(AppIcons.chevronRight),
                ),
              ],
            ),
          ),
          if (rows.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Total for the day',
                      style: context.regularStyle(13).copyWith(color: muted),
                    ),
                  ),
                  Text(
                    formatCurrency(total / 100.0),
                    style: context.boldStyle(14),
                  ),
                ],
              ),
            ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.all(context.getRSize(24)),
                      child: Text(
                        isSunday
                            ? 'No daily allowances on Sundays.'
                            : 'No daily allowance is due on this day.',
                        textAlign: TextAlign.center,
                        style: context.regularStyle(14).copyWith(color: muted),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      context.getRSize(16),
                      context.getRSize(12),
                      context.getRSize(16),
                      context.getRSize(16) + context.deviceBottomPadding,
                    ),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) =>
                        SizedBox(height: context.getRSize(10)),
                    itemBuilder: (context, i) => _AllowanceCard(
                      row: rows[i],
                      storeName:
                          storeNames[rows[i].worker.storeId] ?? 'Unknown store',
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _AllowanceDialog(
                          row: rows[i],
                          day: _day,
                          now: widget.now,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AllowanceCard extends StatelessWidget {
  const _AllowanceCard({
    required this.row,
    required this.storeName,
    required this.onTap,
  });

  final AllowanceDayRow row;
  final String storeName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final statusLabel = switch (row.status) {
      AllowanceDayStatus.due => 'Posts automatically',
      AllowanceDayStatus.posted => 'Recorded',
      AllowanceDayStatus.changed => 'Changed',
      AllowanceDayStatus.cancelled => 'Cancelled',
    };
    final cancelled = row.status == AllowanceDayStatus.cancelled;
    return Material(
      key: PayrollAllowanceKeys.row(row.worker.id),
      color: t.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(14)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      toNameCase(row.worker.name),
                      style: context.boldStyle(15),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      '$storeName · $statusLabel',
                      style: context.regularStyle(12).copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              Text(
                formatCurrency(row.amountKobo / 100.0),
                style: context
                    .boldStyle(15)
                    .copyWith(
                      color: cancelled ? muted : null,
                      decoration: cancelled ? TextDecoration.lineThrough : null,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// #669 — the Payroll app-bar action that opens [PayrollAllowancesScreen].
class PayrollAllowancesButton extends StatelessWidget {
  const PayrollAllowancesButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: PayrollAllowanceKeys.openButton,
      tooltip: 'Daily allowances',
      icon: const Icon(AppIcons.calendar),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const PayrollAllowancesScreen(),
        ),
      ),
    );
  }
}

/// Change or cancel one worker's allowance for one day.
class _AllowanceDialog extends ConsumerStatefulWidget {
  const _AllowanceDialog({required this.row, required this.day, this.now});

  final AllowanceDayRow row;
  final DateTime day;
  final DateTime? now;

  @override
  ConsumerState<_AllowanceDialog> createState() => _AllowanceDialogState();
}

class _AllowanceDialogState extends ConsumerState<_AllowanceDialog> {
  late final TextEditingController _amount;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(
      text: koboToInputText(
        widget.row.status == AllowanceDayStatus.cancelled
            ? widget.row.worker.dailyAllowanceKobo
            : widget.row.amountKobo,
      ),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _apply(int amountKobo) async {
    try {
      await ref
          .read(databaseProvider)
          .payrollDao
          .setAllowanceForDay(
            workerId: widget.row.worker.id,
            entryDate: payrollDayKey(widget.day),
            amountKobo: amountKobo,
            now: widget.now,
          );
      if (!mounted) return;
      Navigator.pop(context);
      AppNotification.showSuccess(
        context,
        amountKobo == 0 ? 'Allowance cancelled.' : 'Allowance updated.',
      );
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not update the allowance. Please try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final posted = widget.row.original != null;
    return AlertDialog(
      scrollable: true,
      title: Text(toNameCase(widget.row.worker.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily allowance for ${DateFormat('EEE d MMM').format(widget.day)}',
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: PayrollAllowanceKeys.amountField,
            controller: _amount,
            labelText: 'Amount',
            prefixText: '$activeCurrencySymbol ',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          if (posted) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              'Already recorded: the change is saved as a new entry today.',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
          ],
        ],
      ),
      actions: [
        if (widget.row.status != AllowanceDayStatus.cancelled)
          AppButton(
            key: PayrollAllowanceKeys.cancelAllowanceButton,
            text: 'Cancel allowance',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onAsyncPressed: () => _apply(0),
          ),
        AppButton(
          text: 'Close',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.small,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: PayrollAllowanceKeys.saveButton,
          text: 'Save',
          size: AppButtonSize.small,
          onAsyncPressed: () =>
              _apply((parseCurrency(_amount.text.trim()) * 100).round()),
        ),
      ],
    );
  }
}
