import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

/// Unscaled height of the pinned tab bar. The tabs stack an icon above their
/// label, which is Flutter's taller `_kTextAndIconTabHeight` form.
const double _kTabBarHeight = 72;

/// Key prefix on every expense row in the Expenses tab, so a viewport test can
/// assert a *complete* row is laid out and hit-testable (PRD #239's second
/// assertion — a list starved to zero height reports no overflow at all).
const String kExpenseRowKeyPrefix = 'expense-row-';

/// Friendly label for an expense payment-method code (§20). Codes are
/// 'cash'/'transfer'/'pos'/'card'/'other'.
String _paymentMethodLabel(String? code) {
  switch (code) {
    case 'cash':
      return 'Cash';
    case 'transfer':
      return 'Bank Transfer';
    case 'pos':
      return 'POS card';
    case 'card':
      return 'Card';
    case 'other':
      return 'Other';
    default:
      return 'Other';
  }
}

class ExpensesScreen extends ConsumerStatefulWidget {
  final String? initialPeriod;
  const ExpensesScreen({super.key, this.initialPeriod});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _periodFilter = 'This Month'; // §20.1/§30.6 default
  DateTimeRange? _customRange;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    if (widget.initialPeriod != null) {
      _periodFilter = widget.initialPeriod!;
      if (_periodFilter.startsWith('Custom:')) {
        final (start, end) = parseCustomDateRange(_periodFilter);
        if (start != null && end != null) {
          _customRange = DateTimeRange(start: start, end: end);
        }
      }
    }
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  bool _isInPeriod(DateTime date, String period) =>
      isDateInPeriod(date, period);

  /// Period labels this viewer may choose (§19.2/§30.11 — roles below Manager
  /// are capped to Today/This Week/This Month).
  List<String> get _periodOptions => datePeriodLabelsForRole(
    managerUp: Gates.seeExtendedDateRanges.allows(ref),
  );

  /// [_periodFilter] clamped into [_periodOptions], so the dropdown value and
  /// the list filter agree for capped viewers.
  String get _effectivePeriod {
    final isCustom = _periodFilter.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _periodFilter;
    if (_periodOptions.contains(dropdownValue)) {
      return _periodFilter;
    }
    return _periodOptions.first;
  }

  /// Resolves a recordedBy user id to a name; never shows a raw UUID (rule #4).
  String _recordedByName(String? userId, Map<String, UserData> users) {
    if (userId == null) return '—';
    final u = users[userId];
    if (u == null || u.name.trim().isEmpty) return '—';
    return u.name;
  }

