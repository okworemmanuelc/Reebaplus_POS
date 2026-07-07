import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// One reconciliation bucket's detail (§25.9) — a Day / Week / Month / Year span
/// in the active store scope. Rolls up sales, stock audit, valued shrinkage,
/// debts, expenses and crates; for the **CEO** it also shows a cost-based P&L and
/// a recorded statement of account. A **Manager** never sees cost / COGS / margin
/// / profit / goods-received (cost wall, §25.3); their shrinkage is valued at
/// selling price (an accountability figure). A non-Day bucket lists the
/// next-finer buckets inside it as a drill-down breakdown.
class DailyReconciliationDetailScreen extends ConsumerWidget {
  const DailyReconciliationDetailScreen({
    super.key,
    required this.start,
    required this.endExclusive,
    required this.grouping,
    required this.title,
  });

  final DateTime start;
  final DateTime endExclusive;
  final ReconGrouping grouping;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currencySymbolProvider); // rebuild money on currency change
    final theme = Theme.of(context);
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final d = computeReconData(
      ref,
      start: start,
      endExclusive: endExclusive,
      isCeo: isCeo,
    );
    final children = grouping.finer == null
        ? const <ReconBucket>[]
        : buildReconBuckets(
            ref,
            start: start,
            endExclusive: endExclusive,
            grouping: grouping.finer!,
          );

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: context.h3.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              scopeLabel,
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(
              FontAwesomeIcons.fileCsv.data,
              size: 18,
              color: context.primaryColor,
            ),
            onPressed: () => _exportCsv(context, d, isCeo, scopeLabel),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(
          context.spacingM,
        ).copyWith(bottom: context.spacingM + context.deviceBottomPadding),
        children: [
          _salesCard(context, theme, d),
          if (isCeo) ...[
            SizedBox(height: context.spacingM),
            _plCard(context, theme, d),
            SizedBox(height: context.spacingM),
            _cashFlowCard(context, theme, d),
          ],
          SizedBox(height: context.spacingM),
          _stockReconciliationCard(context, theme, d, isCeo: isCeo),
          if (isCeo) ...[
            SizedBox(height: context.spacingM),
            _businessWorthCard(context, theme, d),
          ],
          if (!isCeo) ...[
            SizedBox(height: context.spacingM),
            _debtsExpensesCard(context, theme, d),
          ],
          if (d.showCrates) ...[
            SizedBox(height: context.spacingM),
            _cratesCard(context, theme, d),
          ],
          if (children.isNotEmpty) ...[
            SizedBox(height: context.spacingM),
            _breakdown(context, theme, children),
          ],
        ],
      ),
    );
  }

  // ── Cards ───────────────────────────────────────────────────────────────

  Widget _salesCard(BuildContext context, ThemeData theme, ReconData d) {
    return _card(
      context,
      theme,
      'Sales summary',
      FontAwesomeIcons.chartLine.data,
      context.primaryColor,
      [
        _line(context, theme, 'Items sold', fmtNumber(d.itemsSold)),
        _line(context, theme, 'Products (SKUs) sold', fmtNumber(d.skus)),
        _line(
          context,
          theme,
          'Total sales',
          formatCurrency(d.totalRevenueKobo / 100.0),
          strong: true,
        ),
        if (d.refundsKobo > 0)
          _line(
            context,
            theme,
            'Refunds',
            '− ${formatCurrency(d.refundsKobo / 100.0)}',
          ),
        if (d.vatEnabled)
          _line(
            context,
            theme,
            'VAT due (${d.vatRateLabel}%)',
            formatCurrency(d.vatKobo / 100.0),
          ),
        _line(
          context,
          theme,
          'Best staff',
          d.bestStaff == null
              ? '—'
              : '${d.bestStaff} (${formatCurrency(d.bestStaffKobo / 100.0)})',
        ),
        _line(
          context,
          theme,
          'Top items',
          d.topItems.isEmpty
              ? '—'
              : d.topItems.map((e) => '${e.name} (×${e.qty})').join('\n'),
        ),
      ],
    );
  }

  Widget _plCard(BuildContext context, ThemeData theme, ReconData d) {
    final net = d.netProfitKobo;
    final netColor = net >= 0
        ? theme.extension<AppSemanticColors>()!.success
        : theme.colorScheme.error;
    return _card(
      context,
      theme,
      'Profit & Loss',
      FontAwesomeIcons.chartPie.data,
      netColor,
      [
        _line(
          context,
          theme,
          'Revenue',
          formatCurrency(d.costedRevenueKobo / 100.0),
        ),
        if (d.discountsKobo > 0) ...[
          _line(
            context,
            theme,
            'Discounts',
            '− ${formatCurrency(d.discountsKobo / 100.0)}',
          ),
          _line(
            context,
            theme,
            'Net revenue',
            formatCurrency(d.netRevenueKobo / 100.0),
          ),
        ],
        _line(
          context,
          theme,
          'Cost of goods sold',
          '− ${formatCurrency(d.cogsKobo / 100.0)}',
        ),
        _divider(theme),
        _line(
          context,
          theme,
          'Gross profit',
          formatCurrency(d.grossProfitKobo / 100.0),
          strong: true,
        ),
        _line(
          context,
          theme,
          'Expenses (${d.expensesCount})',
          '− ${formatCurrency(d.expensesKobo / 100.0)}',
        ),
        _line(
          context,
          theme,
          'Damages (at cost)',
          '− ${formatCurrency(d.damageCostKobo / 100.0)}',
        ),
        if (d.crateDamageDepositKobo > 0)
          _line(
            context,
            theme,
            'Crate deposit loss',
            '− ${formatCurrency(d.crateDamageDepositKobo / 100.0)}',
          ),
        _divider(theme),
        _line(
          context,
          theme,
          'Net profit',
          formatCurrency(net / 100.0),
          strong: true,
          color: netColor,
        ),
        if (d.uncostedItems > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Excludes ${fmtNumber(d.uncostedItems)} item(s) sold with no recorded '
            'buying price (e.g. quick sales).',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
    );
  }

  /// Derived cash-flow summary (ADR 0014): the period's expected cash MOVEMENT
  /// from recorded cash tenders — cash sales + debts collected in, refunds +
  /// cash expenses + cash supplier payments out. **Business-wide** (the
  /// payment_transactions ledger has no store) and **not a counted drawer**:
  /// there is no opening float to add this to (Hard Rule #8). CEO-only.
  Widget _cashFlowCard(BuildContext context, ThemeData theme, ReconData d) {
    final successColor = theme.extension<AppSemanticColors>()!.success;
    final dangerColor = theme.colorScheme.error;
    final netColor = d.netCashMovementKobo >= 0 ? successColor : dangerColor;
    return _card(
      context,
      theme,
      'Cash flow (business-wide)',
      FontAwesomeIcons.moneyBillWave.data,
      netColor,
      [
        _line(context, theme, 'Cash sales',
            '+ ${formatCurrency(d.cashSalesKobo / 100.0)}'),
        _line(context, theme, 'Debts collected (cash)',
            '+ ${formatCurrency(d.cashDebtsCollectedKobo / 100.0)}'),
        _line(context, theme, 'Cash in',
            formatCurrency(d.cashInKobo / 100.0), strong: true),
        _divider(theme),
        _line(context, theme, 'Refunds paid (cash)',
            '− ${formatCurrency(d.cashRefundsKobo / 100.0)}'),
        _line(context, theme, 'Expenses paid (cash)',
            '− ${formatCurrency(d.cashExpensesKobo / 100.0)}'),
        _line(context, theme, 'Paid to suppliers (cash)',
            '− ${formatCurrency(d.cashSupplierPaidKobo / 100.0)}'),
        _line(context, theme, 'Cash out',
            formatCurrency(d.cashOutKobo / 100.0), strong: true),
        _divider(theme),
        _line(context, theme, 'Net cash movement',
            formatCurrency(d.netCashMovementKobo / 100.0),
            strong: true, color: netColor),
        const SizedBox(height: 6),
        Text(
          'Expected cash movement from recorded cash tenders — business-wide, '
          'not a counted drawer.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  /// The single stock section of the closing — replaces the former separate
  /// Shrinkage, Stock audit, Stock reconciliation and Integrity cards, which
  /// each re-showed the same shortage / damage / COGS figures. For the CEO it is
  /// a cost-valued flow equation (Opening + Goods received − COGS − Damages −
  /// Expired ± Other = Expected closing) reconciled to the physical count, then
  /// the count-reconciled profit. For a Manager (cost wall §25.3) it is a
  /// retail-valued shrinkage + count view with no cost/COGS/flow.
  Widget _stockReconciliationCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    required bool isCeo,
  }) {
    final successColor = theme.extension<AppSemanticColors>()!.success;
    final dangerColor = theme.colorScheme.error;
    final hasShortage = d.shortageUnits > 0;

    // Physical-count detail, shared by both roles.
    List<Widget> countSection() => [
      _line(context, theme, 'Products counted', fmtNumber(d.productsCounted)),
      _line(
        context,
        theme,
        'Short',
        '${fmtNumber(d.shortageCount)} products · ${fmtNumber(d.shortageUnits)} units',
        danger: hasShortage,
      ),
      _line(
        context,
        theme,
        'Surplus',
        '${fmtNumber(d.surplusCount)} products · ${fmtNumber(d.surplusUnits)} units',
      ),
      if (d.shortages.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          'Shortages',
          style: context.bodySmall.copyWith(fontWeight: FontWeight.w700),
        ),
        for (final s in d.shortages)
          _line(
            context,
            theme,
            s.name,
            '${s.diff} (had ${s.system}, counted ${s.actual})',
            danger: true,
          ),
      ],
    ];

    if (!isCeo) {
      // Manager: retail-valued shrinkage + count. No cost, COGS or flow.
      final shrinkVal = d.shortageRetailKobo + d.damageRetailKobo;
      return _card(
        context,
        theme,
        'Stock & shrinkage',
        FontAwesomeIcons.boxesStacked.data,
        Colors.blueAccent,
        [
          _line(
            context,
            theme,
            'Stock shortages',
            '${fmtNumber(d.shortageUnits)} unit(s) · ${formatCurrency(d.shortageRetailKobo / 100.0)}',
            danger: hasShortage,
          ),
          _line(
            context,
            theme,
            'Damages recorded',
            '${fmtNumber(d.damageUnits)} unit(s) · ${formatCurrency(d.damageRetailKobo / 100.0)}',
          ),
          _divider(theme),
          _line(
            context,
            theme,
            'Sellable value unaccounted',
            formatCurrency(shrinkVal / 100.0),
            strong: true,
          ),
          const SizedBox(height: 6),
          Text(
            'Valued at selling price — an accountability figure, not the '
            'company\'s cost of the loss.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
          if (d.hasStockCount) ...[_divider(theme), ...countSection()],
        ],
        danger: hasShortage,
      );
    }

    // CEO: cost-valued flow equation reconciled to the count.
    final variance = d.stockVarianceKobo;
    final hasVariance = d.hasStockCount && variance != 0;
    return _card(
      context,
      theme,
      'Stock reconciliation (at cost)',
      FontAwesomeIcons.scaleBalanced.data,
      Colors.blueAccent,
      [
        if (d.hasStockFlow) ...[
          _line(context, theme, 'Opening stock',
              formatCurrency(d.stockOpeningKobo / 100.0)),
          _line(context, theme, 'Goods received',
              '+ ${formatCurrency(d.stockReceivedKobo / 100.0)}'),
          _line(context, theme, 'Cost of goods sold',
              '− ${formatCurrency(d.stockCogsKobo / 100.0)}'),
          _line(context, theme, 'Damages',
              '− ${formatCurrency(d.stockDamagesKobo / 100.0)}'),
          _line(context, theme, 'Expired',
              '− ${formatCurrency(d.stockExpiredKobo / 100.0)}'),
          if (d.stockOtherMovementsKobo != 0)
            _line(
              context,
              theme,
              'Other movements',
              '${d.stockOtherMovementsKobo >= 0 ? '+ ' : '− '}'
                  '${formatCurrency(d.stockOtherMovementsKobo.abs() / 100.0)}',
            ),
          _divider(theme),
          _line(context, theme, 'Expected closing',
              formatCurrency(d.stockExpectedClosingKobo / 100.0),
              strong: true),
          if (d.hasStockCount)
            _line(
              context,
              theme,
              'Variance (counted − expected)',
              '${variance >= 0 ? '+ ' : '− '}'
                  '${formatCurrency(variance.abs() / 100.0)}',
              strong: true,
              color: hasVariance ? dangerColor : null,
            ),
        ],
        if (d.hasStockCount) ...[
          _divider(theme),
          ...countSection(),
          _divider(theme),
          _line(
            context,
            theme,
            'Count-reconciled profit',
            formatCurrency(d.integrityAdjustedProfitKobo / 100.0),
            strong: true,
            color: hasVariance ? dangerColor : successColor,
          ),
          const SizedBox(height: 6),
          Text(
            hasVariance
                ? 'The physical count is off the recorded flows by '
                      '${formatCurrency(variance.abs() / 100.0)} — an unbooked '
                      'shrinkage or miscount, not reflected in reported profit.'
                : 'The physical count matches recorded sales, receipts, damages '
                      'and expiries — reported profit reconciles.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ] else ...[
          const SizedBox(height: 6),
          Text(
            'Valued at current cost. No stock count in this period, so there is '
            'no variance to reconcile against.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      danger: hasVariance,
    );
  }

  /// Point-in-time net worth: the inventory-on-hand asset, held empty-crate
  /// deposits, money owed to us and the supplier-account position.
  Widget _businessWorthCard(BuildContext context, ThemeData theme, ReconData d) {
    final successColor = theme.extension<AppSemanticColors>()!.success;
    final dangerColor = theme.colorScheme.error;
    final positionColor = d.businessNetPositionKobo >= 0 ? successColor : dangerColor;

    return _card(
      context,
      theme,
      'Business worth right now (point-in-time)',
      FontAwesomeIcons.vault.data,
      positionColor,
      [
        _line(context, theme, 'Inventory on hand (at cost)', '+ ${formatCurrency(d.inventoryOnHandKobo / 100.0)}'),
        if (d.showCrates)
          _line(context, theme, 'Empty crates held (now)', '+ ${formatCurrency(d.crateDepositKobo / 100.0)}'),
        _line(context, theme, 'Outstanding customer debt (at risk)', '+ ${formatCurrency(d.totalOwedKobo / 100.0)}', color: d.totalOwedKobo > 0 ? dangerColor : null),
        // Supplier account position — tracks payments made to suppliers vs
        // goods received. Negative (red) = a debt we owe them for unpaid goods;
        // positive (green) = money we paid them in advance (a prepayment), not
        // money we hold on their behalf.
        if (d.supplierAccountBalanceKobo < 0)
          _line(context, theme, 'Owed to suppliers (now)', '− ${formatCurrency(d.supplierAccountBalanceKobo.abs() / 100.0)}', color: dangerColor)
        else
          _line(context, theme, 'Paid in advance to suppliers (now)', '+ ${formatCurrency(d.supplierAccountBalanceKobo / 100.0)}', color: d.supplierAccountBalanceKobo > 0 ? successColor : null),
        _divider(theme),
        _line(context, theme, 'Business net position (now)', formatCurrency(d.businessNetPositionKobo / 100.0), strong: true, color: positionColor),
        if (d.uncostedInventoryItems > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Excludes ${fmtNumber(d.uncostedInventoryItems)} inventory item(s) with no recorded buying price.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        const SizedBox(height: 6),
        Text('Point-in-time net position. Not a cash balance.', style: context.bodySmall.copyWith(color: theme.hintColor)),
      ],
    );
  }

  Widget _debtsExpensesCard(
    BuildContext context,
    ThemeData theme,
    ReconData d,
  ) {
    return _card(
      context,
      theme,
      'Debts & expenses',
      FontAwesomeIcons.moneyBillWave.data,
      Colors.redAccent,
      [
        _line(
          context,
          theme,
          'Outstanding customer debt (business-wide)',
          formatCurrency(d.totalOwedKobo / 100.0),
          danger: d.totalOwedKobo > 0,
        ),
        _line(
          context,
          theme,
          'Expenses recorded (${d.expensesCount})',
          formatCurrency(d.expensesKobo / 100.0),
        ),
      ],
    );
  }

  Widget _cratesCard(BuildContext context, ThemeData theme, ReconData d) {
    return _card(
      context,
      theme,
      'Empty crates (held now)',
      FontAwesomeIcons.boxOpen.data,
      theme.colorScheme.primary,
      [
        if (d.manufacturerEmpties.isEmpty)
          _line(context, theme, 'Crates held', '0 crates')
        else ...[
          for (final m in d.manufacturerEmpties)
            _line(
              context,
              theme,
              m.manufacturerName,
              '${fmtNumber(m.count)} crate(s) · ${formatCurrency(m.valueKobo / 100.0)}',
            ),
          _divider(theme),
          _line(
            context,
            theme,
            'Total empty-crate value (now)',
            formatCurrency(d.crateDepositKobo / 100.0),
            strong: true,
          ),
        ],
      ],
    );
  }

  Widget _breakdown(
    BuildContext context,
    ThemeData theme,
    List<ReconBucket> children,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: context.spacingS,
            bottom: context.spacingS,
          ),
          child: Text(
            'Breakdown by ${children.first.grouping.label.toLowerCase()}',
            style: context.bodyMedium.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        for (final b in children) ...[
          _bucketCard(context, theme, b),
          SizedBox(height: context.spacingS),
        ],
      ],
    );
  }

  Widget _bucketCard(BuildContext context, ThemeData theme, ReconBucket b) {
    final mismatch = b.hasShortage;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radiusL),
        onTap: () => Navigator.push(
          context,
          slideDownRoute(
            DailyReconciliationDetailScreen(
              start: b.start,
              endExclusive: b.endExclusive,
              grouping: b.grouping,
              title: b.label,
            ),
          ),
        ),
        child: Container(
          padding: EdgeInsets.all(context.spacingM),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(context.radiusL),
            border: Border.all(
              color: mismatch
                  ? theme.colorScheme.error.withValues(alpha: 0.3)
                  : theme.dividerColor.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.label,
                      style: context.bodyMedium.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${fmtNumber(b.itemsSold)} items sold',
                      style: context.bodySmall.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              if (mismatch)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Mismatch',
                    style: context.bodySmall.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared widgets ────────────────────────────────────────────────────────

  Widget _card(
    BuildContext context,
    ThemeData theme,
    String title,
    IconData icon,
    Color color,
    List<Widget> children, {
    bool danger = false,
  }) {
    return Container(
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(
          color: danger
              ? theme.colorScheme.error.withValues(alpha: 0.35)
              : theme.dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: context.bodyMedium.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          SizedBox(height: context.spacingS),
          ...children,
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context,
    ThemeData theme,
    String label,
    String value, {
    bool strong = false,
    bool danger = false,
    Color? color,
  }) {
    final c = color ?? (danger ? theme.colorScheme.error : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: context.bodySmall.copyWith(
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
              color: c,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Divider(
      height: 1,
      color: theme.dividerColor.withValues(alpha: 0.25),
    ),
  );

  Future<void> _exportCsv(
    BuildContext context,
    ReconData d,
    bool isCeo,
    String scope,
  ) async {
    String money(int kobo) => (kobo / 100.0).toStringAsFixed(2);
    final rows = <List<String>>[
      ['Items sold', '${d.itemsSold}'],
      ['Products (SKUs) sold', '${d.skus}'],
      ['Total sales', money(d.totalRevenueKobo)],
      if (d.vatEnabled) ['VAT due (${d.vatRateLabel}%)', money(d.vatKobo)],
      if (isCeo) ...[
        // Net result for this period (flow) — mirrors _netResultCard.
        ['Inventory on hand (at cost)', money(d.inventoryOnHandKobo)],
        ['Goods received', money(d.goodsReceivedKobo)],
        ['Paid to suppliers', money(d.supplierPaidKobo)],
        ['Refunds', money(d.refundsKobo)],
        ['Expenses', money(d.expensesKobo)],
        ['Damages (at cost)', money(d.damageCostKobo)],
        if (d.crateDamageDepositKobo > 0)
          ['Crate deposit loss (at deposit)', money(d.crateDamageDepositKobo)],
        ['Stock shortages (at cost)', money(d.shortageCostKobo)],
        ['Net result for period', money(d.periodNetResultKobo)],
        // Profit & Loss — mirrors _plCard.
        ['Revenue (costed, gross)', money(d.costedRevenueKobo)],
        ['Discounts', money(d.discountsKobo)],
        ['Net revenue (costed)', money(d.netRevenueKobo)],
        ['Cost of goods sold', money(d.cogsKobo)],
        ['Gross profit', money(d.grossProfitKobo)],
        ['Gross margin %', d.grossMarginPct],
        ['Net profit', money(d.netProfitKobo)],
        // Business worth right now (point-in-time) — mirrors _businessWorthCard.
        // Supplier account position: negative = a debt we owe for unpaid goods,
        // positive = money we paid the supplier in advance (a prepayment).
        ['Supplier account balance (now)', money(d.supplierAccountBalanceKobo)],
        ['Business net position (now)', money(d.businessNetPositionKobo)],
        // Cash flow (business-wide) — mirrors _cashFlowCard.
        ['Cash sales', money(d.cashSalesKobo)],
        ['Debts collected (cash)', money(d.cashDebtsCollectedKobo)],
        ['Refunds paid (cash)', money(d.cashRefundsKobo)],
        ['Expenses paid (cash)', money(d.cashExpensesKobo)],
        ['Paid to suppliers (cash)', money(d.cashSupplierPaidKobo)],
        ['Net cash movement', money(d.netCashMovementKobo)],
        // Stock reconciliation (at cost) — mirrors _stockFlowCard.
        ['Opening stock (at cost)', money(d.stockOpeningKobo)],
        ['Goods received (at cost)', money(d.stockReceivedKobo)],
        ['COGS (at current cost)', money(d.stockCogsKobo)],
        ['Damages (stock, at cost)', money(d.stockDamagesKobo)],
        ['Expired (at cost)', money(d.stockExpiredKobo)],
        ['Other stock movements (at cost)', money(d.stockOtherMovementsKobo)],
        ['Expected closing (at cost)', money(d.stockExpectedClosingKobo)],
        ['Stock variance (counted − expected)', money(d.stockVarianceKobo)],
        // Integrity check — mirrors _integrityCard.
        ['Count-reconciled profit', money(d.integrityAdjustedProfitKobo)],
        ['Stock shortages (units)', '${d.shortageUnits}'],
      ] else ...[
        ['Stock shortages (units)', '${d.shortageUnits}'],
        [
          'Sellable value unaccounted',
          money(d.shortageRetailKobo + d.damageRetailKobo),
        ],
      ],
      ['Expenses recorded', money(d.expensesKobo)],
      ['Outstanding customer debt', money(d.totalOwedKobo)],
      if (d.showCrates) ['Empty crates held (units)', '${d.crateUnits}'],
    ];
    final name = isCeo ? 'business_statement' : 'store_reconciliation';
    try {
      await shareCsv(
        csv: buildCsv(['Metric', 'Value'], rows),
        fileName: '${name}_${title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}',
        subject: 'Reconciliation — $scope — $title',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
      }
    }
  }
}
