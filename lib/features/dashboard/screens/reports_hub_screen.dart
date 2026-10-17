import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/supplier_accounts_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

const String kReportCardKeyPrefix = 'report-card-';
Key reportCardKey(String title) => Key('$kReportCardKeyPrefix$title');

class ReportsHubScreen extends ConsumerStatefulWidget {
  const ReportsHubScreen({super.key});

  @override
  ConsumerState<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends ConsumerState<ReportsHubScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // §25.3 role gating — the Reports hub is CEO + Manager only (§11.3). Each
    // card is additionally guarded so it is hidden (never greyed — rule #7) for
    // any role lacking it. Each manager-up card now cites its own named registry
    // gate (issue #22) — tier lives only in the atoms, never inline here. The
    // CEO-only Profit card lands in the §25 Profit pass.
    // §13.4 / rule #13 — crate-deposit features only exist for Bar & Beer
    // distributor businesses. Gate the Crate Deposits report card on the same
    // business-type check the Inventory Empty Crates tab uses (case-insensitive).
    final isCrate = businessTracksCrates(ref.watch(currentBusinessProvider));
    // §16.6.1 + §12.3.1 — count of stock-keeper adjustments AND cashier Quick
    // Sale requests awaiting this viewer's approval (a CEO sees all stores; a
    // Manager only their assigned store(s)).
    // #212 adds a third kind: crate-deposit MONEY legs (ADR 0023 rule 6),
    // counted only for a viewer who may actually decide money. Every brand
    // defaults to `none`, so this term is 0 on any business that has not
    // deliberately switched a brand on and the badge reads exactly as before.
    final pendingApprovals =
        ref.watch(viewerScopedPendingStockRequestsProvider).length +
        ref.watch(viewerScopedPendingQuickSaleRequestsProvider).length +
        (Gates.confirmCrateDeposit.allows(ref)
            ? ref.watch(viewerScopedPendingCrateDepositsProvider).length
            : 0);

    // Build the visible card list first so the grid can size itself to what
    // actually renders (cards are hidden per role / business type — rule #7).
    final cards = <Widget>[
      // Pending Approvals (§16.6.1 + §12.3.1) — stock-keeper Add/Remove requests
      // AND cashier Quick Sale requests await the affected store's Manager / the
      // CEO here. Shown first as an action item; the badge counts the combined
      // outstanding total.
      if (Gates.viewApprovals.allows(ref))
        _buildReportCard(
          context,
          title: 'Approvals',
          subtitle: 'Stock, quick sales & crate deposits',
          icon: AppIcons.clipboardList,
          tone: IconTileTone.warning,
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
      if (Gates.dailyReconciliation.allows(ref))
        _buildReportCard(
          context,
          title: 'Daily Reconciliation',
          subtitle: 'Day · Week · Month · Year',
          icon: AppIcons.auditCheck,
          tone: IconTileTone.info,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const DailyReconciliationListScreen()),
          ),
        ),
      // §13.4 Ring 7 — Crate Deposits balancing report. Crate-only (rule #13) +
      // CEO/Manager (§25.3, role-gated like Customer Ledger).
      if (Gates.crateDepositsReport.allows(ref) && isCrate)
        _buildReportCard(
          context,
          title: 'Crate Deposits',
          subtitle: 'Held · Refunded · Kept',
          icon: AppIcons.beerMug,
          tone: IconTileTone.malt,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const CrateDepositsReportScreen()),
          ),
        ),
      // §25.2 Supplier Accounts Report — outstanding balance, total paid and
      // total received per supplier, store-scoped. Manager-up AND suppliers.manage
      // (CEO by default, Manager only when the CEO toggles it on; hidden for
      // Cashier / Stock keeper). The isMgrUp && key composite is lifted verbatim
      // into Gates.supplierAccountsReport (issue #18).
      if (Gates.supplierAccountsReport.allows(ref))
        _buildReportCard(
          context,
          title: 'Supplier Accounts',
          subtitle: 'Balances · Paid · Received',
          icon: AppIcons.bank,
          tone: IconTileTone.info,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const SupplierAccountsReportScreen()),
          ),
        ),
      // Profit Report — CEO only (§25.2/§25.3); reports.see_profit is granted to
      // the CEO alone by default. The isMgrUp && key composite is lifted verbatim
      // into Gates.profitReportEntry (issue #18).
      if (Gates.profitReportEntry.allows(ref))
        _buildReportCard(
          context,
          title: 'Profit Report',
          subtitle: 'Margins & COGS',
          icon: AppIcons.chartPie,
          tone: IconTileTone.green,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const ProfitReportScreen()),
          ),
        ),
    ];

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        decoration: AppDecorations.pageBackground(context),
        child: SharedScaffold(
          activeRoute: 'dashboard',
          backgroundColor: Colors.transparent,
          appBar: ReportTopBar(
            key: ReportKeys.topBar,
            height: reportTopBarHeight(context),
            header: ScreenHeader(
              leading: const ReportBackButton(),
              icon: AppIcons.analytics,
              title: 'Business Reports',
              subtitle: ref.watch(activeStoreLabelProvider),
            ),
          ),
          // Each report owns its own period filter where its data lives; the hub
          // is just the menu of cards (no duplicate hub-level period bar).
          body: LayoutBuilder(
            builder: (context, constraints) {
              // List screen: capped at the batch-wide 720 and centred; the top
              // bar still spans the width.
              final gutter = reportGutter(
                context,
                constraints.maxWidth,
                maxWidth: kSettingsMaxContentWidth,
              );
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  context.getRSize(16),
                  gutter,
                  context.getRSize(16) + context.deviceBottomPadding,
                ),
                itemCount: cards.length,
                separatorBuilder: (_, _) =>
                    SizedBox(height: context.getRSize(12)),
                itemBuilder: (_, i) => cards[i],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildReportCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required IconTileTone tone,
    required VoidCallback onTap,
    int badgeCount = 0,
  }) {
    return ReportHubCard(
      cardKey: reportCardKey(title),
      badgeKey: Key('report-card-badge-$title'),
      icon: icon,
      tone: tone,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      badgeCount: badgeCount,
    );
  }
}
