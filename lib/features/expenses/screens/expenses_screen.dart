import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

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
  String _periodFilter = 'Last 30 days'; // §20.1/§30.6 default
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
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
    }
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  bool _isInPeriod(DateTime date, String period) =>
      datePeriodFromLabel(period).includes(date);

  /// Resolves a recordedBy user id to a name; never shows a raw UUID (rule #4).
  String _recordedByName(String? userId, Map<String, UserData> users) {
    if (userId == null) return '—';
    final u = users[userId];
    if (u == null || u.name.trim().isEmpty) return '—';
    return u.name;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    return Scaffold(
      backgroundColor: _bg,
      drawer: const AppDrawer(activeRoute: 'expenses'),
      appBar: _buildAppBar(context),
      body: Builder(
        builder: (context) {
          // §20.3 — store-scoped to the viewer (CEO: all stores; others: own).
          final allExpenses = ref.watch(viewerScopedExpensesProvider);
          final categoryNames =
              ref.watch(expenseCategoryNamesProvider).valueOrNull ??
                  const <String, String>{};
          final users = ref.watch(usersByBusinessProvider).valueOrNull ??
              const <String, UserData>{};

          // Approved expenses inside the selected period (the headline total).
          final periodApproved = allExpenses
              .where((e) =>
                  e.expense.status == 'approved' &&
                  _isInPeriod(e.expense.expenseDate, _periodFilter))
              .toList();
          final approvedTotal = periodApproved.fold<int>(
            0,
            (sum, e) => sum + e.expense.amountKobo,
          );

          // §20.1/§20.3 — the monthly budget bar is always visible and always
          // reflects the last-30-days window, independent of the period
          // selector above the list.
          final monthly = allExpenses
              .where((e) => _isInPeriod(e.expense.expenseDate, 'Last 30 days'))
              .toList();
          final budgetSpentKobo = monthly
              .where((e) => e.expense.status == 'approved')
              .fold<int>(0, (sum, e) => sum + e.expense.amountKobo);
          final budgetPendingKobo = monthly
              .where((e) => e.expense.status == 'pending')
              .fold<int>(0, (sum, e) => sum + e.expense.amountKobo);

          return Column(
            children: [
              _buildHeaderArea(
                context,
                approvedTotalKobo: approvedTotal,
                budgetSpentKobo: budgetSpentKobo,
                budgetPendingKobo: budgetPendingKobo,
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildExpensesTab(
                      context,
                      allExpenses: allExpenses,
                      categoryNames: categoryNames,
                      users: users,
                    ),
                    _buildStatsTab(
                      context,
                      periodApproved: periodApproved,
                      categoryNames: categoryNames,
                      users: users,
                      approvedTotalKobo: approvedTotal,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: hasPermission(ref, 'expenses.create')
          ? AppFAB(
              heroTag: 'expenses_fab',
              onPressed: () => AddExpenseScreen.show(context),
              icon: FontAwesomeIcons.plus,
              label: 'Add Expense',
            )
          : null,
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      iconTheme: IconThemeData(color: _text),
      leading: Builder(
        builder: (ctx) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Scaffold.of(ctx).openDrawer(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 2.5,
                  width: context.getRSize(22),
                  decoration: BoxDecoration(
                    color: _text,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  height: 2.5,
                  width: context.getRSize(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  height: 2.5,
                  width: context.getRSize(22),
                  decoration: BoxDecoration(
                    color: _text,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        const NotificationBell(),
        SizedBox(width: context.getRSize(8)),
      ],
      title: Row(
        children: [
          Container(
            padding: EdgeInsets.all(context.getRSize(8)),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.error.withValues(alpha: 0.8),
                  danger,
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color:
                      Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              FontAwesomeIcons.fileInvoiceDollar,
              color: Colors.white,
              size: context.getRSize(16),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'Expenses',
                    style: TextStyle(
                      fontSize: context.getRFontSize(18),
                      fontWeight: FontWeight.w800,
                      color: _text,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                Text(
                  'Manage operating costs',
                  style: TextStyle(
                    fontSize: context.getRFontSize(11),
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
      bottom: TabBar(
        controller: _tabController,
        labelColor: Theme.of(context).colorScheme.error,
        unselectedLabelColor: _subtext,
        indicatorColor: Theme.of(context).colorScheme.error,
        indicatorWeight: 3,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: context.getRFontSize(14),
        ),
        tabs: const [
          Tab(icon: Icon(FontAwesomeIcons.list, size: 16), text: 'Expenses'),
          Tab(icon: Icon(FontAwesomeIcons.chartPie, size: 16), text: 'Stats'),
        ],
      ),
    );
  }

  Widget _buildHeaderArea(
    BuildContext context, {
    required int approvedTotalKobo,
    required int budgetSpentKobo,
    required int budgetPendingKobo,
  }) {
    return Container(
      color: _surface,
      padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Expenses',
                      style: TextStyle(
                        color: _subtext,
                        fontSize: context.getRFontSize(13),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      formatCurrency(approvedTotalKobo / 100.0),
                      style: TextStyle(
                        color: _text,
                        fontSize: context.getRFontSize(24),
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                AppDropdown<String>(
                  value: _periodFilter,
                  width: context.getRSize(130),
                  items: kDatePeriodLabels.map((String val) {
                    return DropdownMenuItem<String>(
                        value: val, child: Text(val));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _periodFilter = val);
                  },
                ),
              ],
            ),
          ),
          // §20.1/§20.3: monthly budget bar — always visible; reflects the
          // last-30-days window regardless of the selected period.
          _buildBudgetBar(
            context,
            spentKobo: budgetSpentKobo,
            pendingKobo: budgetPendingKobo,
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── BUDGET BAR (§20.3) ─────────────────────────────

  Widget _buildBudgetBar(
    BuildContext context, {
    required int spentKobo,
    required int pendingKobo,
  }) {
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final currentUser = ref.read(authProvider).currentUser;
    final budgets = ref.watch(expenseBudgetsProvider).valueOrNull ?? const [];
    final scopeStoreId = isCeo ? null : currentUser?.storeId;
    final goalKobo = resolveMonthlyBudgetKobo(budgets, scopeStoreId);

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(8),
      ),
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
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
        Row(
          children: [
            Icon(
              FontAwesomeIcons.bullseye,
              size: context.getRSize(12),
              color: _subtext,
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              'No monthly budget set',
              style: TextStyle(
                color: _subtext,
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        if (isCeo)
          AppButton(
            text: 'Set budget',
            icon: FontAwesomeIcons.bullseye,
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
    final percent = (spentKobo / goalKobo).clamp(0.0, 1.2);
    final isOver = spentKobo > goalKobo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.bullseye,
                  size: context.getRSize(12),
                  color: isOver ? danger : success,
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  'Monthly Budget',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  '${(percent * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: isOver ? danger : success,
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (isCeo) ...[
                  SizedBox(width: context.getRSize(6)),
                  InkWell(
                    onTap: () => _openBudgetDialog(scopeStoreId, goalKobo),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: EdgeInsets.all(context.getRSize(4)),
                      child: Icon(
                        FontAwesomeIcons.penToSquare,
                        size: context.getRSize(11),
                        color: _subtext,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        SizedBox(height: context.getRSize(10)),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent > 1.0 ? 1.0 : percent,
            backgroundColor: _border,
            valueColor: AlwaysStoppedAnimation<Color>(isOver ? danger : success),
            minHeight: context.getRSize(6),
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Spent: ${formatCurrency(spentKobo / 100.0)}',
              style: TextStyle(
                color: _text,
                fontSize: context.getRFontSize(11),
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'Goal: ${formatCurrency(goalKobo / 100.0)}',
              style: TextStyle(
                color: _subtext,
                fontSize: context.getRFontSize(11),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (pendingKobo > 0) ...[
          SizedBox(height: context.getRSize(6)),
          Text(
            '${formatCurrency(pendingKobo / 100.0)} pending approval',
            style: TextStyle(
              color: amberPrimaryDark,
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.w600,
            ),
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
          backgroundColor: _surface,
          title: Text(
            'Monthly budget',
            style: TextStyle(color: _text, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set the monthly spending goal for this view.',
                style: TextStyle(color: _subtext, fontSize: 13),
              ),
              SizedBox(height: context.getRSize(16)),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: TextStyle(color: _text),
                decoration: InputDecoration(
                  prefixText: '$activeCurrencySymbol ',
                  prefixStyle: TextStyle(color: _text),
                  labelText: 'Amount (naira)',
                  labelStyle: TextStyle(color: _subtext),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: _border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                  ),
                ),
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
                final v = double.tryParse(controller.text.trim());
                if (v == null || v <= 0) {
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
    await db.expenseBudgetsDao.setBudget(
      storeId: scopeStoreId,
      amountKobo: (naira * 100).round(),
    );
    if (!mounted) return;
    AppNotification.showSuccess(context, 'Monthly budget updated.');
  }

  // ─────────────────────────── EXPENSES TAB ───────────────────────────────────

  Widget _buildExpensesTab(
    BuildContext context, {
    required List<ExpenseWithCategory> allExpenses,
    required Map<String, String> categoryNames,
    required Map<String, UserData> users,
  }) {
    final canApprove = hasPermission(ref, 'expenses.approve');
    final pending = canApprove
        ? allExpenses
            .where((e) => e.expense.status == 'pending')
            .toList()
        : const <ExpenseWithCategory>[];

    // Period-filtered list (all statuses) for the main grouped section.
    final periodList = allExpenses
        .where((e) => _isInPeriod(e.expense.expenseDate, _periodFilter))
        .toList();

    if (pending.isEmpty && periodList.isEmpty) {
      return _emptyState(context, 'No expenses found');
    }

    // Group the period list by resolved category name.
    final Map<String, List<ExpenseWithCategory>> grouped = {};
    for (final e in periodList) {
      final cat = _categoryName(e, categoryNames);
      grouped.putIfAbsent(cat, () => []).add(e);
    }
    final sortedCategories = grouped.keys.toList()..sort();

    return AppRefreshWrapper(
      child: ListView(
        padding: EdgeInsets.only(
          bottom: context.getRSize(100) + context.deviceBottomInset,
        ),
        children: [
          if (pending.isNotEmpty)
            _buildPendingApprovals(context, pending, categoryNames, users),
          ...sortedCategories.expand((cat) {
            final catList = grouped[cat]!
              ..sort(
                  (a, b) => b.expense.expenseDate.compareTo(a.expense.expenseDate));
            final catSum =
                catList.fold<int>(0, (s, e) => s + e.expense.amountKobo);
            return [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(20),
                  context.getRSize(20),
                  context.getRSize(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      cat.toUpperCase(),
                      style: TextStyle(
                        color: _subtext,
                        fontSize: context.getRFontSize(12),
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      formatCurrency(catSum / 100.0),
                      style: TextStyle(
                        color: _subtext,
                        fontSize: context.getRFontSize(13),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              ...catList.map((e) => _buildExpenseCard(context, e, categoryNames,
                  users, withMenu: true)),
            ];
          }),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(FontAwesomeIcons.receipt,
              size: context.getRSize(48), color: _border),
          SizedBox(height: context.getRSize(16)),
          Text(
            message,
            style: TextStyle(
              color: _subtext,
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _categoryName(ExpenseWithCategory e, Map<String, String> names) {
    if (e.category != null) return e.category!.name;
    final id = e.expense.categoryId;
    if (id != null && names[id] != null) return names[id]!;
    return 'Uncategorized';
  }

  // ─────────────────────── PENDING APPROVALS (§20.4) ─────────────────────────

  Widget _buildPendingApprovals(
    BuildContext context,
    List<ExpenseWithCategory> pending,
    Map<String, String> categoryNames,
    Map<String, UserData> users,
  ) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(4),
      ),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: amberPrimary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: amberPrimary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.clockRotateLeft,
                size: context.getRSize(13),
                color: amberPrimaryDark,
              ),
              SizedBox(width: context.getRSize(8)),
              Text(
                'Pending approval (${pending.length})',
                style: TextStyle(
                  color: amberPrimaryDark,
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          ...pending.map((e) => _buildPendingRow(context, e, categoryNames, users)),
        ],
      ),
    );
  }

  Widget _buildPendingRow(
    BuildContext context,
    ExpenseWithCategory e,
    Map<String, String> categoryNames,
    Map<String, UserData> users,
  ) {
    final exp = e.expense;
    final cat = _categoryName(e, categoryNames);
    final by = _recordedByName(exp.recordedBy, users);

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(10)),
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  exp.description.isNotEmpty ? exp.description : cat,
                  style: TextStyle(
                    color: _text,
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(14),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatCurrency(exp.amountKobo / 100.0),
                style: TextStyle(
                  color: _text,
                  fontWeight: FontWeight.bold,
                  fontSize: context.getRFontSize(14),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            '$cat · by $by',
            style: TextStyle(
              color: _subtext,
              fontSize: context.getRFontSize(12),
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  text: 'Reject',
                  icon: FontAwesomeIcons.xmark,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.xsmall,
                  onPressed: () => _rejectExpense(exp),
                ),
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: AppButton(
                  text: 'Approve',
                  icon: FontAwesomeIcons.check,
                  variant: AppButtonVariant.success,
                  size: AppButtonSize.xsmall,
                  onPressed: () => _approveExpense(exp),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _approveExpense(ExpenseData exp) async {
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    final db = ref.read(databaseProvider);
    final today = await ref.read(todaysBusinessDateProvider.future);

    // §20.5: approving an expense that pays from a tracked account posts the
    // funds debit — require an open day for the store first.
    final tracked = exp.paymentMethod != null && exp.paymentMethod != 'other';
    if (tracked) {
      if (exp.storeId == null) {
        if (!mounted) return;
        AppNotification.showError(
          context,
          'Open the day in Funds Register before approving a cash/bank/POS expense.',
        );
        return;
      }
      final day = await db.fundDaysDao.getDay(exp.storeId!, today);
      if (!mounted) return;
      if (day == null || day.status != 'open') {
        AppNotification.showError(
          context,
          'Open the day in Funds Register before approving a cash/bank/POS expense.',
        );
        return;
      }
    }

    await db.expensesDao.approveExpense(
      expenseId: exp.id,
      approverId: currentUser.id,
      businessDate: today,
    );
    if (!mounted) return;
    AppNotification.showSuccess(context, 'Expense approved.');
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
              backgroundColor: _surface,
              title: Text(
                'Reject expense',
                style: TextStyle(color: _text, fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The recorder is notified. No money moves on a rejection.',
                    style: TextStyle(color: _subtext, fontSize: 13),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  TextField(
                    controller: reasonController,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    style: TextStyle(color: _text),
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Reason (required)',
                      labelStyle: TextStyle(color: _subtext),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                    ),
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
                  icon: FontAwesomeIcons.xmark,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.small,
                  onPressed:
                      r.isEmpty ? null : () => Navigator.pop(ctx, r),
                ),
              ],
            );
          },
        );
      },
    );

    if (reason == null || reason.isEmpty) return;
    final db = ref.read(databaseProvider);
    await db.expensesDao.rejectExpense(
      expenseId: exp.id,
      approverId: currentUser.id,
      reason: reason,
    );
    if (!mounted) return;
    AppNotification.showSuccess(context, 'Expense rejected.');
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
            style: TextStyle(color: _text, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'This removes the expense. An approved expense paid from a tracked '
            'account also reverses its funds debit today.',
            style: TextStyle(color: _subtext, fontSize: 13),
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
              icon: FontAwesomeIcons.trash,
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

    // An approved, tracked-account expense reverses its funds debit on delete —
    // require an open day, dated to today (§20.5).
    final reversesDebit = exp.status == 'approved' &&
        exp.paymentMethod != null &&
        exp.paymentMethod != 'other' &&
        exp.storeId != null;
    String? businessDate;
    if (reversesDebit) {
      final today = await ref.read(todaysBusinessDateProvider.future);
      final day = await db.fundDaysDao.getDay(exp.storeId!, today);
      if (!mounted) return;
      if (day == null || day.status != 'open') {
        AppNotification.showError(
          context,
          'Open the day in Funds Register before deleting a cash/bank/POS expense.',
        );
        return;
      }
      businessDate = today;
    }

    await db.expensesDao.softDeleteExpense(
      expenseId: exp.id,
      performedBy: currentUser.id,
      businessDate: businessDate,
    );
    if (!mounted) return;
    AppNotification.showSuccess(context, 'Expense deleted.');
  }

  Widget? _buildCardMenu(ExpenseData exp) {
    final canEdit = _canEdit(exp);
    final canDelete = _canDelete();
    if (!canEdit && !canDelete) return null;

    return PopupMenuButton<String>(
      icon: Icon(
        FontAwesomeIcons.ellipsisVertical,
        size: context.getRSize(14),
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
                Icon(FontAwesomeIcons.penToSquare,
                    size: context.getRSize(13), color: _text),
                SizedBox(width: context.getRSize(10)),
                Text('Edit', style: TextStyle(color: _text)),
              ],
            ),
          ),
        if (canDelete)
          PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                Icon(FontAwesomeIcons.trash,
                    size: context.getRSize(13), color: danger),
                SizedBox(width: context.getRSize(10)),
                const Text('Delete', style: TextStyle(color: danger)),
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
  }) {
    final exp = e.expense;
    return _ExpenseCard(
      exp: exp,
      categoryName: _categoryName(e, categoryNames),
      recordedByName: _recordedByName(exp.recordedBy, users),
      trailing: withMenu ? _buildCardMenu(exp) : null,
    );
  }

  // ─────────────────────────── STATS TAB ──────────────────────────────────────

  Widget _buildStatsTab(
    BuildContext context, {
    required List<ExpenseWithCategory> periodApproved,
    required Map<String, String> categoryNames,
    required Map<String, UserData> users,
    required int approvedTotalKobo,
  }) {
    if (periodApproved.isEmpty) {
      return const Center(child: Text('No data for statistics.'));
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

    final colors = [
      const Color(0xFFEF4444), // red
      const Color(0xFFF59E0B), // amber
      const Color(0xFF10B981), // emerald
      const Color(0xFF3B82F6), // blue
      const Color(0xFF8B5CF6), // purple
      const Color(0xFFEC4899), // pink
    ];

    return AppRefreshWrapper(
      child: ListView(
        padding: EdgeInsets.all(context.getRSize(16)).copyWith(
          bottom: context.getRSize(100) + context.deviceBottomInset,
        ),
        children: [
          _buildAnnualProjectionCard(context),
          SizedBox(height: context.getRSize(16)),
          _buildBudgetComparisonCard(context),
          _buildTopStaffCard(context, periodApproved, users),
          SizedBox(height: context.getRSize(8)),

          // Category Breakdown Header
          Text(
            'Category Breakdown',
            style: TextStyle(
              color: _text,
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: context.getRSize(16)),

          Container(
            padding: EdgeInsets.all(context.getRSize(16)),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border),
            ),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    children: List.generate(sortedCats.length, (index) {
                      final cat = sortedCats[index];
                      final amt = catTotals[cat]!;
                      final flex = total == 0 ? 0 : (amt / total * 1000).toInt();
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
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: colors[index % colors.length],
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(width: context.getRSize(12)),
                        Expanded(
                          child: Text(
                            cat,
                            style: TextStyle(
                              color: _text,
                              fontSize: context.getRFontSize(14),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          formatCurrency(amt / 100.0),
                          style: TextStyle(
                            color: _text,
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(width: context.getRSize(12)),
                        SizedBox(
                          width: context.getRSize(45),
                          child: Text(
                            '$pct%',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: _subtext,
                              fontSize: context.getRFontSize(12),
                              fontWeight: FontWeight.bold,
                            ),
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
    );
  }

  /// "This month vs budget" card (§20.3) — shown only when a monthly goal is
  /// set for the current scope. Compares approved this-month spend to the goal.
  Widget _buildBudgetComparisonCard(BuildContext context) {
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final currentUser = ref.read(authProvider).currentUser;
    final budgets = ref.watch(expenseBudgetsProvider).valueOrNull ?? const [];
    final scopeStoreId = isCeo ? null : currentUser?.storeId;
    final goalKobo = resolveMonthlyBudgetKobo(budgets, scopeStoreId);
    if (goalKobo == null || goalKobo == 0) return const SizedBox.shrink();

    final now = DateTime.now();
    final allExpenses = ref.watch(viewerScopedExpensesProvider);
    final monthKobo = allExpenses
        .where((e) =>
            e.expense.status == 'approved' &&
            e.expense.expenseDate.year == now.year &&
            e.expense.expenseDate.month == now.month)
        .fold<int>(0, (s, e) => s + e.expense.amountKobo);

    final pct = monthKobo / goalKobo * 100;
    final isOver = monthKobo > goalKobo;
    final color = isOver ? danger : success;

    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(16)),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(FontAwesomeIcons.bullseye,
                    size: context.getRSize(14), color: color),
                SizedBox(width: context.getRSize(8)),
                Text(
                  'This month vs budget',
                  style: TextStyle(
                    color: _text,
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: color,
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              '${formatCurrency(monthKobo / 100.0)} of ${formatCurrency(goalKobo / 100.0)} '
              '— ${isOver ? "over budget" : "under budget"}',
              style: TextStyle(
                color: _subtext,
                fontSize: context.getRFontSize(12),
              ),
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
      child: Container(
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(FontAwesomeIcons.userTag,
                    size: context.getRSize(14), color: _subtext),
                SizedBox(width: context.getRSize(8)),
                Text(
                  'Top staff by spend',
                  style: TextStyle(
                    color: _text,
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.bold,
                  ),
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
                        style: TextStyle(
                          color: _text,
                          fontSize: context.getRFontSize(13),
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      formatCurrency(entry.value / 100.0),
                      style: TextStyle(
                        color: _text,
                        fontSize: context.getRFontSize(13),
                        fontWeight: FontWeight.bold,
                      ),
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
    final currentYearApproved = allExpenses.where((e) =>
        e.expense.status == 'approved' &&
        e.expense.expenseDate.year == now.year);
    final totalThisYear = currentYearApproved.fold<double>(
        0, (s, e) => s + e.expense.amountKobo / 100.0);

    final projection =
        currentYearApproved.isEmpty ? 0.0 : (totalThisYear / now.month) * 12;
    return Container(
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.error.withValues(alpha: 0.8),
            danger,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.chartLine,
                color: Colors.white,
                size: context.getRSize(16),
              ),
              SizedBox(width: context.getRSize(10)),
              Text(
                'Annual Projection',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            formatCurrency(projection),
            style: TextStyle(
              color: Colors.white,
              fontSize: context.getRFontSize(28),
              fontWeight: FontWeight.bold,
              letterSpacing: -0.5,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            'Estimated spend based on current year trajectory.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: context.getRFontSize(12),
            ),
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
  final Widget? trailing;

  const _ExpenseCard({
    required this.exp,
    required this.categoryName,
    required this.recordedByName,
    this.trailing,
  });

  IconData _getIconForCategory(String category) {
    switch (category.toLowerCase()) {
      case 'fuel':
        return FontAwesomeIcons.gasPump;
      case 'salary':
        return FontAwesomeIcons.users;
      case 'rent':
        return FontAwesomeIcons.building;
      case 'maintenance':
        return FontAwesomeIcons.wrench;
      case 'utilities':
        return FontAwesomeIcons.bolt;
      case 'supplies':
        return FontAwesomeIcons.box;
      default:
        return FontAwesomeIcons.fileInvoice;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardBg = Theme.of(context).cardColor;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol = Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;

    final dateStr = DateFormat('MMM d, y • h:mm a').format(exp.expenseDate);
    final isRejected = exp.status == 'rejected';

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(6),
      ),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.all(context.getRSize(12)),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _getIconForCategory(categoryName),
                    color: Theme.of(context).colorScheme.error,
                    size: context.getRSize(16),
                  ),
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
                              style: TextStyle(
                                color: textCol,
                                fontWeight: FontWeight.bold,
                                fontSize: context.getRFontSize(15),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            formatCurrency(exp.amountKobo / 100.0),
                            style: TextStyle(
                              color: textCol,
                              fontWeight: FontWeight.bold,
                              fontSize: context.getRFontSize(15),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.getRSize(6)),
                      Row(
                        children: [
                          _StatusBadge(status: exp.status),
                          SizedBox(width: context.getRSize(8)),
                          Expanded(
                            child: Text(
                              _paymentMethodLabel(exp.paymentMethod),
                              style: TextStyle(
                                color: subtextCol,
                                fontSize: context.getRFontSize(13),
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            dateStr,
                            style: TextStyle(
                              color: subtextCol,
                              fontSize: context.getRFontSize(12),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.getRSize(8)),
                      Row(
                        children: [
                          Icon(
                            FontAwesomeIcons.userPen,
                            size: context.getRSize(10),
                            color: subtextCol,
                          ),
                          SizedBox(width: context.getRSize(4)),
                          Text(
                            recordedByName,
                            style: TextStyle(
                              color: subtextCol,
                              fontSize: context.getRFontSize(12),
                            ),
                          ),
                          if (exp.reference != null &&
                              exp.reference!.isNotEmpty) ...[
                            SizedBox(width: context.getRSize(12)),
                            Icon(
                              FontAwesomeIcons.hashtag,
                              size: context.getRSize(10),
                              color: subtextCol,
                            ),
                            SizedBox(width: context.getRSize(4)),
                            Expanded(
                              child: Text(
                                exp.reference!,
                                style: TextStyle(
                                  color: subtextCol,
                                  fontSize: context.getRFontSize(12),
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
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
                style: TextStyle(
                  color: danger,
                  fontSize: context.getRFontSize(12),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small status pill on each expense card (§20.4).
class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    switch (status) {
      case 'approved':
        color = success;
        label = 'Approved';
        break;
      case 'rejected':
        color = danger;
        label = 'Rejected';
        break;
      default:
        color = amberPrimaryDark;
        label = 'Pending CEO approval';
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: context.getRFontSize(10),
        ),
      ),
    );
  }
}
