import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/supplier_accounts_report_screen.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/skeletons/first_load_skeletons.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

const String kReportCardKeyPrefix = 'report-card-';
Key reportCardKey(String title) => Key('$kReportCardKeyPrefix$title');

class ReportsHubScreen extends ConsumerStatefulWidget {
  const ReportsHubScreen({super.key});

  @override
  ConsumerState<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends ConsumerState<ReportsHubScreen> {
  bool _isScrolled = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semanticColors = theme.extension<AppSemanticColors>();
    final warningColor = semanticColors?.warning ?? theme.colorScheme.secondary;
    final infoColor = semanticColors?.info ?? theme.colorScheme.primary;
    final successColor = semanticColors?.success ?? theme.colorScheme.primary;
    final primaryColor = theme.colorScheme.primary;
    final secondaryColor = theme.colorScheme.secondary;

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
          icon: FontAwesomeIcons.clipboardList.data,
          color: warningColor,
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
          icon: FontAwesomeIcons.clipboardCheck.data,
          color: primaryColor,
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
          icon: FontAwesomeIcons.beerMugEmpty.data,
          color: secondaryColor,
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
          icon: FontAwesomeIcons.buildingColumns.data,
          color: infoColor,
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
          icon: FontAwesomeIcons.chartPie.data,
          color: successColor,
          onTap: () => Navigator.push(
            context,
            slideDownRoute(const ProfitReportScreen()),
          ),
        ),
    ];

    // First load: show the reports skeleton (brief §4.4) while data streams in.
    if (ref.watch(firstLoadSkeletonActiveProvider)) {
      return ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: Container(
          decoration: AppDecorations.glassyBackground(context),
          child: SharedScaffold(
            activeRoute: 'dashboard',
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: Text(
                'Business Reports',
                style: context.h3.copyWith(fontWeight: FontWeight.bold),
              ),
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              backgroundColor: Colors.transparent,
              leading: BackButton(color: context.primaryColor),
            ),
            body: const SafeArea(child: ReportsSkeleton()),
          ),
        ),
      );
    }

    final textScaler = MediaQuery.textScalerOf(context);
    final cardHeight = math.max(154.0, context.getRSize(154.0)) +
        (textScaler.scale(20.0) - 20.0) * 3.5;

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        decoration: AppDecorations.glassyBackground(context),
        child: SharedScaffold(
          activeRoute: 'dashboard',
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: _isScrolled
                ? theme.colorScheme.surface.withValues(alpha: 0.8)
                : Colors.transparent,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
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
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            leading: BackButton(color: context.primaryColor),
          ),
          // Each report owns its own period filter where its data lives; the hub
          // is just the menu of cards (no duplicate hub-level period bar).
          body: NotificationListener<ScrollUpdateNotification>(
            onNotification: (notif) {
              if (notif.metrics.axis == Axis.vertical) {
                if (notif.metrics.pixels > 10 && !_isScrolled) {
                  setState(() => _isScrolled = true);
                } else if (notif.metrics.pixels <= 10 && _isScrolled) {
                  setState(() => _isScrolled = false);
                }
              }
              return false;
            },
            child: GridView(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: cardHeight,
                mainAxisSpacing: context.getRSize(12),
                crossAxisSpacing: context.getRSize(12),
              ),
              padding: EdgeInsets.fromLTRB(
                context.getRSize(16),
                context.getRSize(16),
                context.getRSize(16),
                context.getRSize(16) + context.deviceBottomPadding,
              ),
              children: cards,
            ),
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
    required Color color,
    required VoidCallback onTap,
    int badgeCount = 0,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardRadius = context.radiusL;

    return GlassyCard(
      radius: cardRadius,
      padding: EdgeInsets.zero,
      border: Border.all(
        color: isDark
            ? color.withValues(alpha: 0.22)
            : color.withValues(alpha: 0.16),
        width: 1.0,
      ),
      child: Material(
        key: reportCardKey(title),
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(cardRadius),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              math.max(14.0, context.getRSize(14.0)),
              math.max(13.0, context.getRSize(13.0)),
              math.max(14.0, context.getRSize(14.0)),
              math.max(16.0, context.getRSize(16.0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: math.max(34.0, context.getRSize(36.0)),
                      height: math.max(34.0, context.getRSize(36.0)),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color.withValues(alpha: 0.18),
                            color.withValues(alpha: 0.06),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(context.radiusM),
                        border: Border.all(
                          color: color.withValues(alpha: 0.25),
                          width: 1.0,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          icon,
                          color: color,
                          size: math.max(16.0, context.getRSize(17.0)),
                        ),
                      ),
                    ),
                    if (badgeCount > 0)
                      Container(
                        key: Key('report-card-badge-$title'),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(8),
                          vertical: context.getRSize(3),
                        ),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(context.radiusS),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.35),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text(
                          '$badgeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      )
                    else
                      Icon(
                        FontAwesomeIcons.chevronRight.data,
                        size: math.max(11.0, context.getRSize(12.0)),
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.35),
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  title,
                  style: (theme.textTheme.titleSmall ?? context.bodyMedium)
                      .copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: math.max(3.0, context.getRSize(3.0))),
                Text(
                  subtitle,
                  style: context.bodySmall.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: math.max(4.0, context.getRSize(4.0))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
