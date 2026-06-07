import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/customer_ledger_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

class ReportsHubScreen extends ConsumerStatefulWidget {
  const ReportsHubScreen({super.key});

  @override
  ConsumerState<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends ConsumerState<ReportsHubScreen> {
  String _selectedPeriod = kDatePeriodLabels.first; // Last 24 hours (§30.11)
  final List<String> _periods = kDatePeriodLabels;

  bool _isDateInPeriod(DateTime date, String period) =>
      datePeriodFromLabel(period).includes(date);

  @override
  Widget build(BuildContext context) {
    // §25.3 role gating — the Reports hub is CEO + Manager only (§11.3). Each
    // card is additionally guarded so it is hidden (never greyed — rule #7) for
    // any role lacking it. The CEO-only Profit card lands in the §25 Profit pass.
    final isMgrUp = isManagerOrAbove(ref);
    // §13.4 / rule #13 — crate-deposit features only exist for Bar & Beer
    // distributor businesses. Gate the Crate Deposits report card on the same
    // business-type check the Inventory Empty Crates tab uses (case-insensitive).
    final businessId = ref.read(authProvider).currentUser?.businessId;
    final isCrate = isCrateBusiness(
      ref
          .watch(localBusinessesProvider)
          .valueOrNull
          ?.where((b) => b.id == businessId)
          .map((b) => b.type)
          .firstOrNull,
    );
    // §16.6.1 + §12.3.1 — count of stock-keeper adjustments AND cashier Quick
    // Sale requests awaiting this viewer's approval (a CEO sees all stores; a
    // Manager only their assigned store(s)).
    final pendingApprovals =
        ref.watch(viewerScopedPendingStockRequestsProvider).length +
            ref.watch(viewerScopedPendingQuickSaleRequestsProvider).length;
    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text(
          'Business Reports',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          _buildPeriodSelector(),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              context.backgroundColor,
              context.backgroundColor.withValues(alpha: 0.8),
            ],
          ),
        ),
        child: GridView.count(
          crossAxisCount: 2,
          padding: EdgeInsets.all(context.spacingM).copyWith(
            bottom: context.spacingM + context.deviceBottomPadding,
          ),
          mainAxisSpacing: context.spacingM,
          crossAxisSpacing: context.spacingM,
          children: [
            // Pending Approvals (§16.6.1 + §12.3.1) — stock-keeper Add/Remove
            // requests AND cashier Quick Sale requests await the affected
            // store's Manager / the CEO here. Shown first as an action item; the
            // badge counts the combined outstanding total.
            if (isMgrUp)
              _buildReportCard(
                context,
                title: 'Approvals',
                subtitle: 'Stock & quick sales',
                icon: FontAwesomeIcons.clipboardList,
                color: Colors.orange,
                locked: false,
                badgeCount: pendingApprovals,
                onTap: () {
                  Navigator.push(
                    context,
                    slideDownRoute(const StockApprovalsScreen()),
                  );
                },
              ),
            if (isMgrUp && hasPermission(ref, 'reports.see_sales'))
              _buildReportCard(
                context,
                title: 'Sales Report',
                subtitle: 'Revenue & Volume',
                icon: FontAwesomeIcons.chartLine,
                color: context.primaryColor,
                locked: false,
                onTap: () {
                  final ordersAsync = ref.read(allOrdersProvider);
                  ordersAsync.whenData((allOrders) {
                    final filtered = allOrders
                        .where((o) =>
                            o.order.status == 'completed' &&
                            _isDateInPeriod(o.order.createdAt, _selectedPeriod))
                        .toList();
                    Navigator.push(
                      context,
                      slideDownRoute(
                        SalesDetailScreen(
                          orders: filtered,
                          mode: 'sales',
                          period: _selectedPeriod,
                        ),
                      ),
                    );
                  });
                },
              ),
            if (isMgrUp)
              _buildReportCard(
                context,
                title: 'Daily Reconciliation',
                subtitle: 'Day-by-Day Audit',
                icon: FontAwesomeIcons.clipboardCheck,
                color: Colors.indigo,
                locked: false,
                onTap: () {
                  Navigator.push(
                    context,
                    slideDownRoute(
                      DailyReconciliationListScreen(
                        initialPeriod: _selectedPeriod,
                      ),
                    ),
                  );
                },
              ),
            if (isMgrUp && hasPermission(ref, 'reports.see_expenses'))
              _buildReportCard(
                context,
                title: 'Expense Tracker',
                subtitle: 'Outflow Analysis',
                icon: FontAwesomeIcons.fileInvoiceDollar,
                color: Colors.redAccent,
                locked: false,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ExpensesScreen()),
                  );
                },
              ),
            // Customer Ledger has no dedicated permission key, so it gates on
            // role alone — CEO + Manager only (§25.3).
            if (isMgrUp)
              _buildReportCard(
                context,
                title: 'Customer Ledger',
                subtitle: 'Wallet & Credit',
                icon: FontAwesomeIcons.wallet,
                color: Colors.purpleAccent,
                locked: false,
                onTap: () {
                  Navigator.push(
                    context,
                    slideDownRoute(const CustomerLedgerScreen()),
                  );
                },
              ),
            // §13.4 Ring 7 — Crate Deposits balancing report. Crate-only
            // (rule #13) + CEO/Manager (§25.3, role-gated like Customer Ledger).
            if (isMgrUp && isCrate)
              _buildReportCard(
                context,
                title: 'Crate Deposits',
                subtitle: 'Held · Refunded · Kept',
                icon: FontAwesomeIcons.beerMugEmpty,
                color: Colors.teal,
                locked: false,
                onTap: () {
                  Navigator.push(
                    context,
                    slideDownRoute(const CrateDepositsReportScreen()),
                  );
                },
              ),
            // Profit Report — CEO only (§25.2/§25.3); reports.see_profit is
            // granted to the CEO alone by default.
            if (isMgrUp && hasPermission(ref, 'reports.see_profit'))
              _buildReportCard(
                context,
                title: 'Profit Report',
                subtitle: 'Margins & COGS',
                icon: FontAwesomeIcons.chartPie,
                color: Colors.green,
                locked: false,
                onTap: () {
                  Navigator.push(
                    context,
                    slideDownRoute(
                      ProfitReportScreen(initialPeriod: _selectedPeriod),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      width: 100,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: AppDropdown<String>(
        value: _selectedPeriod,
        items: _periods
            .map((p) => DropdownMenuItem(
                value: p,
                child: Text(p, style: const TextStyle(fontSize: 12))))
            .toList(),
        onChanged: (v) =>
            setState(() => _selectedPeriod = v ?? kDatePeriodLabels.first),
      ),
    );
  }

  Widget _buildReportCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    bool locked = false,
    int badgeCount = 0,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radiusL),
        child: Container(
          padding: EdgeInsets.all(context.spacingM),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(context.radiusL),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.1),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: context.bodyMedium.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: context.bodySmall.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
              if (locked)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.3),
                    ),
                  ),
                ),
              if (badgeCount > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$badgeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
