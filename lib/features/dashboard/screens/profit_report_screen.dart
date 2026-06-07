import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';

/// Profit Report (§25.2) — CEO only. Revenue, cost of goods sold, gross profit
/// and margin over the selected period, with a per-product breakdown. Profit
/// per item = (unit price − buying price) × quantity, using the buying price
/// captured on the order line at sale time (`order_items.buying_price_kobo`).
///
/// Role visibility (§25.3) is enforced upstream — the Business Reports hub only
/// shows this card to a role holding `reports.see_profit`, which by default is
/// the CEO alone.
class ProfitReportScreen extends ConsumerStatefulWidget {
  const ProfitReportScreen({super.key, required this.initialPeriod});

  /// The hub's global period, used as this screen's starting filter (§25.5).
  /// The screen can override it locally (§25.6).
  final String initialPeriod;

  @override
  ConsumerState<ProfitReportScreen> createState() => _ProfitReportScreenState();
}

class _ProfitReportScreenState extends ConsumerState<ProfitReportScreen> {
  late String _period = widget.initialPeriod;

  /// Aggregate completed orders in [period] into headline totals + per-product
  /// rows (sorted by gross profit, descending). Lines whose captured buying
  /// price is 0 — cost was never recorded, e.g. a product created by a role
  /// without `products.edit_buying_price` — are treated as UNKNOWN cost and
  /// EXCLUDED from the profit math, exactly as the dashboard Net Profit
  /// (home_screen.dart) and the Sales breakdown do. Booking them at zero cost
  /// would overstate gross profit as 100% for those items. Their quantity is
  /// reported separately as [_ProfitData.uncostedItems] so the exclusion is
  /// transparent and Revenue − COGS always equals Gross Profit.
  _ProfitData _compute(List<OrderWithItems> orders, String period) {
    final window = datePeriodFromLabel(period);
    final byProduct = <String, _ProductAccum>{};
    var revenueKobo = 0;
    var cogsKobo = 0;
    var uncostedItems = 0;

    for (final o in orders) {
      if (o.order.status != 'completed') continue;
      if (!window.includes(o.order.createdAt)) continue;
      for (final i in o.items) {
        final product = i.product;
        // Quick-sale lines (§12.3) have no product and no captured cost — like
        // any uncosted line, they are excluded from the profit math.
        if (product == null || i.item.buyingPriceKobo <= 0) {
          uncostedItems += i.item.quantity;
          continue;
        }
        final lineRevenue = i.item.quantity * i.item.unitPriceKobo;
        final lineCogs = i.item.quantity * i.item.buyingPriceKobo;
        revenueKobo += lineRevenue;
        cogsKobo += lineCogs;
        final acc = byProduct.putIfAbsent(
          product.id,
          () => _ProductAccum(product.name),
        );
        acc.qty += i.item.quantity;
        acc.revenueKobo += lineRevenue;
        acc.cogsKobo += lineCogs;
      }
    }

    final products = byProduct.values
        .map((a) => _ProductProfit(
              name: a.name,
              qty: a.qty,
              revenueKobo: a.revenueKobo,
              cogsKobo: a.cogsKobo,
            ))
        .toList()
      ..sort((a, b) => b.profitKobo.compareTo(a.profitKobo));

    return _ProfitData(
      revenueKobo: revenueKobo,
      cogsKobo: cogsKobo,
      products: products,
      uncostedItems: uncostedItems,
    );
  }

  Future<void> _exportCsv(_ProfitData data) async {
    // Mirror the on-screen gate: omit the raw Cost-of-goods column unless the
    // viewer holds `reports.see_cost_prices`.
    final canSeeCost = ref
        .read(currentUserPermissionsProvider)
        .contains('reports.see_cost_prices');
    final rows = <List<String>>[
      for (final p in data.products)
        [
          p.name,
          '${p.qty}',
          (p.revenueKobo / 100.0).toStringAsFixed(2),
          if (canSeeCost) (p.cogsKobo / 100.0).toStringAsFixed(2),
          (p.profitKobo / 100.0).toStringAsFixed(2),
          p.marginPct.toStringAsFixed(1),
        ],
    ];
    rows.add([
      'TOTAL',
      '',
      (data.revenueKobo / 100.0).toStringAsFixed(2),
      if (canSeeCost) (data.cogsKobo / 100.0).toStringAsFixed(2),
      (data.profitKobo / 100.0).toStringAsFixed(2),
      data.marginPct.toStringAsFixed(1),
    ]);
    try {
      await shareCsv(
        csv: buildCsv(
          [
            'Product', 'Qty sold', 'Revenue',
            if (canSeeCost) 'Cost of goods',
            'Gross profit', 'Margin %',
          ],
          rows,
        ),
        fileName: 'profit_report_${_period.replaceAll(' ', '_')}',
        subject: 'Profit Report — $_period',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    // `reports.see_cost_prices` ("See buying prices in reports") gates the raw
    // Cost-of-goods figure on top of the screen's upstream `reports.see_profit`
    // gate — so a CEO can grant someone the Profit Report yet withhold the raw
    // cost. Revenue / Gross Profit / Margin stay (they're `reports.see_profit`).
    final canSeeCost = hasPermission(ref, 'reports.see_cost_prices');
    final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
    final data = _compute(orders, _period);
    final hasCostedData = data.products.isNotEmpty;
    final hasAnySales = hasCostedData || data.uncostedItems > 0;

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text(
          'Profit Report',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(FontAwesomeIcons.fileCsv,
                size: 18, color: context.primaryColor),
            onPressed: hasCostedData ? () => _exportCsv(data) : null,
          ),
          SizedBox(
            width: 110,
            child: AppDropdown<String>(
              value: _period,
              items: kDatePeriodLabels
                  .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text(p, style: const TextStyle(fontSize: 12))))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _period = v ?? kDatePeriodLabels.first),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !hasAnySales
          ? _emptyState(theme)
          : ListView(
              padding: EdgeInsets.all(context.spacingM).copyWith(
                bottom: context.spacingM + context.deviceBottomPadding,
              ),
              children: [
                if (hasCostedData) _headline(theme, data, canSeeCost),
                if (data.uncostedItems > 0) ...[
                  if (hasCostedData) SizedBox(height: context.spacingM),
                  _uncostedNote(theme, data.uncostedItems,
                      allUncosted: !hasCostedData),
                ],
                if (hasCostedData) ...[
                  SizedBox(height: context.spacingM),
                  _breakdownCard(theme, data),
                ],
              ],
            ),
    );
  }

