import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_parts.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_lines.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

/// Keys for tests.
class PayrollHistoryKeys {
  static const staffPicker = Key('payroll-history-staff');
  static const monthPicker = Key('payroll-history-month');
  static const summary = Key('payroll-history-summary');
  static const total = Key('payroll-history-total');
  static Key kind(PayrollKind k) => Key('payroll-history-kind-${k.name}');
  static Key row(int i) => Key('payroll-history-row-$i');
}

String _money(int kobo) => formatCurrency(kobo / 100);

/// The History lines and totals for the chosen staff and month, before the
/// type filter (a worker's own page has every month).
({List<PayrollHistoryRow> rows, PayrollHistoryTotals totals}) payrollHistoryFor(
  WidgetRef ref, {
  required String? month,
  required String? workerId,
}) {
  final statements = workerId != null
      ? ref.watch(payrollWorkerStatementsProvider(workerId)).valueOrNull
      : ref.watch(payrollMonthStatementsProvider(month ?? '')).valueOrNull;
  final rows = payrollHistoryRows(
    workers: ref.watch(payrollWorkersProvider).valueOrNull ?? const [],
    entries: ref.watch(payrollAllEntriesProvider).valueOrNull ?? const [],
    statements: statements ?? const [],
    month: month,
    workerId: workerId,
  );
  return (rows: rows, totals: PayrollHistoryTotals.of(rows));
}

bool _kindMatches(PayrollHistoryRow r, PayrollKind kind) =>
    kind == PayrollKind.all || r.kind == kind;

/// Picks a Salary Month from the last two years. [allowAll] adds "All months"
/// (returned as the empty string).
Future<String?> pickPayrollMonth(
  BuildContext context, {
  required String? current,
  bool allowAll = false,
}) {
  final thisMonth = payrollMonthKey(DateTime.now());
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: context.sheetMaxHeight(0.7)),
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (allowAll)
            ListTile(
              title: const Text('All months'),
              selected: current == null,
              onTap: () => Navigator.pop(sheet, ''),
            ),
          for (var i = 0; i < 24; i++)
            Builder(
              builder: (_) {
                final m = payrollShiftMonth(thisMonth, -i);
                return ListTile(
                  title: Text(payrollMonthLabel(m)),
                  selected: m == current,
                  onTap: () => Navigator.pop(sheet, m),
                );
              },
            ),
        ],
      ),
    ),
  );
}

/// Picks who History shows. Returns the empty string for all staff.
Future<String?> _pickStaff(
  BuildContext context,
  List<PayrollWorkerData> workers,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  constraints: BoxConstraints(maxHeight: context.sheetMaxHeight(0.7)),
  builder: (sheet) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          title: const Text('All staff'),
          onTap: () => Navigator.pop(sheet, ''),
        ),
        for (final w in workers)
          ListTile(
            title: Text(toNameCase(w.name)),
            onTap: () => Navigator.pop(sheet, w.id),
          ),
      ],
    ),
  ),
);

/// Opens a worker's whole History (a phone's "See all").
void openWorkerHistory(BuildContext context, PayrollWorkerData worker) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => _WorkerHistoryPage(worker: worker)),
  );
}

class _WorkerHistoryPage extends ConsumerStatefulWidget {
  const _WorkerHistoryPage({required this.worker});

  final PayrollWorkerData worker;

  @override
  ConsumerState<_WorkerHistoryPage> createState() => _WorkerHistoryPageState();
}

class _WorkerHistoryPageState extends ConsumerState<_WorkerHistoryPage> {
  String? _month;
  PayrollKind _kind = PayrollKind.all;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: AppDecorations.pageBackground(context),
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PayrollTopBar(
        height: payrollTopBarHeight(context),
        child: PayrollFormHeader(
          title: payrollName(widget.worker),
          subtitle: 'Payment history',
          icon: AppIcons.arrowBack,
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kPayrollColumnMaxWidth),
          child: PayrollHistoryPhone(
            month: _month,
            workerId: widget.worker.id,
            kind: _kind,
            allowAllMonths: true,
            onMonthChanged: (m) => setState(() => _month = m),
            onKindChanged: (k) => setState(() => _kind = k),
          ),
        ),
      ),
    ),
  );
}

