import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';

/// Shows when the user taps "Total Sales" or "Net Profit" on the dashboard.
/// [mode] = 'sales' → revenue-focused columns.
/// [mode] = 'profit' → adds a Profit/Loss column per item.
class SalesDetailScreen extends ConsumerStatefulWidget {
  final List<OrderWithItems> orders;
  final String mode; // 'sales' | 'profit'
  final String period;

  const SalesDetailScreen({
    super.key,
    required this.orders,
    required this.mode,
    required this.period,
  });

  @override
  ConsumerState<SalesDetailScreen> createState() => _SalesDetailScreenState();
}

class _SalesDetailScreenState extends ConsumerState<SalesDetailScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loading = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    // Build flat list of rows — one row per item per order
    final rows = <_SaleRow>[];
    for (final o in widget.orders) {
      for (final i in o.items) {
        final revenue = i.item.quantity * i.item.unitPriceKobo / 100.0;
        final cogs = i.item.buyingPriceKobo > 0
            ? i.item.quantity * i.item.buyingPriceKobo / 100.0
            : null;
        final profit = cogs != null ? revenue - cogs : null;
        rows.add(
          _SaleRow(
            date: o.order.createdAt,
            productName: i.product.name,
            qty: i.item.quantity,
            revenue: revenue,
            profit: profit,
          ),
        );
      }
    }

    // Sort newest first
    rows.sort((a, b) => b.date.compareTo(a.date));

    // Totals
    final totalRevenue = rows.fold<double>(0, (s, r) => s + r.revenue);
    final hasProfit = rows.any((r) => r.profit != null);
    final totalProfit = hasProfit
        ? rows.fold<double>(0, (s, r) => s + (r.profit ?? 0))
        : null;

    final isProfitMode = widget.mode == 'profit';
    final headerValue = isProfitMode && totalProfit != null
        ? totalProfit
        : totalRevenue;
    final headerLabel = isProfitMode ? 'Net Profit' : 'Total Sales';
    final headerColor = isProfitMode && totalProfit != null
        ? (totalProfit >= 0 ? const Color(0xFF22C55E) : colorScheme.error)
        : colorScheme.primary;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 18,
            color: colorScheme.onSurface,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$headerLabel Breakdown',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: colorScheme.onSurface,
              ),
            ),
            Text(
              widget.period,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : rows.isEmpty
          ? _buildEmpty(context)
          : Column(
              children: [
                // ── Summary card at the top ──────────────────────────────
                _buildSummaryCard(
                  context,
                  label: headerLabel,
                  value: headerValue,
                  color: headerColor,
                  rowCount: rows.length,
                  totalRevenue: totalRevenue,
                  totalProfit: totalProfit,
                  isProfitMode: isProfitMode,
                ),
                // ── Table header ─────────────────────────────────────────
                _buildTableHeader(
                  context,
                  showProfit: isProfitMode && hasProfit,
                ),
                const Divider(height: 1),
                // ── Rows ─────────────────────────────────────────────────
                Expanded(
                  child: ListView.separated(
                    padding: EdgeInsets.only(bottom: context.deviceBottomInset),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: theme.dividerColor),
                    itemBuilder: (ctx, idx) => _buildRow(
                      ctx,
                      rows[idx],
                      showProfit: isProfitMode && hasProfit,
                      isEven: idx.isEven,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.chartLine,
            size: 48,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'No sales data for this period',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
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
    required bool isProfitMode,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: EdgeInsets.all(context.spacingM),
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
              Icon(
                isProfitMode
                    ? FontAwesomeIcons.chartLine
                    : FontAwesomeIcons.nairaSign,
                color: color,
                size: context.getRSize(18),
              ),
              SizedBox(width: context.getRSize(8)),
              Text(
                label,
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            formatCurrency(value),
            style: TextStyle(
              fontSize: context.getRFontSize(28),
              fontWeight: FontWeight.w900,
              color: theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Row(
            children: [
              _chip(context, '$rowCount item${rowCount == 1 ? '' : 's'} sold'),
              if (isProfitMode && totalProfit != null) ...[
                SizedBox(width: context.getRSize(8)),
                _chip(context, 'Revenue: ${formatCurrency(totalRevenue)}'),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String text) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: context.getRFontSize(11),
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildTableHeader(BuildContext context, {required bool showProfit}) {
    final subtext = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.45);
    final style = TextStyle(
      fontSize: context.getRFontSize(11),
      fontWeight: FontWeight.w700,
      color: subtext,
      letterSpacing: 0.5,
    );

    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingM,
        vertical: context.getRSize(10),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('PRODUCT', style: style)),
          SizedBox(
            width: context.getRSize(50),
            child: Text('QTY', style: style, textAlign: TextAlign.center),
          ),
          SizedBox(
            width: context.getRSize(80),
            child: Text('REVENUE', style: style, textAlign: TextAlign.right),
          ),
          if (showProfit)
            SizedBox(
              width: context.getRSize(80),
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
    required bool isEven,
  }) {
    final theme = Theme.of(context);
    final profitColor = row.profit == null
        ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
        : (row.profit! >= 0
              ? const Color(0xFF22C55E)
              : theme.colorScheme.error);

    return Container(
      color: isEven
          ? Colors.transparent
          : theme.colorScheme.onSurface.withValues(alpha: 0.02),
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingM,
        vertical: context.getRSize(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Product + Date
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.productName,
                  style: TextStyle(
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  DateFormat('dd MMM, HH:mm').format(row.date),
                  style: TextStyle(
                    fontSize: context.getRFontSize(11),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
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
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          // Revenue
          SizedBox(
            width: context.getRSize(80),
            child: Text(
              formatCurrency(row.revenue),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          // Profit/Loss
          if (showProfit)
            SizedBox(
              width: context.getRSize(80),
              child: Text(
                row.profit != null ? formatCurrency(row.profit!) : '—',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w700,
                  color: profitColor,
                ),
              ),
            ),
        ],
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
