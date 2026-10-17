import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
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
///
/// #200 / PRD #155 US 32 — this is also where the **catalogue-price concession**
/// is read: the story asked for under-the-counter discounting to be "visible in
/// margin review", and margin review happens here. `catalogue − charged` (from
/// `order_items.catalogue_price_kobo`) reports as "Sold below list price", on the
/// headline, per product, and in the CSV. It sits under `reports.see_profit`, not
/// `reports.see_cost_prices` — a selling-price fact, not a buying price.
class ProfitReportScreen extends ConsumerStatefulWidget {
  const ProfitReportScreen({super.key, this.initialPeriod});

  /// Optional starting filter. Defaults to the canonical first period (Today)
  /// when not supplied; the screen owns its own period dropdown (§25.5/§25.6).
  final String? initialPeriod;

  @override
  ConsumerState<ProfitReportScreen> createState() => _ProfitReportScreenState();
}

class _ProfitReportScreenState extends ConsumerState<ProfitReportScreen> {
  late String _period = widget.initialPeriod ?? kDatePeriodLabels.first;
  DateTimeRange? _customRange;

  @override
  void initState() {
    super.initState();
    if (widget.initialPeriod != null &&
        widget.initialPeriod!.startsWith('Custom:')) {
      final (start, end) = parseCustomDateRange(widget.initialPeriod!);
      if (start != null && end != null) {
        _customRange = DateTimeRange(start: start, end: end);
      }
    }
  }

  /// Aggregate completed orders in [period] into headline totals + per-product
  /// rows (sorted by gross profit, descending). Lines whose captured buying
  /// price is 0 — cost was never recorded, e.g. a product created by a role
  /// without `products.edit_buying_price` — are treated as UNKNOWN cost and
  /// EXCLUDED from the profit math, exactly as the dashboard Net Profit
  /// (home_screen.dart) and the Sales breakdown do. Booking them at zero cost
  /// would overstate gross profit as 100% for those items. Their quantity is
  /// reported separately as [_ProfitData.uncostedItems] so the exclusion is
  /// transparent and Revenue − COGS always equals Gross Profit.
  ///
  /// [inScope] is the store predicate (#195) — `reconStoreFilter`, the SAME one
  /// the Daily Reconciliation uses, so it honours the §12.1 active store, a
  /// non-CEO's store confinement, and the van exclusion (#140/#142). It is
  /// applied PER LINE (and to the order's own store for the discount), matching
  /// the reconciliation exactly. Before #195 this screen read every store's
  /// orders whatever the lock said, so a locked-store Home and Recon showed the
  /// store while Profit showed the whole business — three screens, three
  /// answers, which is what US 28 forbids.
  _ProfitData _compute(
    List<OrderWithItems> orders,
    String period,
    bool Function(String? storeId) inScope,
  ) {
    final byProduct = <String, _ProductAccum>{};
    var revenueKobo = 0;
    var cogsKobo = 0;
    var uncostedItems = 0;
    var concessionKobo = 0;

    for (final o in orders) {
      // Recognized at checkout ('pending'), not at the ceremonial Confirm
      // ('completed'). Count any non-reversed sale.
      if (!orderCountsAsSale(o.order.status)) continue;
      if (!isDateInPeriod(o.order.createdAt, period)) continue;
      for (final i in o.items) {
        // #195 — per-LINE store scope, like the reconciliation. This also
        // carries the #140 van exclusion (a van fails `reconStoreFilter` by
        // construction): a van sale is not a store sale, its COGS is not
        // per-line (it is the trip's lot snapshot, booked at close), so
        // including it would report road revenue at 100% margin. Van P&L comes
        // from the closed-trip artifact instead (van-sales spec §5.4 / §8.1).
        if (!inScope(i.item.storeId)) continue;
        final product = i.product;
        // #200 / US 32 — the catalogue-price concession is a SELLING-price fact,
        // so it is counted before the uncosted skip below: a price cut on a line
        // whose cost was never recorded is still a price cut, and dropping it
        // would leave exactly the give-away this story exists to surface
        // invisible. (It therefore covers a wider line set than the per-product
        // rows, which follow the costed breakdown.)
        final lineConcession = lineConcessionKobo(
          cataloguePriceKobo: i.item.cataloguePriceKobo,
          unitPriceKobo: i.item.unitPriceKobo,
          quantity: i.item.quantity,
        );
        concessionKobo += lineConcession;
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
        acc.concessionKobo += lineConcession;
      }
    }

    final products =
        byProduct.values
            .map(
              (a) => _ProductProfit(
                name: a.name,
                qty: a.qty,
                revenueKobo: a.revenueKobo,
                cogsKobo: a.cogsKobo,
                concessionKobo: a.concessionKobo,
              ),
            )
            .toList()
          ..sort((a, b) => b.profitKobo.compareTo(a.profitKobo));

    return _ProfitData(
      revenueKobo: revenueKobo,
      cogsKobo: cogsKobo,
      products: products,
      uncostedItems: uncostedItems,
      concessionKobo: concessionKobo,
      // #176 — the single "Total Sales" definition shared with the Home
      // dashboard and the Daily Reconciliation (deposit-exclusive item lines
      // minus discounts, ALL lines incl. quick sales). Distinct from
      // [revenueKobo], which is costed-only so Revenue − COGS == Gross Profit.
      totalSalesKobo: computeTotalSalesKobo(
        orders,
        inSpan: (createdAt) => isDateInPeriod(createdAt, period),
        // #195 — the SAME store predicate the Revenue / COGS / Gross Profit
        // figures above apply, and the same one the reconciliation applies.
        // Without it this tile counted stores (and, per #142 / van-sales spec
        // §8.1, road sales) that everything under it did not, and the one
        // screen contradicted itself.
        inScope: inScope,
      ),
    );
  }