/// A drop-down look-alike that opens a sheet.
class _PickerTile extends StatelessWidget {
  const _PickerTile({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return Material(
      color: t.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.dividerColor),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(14),
            vertical: context.getRSize(13),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.boldStyle(15),
                ),
              ),
              Icon(
                AppIcons.chevronDown,
                size: context.getRSize(22),
                color: payrollMuted(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// History on a phone: filters, what was paid out, then each day's lines.
class PayrollHistoryPhone extends ConsumerWidget {
  const PayrollHistoryPhone({
    super.key,
    required this.month,
    required this.workerId,
    required this.kind,
    required this.onMonthChanged,
    required this.onKindChanged,
    this.onWorkerChanged,
    this.allowAllMonths = false,
    this.header,
  });

  /// Null = every month.
  final String? month;
  final String? workerId;
  final PayrollKind kind;
  final ValueChanged<String?> onMonthChanged;
  final ValueChanged<PayrollKind> onKindChanged;

  /// Null hides the staff picker (a worker's own page).
  final ValueChanged<String?>? onWorkerChanged;
  final bool allowAllMonths;

  /// Scrolls with the list (the Overview / History switch).
  final Widget? header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currencySymbolProvider);
    final workers = ref.watch(payrollWorkersProvider).valueOrNull ?? const [];
    final data = payrollHistoryFor(ref, month: month, workerId: workerId);
    final rows = data.rows.where((r) => _kindMatches(r, kind)).toList();
    final byDay = <String, List<PayrollHistoryRow>>{};
    for (final r in rows) {
      (byDay[r.date] ??= []).add(r);
    }
    final worker = workers.where((w) => w.id == workerId).firstOrNull;
    final gap = SizedBox(height: context.getRSize(12));
    final muted = payrollMuted(context);
    final thisMonth = month == payrollMonthKey(DateTime.now());
    final heading = month == null
        ? 'Paid out so far'
        : 'Paid out in ${payrollMonthName(month!)}${thisMonth ? ' so far' : ''}';

    final monthTile = _PickerTile(
      key: PayrollHistoryKeys.monthPicker,
      label: month == null ? 'All months' : payrollMonthLabel(month!),
      onTap: () async {
        final picked = await pickPayrollMonth(
          context,
          current: month,
          allowAll: allowAllMonths,
        );
        if (picked != null) onMonthChanged(picked.isEmpty ? null : picked);
      },
    );

    var index = 0;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(96) + context.deviceBottomPadding,
      ),
      children: [
        ?header,
        if (onWorkerChanged == null)
          monthTile
        else
          Row(
            children: [
              Expanded(
                child: _PickerTile(
                  key: PayrollHistoryKeys.staffPicker,
                  label: worker == null ? 'All staff' : payrollName(worker),
                  onTap: () async {
                    final picked = await _pickStaff(context, workers);
                    if (picked != null) {
                      onWorkerChanged!(picked.isEmpty ? null : picked);
                    }
                  },
                ),
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(child: monthTile),
            ],
          ),
        SizedBox(height: context.getRSize(6)),
        Wrap(
          spacing: context.getRSize(8),
          children: [
            for (final k in PayrollKind.values)
              PayrollPillChip(
                key: PayrollHistoryKeys.kind(k),
                label: payrollKindLabel(k),
                selected: kind == k,
                onTap: () => onKindChanged(k),
              ),
          ],
        ),
        SizedBox(height: context.getRSize(6)),
        PayrollCard(
          key: PayrollHistoryKeys.summary,
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading,
                  style: context.semiBoldStyle(14).copyWith(color: muted),
                ),
                SizedBox(height: context.getRSize(6)),
                Text(
                  _money(data.totals.totalKobo),
                  key: PayrollHistoryKeys.total,
                  style: context.boldStyle(32),
                ),
                if (data.totals.breakdown.isNotEmpty) ...[
                  SizedBox(height: context.getRSize(6)),
                  Text(
                    data.totals.breakdown,
                    style: context.regularStyle(14).copyWith(color: muted),
                  ),
                ],
              ],
            ),
          ),
        ),
        gap,
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.all(context.getRSize(24)),
            child: Text(
              'No payments to show.',
              textAlign: TextAlign.center,
              style: context.semiBoldStyle(15).copyWith(color: muted),
            ),
          ),
        for (final day in byDay.entries) ...[
          Padding(
            padding: EdgeInsets.only(
              top: context.getRSize(6),
              bottom: context.getRSize(8),
            ),
            child: Text(
              payrollLongDay(day.key),
              style: context.boldStyle(15).copyWith(color: muted),
            ),
          ),
          PayrollCard(
            padding: 0,
            child: Column(
              children: [
                for (var i = 0; i < day.value.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: Theme.of(context).dividerColor),
                  _PhoneRow(
                    key: PayrollHistoryKeys.row(index++),
                    row: day.value[i],
                  ),
                ],
              ],
            ),
          ),
          gap,
        ],
      ],
    );
  }
}

class _PhoneRow extends ConsumerWidget {
  const _PhoneRow({super.key, required this.row});

