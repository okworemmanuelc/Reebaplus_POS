import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

/// Shows when the user taps "Total Sales" or "Net Profit" on the dashboard.
/// [mode] = 'sales' → revenue-focused columns.
/// [mode] = 'profit' → adds a Profit/Loss column per item.
///
/// #195 — the headline here must equal the tile that opened it. Two things make
/// that true: the per-line [inScope] predicate (the same one the tile summed
/// with), and subtracting the orders' discounts from the header total. The
/// header used to sum item lines with NO discount subtracted, so tapping Total
/// Sales opened a BIGGER number than the tile it came from.
class SalesDetailScreen extends ConsumerStatefulWidget {
  final List<OrderWithItems> orders;
  final String mode; // 'sales' | 'profit'
  final String period;

  /// Store predicate applied per line, matching the tile's own scope. Defaults
  /// to every store for a caller that has already filtered its orders.
  final bool Function(String? storeId) inScope;

  const SalesDetailScreen({
    super.key,
    required this.orders,
    required this.mode,
    required this.period,
    this.inScope = _anyStore,
  });

  @override
  ConsumerState<SalesDetailScreen> createState() => _SalesDetailScreenState();
}

bool _anyStore(String? _) => true;

class _SalesDetailScreenState extends ConsumerState<SalesDetailScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loading = false;
  }

  /// The discounts given on the orders in view, scoped by each order's own
  /// store exactly as [computeTotalSalesKobo] scopes them. Contra-revenue: it
  /// is subtracted from BOTH the revenue and the profit totals, since a
  /// discount is money neither earned nor kept.
  double _discountTotal() {
    var kobo = 0;
    for (final o in widget.orders) {
      kobo += orderDiscountKobo(o, inScope: widget.inScope);
    }
    return kobo / 100.0;
  }

  // Flat list of rows — one row per item per order, newest first.
  List<_SaleRow> _buildRows() {
    final rows = <_SaleRow>[];
    for (final o in widget.orders) {
      for (final i in o.items) {
        if (!widget.inScope(i.item.storeId)) continue;
        final revenue = i.item.quantity * i.item.unitPriceKobo / 100.0;
        final cogs = i.item.buyingPriceKobo > 0
            ? i.item.quantity * i.item.buyingPriceKobo / 100.0
            : null;
        final profit = cogs != null ? revenue - cogs : null;
        rows.add(
          _SaleRow(
            date: o.order.createdAt,
            // §12.3 Quick Sale: no product → name from the price snapshot.
            productName: i.displayName,
            qty: i.item.quantity,
            revenue: revenue,
            profit: profit,
          ),
        );
      }
    }
    rows.sort((a, b) => b.date.compareTo(a.date));
    return rows;
  }

  // CSV columns mirror the on-screen table: the Profit column only in profit mode.
  Future<void> _exportCsv() async {
    final isProfit = widget.mode == 'profit';
    final rows = _buildRows();
    final csvRows = <List<String>>[
      for (final r in rows)
        [
          DateFormat('yyyy-MM-dd HH:mm').format(r.date),
          r.productName,
          '${r.qty}',
          r.revenue.toStringAsFixed(2),
          if (isProfit) (r.profit != null ? r.profit!.toStringAsFixed(2) : ''),
        ],
    ];
    // #195 — the order-level discount lives on no row, so the export closes
    // with the same netted totals the screen shows. Summing the item rows alone
    // would reproduce exactly the gross-vs-net contradiction this issue fixed.
    final discounts = _discountTotal();
    if (discounts != 0) {
      csvRows.add([
        '',
        'Less discounts',
        '',
        (-discounts).toStringAsFixed(2),
        if (isProfit) (-discounts).toStringAsFixed(2),
      ]);
    }
    final grossRevenue = rows.fold<double>(0, (s, r) => s + r.revenue);
    final hasProfit = rows.any((r) => r.profit != null);
    csvRows.add([
      '',
      'TOTAL',
      '${rows.fold<int>(0, (s, r) => s + r.qty)}',
      (grossRevenue - discounts).toStringAsFixed(2),
      if (isProfit)
        hasProfit
            ? (rows.fold<double>(0, (s, r) => s + (r.profit ?? 0)) - discounts)
                  .toStringAsFixed(2)
            : '',
    ]);
    try {
      await shareCsv(
        csv: buildCsv(
          isProfit
              ? ['Date', 'Product', 'Qty', 'Revenue', 'Profit']
              : ['Date', 'Product', 'Qty', 'Revenue'],
          csvRows,
        ),
        fileName:
            '${isProfit ? 'profit' : 'sales'}_report_${widget.period.replaceAll(' ', '_')}',
        subject: '${isProfit ? 'Profit' : 'Sales'} — ${widget.period}',
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
    final colorScheme = theme.colorScheme;
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;

    final rows = _buildRows();

    // Totals. #195 — the discount is order-level, so it cannot live on a row;
    // it is netted out of both totals here so this screen states the same
    // "Total Sales" (item lines − discounts, deposit-exclusive) the dashboard
    // tile did. The discount chip below shows the amount, so the rows still add
    // up to a figure the reader can see.
    final discounts = _discountTotal();
    final grossRevenue = rows.fold<double>(0, (s, r) => s + r.revenue);
    final totalRevenue = grossRevenue - discounts;
    final hasProfit = rows.any((r) => r.profit != null);
    final totalProfit = hasProfit
        ? rows.fold<double>(0, (s, r) => s + (r.profit ?? 0)) - discounts
        : null;

    final isProfitMode = widget.mode == 'profit';
    final headerValue = isProfitMode && totalProfit != null
        ? totalProfit
        : totalRevenue;
    final headerLabel = isProfitMode ? 'Net Profit' : 'Total Sales';
    final headerColor = isProfitMode && totalProfit != null
        ? (totalProfit >= 0 ? f.green : f.danger)
        : colorScheme.primary;

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: ReportTopBar(
          key: ReportKeys.topBar,
          height: reportTopBarHeight(context),
          header: ScreenHeader(
            leading: const ReportBackButton(),
            icon: isProfitMode ? AppIcons.analytics : AppIcons.naira,
            title: '$headerLabel Breakdown',
            subtitle: widget.period,
            actions: [
              ReportBarAction(
                key: ReportKeys.export,
                icon: AppIcons.fileCsv,
                tooltip: 'Export CSV',
                onPressed: rows.isEmpty ? null : _exportCsv,
              ),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : rows.isEmpty
            ? _buildEmpty(context)
            : LayoutBuilder(
                builder: (context, constraints) {
                  final gutter = reportGutter(context, constraints.maxWidth);
                  final showProfit = isProfitMode && hasProfit;
                  return CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          context.getRSize(16),
                          gutter,
                          0,
                        ),
                        sliver: SliverToBoxAdapter(
                          // ── Summary card at the top ──────────────────
                          child: _buildSummaryCard(
                            context,
                            label: headerLabel,
                            value: headerValue,
                            color: headerColor,
                            rowCount: rows.length,
                            totalRevenue: totalRevenue,
                            totalProfit: totalProfit,
                            discounts: discounts,
                            isProfitMode: isProfitMode,
                          ),
                        ),
                      ),
                      // ── Table header ─────────────────────────────────
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          context.getRSize(8),
                          gutter,
                          context.getRSize(4),
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _buildTableHeader(
                            context,
                            showProfit: showProfit,
                          ),
                        ),
                      ),
                      // ── Rows ─────────────────────────────────────────
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          0,
                          gutter,
                          context.getRSize(16) + context.deviceBottomPadding,
                        ),
                        sliver: SliverList.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, _) =>
                              SizedBox(height: context.getRSize(8)),
                          itemBuilder: (ctx, idx) =>
                              _buildRow(ctx, rows[idx], showProfit: showProfit),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return const ReportEmpty(
      icon: AppIcons.analytics,
      message: 'No sales data for this period',
    );
  }

  Widget _buildSummaryCard(
    BuildContext context, {
    required String label,
    required double value,
    required Color color,
    required int rowCount,
    required double totalRevenue,
    required double? totalProfit,
    required double discounts,
    required bool isProfitMode,
  }) {
    return ReportHeadlineCard(
      icon: isProfitMode ? AppIcons.analytics : AppIcons.naira,
      tone: isProfitMode ? IconTileTone.green : IconTileTone.info,
      label: label,
      figure: formatCurrency(value),
      figureColor: color,
      chips: [
        ReportChip('$rowCount item${rowCount == 1 ? '' : 's'} sold'),
        if (isProfitMode && totalProfit != null)
          ReportChip('Revenue: ${formatCurrency(totalRevenue)}'),
        // #195 — the order-level discount that the per-item rows below
        // cannot show. Without it the rows would look like they don't add
        // up to the headline.
        if (discounts != 0)
          ReportChip('Less discounts: ${formatCurrency(discounts)}'),
      ],
    );
  }

  Widget _buildTableHeader(BuildContext context, {required bool showProfit}) {
    final muted =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).colorScheme.onSurface;
    final style = context
        .boldStyle(11)
        .copyWith(color: muted, letterSpacing: 0.5);
    // Same inset as a row card (1 border + 14 padding), so the labels sit over
    // their columns.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.getRSize(15)),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('PRODUCT', style: style)),
          SizedBox(
            width: context.getRSize(50),
            child: Text('QTY', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(88),
            child: Text('REVENUE', style: style, textAlign: TextAlign.right),
          ),
          if (showProfit)
            SizedBox(
              width: context.getRSize(88),
              child: Text('PROFIT', style: style, textAlign: TextAlign.right),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    _SaleRow row, {
    required bool showProfit,
  }) {
    final theme = Theme.of(context);
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    final profitColor = row.profit == null
        ? muted
        : (row.profit! >= 0 ? f.green : f.danger);

    return ReportCard(
      padding: EdgeInsets.all(context.getRSize(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 34),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Product + Date
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.productName,
                    style: context
                        .boldStyle(14)
                        .copyWith(color: theme.colorScheme.onSurface),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    DateFormat('dd MMM, HH:mm').format(row.date),
                    style: context.regularStyle(12).copyWith(color: muted),
                  ),
                ],
              ),
            ),
            // Qty
            SizedBox(
              width: context.getRSize(50),
              child: Text(
                '×${row.qty}',
                textAlign: TextAlign.center,
                style: context
                    .boldStyle(13)
                    .copyWith(color: theme.colorScheme.primary),
              ),
            ),
            // Revenue
            SizedBox(
              width: context.getRSize(88),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  formatCurrency(row.revenue),
                  maxLines: 1,
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: theme.colorScheme.onSurface),
                ),
              ),
            ),
            // Profit/Loss
            if (showProfit)
              SizedBox(
                width: context.getRSize(88),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    row.profit != null ? formatCurrency(row.profit!) : '—',
                    maxLines: 1,
                    style: context
                        .extraBoldStyle(13)
                        .copyWith(color: profitColor),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SaleRow {
  final DateTime date;
  final String productName;
  final int qty;
  final double revenue;
  final double? profit;

  _SaleRow({
    required this.date,
    required this.productName,
    required this.qty,
    required this.revenue,
    required this.profit,
  });
}
