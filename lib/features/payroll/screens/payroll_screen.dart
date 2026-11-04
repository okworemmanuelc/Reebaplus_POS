import 'dart:async';

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
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/payroll/payroll_money_providers.dart';
import 'package:reebaplus_pos/features/payroll/payroll_overview.dart';
import 'package:reebaplus_pos/features/payroll/payslip.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_allowances_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_history_view.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_worker_screen.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_entry_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_parts.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_print.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_dialog.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

export 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_dialog.dart'
    show PayrollKeys;

String _money(int kobo) => formatCurrency(kobo / 100);

enum _Tab { overview, history }

enum _StaffFilter { all, unpaid, paid }

/// Payroll (#723, from the owner's mockups): the month at a glance and every
/// payment made. A phone stacks it; a wide screen shows the staff list beside
/// the chosen worker, and History as a table. Reached from the drawer only
/// with `payroll.manage`. Workers are added by hand; nobody joins by default.
class PayrollScreen extends ConsumerStatefulWidget {
  const PayrollScreen({super.key});

  @override
  ConsumerState<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends ConsumerState<PayrollScreen> {
  _Tab _tab = _Tab.overview;
  String _month = payrollMonthKey(DateTime.now());
  _StaffFilter _staffFilter = _StaffFilter.all;
  String? _selectedWorkerId;
  bool _showRemoved = false;
  String? _historyWorkerId;
  PayrollKind _historyKind = PayrollKind.all;
  bool _printing = false;

  bool get _atThisMonth => _month == payrollMonthKey(DateTime.now());

  void _moveMonth(int delta) =>
      setState(() => _month = payrollShiftMonth(_month, delta));

  void _openWorker(String workerId) {
    if (context.isWideLayout) {
      setState(() => _selectedWorkerId = workerId);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PayrollWorkerScreen(workerId: workerId, month: _month),
      ),
    );
  }