  final PayrollHistoryRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = row.staffCount > 1;
    final method = payrollPaymentMethodLabel(row.method);
    final title = group
        ? '${row.title}, ${row.staffCount} staff'
        : (row.workerName ?? row.title);
    final what = row.details == null || row.details!.isEmpty
        ? row.title
        : (row.kind == PayrollKind.bonus
              ? '${row.title}, ${row.details}'
              : row.details!);
    final subtitle = row.isWaiting
        ? 'Waiting for CEO approval'
        : group
        ? payrollRowSubtitle(row)
        : row.kind == PayrollKind.salary
        ? 'Salary, ${method.toLowerCase()}'
        : row.kind == PayrollKind.allowance
        ? 'Daily allowance, ${method.toLowerCase()}'
        : what;
    return InkWell(
      onTap: () => openPayrollRow(context, ref, row),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Row(
          children: [
            PayrollKindIcon(kind: row.kind),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.boldStyle(15)),
                  Text(
                    subtitle,
                    style: context
                        .regularStyle(13)
                        .copyWith(color: payrollMuted(context)),
                  ),
                ],
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Text(payrollRowAmount(row), style: context.boldStyle(15)),
          ],
        ),
      ),
    );
  }
}

/// History on a tablet: staff and type on the left, then the month's figures
/// (a tile doubles as the type filter) over one table.
class PayrollHistoryTablet extends ConsumerWidget {
  const PayrollHistoryTablet({
    super.key,
    required this.month,
    required this.workerId,
    required this.kind,
    required this.onWorkerChanged,
    required this.onKindChanged,
  });