  Future<void> _exportCsv(_ProfitData data) async {
    // Mirror the on-screen gate: omit the raw Cost-of-goods column unless the
    // viewer holds `reports.see_cost_prices`. Cites the SAME named gate as the
    // on-screen headline (`.allowsNow` — a one-shot read in this export path),
    // so the two can't drift (issue #18).
    final canSeeCost = Gates.seeReportCostPrices.allowsNow(ref);
    final rows = <List<String>>[
      for (final p in data.products)
        [
          p.name,
          '${p.qty}',
          (p.revenueKobo / 100.0).toStringAsFixed(2),
          if (canSeeCost) (p.cogsKobo / 100.0).toStringAsFixed(2),
          (p.profitKobo / 100.0).toStringAsFixed(2),
          p.marginPct.toStringAsFixed(1),
          // #200 / US 32 — the concession travels with the export, so margin
          // review off-device sees the same give-away the screen shows.
          (p.concessionKobo / 100.0).toStringAsFixed(2),
        ],
    ];
    rows.add([
      'TOTAL',
      '',
      (data.revenueKobo / 100.0).toStringAsFixed(2),
      if (canSeeCost) (data.cogsKobo / 100.0).toStringAsFixed(2),
      (data.profitKobo / 100.0).toStringAsFixed(2),
      data.marginPct.toStringAsFixed(1),
      // Period total — counts every sold line, so it can exceed the sum of the
      // costed product rows above (see [_ProfitData.concessionKobo]).
      (data.concessionKobo / 100.0).toStringAsFixed(2),
    ]);
    try {
      final friendlyPeriod = formatPeriodLabel(_period);
      final sanitizedPeriod = friendlyPeriod
          .replaceAll(' ', '_')
          .replaceAll(',', '')
          .replaceAll('–', 'to');
      await shareCsv(
        csv: buildCsv([
          'Product',
          'Qty sold',
          'Revenue',
          if (canSeeCost) 'Cost of goods',
          'Gross profit',
          'Margin %',
          'Sold below list price',
        ], rows),
        fileName: 'profit_report_$sanitizedPeriod',
        subject: 'Profit Report — $friendlyPeriod',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    // `reports.see_cost_prices` ("See buying prices in reports") gates the raw
    // Cost-of-goods figure on top of the screen's upstream `reports.see_profit`
    // gate — so a CEO can grant someone the Profit Report yet withhold the raw
    // cost. Revenue / Gross Profit / Margin stay (they're `reports.see_profit`).
    final canSeeCost = Gates.seeReportCostPrices.allows(ref);
    final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
    // #195 — the §12.1 active store, the viewer's confinement and the van
    // exclusion, in the one predicate the Daily Reconciliation uses.
    final data = _compute(orders, _period, reconStoreFilter(ref));
    final hasCostedData = data.products.isNotEmpty;
    final hasAnySales = hasCostedData || data.uncostedItems > 0;

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'dashboard',
        backgroundColor: Colors.transparent,
        appBar: ReportTopBar(
          key: ReportKeys.topBar,
          height: reportTopBarHeight(context),
          header: ScreenHeader(
            leading: const ReportBackButton(),
            icon: AppIcons.chartPie,
            title: 'Profit Report',
            subtitle: ref.watch(activeStoreLabelProvider),
            actions: [
              ReportBarAction(
                key: ReportKeys.export,
                icon: AppIcons.fileCsv,
                tooltip: 'Export CSV',
                onPressed: hasCostedData ? () => _exportCsv(data) : null,
              ),
            ],
          ),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final gutter = reportGutter(context, constraints.maxWidth);
            return Column(
              children: [
                // The period filter moved from the old app bar (130dp wide)
                // to its own row, so the title keeps its room at 320dp.
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(12),
                    gutter,
                    context.getRSize(4),
                  ),
                  child: _periodDropdown(),
                ),
                Expanded(
                  child: !hasAnySales
                      ? const ReportEmpty(
                          icon: AppIcons.analytics,
                          message: 'No data for this period.',
                        )
                      : ListView(
                          padding: EdgeInsets.fromLTRB(
                            gutter,
                            context.getRSize(8),
                            gutter,
                            context.getRSize(16) + context.deviceBottomPadding,
                          ),
                          children: [
                            if (hasCostedData)
                              _headline(theme, data, canSeeCost),
                            if (data.uncostedItems > 0) ...[
                              if (hasCostedData)
                                SizedBox(height: context.getRSize(12)),
                              _uncostedNote(
                                theme,
                                data.uncostedItems,
                                allUncosted: !hasCostedData,
                              ),
                            ],
                            if (hasCostedData) ...[
                              SizedBox(height: context.getRSize(12)),
                              _breakdownCard(theme, data),
                            ],
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _periodDropdown() {
    return AppDropdown<String>(
      key: ReportKeys.period,
      value: _period.startsWith('Custom:') ? 'Custom' : _period,
      items: kDatePeriodLabels
          .map(
            (p) => DropdownMenuItem(
              value: p,
              child: Text(
                p,
                style: context
                    .mediumStyle(14)
                    .copyWith(color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
          )
          .toList(),
      onChanged: (v) async {
        if (v == 'Custom') {
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
              _period =
                  'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
            });
          }
        } else if (v != null) {
          setState(() {
            _period = v;
            _customRange = null;
          });
        }
      },
    );
  }

  Widget _uncostedNote(
    ThemeData theme,
    int items, {
    required bool allUncosted,
  }) {
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    return ReportCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconTile(
            icon: AppIcons.infoCircle,
            tone: IconTileTone.warning,
            size: 36,
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Text(
              allUncosted
                  ? '$items item${items == 1 ? '' : 's'} sold this period had no '
                        'recorded buying price, so profit can\'t be calculated.'
                  : 'Profit excludes $items item${items == 1 ? '' : 's'} sold '
                        'with no recorded buying price.',
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headline(ThemeData theme, _ProfitData data, bool canSeeCost) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final profit = data.profitKobo;
    final color = profit >= 0 ? f.green : f.danger;
    return ReportHeadlineCard(
      icon: AppIcons.analytics,
      tone: profit >= 0 ? IconTileTone.green : IconTileTone.danger,
      label: 'Gross Profit',
      figure: formatCurrency(profit / 100.0),
      figureColor: color,
      chips: [
        // #176 — the shared "Total Sales" (all lines − discounts,
        // deposit-exclusive), identical to the Home dashboard and the
        // Daily Reconciliation for the same period.
        ReportChip(
          'Total sales: ${formatCurrency(data.totalSalesKobo / 100.0)}',
        ),
        ReportChip(
          'Costed revenue: ${formatCurrency(data.revenueKobo / 100.0)}',
        ),
        if (canSeeCost)
          ReportChip('Cost of goods: ${formatCurrency(data.cogsKobo / 100.0)}'),
        ReportChip('Margin: ${data.marginPct.toStringAsFixed(1)}%'),
        // #200 / US 32 — the catalogue-price concession, the reason a
        // margin can read low without a single recorded discount. Shown
        // only when a price was actually overridden this period; the label
        // carries the direction so the amount never needs a minus sign.
        if (data.concessionKobo != 0)
          ReportChip(
            '${data.concessionKobo > 0 ? 'Sold below list price' : 'Sold above list price'}: '
            '${formatCurrency(data.concessionKobo.abs() / 100.0)}',
          ),
      ],
    );
  }

  Widget _breakdownCard(ThemeData theme, _ProfitData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ReportGroupLabel('By product'),
        SizedBox(height: context.getRSize(10)),
        ReportCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < data.products.length; i++) ...[
                if (i > 0) const ReportDivider(),
                _productRow(theme, data.products[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _productRow(ThemeData theme, _ProductProfit p) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    final color = p.profitKobo >= 0 ? f.green : f.danger;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.name,
                style: context
                    .boldStyle(14)
                    .copyWith(color: theme.colorScheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: context.getRSize(2)),
              Text(
                '×${p.qty}  ·  Rev ${formatCurrency(p.revenueKobo / 100.0)}  ·  ${p.marginPct.toStringAsFixed(1)}%',
                style: context.regularStyle(12).copyWith(color: muted),
              ),
              // #200 / US 32 — per-product concession, so margin review can see
              // WHICH product the money was given away on, not just the total.
              if (p.concessionKobo != 0)
                Text(
                  p.concessionKobo > 0
                      ? 'Sold below list price by '
                            '${formatCurrency(p.concessionKobo / 100.0)}'
                      : 'Sold above list price by '
                            '${formatCurrency(p.concessionKobo.abs() / 100.0)}',
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
            ],
          ),
        ),
        SizedBox(width: context.getRSize(8)),
        Text(
          formatCurrency(p.profitKobo / 100.0),
          style: context.extraBoldStyle(14).copyWith(color: color),
        ),
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
    required this.concessionKobo,
    required this.totalSalesKobo,
  });

  /// Revenue of the cost-known lines only (matches [cogsKobo]'s line set so the
  /// headline stays self-consistent: Revenue − COGS == Gross Profit).
  final int revenueKobo;
  final int cogsKobo;
  final List<_ProductProfit> products;

  /// Quantity of sold items excluded from the profit math because their captured
  /// buying price was 0 (cost never recorded). Surfaced as a transparency note.
  final int uncostedItems;

  /// #200 / PRD #155 US 32 — money given away by selling below the tier list
  /// price ("catalogue − charged", from `order_items.catalogue_price_kobo`).
  /// Positive = the shop charged less than list; negative = more. Summed over
  /// EVERY sold line in the period (see `_compute`), so it is not limited to the
  /// costed lines the per-product rows below cover. It does NOT enter
  /// [revenueKobo]/[cogsKobo]/[profitKobo]: the concession is already inside the
  /// price that was charged, so subtracting it again would double-count. It is
  /// reported beside the margin as the review figure the story asked for.
  final int concessionKobo;

  /// The single "Total Sales" for the period (#176) — deposit-exclusive item
  /// lines minus discounts over ALL sold lines (including quick sales), shared
  /// with the Home dashboard and Daily Reconciliation. Distinct from
  /// [revenueKobo] (costed-only) which drives the margin.
  final int totalSalesKobo;

  int get profitKobo => revenueKobo - cogsKobo;
  double get marginPct => revenueKobo > 0 ? profitKobo / revenueKobo * 100 : 0;
}

class _ProductAccum {
  _ProductAccum(this.name);
  final String name;
  int qty = 0;
  int revenueKobo = 0;
  int cogsKobo = 0;
  int concessionKobo = 0;
}

class _ProductProfit {
  _ProductProfit({
    required this.name,
    required this.qty,
    required this.revenueKobo,
    required this.cogsKobo,
    required this.concessionKobo,
  });

  final String name;
  final int qty;
  final int revenueKobo;
  final int cogsKobo;

  /// Money given away on this product by selling below its list price (#200 /
  /// US 32). See [_ProfitData.concessionKobo].
  final int concessionKobo;

  int get profitKobo => revenueKobo - cogsKobo;
  double get marginPct => revenueKobo > 0 ? profitKobo / revenueKobo * 100 : 0;
}