  Widget _page({
    required PreferredSizeWidget appBar,
    required Widget body,
    Widget? fab,
  }) {
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        drawer: context.isRailLayout
            ? null
            : const AppDrawer(activeRoute: 'expenses'),
        appBar: appBar,
        body: DrawerHost(
          // Side insets (a cutout, a sideways nav bar) are cleared here; under
          // MainLayout they are already removed, so this is a no-op there.
          child: SafeArea(top: false, bottom: false, child: body),
        ),
        floatingActionButton: fab,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    // Hard rule #6 (load-bearing): the Expenses screen IS the expense
    // report/list, so it is body-guarded on Gates.viewExpenses
    // (`reports.see_expenses`) — the drawer item and the Home "Total Expenses"
    // card gate on the same key, but no alternate route may expose the report.
    // Guarded.screen waits for the permission set to resolve first (no denial
    // flash), and — Expenses being a MainLayout tab — the loading/denied
    // surfaces keep the drawer + app-bar chrome (nav stays reachable) instead
    // of the default full-screen scaffold. The Add-Expense FAB additionally
    // cites Gates.addExpense.
    return Guarded.screen(
      gate: Gates.viewExpenses,
      loading: _page(
        appBar: _buildAppBar(context),
        body: const SizedBox.shrink(),
      ),
      denied: _page(
        appBar: _buildAppBar(context),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'You don’t have access to Expenses.',
              textAlign: TextAlign.center,
              style: context.regularStyle(14).copyWith(color: _subtext),
            ),
          ),
        ),
      ),
      builder: _buildExpenses,
    );
  }

  /// The Expenses body, shown once [Gates.viewExpenses] has resolved and
  /// granted. Split out of [build] so the `Guarded.screen` guard above owns
  /// the permissions-ready / denial decision.
  Widget _buildExpenses(BuildContext context) {
    return _page(
      appBar: _buildAppBar(context),
      body: Builder(
        builder: (context) {
          if (ref.watch(zeroStoresEmptySurfaceProvider)) {
            return const FirstRunEmptyState();
          }
          // §20.8 — scoped to the active store (picker); "All Stores" = aggregate.
          final allExpenses = ref.watch(viewerScopedExpensesProvider);
          final categoryNames =
              ref.watch(expenseCategoryNamesProvider).valueOrNull ??
              const <String, String>{};
          final users =
              ref.watch(usersByBusinessProvider).valueOrNull ??
              const <String, UserData>{};

          // §20.8 — active-store scope: caption it (when the picker is in play)
          // and, under "All Stores", show which store recorded each expense.
          final scopeStoreId = ref.watch(expenseScopeStoreIdProvider);
          final stores =
              ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
          final storeNameById = {for (final s in stores) s.id: s.name};
          final showScope = ref.watch(selectableStoresProvider).length > 1;
          final scopeLabel = scopeStoreId == null
              ? 'All Stores'
              : (storeNameById[scopeStoreId] ?? 'Store');
          final showRowStore = scopeStoreId == null && stores.length > 1;

          // Approved expenses inside the selected period (the headline total).
          final periodApproved = allExpenses
              .where(
                (e) =>
                    e.expense.status == 'approved' &&
                    _isInPeriod(e.expense.expenseDate, _effectivePeriod),
              )
              .toList();
          final approvedTotal = periodApproved.fold<int>(
            0,
            (sum, e) => sum + e.expense.amountKobo,
          );

          // §20.1/§20.3 — the monthly budget bar is always visible and always
          // reflects the last-30-days window, independent of the period
          // selector above the list.
          final monthly = allExpenses
              .where((e) => _isInPeriod(e.expense.expenseDate, 'This Month'))
              .toList();
          final budgetSpentKobo = monthly
              .where((e) => e.expense.status == 'approved')
              .fold<int>(0, (sum, e) => sum + e.expense.amountKobo);
          final budgetPendingKobo = monthly
              .where((e) => e.expense.status == 'pending')
              .fold<int>(0, (sum, e) => sum + e.expense.amountKobo);

          // One scrollable surface (PRD #239 / #256): the Total Expenses figure
          // with its period selector and the Monthly Budget card scroll away,
          // the tab bar pins beneath them, and each tab is its own scroll view.
          // Every sliver is capped at 720dp and centred through its own side
          // gutter (width only — no scroll view is given a height).
          return AppRefreshWrapper(
            child: TabbedSliverScaffold(
              controller: _tabController,
              // The tabs carry an icon above their label, so the bar needs the
              // full icon+text height; PinnedTabBarDelegate floors it at the
              // 48dp tap target if the responsive scale resolves shorter.
              tabBarExtent: max(
                kMinInteractiveDimension,
                context.getRSize(_kTabBarHeight),
              ),
              headerSlivers: [
                SliverToBoxAdapter(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: expenseGutter(
                          context,
                          constraints.maxWidth,
                        ),
                        vertical: context.getRSize(16),
                      ),
                      child: _buildHeaderArea(
                        context,
                        approvedTotalKobo: approvedTotal,
                        budgetSpentKobo: budgetSpentKobo,
                        budgetPendingKobo: budgetPendingKobo,
                        scopeLabel: showScope ? scopeLabel : null,
                      ),
                    ),
                  ),
                ),
              ],
              tabBar: _buildTabBar(context),
              tabViews: [
                TabSliverView(
                  storageKey: 'expenses-list',
                  slivers: _expensesTabSlivers(
                    context,
                    allExpenses: allExpenses,
                    categoryNames: categoryNames,
                    users: users,
                    storeNameById: storeNameById,
                    showRowStore: showRowStore,
                  ),
                ),
                TabSliverView(
                  storageKey: 'expenses-stats',
                  slivers: _statsTabSlivers(
                    context,
                    periodApproved: periodApproved,
                    categoryNames: categoryNames,
                    users: users,
                    approvedTotalKobo: approvedTotal,
                  ),
                ),
              ],
            ),
          );
        },
      ),
      fab:
          (ref.watch(allStoresProvider).valueOrNull?.isNotEmpty == true &&
              !ref.watch(zeroStoresEmptySurfaceProvider) &&
              Gates.addExpense.allows(ref))
          ? AppFAB(
              heroTag: 'expenses_fab',
              onPressed: () => AddExpenseScreen.show(context),
              icon: AppIcons.add,
              label: 'Add Expense',
            )
          : null,
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return ExpenseTopBar(
      key: ExpenseKeys.topBar,
      height: expenseTopBarHeight(context),
      header: ScreenHeader(
        icon: AppIcons.expenses,
        title: 'Expenses',
        subtitle: ref.watch(activeStoreLabelProvider),
        leading: context.isRailLayout
            ? null
            : const SizedBox.square(
                dimension: kMinInteractiveDimension,
                child: MenuButton(),
              ),
        actions: const [ExpenseLiveBell()],
      ),
    );
  }

  /// The tab bar. It used to hang off the app bar's `bottom`, where it was
  /// fixed chrome above a body that had already been starved; under the shared
  /// scaffold it is the pinned header below the scroll-away summary, so it
  /// stays visible while the content beneath it scrolls (PRD #239 / #256).
  Widget _buildTabBar(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: ExpenseWidthCap(
        child: TabBar(
          controller: _tabController,
          labelColor: primary,
          unselectedLabelColor: _subtext,
          indicatorColor: primary,
          indicatorWeight: 3,
          labelStyle: context.boldStyle(13),
          unselectedLabelStyle: context.semiBoldStyle(13),
          tabs: const [
            Tab(icon: Icon(AppIcons.list, size: 16), text: 'Expenses'),
            Tab(icon: Icon(AppIcons.chartPie, size: 16), text: 'Stats'),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderArea(
    BuildContext context, {
    required int approvedTotalKobo,
    required int budgetSpentKobo,
    required int budgetPendingKobo,
    String? scopeLabel,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpenseCardShell(
          key: ExpenseKeys.totalCard,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Bounded so a large total or a long store name shrinks or
              // truncates instead of pushing the period selector off a
              // 320dp-wide phone.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Expenses',
                      style: context
                          .semiBoldStyle(13)
                          .copyWith(color: _subtext),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatCurrency(approvedTotalKobo / 100.0),
                        style: context.boldStyle(24).copyWith(color: _text),
                      ),
                    ),
                    // §20.8 — active-store scope caption (only when the picker
                    // is in play, i.e. more than one selectable store).
                    if (scopeLabel != null) ...[
                      SizedBox(height: context.getRSize(4)),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            AppIcons.store,
                            size: context.getRSize(10),
                            color: _subtext,
                          ),
                          SizedBox(width: context.getRSize(5)),
                          Flexible(
                            child: Text(
                              scopeLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context
                                  .semiBoldStyle(11)
                                  .copyWith(color: _subtext),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              AppDropdown<String>(
                value: _effectivePeriod.startsWith('Custom:')
                    ? 'Custom'
                    : _effectivePeriod,
                width: context.getRSize(130),
                items: _periodOptions.map((String val) {
                  return DropdownMenuItem<String>(value: val, child: Text(val));
                }).toList(),
                onChanged: (val) async {
                  if (val == 'Custom') {
                    final range = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                      initialDateRange: _customRange,
                      builder: (context, child) =>
                          Theme(data: Theme.of(context), child: child!),
                    );
                    if (range != null) {
                      setState(() {
                        _customRange = range;
                        _periodFilter =
                            'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
                      });
                    }
                  } else if (val != null) {
                    setState(() {
                      _periodFilter = val;
                      _customRange = null;
                    });
                  }
                },
              ),
            ],
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        // §20.1/§20.3: monthly budget bar — always visible; reflects the
        // current calendar month regardless of the selected period.
        _buildBudgetBar(
          context,
          spentKobo: budgetSpentKobo,
          pendingKobo: budgetPendingKobo,
        ),
      ],
    );
  }

  // ─────────────────────────── BUDGET BAR (§20.3) ─────────────────────────────

  Widget _buildBudgetBar(
    BuildContext context, {
    required int spentKobo,
    required int pendingKobo,
  }) {
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final budgets = ref.watch(expenseBudgetsProvider).valueOrNull ?? const [];
    // §20.8 — the goal follows the active store (null = business-wide under
    // "All Stores"), matching the list/spend scope above it.
    final scopeStoreId = ref.watch(expenseScopeStoreIdProvider);
    final goalKobo = resolveMonthlyBudgetKobo(budgets, scopeStoreId);

    return ExpenseCardShell(
      key: ExpenseKeys.budgetCard,
      child: goalKobo == null
          ? _buildBudgetUnset(context, isCeo: isCeo, scopeStoreId: scopeStoreId)
          : _buildBudgetSet(
              context,
              isCeo: isCeo,
              scopeStoreId: scopeStoreId,
              spentKobo: spentKobo,
              pendingKobo: pendingKobo,
              goalKobo: goalKobo,
            ),
    );
  }

  Widget _buildBudgetUnset(
    BuildContext context, {
    required bool isCeo,
    required String? scopeStoreId,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // The caption yields width to the button rather than pushing it off the
        // edge: at 320dp this row wanted 135dp more than it had (#256).
        Expanded(
          child: Row(
            children: [
              Icon(
                AppIcons.target,
                size: context.getRSize(14),
                color: _subtext,
              ),
              SizedBox(width: context.getRSize(8)),
              Flexible(
                child: Text(
                  'No monthly budget set',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.boldStyle(13).copyWith(color: _subtext),
                ),
              ),
            ],
          ),
        ),
        if (isCeo)
          AppButton(
            text: 'Set budget',
            icon: AppIcons.target,
            variant: AppButtonVariant.outline,
            size: AppButtonSize.xsmall,
            isFullWidth: false,
            onPressed: () => _openBudgetDialog(scopeStoreId, null),
          ),
      ],
    );
  }

  Widget _buildBudgetSet(
    BuildContext context, {
    required bool isCeo,
    required String? scopeStoreId,
    required int spentKobo,
    required int pendingKobo,
    required int goalKobo,
  }) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final percent = (spentKobo / goalKobo).clamp(0.0, 1.2);
    final isOver = spentKobo > goalKobo;
    final tone = isOver ? f.danger : f.green;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(AppIcons.target, size: context.getRSize(14), color: tone),
                SizedBox(width: context.getRSize(8)),
                Text(
                  'Monthly Budget',
                  style: context.boldStyle(13).copyWith(color: _subtext),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  '${(percent * 100).toStringAsFixed(1)}%',
                  style: context.boldStyle(13).copyWith(color: tone),
                ),
                if (isCeo)
                  InkWell(
                    onTap: () => _openBudgetDialog(scopeStoreId, goalKobo),
                    borderRadius: BorderRadius.circular(
                      AppSpacing.borderRadiusM,
                    ),
                    child: SizedBox.square(
                      dimension: kMinInteractiveDimension,
                      child: Icon(
                        AppIcons.edit,
                        size: context.getRSize(14),
                        color: _subtext,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        SizedBox(height: context.getRSize(8)),
        ExpenseProgressBar(value: percent > 1.0 ? 1.0 : percent, color: tone),
        SizedBox(height: context.getRSize(8)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Spent: ${formatCurrency(spentKobo / 100.0)}',
              style: context.semiBoldStyle(12).copyWith(color: _text),
            ),
            Text(
              'Goal: ${formatCurrency(goalKobo / 100.0)}',
              style: context.semiBoldStyle(12).copyWith(color: _subtext),
            ),
          ],
        ),
        if (pendingKobo > 0) ...[
          SizedBox(height: context.getRSize(6)),
          Text(
            '${formatCurrency(pendingKobo / 100.0)} pending approval',
            style: context.semiBoldStyle(12).copyWith(color: f.warning),
          ),
        ],
      ],
    );
  }

  Future<void> _openBudgetDialog(String? scopeStoreId, int? currentKobo) async {
    final controller = TextEditingController(
      text: currentKobo == null ? '' : (currentKobo / 100.0).toStringAsFixed(0),
    );
    final naira = await showDialog<double>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          scrollable: true,
          backgroundColor: _surface,
          title: Text(
            'Monthly budget',
            style: ctx.boldStyle(18).copyWith(color: _text),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set the monthly spending goal for this view.',
                style: ctx.regularStyle(13).copyWith(color: _subtext),
              ),
              SizedBox(height: context.getRSize(16)),
              AppInput(
                key: ExpenseKeys.budgetField,
                controller: controller,
                autofocus: true,
                labelText: 'Amount (naira)',
                prefixText: '$activeCurrencySymbol ',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
              ),
            ],
          ),
          actions: [
            AppButton(
              text: 'Cancel',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              onPressed: () => Navigator.pop(ctx),
            ),
            AppButton(
              text: 'Save',
              size: AppButtonSize.small,
              onPressed: () {
                final v = parseCurrency(controller.text.trim());
                if (v <= 0) {
                  Navigator.pop(ctx);
                  return;
                }
                Navigator.pop(ctx, v);
              },
            ),
          ],
        );
      },
    );

    if (naira == null) return;
    final db = ref.read(databaseProvider);
    try {
      await db.expenseBudgetsDao.setBudget(
        storeId: scopeStoreId,
        amountKobo: (naira * 100).round(),
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Monthly budget updated.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not update budget. Please try again.',
        );
      }
    }
  }

  // ─────────────────────────── EXPENSES TAB ───────────────────────────────────

  /// The Expenses tab, as slivers. Nothing here may depend on a supplied
  /// height — that dependency is the defect this screen was fixed for.
  List<Widget> _expensesTabSlivers(
    BuildContext context, {
    required List<ExpenseWithCategory> allExpenses,
    required Map<String, String> categoryNames,
    required Map<String, UserData> users,
    required Map<String, String> storeNameById,
    required bool showRowStore,
  }) {
    final canApprove = Gates.approveExpenses.allows(ref);
    final pending = canApprove
        ? allExpenses.where((e) => e.expense.status == 'pending').toList()
        : const <ExpenseWithCategory>[];

    // Period-filtered list (all statuses) for the main grouped section.
    final periodList = allExpenses
        .where((e) => _isInPeriod(e.expense.expenseDate, _effectivePeriod))
        .toList();

    if (pending.isEmpty && periodList.isEmpty) {
      return [_emptySliver(context, 'No expenses found')];
    }

    // Group the period list by resolved category name.
    final Map<String, List<ExpenseWithCategory>> grouped = {};
    for (final e in periodList) {
      final cat = _categoryName(e, categoryNames);
      grouped.putIfAbsent(cat, () => []).add(e);
    }
    final sortedCategories = grouped.keys.toList()..sort();

    return [
      SliverLayoutBuilder(
        builder: (context, constraints) => SliverPadding(
          // Capped at 720dp and centred through the side gutter; the bottom
          // clears the Add Expense FAB and the device's gesture inset so the
          // last row is never permanently covered.
          padding: EdgeInsets.only(
            left: expenseGutter(context, constraints.crossAxisExtent),
            right: expenseGutter(context, constraints.crossAxisExtent),
            bottom: context.getRSize(100) + context.deviceBottomPadding,
          ),
          sliver: SliverList.list(
            children: [
              if (pending.isNotEmpty)
                _buildPendingApprovals(
                  context,
                  pending,
                  categoryNames,
                  users,
                  storeNameById,
                  showRowStore,
                ),
              ...sortedCategories.expand((cat) {
                final catList = grouped[cat]!
                  ..sort(
                    (a, b) =>
                        b.expense.expenseDate.compareTo(a.expense.expenseDate),
                  );
                final catSum = catList.fold<int>(
                  0,
                  (s, e) => s + e.expense.amountKobo,
                );
                return [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.getRSize(4),
                      context.getRSize(20),
                      context.getRSize(4),
                      context.getRSize(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: SectionHeader(
                            title: cat.toUpperCase(),
                            variant: SectionHeaderVariant.group,
                          ),
                        ),
                        SizedBox(width: context.getRSize(8)),
                        Text(
                          formatCurrency(catSum / 100.0),
                          style: context
                              .boldStyle(13)
                              .copyWith(color: _subtext),
                        ),
                      ],
                    ),
                  ),
                  ...catList.map(
                    (e) => Padding(
                      padding: EdgeInsets.only(bottom: context.getRSize(12)),
                      child: _buildExpenseCard(
                        context,
                        e,
                        categoryNames,
                        users,
                        withMenu: true,
                        storeName: showRowStore
                            ? _storeLabel(e, storeNameById)
                            : null,
                      ),
                    ),
                  ),
                ];
              }),
            ],
          ),
        ),
      ),
    ];
  }

  /// An empty-state message as a sliver. [SliverFillRemaining] with
  /// `hasScrollBody: false` gives it the rest of the viewport when there is
  /// room and its own intrinsic height when there is not, so the message
  /// scrolls into reach instead of overflowing — which is what produced the
  /// red 26px band on a sideways phone.
  Widget _emptySliver(BuildContext context, String message) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: ExpensesEmptyMessage(message: message),
    );
  }

  String _categoryName(ExpenseWithCategory e, Map<String, String> names) {
    if (e.category != null) return e.category!.name;
    final id = e.expense.categoryId;
    if (id != null && names[id] != null) return names[id]!;
    return 'Uncategorized';
  }

  /// §20.8 — the store that recorded an expense, for the "All Stores" aggregate.
  /// Legacy rows with no `store_id` show as "Unassigned".
  String _storeLabel(ExpenseWithCategory e, Map<String, String> storeNameById) {
    final id = e.expense.storeId;
    if (id == null) return 'Unassigned';
    return storeNameById[id] ?? 'Store';
  }

  // ─────────────────────── PENDING APPROVALS (§20.4) ─────────────────────────

  Widget _buildPendingApprovals(
    BuildContext context,
    List<ExpenseWithCategory> pending,
    Map<String, String> categoryNames,
    Map<String, UserData> users,
    Map<String, String> storeNameById,
    bool showRowStore,
  ) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(4)),
      child: ExpenseCardShell(
        key: ExpenseKeys.pendingCard,
        padding: 14,
        decoration: BoxDecoration(
          color: f.warningTint,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
          border: Border.all(color: f.warningOutline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  AppIcons.history,
                  size: context.getRSize(14),
                  color: f.warning,
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    'Pending approval (${pending.length})',
                    style: context.boldStyle(13).copyWith(color: f.warning),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(10)),
            ...pending.map(
              (e) => _buildPendingRow(
                context,
                e,
                categoryNames,
                users,
                showRowStore ? _storeLabel(e, storeNameById) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingRow(
    BuildContext context,
    ExpenseWithCategory e,
    Map<String, String> categoryNames,
    Map<String, UserData> users,
    String? storeName,
  ) {
    final exp = e.expense;
    final cat = _categoryName(e, categoryNames);
    final by = _recordedByName(exp.recordedBy, users);

    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: DecoratedBox(
        decoration: AppDecorations.card(
          context,
          radius: AppSpacing.borderRadiusL,
        ),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      exp.description.isNotEmpty ? exp.description : cat,
                      style: context.boldStyle(14).copyWith(color: _text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    formatCurrency(exp.amountKobo / 100.0),
                    style: context.boldStyle(14).copyWith(color: _text),
                  ),
                ],
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                storeName == null
                    ? '$cat · by $by'
                    : '$cat · by $by · $storeName',
                style: context.regularStyle(12).copyWith(color: _subtext),
              ),
              SizedBox(height: context.getRSize(10)),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      text: 'Reject',
                      icon: AppIcons.close,
                      variant: AppButtonVariant.danger,
                      size: AppButtonSize.xsmall,
                      onPressed: () => _rejectExpense(exp),
                    ),
                  ),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(
                    child: AppButton(
                      text: 'Approve',
                      icon: AppIcons.check,
                      variant: AppButtonVariant.success,
                      size: AppButtonSize.xsmall,
                      onPressed: () => _approveExpense(exp),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _approveExpense(ExpenseData exp) async {
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    final db = ref.read(databaseProvider);

    try {
      await db.expensesDao.approveExpense(
        expenseId: exp.id,
        approverId: currentUser.id,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Expense approved.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not approve expense. Please try again.',
        );
      }
    }
  }

  Future<void> _rejectExpense(ExpenseData exp) async {
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    final reasonController = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final r = reasonController.text.trim();
            return AlertDialog(
              scrollable: true,
              backgroundColor: _surface,
              title: Text(
                'Reject expense',
                style: ctx.boldStyle(18).copyWith(color: _text),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The recorder is notified. No money moves on a rejection.',
                    style: ctx.regularStyle(13).copyWith(color: _subtext),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  AppInput(
                    key: ExpenseKeys.rejectField,
                    controller: reasonController,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    labelText: 'Reason (required)',
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                AppButton(
                  text: 'Back',
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.small,
                  onPressed: () => Navigator.pop(ctx),
                ),
                AppButton(
                  text: 'Reject',
                  icon: AppIcons.close,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.small,
                  onPressed: r.isEmpty ? null : () => Navigator.pop(ctx, r),
                ),
              ],
            );
          },
        );
      },
    );

    if (reason == null || reason.isEmpty) return;
    final db = ref.read(databaseProvider);
    try {
      await db.expensesDao.rejectExpense(
        expenseId: exp.id,
        approverId: currentUser.id,
        reason: reason,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Expense rejected.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not reject expense. Please try again.',
        );
      }
    }
  }

  // ─────────────────────────── EDIT / DELETE (§20.3) ──────────────────────────

  bool _canEdit(ExpenseData exp) {
    final isCeo = ref.read(currentUserRoleProvider)?.slug == 'ceo';
    if (isCeo) return true;
    final slug = ref.read(currentUserRoleProvider)?.slug;
    final currentUser = ref.read(authProvider).currentUser;
    final within24h =
        DateTime.now().difference(exp.createdAt) < const Duration(hours: 24);
    return exp.recordedBy == currentUser?.id &&
        within24h &&
        (slug == 'manager' || slug == 'ceo');
  }

  bool _canDelete() => ref.read(currentUserRoleProvider)?.slug == 'ceo';

  Future<void> _deleteExpense(ExpenseData exp) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _surface,
          title: Text(
            'Delete expense',
            style: ctx.boldStyle(18).copyWith(color: _text),
          ),
          content: Text(
            'This removes the expense.',
            style: ctx.regularStyle(13).copyWith(color: _subtext),
          ),
          actions: [
            AppButton(
              text: 'Cancel',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              onPressed: () => Navigator.pop(ctx, false),
            ),
            AppButton(
              text: 'Delete',
              icon: AppIcons.delete,
              variant: AppButtonVariant.danger,
              size: AppButtonSize.small,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    final db = ref.read(databaseProvider);

    try {
      await db.expensesDao.softDeleteExpense(
        expenseId: exp.id,
        performedBy: currentUser.id,
      );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Expense deleted.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not delete expense. Please try again.',
        );
      }
    }
  }

  Widget? _buildCardMenu(ExpenseData exp) {
    final canEdit = _canEdit(exp);
    final canDelete = _canDelete();
    if (!canEdit && !canDelete) return null;
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

    return PopupMenuButton<String>(
      key: ExpenseKeys.cardMenu,
      icon: Icon(
        AppIcons.moreVertical,
        size: context.getRSize(18),
        color: _subtext,
      ),
      color: _surface,
      onSelected: (value) {
        if (value == 'edit') {
          AddExpenseScreen.show(context, editing: exp);
        } else if (value == 'delete') {
          _deleteExpense(exp);
        }
      },
      itemBuilder: (ctx) => [
        if (canEdit)
          PopupMenuItem<String>(
            value: 'edit',
            child: Row(
              children: [
                Icon(AppIcons.edit, size: context.getRSize(14), color: _text),
                SizedBox(width: context.getRSize(10)),
                Text('Edit', style: ctx.mediumStyle(14).copyWith(color: _text)),
              ],
            ),
          ),
        if (canDelete)
          PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                Icon(
                  AppIcons.delete,
                  size: context.getRSize(14),
                  color: f.danger,
                ),
                SizedBox(width: context.getRSize(10)),
                Text(
                  'Delete',
                  style: ctx.mediumStyle(14).copyWith(color: f.danger),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ─────────────────────────── EXPENSE CARD ───────────────────────────────────

  Widget _buildExpenseCard(
    BuildContext context,
    ExpenseWithCategory e,
    Map<String, String> categoryNames,
    Map<String, UserData> users, {
    bool withMenu = false,
    String? storeName,
  }) {
    final exp = e.expense;
    return _ExpenseCard(
      key: ValueKey('$kExpenseRowKeyPrefix${exp.id}'),
      exp: exp,
      categoryName: _categoryName(e, categoryNames),
      recordedByName: _recordedByName(exp.recordedBy, users),
      storeName: storeName,
      trailing: withMenu ? _buildCardMenu(exp) : null,
    );
  }

  // ─────────────────────────── STATS TAB ──────────────────────────────────────

  /// The Stats tab, as slivers. See [_expensesTabSlivers].
  List<Widget> _statsTabSlivers(
    BuildContext context, {
    required List<ExpenseWithCategory> periodApproved,
    required Map<String, String> categoryNames,
    required Map<String, UserData> users,
    required int approvedTotalKobo,
  }) {
    if (periodApproved.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ExpensesEmptyMessage(message: 'No data for statistics.'),
        ),
      ];
    }

    // Category totals (approved only).
    final Map<String, int> catTotals = {};
    for (final e in periodApproved) {
      final cat = _categoryName(e, categoryNames);
      catTotals[cat] = (catTotals[cat] ?? 0) + e.expense.amountKobo;
    }
    final total = approvedTotalKobo;
    final sortedCats = catTotals.keys.toList()
      ..sort((a, b) => catTotals[b]!.compareTo(catTotals[a]!));

    // Same order as before (red, amber, emerald, blue, purple, pink), on the
    // fixed colour set (pink -> neutral).
    final colors = expenseChartColors(
      Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light,
    );

    return [
      SliverLayoutBuilder(
        builder: (context, constraints) => SliverPadding(
          padding: EdgeInsets.only(
            left: expenseGutter(context, constraints.crossAxisExtent),
            right: expenseGutter(context, constraints.crossAxisExtent),
            top: context.getRSize(16),
            bottom: context.getRSize(100) + context.deviceBottomPadding,
          ),
          sliver: SliverList.list(
            children: [
              _buildAnnualProjectionCard(context),
              SizedBox(height: context.getRSize(16)),
              _buildBudgetComparisonCard(context),
              _buildTopStaffCard(context, periodApproved, users),
              SizedBox(height: context.getRSize(8)),

              // Category Breakdown Header
              const SectionHeader(title: 'Category Breakdown'),
              SizedBox(height: context.getRSize(16)),

              ExpenseCardShell(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppSpacing.borderRadiusS,
                      ),
                      child: Row(
                        children: List.generate(sortedCats.length, (index) {
                          final cat = sortedCats[index];
                          final amt = catTotals[cat]!;
                          final flex = total == 0
                              ? 0
                              : (amt / total * 1000).toInt();
                          if (flex == 0) return const SizedBox();
                          return Expanded(
                            flex: flex,
                            child: Container(
                              height: context.getRSize(16),
                              color: colors[index % colors.length],
                            ),
                          );
                        }),
                      ),
                    ),
                    SizedBox(height: context.getRSize(20)),
                    ...List.generate(sortedCats.length, (index) {
                      final cat = sortedCats[index];
                      final amt = catTotals[cat]!;
                      final pct = total == 0
                          ? '0.0'
                          : (amt / total * 100).toStringAsFixed(1);
                      return Padding(
                        padding: EdgeInsets.only(bottom: context.getRSize(12)),
                        child: Row(
                          children: [
                            Container(
                              width: context.getRSize(12),
                              height: context.getRSize(12),
                              decoration: BoxDecoration(
                                color: colors[index % colors.length],
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: context.getRSize(12)),
                            Expanded(
                              child: Text(
                                cat,
                                style: context
                                    .semiBoldStyle(14)
                                    .copyWith(color: _text),
                              ),
                            ),
                            Text(
                              formatCurrency(amt / 100.0),
                              style: context
                                  .boldStyle(14)
                                  .copyWith(color: _text),
                            ),
                            SizedBox(width: context.getRSize(12)),
                            SizedBox(
                              width: context.getRSize(45),
                              child: Text(
                                '$pct%',
                                textAlign: TextAlign.right,
                                style: context
                                    .boldStyle(12)
                                    .copyWith(color: _subtext),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  /// "This month vs budget" card (§20.8) — shown only when a monthly goal is
  /// set for the active-store scope. Compares approved this-month spend to the goal.
  Widget _buildBudgetComparisonCard(BuildContext context) {
    final budgets = ref.watch(expenseBudgetsProvider).valueOrNull ?? const [];
    final scopeStoreId = ref.watch(expenseScopeStoreIdProvider);
    final goalKobo = resolveMonthlyBudgetKobo(budgets, scopeStoreId);
    if (goalKobo == null || goalKobo == 0) return const SizedBox.shrink();

    final now = DateTime.now();
    final allExpenses = ref.watch(viewerScopedExpensesProvider);
    final monthKobo = allExpenses
        .where(
          (e) =>
              e.expense.status == 'approved' &&
              e.expense.expenseDate.year == now.year &&
              e.expense.expenseDate.month == now.month,
        )
        .fold<int>(0, (s, e) => s + e.expense.amountKobo);

    final pct = monthKobo / goalKobo * 100;
    final isOver = monthKobo > goalKobo;
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final color = isOver ? f.danger : f.green;

    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(16)),
      child: ExpenseCardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.target, size: context.getRSize(16), color: color),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    'This month vs budget',
                    style: context.boldStyle(14).copyWith(color: _text),
                  ),
                ),
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: context.boldStyle(14).copyWith(color: color),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              '${formatCurrency(monthKobo / 100.0)} of ${formatCurrency(goalKobo / 100.0)} '
              '— ${isOver ? "over budget" : "under budget"}',
              style: context.regularStyle(12).copyWith(color: _subtext),
            ),
          ],
        ),
      ),
    );
  }

  /// "Top staff by spend" — top 3 recorders by approved amount in the period.
  Widget _buildTopStaffCard(
    BuildContext context,
    List<ExpenseWithCategory> periodApproved,
    Map<String, UserData> users,
  ) {
    final Map<String, int> byStaff = {};
    for (final e in periodApproved) {
      final id = e.expense.recordedBy;
      if (id == null) continue;
      byStaff[id] = (byStaff[id] ?? 0) + e.expense.amountKobo;
    }
    if (byStaff.isEmpty) return const SizedBox.shrink();

    final top = byStaff.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top3 = top.take(3).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(16)),
      child: ExpenseCardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  AppIcons.customerRole,
                  size: context.getRSize(16),
                  color: _subtext,
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  'Top staff by spend',
                  style: context.boldStyle(14).copyWith(color: _text),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),
            ...top3.map((entry) {
              final name = _recordedByName(entry.key, users);
              return Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(8)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: context.semiBoldStyle(13).copyWith(color: _text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatCurrency(entry.value / 100.0),
                      style: context.boldStyle(13).copyWith(color: _text),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildAnnualProjectionCard(BuildContext context) {
    final now = DateTime.now();
    final allExpenses = ref.watch(viewerScopedExpensesProvider);
    final currentYearApproved = allExpenses.where(
      (e) =>
          e.expense.status == 'approved' &&
          e.expense.expenseDate.year == now.year,
    );
    final totalThisYear = currentYearApproved.fold<double>(
      0,
      (s, e) => s + e.expense.amountKobo / 100.0,
    );

    final projection = currentYearApproved.isEmpty
        ? 0.0
        : (totalThisYear / now.month) * 12;
    return ExpenseCardShell(
      padding: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconTile(
                icon: AppIcons.analytics,
                tone: IconTileTone.danger,
                size: 36,
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Text(
                  'Annual Projection',
                  style: context.semiBoldStyle(14).copyWith(color: _subtext),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(16)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatCurrency(projection),
              style: context.boldStyle(28).copyWith(color: _text),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            'Estimated spend based on current year trajectory.',
            style: context.regularStyle(12).copyWith(color: _subtext),
          ),
        ],
      ),
    );
  }
}

class _ExpenseCard extends StatelessWidget {
  final ExpenseData exp;
  final String categoryName;
  final String recordedByName;

  /// §20.8 — when set (an "All Stores" aggregate view), the store that recorded
  /// the expense is shown on the card. Null in a single-store-scoped view.
  final String? storeName;
  final Widget? trailing;

  const _ExpenseCard({
    super.key,
    required this.exp,
    required this.categoryName,
    required this.recordedByName,
    this.storeName,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final textCol = t.colorScheme.onSurface;
    final subtextCol =
        t.textTheme.bodySmall?.color ?? t.iconTheme.color ?? textCol;

    final dateStr = DateFormat('MMM d, y • h:mm a').format(exp.expenseDate);
    final isRejected = exp.status == 'rejected';

    return ExpenseCardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(
                icon: expenseCategoryIcon(categoryName),
                tone: IconTileTone.danger,
                size: 44,
              ),
              SizedBox(width: context.getRSize(14)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            exp.description.isNotEmpty
                                ? exp.description
                                : categoryName,
                            style: context
                                .boldStyle(15)
                                .copyWith(color: textCol),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(width: context.getRSize(8)),
                        Text(
                          formatCurrency(exp.amountKobo / 100.0),
                          style: context.boldStyle(15).copyWith(color: textCol),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(6)),
                    Row(
                      children: [
                        Flexible(child: ExpenseStatusPill(status: exp.status)),
                        SizedBox(width: context.getRSize(8)),
                        // The full "Sep 18, 2026 • 10:30 AM" stamp is wider
                        // than a 320dp card can spare beside the status
                        // badge; it shortens rather than overflowing (#256).
                        Expanded(
                          child: Text(
                            dateStr,
                            maxLines: 1,
                            textAlign: TextAlign.end,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: subtextCol),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(6)),
                    Text(
                      _paymentMethodLabel(exp.paymentMethod),
                      style: context
                          .semiBoldStyle(13)
                          .copyWith(color: subtextCol),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: context.getRSize(8)),
                    Row(
                      children: [
                        Icon(
                          AppIcons.userEdit,
                          size: context.getRSize(12),
                          color: subtextCol,
                        ),
                        SizedBox(width: context.getRSize(4)),
                        Flexible(
                          child: Text(
                            recordedByName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: subtextCol),
                          ),
                        ),
                        if (exp.reference != null &&
                            exp.reference!.isNotEmpty) ...[
                          SizedBox(width: context.getRSize(12)),
                          Icon(
                            AppIcons.counter,
                            size: context.getRSize(12),
                            color: subtextCol,
                          ),
                          SizedBox(width: context.getRSize(4)),
                          Expanded(
                            child: Text(
                              exp.reference!,
                              style: context
                                  .regularStyle(12)
                                  .copyWith(
                                    color: subtextCol,
                                    fontFamily: 'monospace',
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    // §20.8 — store that recorded this expense ("All Stores").
                    if (storeName != null) ...[
                      SizedBox(height: context.getRSize(6)),
                      Row(
                        children: [
                          Icon(
                            AppIcons.store,
                            size: context.getRSize(12),
                            color: subtextCol,
                          ),
                          SizedBox(width: context.getRSize(4)),
                          Expanded(
                            child: Text(
                              storeName!,
                              style: context
                                  .regularStyle(12)
                                  .copyWith(color: subtextCol),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (isRejected &&
              exp.rejectionReason != null &&
              exp.rejectionReason!.isNotEmpty) ...[
            SizedBox(height: context.getRSize(8)),
            Text(
              'Rejected: ${exp.rejectionReason!}',
              style: context
                  .regularStyle(12)
                  .copyWith(color: f.danger, fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }
}