  final String month;
  final String? workerId;
  final PayrollKind kind;
  final ValueChanged<String?> onWorkerChanged;
  final ValueChanged<PayrollKind> onKindChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currencySymbolProvider);
    final t = Theme.of(context);
    final muted = payrollMuted(context);
    final workers = (ref.watch(payrollWorkersProvider).valueOrNull ?? const [])
        .where((w) => !w.isRemoved)
        .toList();
    final data = payrollHistoryFor(ref, month: month, workerId: workerId);
    final rows = data.rows.where((r) => _kindMatches(r, kind)).toList();

    Widget staffItem(String? id, String label) {
      final on = workerId == id;
      final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
      return Material(
        color: on ? t.colorScheme.primary : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => onWorkerChanged(id),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(16),
              vertical: context.getRSize(13),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context
                    .semiBoldStyle(15)
                    .copyWith(
                      color: on
                          ? t.colorScheme.onPrimary
                          : t.colorScheme.onSurface,
                    ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: kPayrollFilterPaneWidth,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: t.dividerColor)),
          ),
          child: ListView(
            padding: EdgeInsets.all(context.getRSize(20)),
            children: [
              const PayrollFieldLabel('Staff'),
              staffItem(null, 'All staff'),
              for (final w in workers)
                Padding(
                  padding: EdgeInsets.only(top: context.getRSize(4)),
                  child: staffItem(w.id, payrollName(w)),
                ),
              SizedBox(height: context.getRSize(20)),
              const PayrollFieldLabel('Type'),
              Wrap(
                spacing: context.getRSize(8),
                children: [
                  for (final k in PayrollKind.values)
                    PayrollPillChip(
                      key: PayrollHistoryKeys.kind(k),
                      label: payrollKindLabel(k),
                      selected: kind == k,
                      onTap: () => onKindChanged(k),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(24)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    for (final (k, label, kobo) in [
                      (
                        PayrollKind.all,
                        'Total paid out',
                        data.totals.totalKobo,
                      ),
                      (
                        PayrollKind.salary,
                        'Salaries',
                        data.totals.salariesKobo,
                      ),
                      (
                        PayrollKind.allowance,
                        'Allowances',
                        data.totals.allowancesKobo,
                      ),
                      (PayrollKind.bonus, 'Bonuses', data.totals.bonusesKobo),
                      (
                        PayrollKind.advance,
                        'Advances',
                        data.totals.advancesKobo,
                      ),
                    ]) ...[
                      if (k != PayrollKind.all)
                        SizedBox(width: context.getRSize(14)),
                      Expanded(
                        child: PayrollCard(
                          key: k == PayrollKind.all
                              ? PayrollHistoryKeys.total
                              : null,
                          selected: kind == k,
                          onTap: () => onKindChanged(k),
                          child: SizedBox(
                            width: double.infinity,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context
                                      .semiBoldStyle(14)
                                      .copyWith(color: muted),
                                ),
                                SizedBox(height: context.getRSize(4)),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _money(kobo),
                                    style: context.boldStyle(24),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: context.getRSize(18)),
                Expanded(
                  child: DecoratedBox(
                    decoration: AppDecorations.card(
                      context,
                      radius: AppSpacing.borderRadiusL,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppSpacing.borderRadiusL,
                      ),
                      child: _HistoryTable(rows: rows),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryTable extends ConsumerWidget {
  const _HistoryTable({required this.rows});

  final List<PayrollHistoryRow> rows;

  static const _flex = [12, 16, 10, 22, 9, 10];

  Widget _cell(int column, Widget child) => Expanded(
    flex: _flex[column],
    child: Align(
      alignment: column == 5 ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = payrollMuted(context);
    final head = context.boldStyle(14).copyWith(color: muted);
    final pad = EdgeInsets.symmetric(
      horizontal: context.getRSize(20),
      vertical: context.getRSize(14),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: t.inputDecorationTheme.fillColor,
          padding: pad,
          child: Row(
            children: [
              for (final (i, h) in const [
                (0, 'Date'),
                (1, 'Staff'),
                (2, 'Type'),
                (3, 'Details'),
                (4, 'Paid by'),
                (5, 'Amount'),
              ])
                _cell(i, Text(h, style: head)),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    'No payments to show.',
                    style: context.semiBoldStyle(15).copyWith(color: muted),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: t.dividerColor),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return InkWell(
                      key: PayrollHistoryKeys.row(i),
                      onTap: () => openPayrollRow(context, ref, r),
                      child: Padding(
                        padding: pad,
                        child: Row(
                          children: [
                            _cell(
                              0,
                              Text(
                                payrollMediumDay(r.date),
                                style: context
                                    .regularStyle(15)
                                    .copyWith(color: muted),
                              ),
                            ),
                            _cell(
                              1,
                              Text(
                                r.staffLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.boldStyle(15),
                              ),
                            ),
                            _cell(2, _TypePill(kind: r.kind)),
                            _cell(
                              3,
                              Text(
                                r.isWaiting
                                    ? 'Waiting for CEO approval'
                                    : (r.details ?? r.title),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context
                                    .regularStyle(15)
                                    .copyWith(color: muted),
                              ),
                            ),
                            _cell(
                              4,
                              Text(
                                payrollPaymentMethodLabel(r.method),
                                style: context.regularStyle(15),
                              ),
                            ),
                            _cell(
                              5,
                              Text(
                                payrollRowAmount(r),
                                style: context.boldStyle(15),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: EdgeInsets.all(context.getRSize(12)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.dividerColor)),
          ),
          child: Text(
            'Showing ${rows.length} '
            '${rows.length == 1 ? 'payment' : 'payments'}.',
            style: context.regularStyle(14).copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _TypePill extends StatelessWidget {
  const _TypePill({required this.kind});

  final PayrollKind kind;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: t.inputDecorationTheme.fillColor ?? t.dividerColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Text(payrollKindLabel(kind), style: context.boldStyle(13)),
    );
  }
}

/// The month's report for the receipt printer (tablet "Print Report"). Worker
/// names and amounts stay on paper; nothing here reaches a log.
List<ReceiptLine> buildPayrollReportLines({
  required String businessName,
  required String month,
  required List<PayrollHistoryRow> rows,
  required ReceiptPaperSize paperSize,
}) {
  final w = paperSize.charsPerLine;
  final totals = PayrollHistoryTotals.of(rows);
  ReceiptLine text(String s, {bool bold = false, ReceiptAlign? align}) =>
      ReceiptLine.text([
        ReceiptSegment(receiptSafe(s), bold: bold),
      ], align: align ?? ReceiptAlign.left);
  ReceiptLine row(String label, String value, {bool bold = false}) {
    final v = receiptSafe(value);
    final room = w - v.length - 1;
    var l = receiptSafe(label);
    if (l.length > room) l = l.substring(0, room < 0 ? 0 : room);
    final gap = w - l.length - v.length;
    return ReceiptLine.text([
      ReceiptSegment('$l${' ' * (gap < 1 ? 1 : gap)}$v', bold: bold),
    ]);
  }

  final rule = text('-' * w);
  return [
    if (businessName.trim().isNotEmpty)
      text(businessName.toUpperCase(), bold: true, align: ReceiptAlign.center),
    text('PAYROLL REPORT', bold: true, align: ReceiptAlign.center),
    text(payrollMonthLabel(month), align: ReceiptAlign.center),
    rule,
    for (final r in rows)
      row(
        '${payrollShortDay(r.date)} ${r.staffLabel}, ${r.title}',
        payrollRowAmount(r),
      ),
    rule,
    if (totals.salariesKobo != 0) row('Salaries', _money(totals.salariesKobo)),
    if (totals.allowancesKobo != 0)
      row('Allowances', _money(totals.allowancesKobo)),
    if (totals.bonusesKobo != 0) row('Bonuses', _money(totals.bonusesKobo)),
    if (totals.advancesKobo != 0) row('Advances', _money(totals.advancesKobo)),
    if (totals.loansKobo != 0) row('Loans', _money(totals.loansKobo)),
    row('TOTAL PAID OUT', _money(totals.totalKobo), bold: true),
  ];
}
