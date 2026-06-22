import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/supplier_accounts_report_screen.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

class ReportsHubScreen extends ConsumerStatefulWidget {
  const ReportsHubScreen({super.key});

  @override
  ConsumerState<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends ConsumerState<ReportsHubScreen> {
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

    // Build the visible card list first so the grid can size itself to what
    // actually renders (cards are hidden per role / business type — rule #7).
    final cards = <Widget>[
      // Pending Approvals (§16.6.1 + §12.3.1) — stock-keeper Add/Remove requests
      // AND cashier Quick Sale requests await the affected store's Manager / the
      // CEO here. Shown first as an action item; the badge counts the combined
      // outstanding total.
      if (isMgrUp)
        _buildReportCard(
          context,
          title: 'Approvals',
          subtitle: 'Stock & quick sales',
          icon: FontAwesomeIcons.clipboardList.data,
          color: Colors.orange,
          badgeCount: pendingApprovals,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const StockApprovalsScreen()),
          ),
        ),
      // Daily Reconciliation (§25.9) — store-scoped via the §12.1 picker,
      // groupable Day/Week/Month/Year (Manager capped at Month), with the CEO P&L
      // + statement of account folded in. Its own period grouping drives it, so it
      // does not read the hub period.
      if (isMgrUp)
        _buildReportCard(
          context,
          title: 'Daily Reconciliation',
          subtitle: 'Day · Week · Month · Year',
          icon: FontAwesomeIcons.clipboardCheck.data,
          color: Colors.indigo,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const DailyReconciliationListScreen()),
          ),
        ),
      // §13.4 Ring 7 — Crate Deposits balancing report. Crate-only (rule #13) +
      // CEO/Manager (§25.3, role-gated like Customer Ledger).
      if (isMgrUp && isCrate)
        _buildReportCard(
          context,
          title: 'Crate Deposits',
          subtitle: 'Held · Refunded · Kept',
          icon: FontAwesomeIcons.beerMugEmpty.data,
          color: Colors.teal,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const CrateDepositsReportScreen()),
          ),
        ),
      // §25.2 Supplier Accounts Report — outstanding balance, total paid and
      // total received per supplier, store-scoped. Gated on suppliers.manage so
      // it tracks Supplier Accounts access: CEO by default, Manager only when the
      // CEO toggles it on; hidden for Cashier / Stock keeper (Reports hub itself
      // is Manager-up only).
      if (isMgrUp && hasPermission(ref, 'suppliers.manage'))
        _buildReportCard(
          context,
          title: 'Supplier Accounts',
          subtitle: 'Balances · Paid · Received',
          icon: FontAwesomeIcons.buildingColumns.data,
          color: Colors.brown,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const SupplierAccountsReportScreen()),
          ),
        ),
      // Profit Report — CEO only (§25.2/§25.3); reports.see_profit is granted to
      // the CEO alone by default.
      if (isMgrUp && hasPermission(ref, 'reports.see_profit'))
        _buildReportCard(
          context,
          title: 'Profit Report',
          subtitle: 'Margins & COGS',
          icon: FontAwesomeIcons.chartPie.data,
          color: Colors.green,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const ProfitReportScreen()),
          ),
        ),
    ];

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Business Reports',
              style: context.h3.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              ref.watch(activeStoreLabelProvider),
              style: TextStyle(
                fontSize: context.getRFontSize(11),
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
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
        // Each report owns its own period filter where its data lives; the hub
        // is just the menu of cards (no duplicate hub-level period bar).
        child: GridView.count(
          crossAxisCount: 2,
          padding: EdgeInsets.fromLTRB(
            context.spacingM,
            context.spacingM,
            context.spacingM,
            context.spacingM + context.deviceBottomPadding,
          ),
          mainAxisSpacing: context.spacingM,
          crossAxisSpacing: context.spacingM,
          children: cards,
        ),
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
              if (badgeCount > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
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