  void _openAllowances() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const PayrollAllowancesScreen()),
  );

  void _openAdd(bool hasWorkers) {
    if (!hasWorkers) {
      unawaited(openWorkerForm(context));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: PayrollKeys.addRecord,
              leading: const Icon(AppIcons.cash),
              title: const Text('Add Pay Record'),
              subtitle: const Text('Allowance, bonus, advance or loan'),
              onTap: () {
                Navigator.pop(sheet);
                openAddPayRecord(context);
              },
            ),
            ListTile(
              key: PayrollKeys.addWorker,
              leading: const Icon(AppIcons.userAdd),
              title: const Text('Add Staff to Payroll'),
              onTap: () {
                Navigator.pop(sheet);
                unawaited(openWorkerForm(context));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _printReport() async {
    final data = payrollHistoryFor(
      ref,
      month: _month,
      workerId: _historyWorkerId,
    );
    final rows = data.rows
        .where((r) => _historyKind == PayrollKind.all || r.kind == _historyKind)
        .toList();
    await printPayrollLines(
      context,
      ref,
      (size) => buildPayrollReportLines(
        businessName: ref.read(currentBusinessNameProvider),
        month: _month,
        rows: rows,
        paperSize: size,
      ),
      onBusy: (busy) {
        if (mounted) setState(() => _printing = busy);
      },
    );
  }

  Widget _tabs() => PayrollSegmented<_Tab>(
    value: _tab,
    items: const {_Tab.overview: 'Overview', _Tab.history: 'History'},
    keyOf: (t) =>
        t == _Tab.overview ? PayrollKeys.tabOverview : PayrollKeys.tabHistory,
    onChanged: (t) => setState(() => _tab = t),
  );

  Widget _arrow(IconData icon, Key key, VoidCallback? onTap, String tip) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Material(
      color: t.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: t.dividerColor),
      ),
      child: InkWell(
        key: key,
        borderRadius: radius,
        onTap: onTap,
        child: Tooltip(
          message: tip,
          child: SizedBox.square(
            dimension: kMinInteractiveDimension,
            child: Icon(
              icon,
              size: context.getRSize(24),
              color: onTap == null ? t.dividerColor : t.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _previousArrow() => _arrow(
    AppIcons.chevronLeft,
    PayrollKeys.previousMonth,
    () => _moveMonth(-1),
    'Previous month',
  );

  /// Never into a month that has not started.
  Widget _nextArrow() => _arrow(
    AppIcons.chevronRight,
    PayrollKeys.nextMonth,
    _atThisMonth ? null : () => _moveMonth(1),
    'Next month',
  );

  PreferredSizeWidget _topBar(BuildContext context, {required bool wide}) {
    final header = ScreenHeader(
      icon: AppIcons.payrollWallet,
      title: 'Payroll',
      subtitle: 'Salaries, allowances and loans',
      leading: context.isRailLayout ? null : const MenuButton(),
      actions: wide ? const [] : const [PayrollLiveBell()],
    );
    final t = Theme.of(context);
    return PayrollTopBar(
      height: payrollTopBarHeight(context),
      child: !wide
          ? header
          : Row(
              children: [
                Expanded(child: header),
                SizedBox(width: context.getRSize(16)),
                SizedBox(width: 280, child: _tabs()),
                SizedBox(width: context.getRSize(24)),
                if (_tab == _Tab.overview) ...[
                  _previousArrow(),
                  SizedBox(width: context.getRSize(12)),
                  Text(payrollMonthLabel(_month), style: context.boldStyle(16)),
                  SizedBox(width: context.getRSize(12)),
                  _nextArrow(),
                ] else ...[
                  OutlinedButton.icon(
                    key: PayrollHistoryKeys.monthPicker,
                    onPressed: _chooseMonth,
                    icon: Icon(AppIcons.calendar, size: context.getRSize(18)),
                    label: Text(
                      _rangeLabel(),
                      style: context
                          .boldStyle(15)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  AppButton(
                    key: const ValueKey('payroll-print-report'),
                    text: _printing ? 'Printing…' : 'Print Report',
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.small,
                    isFullWidth: false,
                    onPressed: _printing
                        ? null
                        : () => unawaited(_printReport()),
                  ),
                ],
                SizedBox(width: context.getRSize(8)),
                const PayrollLiveBell(),
              ],
            ),
    );
  }

  /// "1 to 30 Nov 2026".
  String _rangeLabel() {
    final parts = _month.split('-');
    final last = DateTime(int.parse(parts[0]), int.parse(parts[1]) + 1, 0);
    return '1 to ${DateFormat('d MMM y').format(last)}';
  }

  Future<void> _chooseMonth() async {
    final picked = await pickPayrollMonth(context, current: _month);
    if (picked != null && picked.isNotEmpty && mounted) {
      setState(() => _month = picked);
    }
  }

  Widget _scaffold({
    required PreferredSizeWidget appBar,
    required Widget body,
    Widget? fab,
  }) => DecoratedBox(
    decoration: AppDecorations.pageBackground(context),
    child: Scaffold(
      backgroundColor: Colors.transparent,
      // One line: test/tour/drawer_presence_ban_test.dart reads it line by line.
      // dart format off
      drawer: context.isRailLayout ? null : const AppDrawer(activeRoute: 'payroll'),
      // dart format on
      appBar: appBar,
      body: DrawerHost(child: SafeArea(top: false, bottom: false, child: body)),
      floatingActionButton: fab,
    ),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final wide = context.isWideLayout;
    final appBar = _topBar(context, wide: wide);
    // Body guard (hard rule #6): the drawer hides the entry, but a live
    // revocation while the screen is open must empty it too.
    if (!Gates.managePayroll.allows(ref)) {
      return _scaffold(
        appBar: appBar,
        body: const Center(
          child: Text('You no longer have access to Payroll.'),
        ),
      );
    }
    final view = ref.watch(payrollMonthViewProvider(_month));
    final workers = ref.watch(payrollWorkersProvider).valueOrNull ?? const [];
    final hasWorkers = workers.any((w) => !w.isRemoved);

    final Widget body;
    if (wide) {
      body = _tab == _Tab.overview
          ? _TabletOverview(
              view: view,
              workers: workers,
              staffFilter: _staffFilter,
              selectedId: _selectedWorkerId,
              onStaffFilter: (f) => setState(() => _staffFilter = f),
              onSelect: _openWorker,
              onChangeAllowances: _openAllowances,
              onAddWorker: () => openWorkerForm(context),
              onSeeAll: (id) => setState(() {
                _tab = _Tab.history;
                _historyWorkerId = id;
              }),
            )
          : PayrollHistoryTablet(
              month: _month,
              workerId: _historyWorkerId,
              kind: _historyKind,
              onWorkerChanged: (id) => setState(() => _historyWorkerId = id),
              onKindChanged: (k) => setState(() => _historyKind = k),
            );
    } else {
      final Widget phone = _tab == _Tab.overview
          ? _PhoneOverview(
              view: view,
              workers: workers,
              staffFilter: _staffFilter,
              showRemoved: _showRemoved,
              atThisMonth: _atThisMonth,
              previous: _previousArrow(),
              next: _nextArrow(),
              tabs: _tabs(),
              onStaffFilter: (f) => setState(() => _staffFilter = f),
              onToggleRemoved: () =>
                  setState(() => _showRemoved = !_showRemoved),
              onOpen: _openWorker,
              onChangeAllowances: _openAllowances,
              onAddWorker: () => openWorkerForm(context),
            )
          : PayrollHistoryPhone(
              month: _month,
              workerId: _historyWorkerId,
              kind: _historyKind,
              header: Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(14)),
                child: _tabs(),
              ),
              onMonthChanged: (m) {
                if (m != null) setState(() => _month = m);
              },
              onWorkerChanged: (id) => setState(() => _historyWorkerId = id),
              onKindChanged: (k) => setState(() => _historyKind = k),
            );
      body = AppRefreshWrapper(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kPayrollColumnMaxWidth),
            child: phone,
          ),
        ),
      );
    }

    return _scaffold(
      appBar: appBar,
      body: body,
      fab: wide
          ? null
          : AppFAB(
              key: PayrollKeys.addButton,
              heroTag: 'payroll_fab',
              icon: AppIcons.add,
              tooltip: 'Add',
              onPressed: () => _openAdd(hasWorkers),
            ),
    );
  }
}

// ─── Shared overview pieces ──────────────────────────────────────────────────

class _EmptyStaff extends StatelessWidget {
  const _EmptyStaff({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final muted = payrollMuted(context);
    return Padding(
      padding: EdgeInsets.all(context.getRSize(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const IconTile(icon: AppIcons.payroll, tone: IconTileTone.neutral),
          SizedBox(height: context.getRSize(12)),
          Text('No staff on Payroll yet', style: context.boldStyle(16)),
          SizedBox(height: context.getRSize(6)),
          Text(
            'Add the people you pay. Nobody is added for you.',
            textAlign: TextAlign.center,
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(14)),
          AppButton(
            key: PayrollKeys.addWorker,
            text: 'Add Staff to Payroll',
            icon: AppIcons.userAdd,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

/// "Salaries to pay this month": the bill, how far through it, and what came
/// off it.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.view, this.tablet = false});

  final PayrollMonthView view;
  final bool tablet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = payrollMuted(context);
    final label = context.semiBoldStyle(14).copyWith(color: muted);
    final thisMonth = view.month == payrollMonthKey(DateTime.now());
    final heading = thisMonth
        ? 'Salaries to pay this month'
        : 'Salaries for ${payrollMonthLabel(view.month)}';
    final note = [
      if (view.advancesKobo > 0) '${_money(view.advancesKobo)} in advances',
      if (view.repaymentsKobo > 0)
        '${_money(view.repaymentsKobo)} in loan repayments',
    ].join(' and ');
    return PayrollCard(
      key: const ValueKey('payroll-summary'),
      padding: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(heading, style: label)),
              if (tablet)
                Text(
                  '${(view.paidShare * 100).round()}% paid',
                  style: context.regularStyle(14).copyWith(color: muted),
                ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          Text(_money(view.totalKobo), style: context.boldStyle(34)),
          SizedBox(height: context.getRSize(12)),
          PayrollProgressBar(value: view.paidShare),
          SizedBox(height: context.getRSize(12)),
          if (tablet)
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: 'Paid ',
                      style: context.regularStyle(15),
                      children: [
                        TextSpan(
                          text: _money(view.paidKobo),
                          style: context.boldStyle(15),
                        ),
                      ],
                    ),
                  ),
                ),
                Text.rich(
                  TextSpan(
                    text: 'Still to pay ',
                    style: context.regularStyle(15),
                    children: [
                      TextSpan(
                        text: _money(view.leftKobo),
                        style: context
                            .boldStyle(15)
                            .copyWith(color: t.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ],
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Paid', style: label),
                      Text(_money(view.paidKobo), style: context.boldStyle(18)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Still to pay', style: label),
                    Text(
                      _money(view.leftKobo),
                      style: context
                          .boldStyle(18)
                          .copyWith(color: t.colorScheme.primary),
                    ),
                  ],
                ),
              ],
            ),
            if (note.isNotEmpty) ...[
              SizedBox(height: context.getRSize(10)),
              Divider(height: 1, color: t.dividerColor),
              SizedBox(height: context.getRSize(10)),
              Text(
                'After taking out $note.',
                style: context.regularStyle(14).copyWith(color: muted),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Today's Daily Allowances. They post themselves, so the only action is to
/// change or cancel one.
class _TodayAllowancesCard extends StatelessWidget {
  const _TodayAllowancesCard({required this.view, required this.onChange});

  final PayrollMonthView view;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final count = view.todayAllowanceStaff;
    return PayrollCard(
      padding: 14,
      child: Row(
        children: [
          const PayrollKindIcon(kind: PayrollKind.allowance),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Today's allowances", style: context.boldStyle(16)),
                Text(
                  count == 0
                      ? 'None today'
                      : '$count staff, ${_money(view.todayAllowanceKobo)}',
                  style: context
                      .regularStyle(14)
                      .copyWith(color: payrollMuted(context)),
                ),
              ],
            ),
          ),
          AppButton(
            key: PayrollKeys.changeAllowances,
            text: 'Change',
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.small,
            isFullWidth: false,
            onPressed: onChange,
          ),
        ],
      ),
    );
  }
}

class _StaffChips extends StatelessWidget {
  const _StaffChips({
    required this.view,
    required this.filter,
    required this.onChanged,
    this.trailing,
  });

  final PayrollMonthView view;
  final _StaffFilter filter;
  final ValueChanged<_StaffFilter> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: context.getRSize(8),
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final (f, label) in [
        (_StaffFilter.all, 'All ${view.rows.length}'),
        (_StaffFilter.unpaid, 'Unpaid ${view.unpaidCount}'),
        (_StaffFilter.paid, 'Paid ${view.paidCount}'),
      ])
        PayrollPillChip(
          key: ValueKey('payroll-staff-filter-${f.name}'),
          label: label,
          selected: filter == f,
          onTap: () => onChanged(f),
        ),
      ?trailing,
    ],
  );
}

List<PayrollWorkerMonth> _filtered(PayrollMonthView view, _StaffFilter f) =>
    switch (f) {
      _StaffFilter.all => view.rows,
      _StaffFilter.unpaid => view.rows.where((r) => !r.isPaid).toList(),
      _StaffFilter.paid => view.rows.where((r) => r.isPaid).toList(),
    };

/// One worker in the staff list.
class _StaffRow extends ConsumerWidget {
  const _StaffRow({
    required this.row,
    required this.onTap,
    this.compact = false,
    this.selected = false,
  });

  final PayrollWorkerMonth row;
  final VoidCallback onTap;

  /// The tablet's shorter wording ("pays 28th").
  final bool compact;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = row.worker;
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final store =
        stores.where((s) => s.id == w.storeId).firstOrNull?.name ?? '';
    final role = payrollWorkerRole(w, store);
    final when = row.isPaid
        ? 'paid ${payrollShortDay(row.paidOn ?? '')}'
        : compact
        ? 'pays ${w.paydayDay == null ? 'last day' : payrollOrdinal(w.paydayDay!)}'
        : 'pays on ${payrollPaydayPhrase(w)}';
    return PayrollCard(
      key: PayrollKeys.workerRow(w.id),
      padding: 14,
      selected: selected,
      onTap: onTap,
      child: Row(
        children: [
          PayrollAvatar(name: w.name, size: 52, strong: selected),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  payrollName(w),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.boldStyle(16),
                ),
                Text(
                  '$role, $when',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .regularStyle(14)
                      .copyWith(color: payrollMuted(context)),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_money(row.cashKobo), style: context.boldStyle(16)),
              SizedBox(height: context.getRSize(4)),
              PayrollStatusPill(paid: row.isPaid, bare: compact),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final muted = payrollMuted(context);
    return Expanded(
      child: PayrollCard(
        padding: 14,
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: context.semiBoldStyle(14).copyWith(color: muted),
              ),
              SizedBox(height: context.getRSize(4)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: context.boldStyle(24)),
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                detail,
                style: context.regularStyle(13).copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Phone ───────────────────────────────────────────────────────────────────

class _PhoneOverview extends StatelessWidget {
  const _PhoneOverview({
    required this.view,
    required this.workers,
    required this.staffFilter,
    required this.showRemoved,
    required this.atThisMonth,
    required this.previous,
    required this.next,
    required this.tabs,
    required this.onStaffFilter,
    required this.onToggleRemoved,
    required this.onOpen,
    required this.onChangeAllowances,
    required this.onAddWorker,
  });

  final PayrollMonthView view;
  final List<PayrollWorkerData> workers;
  final _StaffFilter staffFilter;
  final bool showRemoved;
  final bool atThisMonth;
  final Widget previous;
  final Widget next;
  final Widget tabs;
  final ValueChanged<_StaffFilter> onStaffFilter;
  final VoidCallback onToggleRemoved;
  final ValueChanged<String> onOpen;
  final VoidCallback onChangeAllowances;
  final VoidCallback onAddWorker;

  @override
  Widget build(BuildContext context) {
    final gap = SizedBox(height: context.getRSize(14));
    final muted = payrollMuted(context);
    final staffCount = view.rows.length;
    final shownIds = view.rows.map((r) => r.worker.id).toSet();
    final removed = workers
        .where((w) => w.isRemoved && !shownIds.contains(w.id))
        .toList();
    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(96) + context.deviceBottomPadding,
      ),
      children: [
        Row(
          children: [
            previous,
            Expanded(
              child: Column(
                children: [
                  Text(
                    payrollMonthLabel(view.month),
                    style: context.boldStyle(18),
                  ),
                  Text(
                    '$staffCount staff on payroll',
                    style: context.regularStyle(14).copyWith(color: muted),
                  ),
                ],
              ),
            ),
            next,
          ],
        ),
        gap,
        tabs,
        const PayrollPendingApprovalsCard(),
        gap,
        if (staffCount == 0 && removed.isEmpty)
          _EmptyStaff(onAdd: onAddWorker)
        else ...[
          _SummaryCard(view: view),
          gap,
          if (atThisMonth) ...[
            _TodayAllowancesCard(view: view, onChange: onChangeAllowances),
            gap,
          ],
          Row(
            children: [
              _StatTile(
                label: 'Allowances paid',
                value: _money(view.allowancesKobo),
                detail: '${view.allowanceDays} staff-days',
              ),
              SizedBox(width: context.getRSize(12)),
              _StatTile(
                label: 'Bonuses paid',
                value: _money(view.bonusesKobo),
                detail:
                    '${view.bonusCount} '
                    '${view.bonusCount == 1 ? 'bonus' : 'bonuses'}',
              ),
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          Row(
            children: [
              _StatTile(
                label: 'Advances given',
                value: _money(view.advancesKobo),
                detail: 'Taken from salary',
              ),
              SizedBox(width: context.getRSize(12)),
              _StatTile(
                label: 'Loans still owed',
                value: _money(view.loansOwedKobo),
                detail: '${view.loanStaff} staff paying back',
              ),
            ],
          ),
          SizedBox(height: context.getRSize(20)),
          Row(
            children: [
              Expanded(child: Text('Staff', style: context.boldStyle(20))),
              Text(
                'Tap a name to see their pay',
                style: context.regularStyle(14).copyWith(color: muted),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          _StaffChips(
            view: view,
            filter: staffFilter,
            onChanged: onStaffFilter,
          ),
          SizedBox(height: context.getRSize(6)),
          for (final r in _filtered(view, staffFilter))
            Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(10)),
              child: _StaffRow(row: r, onTap: () => onOpen(r.worker.id)),
            ),
          if (removed.isNotEmpty) ...[
            Center(
              child: TextButton(
                key: PayrollKeys.showRemoved,
                onPressed: onToggleRemoved,
                child: Text(
                  showRemoved
                      ? 'Hide removed staff'
                      : 'Show removed staff (${removed.length})',
                ),
              ),
            ),
            if (showRemoved)
              for (final w in removed)
                Padding(
                  padding: EdgeInsets.only(bottom: context.getRSize(10)),
                  child: PayrollCard(
                    key: PayrollKeys.workerRow(w.id),
                    padding: 14,
                    onTap: () => onOpen(w.id),
                    child: Row(
                      children: [
                        PayrollAvatar(name: w.name, size: 44),
                        SizedBox(width: context.getRSize(12)),
                        Expanded(
                          child: Text(
                            payrollName(w),
                            style: context.boldStyle(15),
                          ),
                        ),
                        Text(
                          'Removed',
                          style: context
                              .regularStyle(13)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ],
      ],
    );
  }
}

// ─── Tablet ──────────────────────────────────────────────────────────────────

class _TabletOverview extends ConsumerWidget {
  const _TabletOverview({
    required this.view,
    required this.workers,
    required this.staffFilter,
    required this.selectedId,
    required this.onStaffFilter,
    required this.onSelect,
    required this.onChangeAllowances,
    required this.onAddWorker,
    required this.onSeeAll,
  });

  final PayrollMonthView view;
  final List<PayrollWorkerData> workers;
  final _StaffFilter staffFilter;
  final String? selectedId;
  final ValueChanged<_StaffFilter> onStaffFilter;
  final ValueChanged<String> onSelect;
  final VoidCallback onChangeAllowances;
  final VoidCallback onAddWorker;
  final ValueChanged<String> onSeeAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final rows = _filtered(view, staffFilter);
    final chosen =
        view.rows.where((r) => r.worker.id == selectedId).firstOrNull ??
        rows.firstOrNull;
    final atThisMonth = view.month == payrollMonthKey(DateTime.now());
    final gap = SizedBox(height: context.getRSize(14));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: kPayrollSidePaneWidth,
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: t.dividerColor)),
          ),
          child: AppRefreshWrapper(
            child: ListView(
              padding: EdgeInsets.all(context.getRSize(20)),
              children: [
                const PayrollPendingApprovalsCard(),
                if (view.rows.isEmpty)
                  _EmptyStaff(onAdd: onAddWorker)
                else ...[
                  _SummaryCard(view: view, tablet: true),
                  gap,
                  if (atThisMonth) ...[
                    _TodayAllowancesCard(
                      view: view,
                      onChange: onChangeAllowances,
                    ),
                    gap,
                  ],
                  _StaffChips(
                    view: view,
                    filter: staffFilter,
                    onChanged: onStaffFilter,
                    trailing: IconButton(
                      key: PayrollKeys.addWorker,
                      tooltip: 'Add Staff to Payroll',
                      onPressed: onAddWorker,
                      icon: Icon(AppIcons.userAdd, size: context.getRSize(22)),
                    ),
                  ),
                  SizedBox(height: context.getRSize(6)),
                  for (final r in rows)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.getRSize(10)),
                      child: _StaffRow(
                        row: r,
                        compact: true,
                        selected: r.worker.id == chosen?.worker.id,
                        onTap: () => onSelect(r.worker.id),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: chosen == null
              ? const SizedBox.shrink()
              : _TabletWorker(
                  row: chosen,
                  onSeeAll: () => onSeeAll(chosen.worker.id),
                ),
        ),
      ],
    );
  }
}

class _TabletWorker extends ConsumerWidget {
  const _TabletWorker({required this.row, required this.onSeeAll});

  final PayrollWorkerMonth row;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final w = row.worker;
    final muted = payrollMuted(context);
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final store =
        stores.where((s) => s.id == w.storeId).firstOrNull?.name ?? '';
    final allowance = w.dailyAllowanceKobo > 0
        ? ', allowance ${_money(w.dailyAllowanceKobo)} a day'
        : '';
    final pays = w.paydayDay == null
        ? 'paid on the last day'
        : 'paid on the ${payrollOrdinal(w.paydayDay!)}';
    final recent = payrollWorkerHistory(ref, w).take(5).toList();
    final first = payrollName(w).split(' ').first;
    final pad = EdgeInsets.symmetric(
      horizontal: context.getRSize(20),
      vertical: context.getRSize(14),
    );
    final head = context.boldStyle(14).copyWith(color: muted);
    final gapX = SizedBox(width: context.getRSize(16));
    return LayoutBuilder(
      builder: (context, box) {
        // A smaller tablet: the buttons drop under the name and the loan under
        // the other two cards.
        final narrow = box.maxWidth < kPayrollThreeCardsMinWidth;
        return ListView(
          padding: EdgeInsets.all(context.getRSize(24)),
          children: [
            Row(
              children: [
                PayrollAvatar(name: w.name, size: 72, strong: true),
                SizedBox(width: context.getRSize(16)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              payrollName(w),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.boldStyle(26),
                            ),
                          ),
                          IconButton(
                            key: PayrollKeys.editWorker,
                            tooltip: 'Edit',
                            onPressed: () => openWorkerForm(context, worker: w),
                            icon: Icon(
                              AppIcons.edit,
                              size: context.getRSize(20),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${payrollWorkerRole(w, store)}. Salary '
                        '${_money(w.monthlySalaryKobo)} a month$allowance, $pays.',
                        style: context.regularStyle(15).copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                if (!narrow) ...[
                  gapX,
                  PayrollWorkerActions(row: row, vertical: false),
                ],
              ],
            ),
            if (narrow) ...[
              SizedBox(height: context.getRSize(14)),
              Align(
                alignment: Alignment.centerRight,
                child: PayrollWorkerActions(row: row, vertical: false),
              ),
            ],
            SizedBox(height: context.getRSize(20)),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: PayrollSalaryCard(row: row)),
                  gapX,
                  Expanded(child: PayrollOnTheDayCard(row: row, tablet: true)),
                  if (!narrow) ...[
                    gapX,
                    Expanded(child: PayrollLoanCard(row: row, showEmpty: true)),
                  ],
                ],
              ),
            ),
            if (narrow && row.loan.hasLoan) ...[
              SizedBox(height: context.getRSize(16)),
              PayrollLoanCard(row: row),
            ],
            SizedBox(height: context.getRSize(20)),
            DecoratedBox(
              decoration: AppDecorations.card(
                context,
                radius: AppSpacing.borderRadiusL,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: pad,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            "$first's payment history",
                            style: context.boldStyle(18),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('payroll-see-all'),
                          onPressed: onSeeAll,
                          child: Text('See all', style: context.boldStyle(15)),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    color: t.inputDecorationTheme.fillColor,
                    padding: pad,
                    child: Row(
                      children: [
                        Expanded(flex: 2, child: Text('Date', style: head)),
                        Expanded(flex: 4, child: Text('What', style: head)),
                        Expanded(flex: 2, child: Text('Paid by', style: head)),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'Amount',
                            textAlign: TextAlign.end,
                            style: head,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (recent.isEmpty)
                    Padding(
                      padding: pad,
                      child: Text(
                        'No payments yet.',
                        style: context.regularStyle(15).copyWith(color: muted),
                      ),
                    ),
                  for (var i = 0; i < recent.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: t.dividerColor),
                    InkWell(
                      onTap: () => openPayrollRow(context, ref, recent[i]),
                      child: Padding(
                        padding: pad,
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                payrollMediumDay(recent[i].date),
                                style: context
                                    .regularStyle(15)
                                    .copyWith(color: muted),
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: Text(
                                [
                                  recent[i].title,
                                  if (recent[i].kind == PayrollKind.bonus &&
                                      recent[i].details != null)
                                    recent[i].details!,
                                  if (recent[i].kind == PayrollKind.advance &&
                                      recent[i].details != null)
                                    recent[i].details!.toLowerCase(),
                                  if (recent[i].kind == PayrollKind.loan &&
                                      !recent[i].isMoneyIn &&
                                      recent[i].details != null)
                                    recent[i].details!,
                                ].join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.boldStyle(15),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                payrollPaymentMethodLabel(recent[i].method),
                                style: context.regularStyle(15),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                payrollRowAmount(recent[i]),
                                textAlign: TextAlign.end,
                                style: context.boldStyle(15),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