  Widget _uncostedNote(ThemeData theme, int items, {required bool allUncosted}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(FontAwesomeIcons.circleInfo, size: 15, color: theme.hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              allUncosted
                  ? '$items item${items == 1 ? '' : 's'} sold this period had no '
                      'recorded buying price, so profit can\'t be calculated.'
                  : 'Profit excludes $items item${items == 1 ? '' : 's'} sold '
                      'with no recorded buying price.',
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FontAwesomeIcons.chartLine,
              size: 40, color: theme.hintColor.withValues(alpha: 0.5)),
          SizedBox(height: context.spacingM),
          Text('No data for this period.',
              style: context.bodyMedium.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _headline(ThemeData theme, _ProfitData data, bool canSeeCost) {
    final profit = data.profitKobo;
    final color = profit >= 0 ? const Color(0xFF22C55E) : theme.colorScheme.error;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FontAwesomeIcons.chartLine, color: color, size: 16),
              const SizedBox(width: 8),
              Text('Gross Profit',
                  style: context.bodyMedium
                      .copyWith(fontWeight: FontWeight.w700, color: color)),
            ],
          ),
          SizedBox(height: context.spacingS),
          Text(
            formatCurrency(profit / 100.0),
            style: context.h2.copyWith(
                fontWeight: FontWeight.w900,
                color: theme.colorScheme.onSurface),
          ),
          SizedBox(height: context.spacingS),
          Wrap(
            spacing: context.spacingS,
            runSpacing: context.spacingS,
            children: [
              _chip(theme, 'Revenue', formatCurrency(data.revenueKobo / 100.0)),
              if (canSeeCost)
                _chip(theme, 'Cost of goods',
                    formatCurrency(data.cogsKobo / 100.0)),
              _chip(theme, 'Margin', '${data.marginPct.toStringAsFixed(1)}%'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$label: $value',
          style: context.bodySmall.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _breakdownCard(ThemeData theme, _ProfitData data) {
    return Container(
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('By product',
              style: context.bodyMedium.copyWith(fontWeight: FontWeight.bold)),
          SizedBox(height: context.spacingS),
          for (var i = 0; i < data.products.length; i++) ...[
            if (i > 0)
              Divider(
                  height: context.spacingM,
                  color: theme.dividerColor.withValues(alpha: 0.2)),
            _productRow(theme, data.products[i]),
          ],
        ],
      ),
    );
  }

  Widget _productRow(ThemeData theme, _ProductProfit p) {
    final color =
        p.profitKobo >= 0 ? const Color(0xFF22C55E) : theme.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.name,
                  style:
                      context.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                '×${p.qty}  ·  Rev ${formatCurrency(p.revenueKobo / 100.0)}  ·  ${p.marginPct.toStringAsFixed(1)}%',
                style: context.bodySmall.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(formatCurrency(p.profitKobo / 100.0),
            style: context.bodyMedium
                .copyWith(fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

class _ProfitData {
  _ProfitData({
    required this.revenueKobo,
    required this.cogsKobo,
    required this.products,
    required this.uncostedItems,
  });

  /// Revenue of the cost-known lines only (matches [cogsKobo]'s line set so the
  /// headline stays self-consistent: Revenue − COGS == Gross Profit).
  final int revenueKobo;
  final int cogsKobo;
  final List<_ProductProfit> products;

  /// Quantity of sold items excluded from the profit math because their captured
  /// buying price was 0 (cost never recorded). Surfaced as a transparency note.
  final int uncostedItems;

  int get profitKobo => revenueKobo - cogsKobo;
  double get marginPct => revenueKobo > 0 ? profitKobo / revenueKobo * 100 : 0;
}

class _ProductAccum {
  _ProductAccum(this.name);
  final String name;
  int qty = 0;
  int revenueKobo = 0;
  int cogsKobo = 0;
}

class _ProductProfit {
  _ProductProfit({
    required this.name,
    required this.qty,
    required this.revenueKobo,
    required this.cogsKobo,
  });

  final String name;
  final int qty;
  final int revenueKobo;
  final int cogsKobo;

  int get profitKobo => revenueKobo - cogsKobo;
  double get marginPct => revenueKobo > 0 ? profitKobo / revenueKobo * 100 : 0;
}
