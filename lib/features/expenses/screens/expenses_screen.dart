import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/features/expenses/data/models/expense.dart';
import 'package:reebaplus_pos/features/expenses/widgets/add_expense_sheet.dart';
import 'package:reebaplus_pos/core/utils/constants.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';

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
  Color get _subtext => Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
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

  Expense _toExpense(ExpenseData d, Map<String, String> categoryNames) =>
      Expense(
        id: d.id,
        category: d.categoryId != null
            ? (categoryNames[d.categoryId!] ?? 'Uncategorized')
            : 'Uncategorized',
        amount: d.amountKobo / 100.0,
        paymentMethod: d.paymentMethod ?? 'Cash',
        description: d.description.isNotEmpty ? d.description : null,
        date: d.createdAt,
        createdAt: d.createdAt,
        recordedBy: d.recordedBy ?? '',
        reference: d.reference,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
          backgroundColor: _bg,
          drawer: const AppDrawer(activeRoute: 'expenses'),
          appBar: _buildAppBar(context),
          body: Builder(
            builder: (context) {
              final expensesAsync = ref.watch(allExpensesProvider);
              final allExpenses = expensesAsync.valueOrNull ?? [];
              final categoryNames =
                  ref.watch(expenseCategoryNamesProvider).valueOrNull ??
                      const <String, String>{};
              final periodExpenses = allExpenses
                  .where((e) => _isInPeriod(e.expense.createdAt, _periodFilter))
                  .map((d) => _toExpense(d.expense, categoryNames))
                  .toList();

              final totalForPeriod = periodExpenses.fold(
                0.0,
                (sum, e) => sum + e.amount,
              );

              return Column(
                children: [
                  _buildHeaderArea(context, totalForPeriod),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildExpensesTab(context, periodExpenses),
                        _buildStatsTab(context, periodExpenses),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          floatingActionButton: AppFAB(
            heroTag: 'expenses_fab',
            onPressed: () => AddExpenseSheet.show(context),
            icon: FontAwesomeIcons.plus,
            label: 'Add Expense',
          ),
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
                colors: [Theme.of(context).colorScheme.error.withValues(alpha: 0.8), danger],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
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

  Widget _buildHeaderArea(BuildContext context, double totalAmount) {
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
                      formatCurrency(totalAmount),
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
                    return DropdownMenuItem<String>(value: val, child: Text(val));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _periodFilter = val);
                  },
                ),
              ],
            ),
          ),
          _buildBudgetTracker(totalAmount),
        ],
      ),
    );
  }

  Widget _buildExpensesTab(BuildContext context, List<Expense> list) {
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FontAwesomeIcons.receipt,
              size: context.getRSize(48),
              color: _border,
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'No expenses found',
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

    // Grouping
    final Map<String, List<Expense>> grouped = {};
    for (var e in list) {
      if (!grouped.containsKey(e.category)) grouped[e.category] = [];
      grouped[e.category]!.add(e);
    }

    // Sort categories alphabetically
    final sortedCategories = grouped.keys.toList()..sort();

    return AppRefreshWrapper(
      child: ListView.builder(
        padding: EdgeInsets.only(
            bottom: context.getRSize(100) + context.deviceBottomInset),
        itemCount: sortedCategories.length,
        itemBuilder: (context, cIndex) {
        final cat = sortedCategories[cIndex];
        final catList = grouped[cat]!..sort((a, b) => b.date.compareTo(a.date));
        final catSum = catList.fold(0.0, (sum, e) => sum + e.amount);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                    formatCurrency(catSum),
                    style: TextStyle(
                      color: _subtext,
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            ...catList.map((e) => _ExpenseCard(expense: e)),
          ],
        );
      },
    ));
  }

  Widget _buildStatsTab(BuildContext context, List<Expense> periodExpenses) {
    if (periodExpenses.isEmpty) {
      return const Center(child: Text('No data for statistics.'));
    }

    // Calculate category totals
    final Map<String, double> catTotals = {};
    double total = 0;
    for (var e in periodExpenses) {
      catTotals[e.category] = (catTotals[e.category] ?? 0) + e.amount;
      total += e.amount;
    }

    // Sort categories by amount descending
    final sortedCats = catTotals.keys.toList()
      ..sort((a, b) => catTotals[b]!.compareTo(catTotals[a]!));

    // Assign consistent colors (up to a few standard colors, falling back)
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
        padding: EdgeInsets.all(
          context.getRSize(16),
        ).copyWith(bottom: context.getRSize(100) + context.deviceBottomInset),
        children: [
          // Annual Projection Card
          _buildAnnualProjectionCard(context),
          SizedBox(height: context.getRSize(24)),

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

        // Native Bar Chart View
        Container(
          padding: EdgeInsets.all(context.getRSize(16)),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: [
              // Visual Proportional Bar
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: List.generate(sortedCats.length, (index) {
                    final cat = sortedCats[index];
                    final amt = catTotals[cat]!;
                    final flex = (amt / total * 1000).toInt();
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
              // Legend
              ...List.generate(sortedCats.length, (index) {
                final cat = sortedCats[index];
                final amt = catTotals[cat]!;
                final pct = (amt / total * 100).toStringAsFixed(1);
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
                        formatCurrency(amt),
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
    ));
  }

  Widget _buildAnnualProjectionCard(BuildContext context) {
    final now = DateTime.now();
    final allExpenses = ref.watch(allExpensesProvider).valueOrNull ?? [];
    final currentYearExpenses = allExpenses.where((e) => e.expense.createdAt.year == now.year);
    final totalThisYear = currentYearExpenses.fold<double>(0, (s, e) => s + e.expense.amountKobo / 100.0);

    final projection = currentYearExpenses.isEmpty ? 0.0 : (totalThisYear / now.month) * 12;
    return Container(
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.error.withValues(alpha: 0.8), danger],
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

  Widget _buildBudgetTracker(double totalSpent) {
    double budget = 0;
    switch (datePeriodFromLabel(_periodFilter)) {
      case DatePeriod.last24Hours:
        budget = budgetToday;
        break;
      case DatePeriod.last7Days:
        budget = budgetWeek;
        break;
      case DatePeriod.last30Days:
        budget = budgetMonth;
        break;
      case DatePeriod.lastYear:
        budget = budgetYear;
        break;
      case DatePeriod.toDate:
        // No specific budget for "To date", so hide the tracker.
        return const SizedBox();
    }

    final double percent = (totalSpent / budget).clamp(0.0, 1.2); // Cap visually at 120%
    final bool isOver = totalSpent > budget;

    return Container(
      margin: EdgeInsets.symmetric(horizontal: context.getRSize(16), vertical: context.getRSize(8)),
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
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
                    'Budget Activity',
                    style: TextStyle(
                      color: _subtext,
                      fontSize: context.getRFontSize(12),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Text(
                '${(percent * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: isOver ? danger : success,
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.bold,
                ),
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
                'Spent: ${formatCurrency(totalSpent)}',
                style: TextStyle(
                  color: _text,
                  fontSize: context.getRFontSize(11),
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Goal: ${formatCurrency(budget)}',
                style: TextStyle(
                  color: _subtext,
                  fontSize: context.getRFontSize(11),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExpenseCard extends StatelessWidget {
  final Expense expense;

  const _ExpenseCard({required this.expense});

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
    final subtextCol = Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;

    final dateStr = DateFormat('MMM d, y • h:mm a').format(expense.date);

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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(context.getRSize(12)),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _getIconForCategory(expense.category),
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
                          expense.description ?? expense.category,
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
                        formatCurrency(expense.amount),
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        expense.paymentMethod,
                        style: TextStyle(
                          color: subtextCol,
                          fontSize: context.getRFontSize(13),
                          fontWeight: FontWeight.w600,
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
                        expense.recordedBy,
                        style: TextStyle(
                          color: subtextCol,
                          fontSize: context.getRFontSize(12),
                        ),
                      ),
                      if (expense.reference != null &&
                          expense.reference!.isNotEmpty) ...[
                        SizedBox(width: context.getRSize(12)),
                        Icon(
                          FontAwesomeIcons.hashtag,
                          size: context.getRSize(10),
                          color: subtextCol,
                        ),
                        SizedBox(width: context.getRSize(4)),
                        Text(
                          expense.reference!,
                          style: TextStyle(
                            color: subtextCol,
                            fontSize: context.getRFontSize(12),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}






