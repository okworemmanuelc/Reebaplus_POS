import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_cards.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// The Sales and Stock History cards of Product Details (#487 PR 5). Plain data
// in, theme-only styling, no database: the screen reads, these draw.

Color _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
}

// ── Sales ────────────────────────────────────────────────────────────────────

/// "Sales": a Week | Month switch, the units sold, Revenue and Profit tiles and
/// a bar per day drawn with plain widgets. [days] runs oldest to today (see
/// `OrdersDao.getProductSalesByDay`); null while it loads.
class ProductSalesCard extends StatefulWidget {
  const ProductSalesCard({
    super.key,
    required this.days,
    required this.unit,
    required this.crates,
    required this.showProfit,
  });

  final List<ProductDaySales>? days;
  final String? unit;
  final bool crates;

  /// Profit needs `Gates.editBuyingPrice`.
  final bool showProfit;

  @override
  State<ProductSalesCard> createState() => _ProductSalesCardState();
}

class _ProductSalesCardState extends State<ProductSalesCard> {
  bool _month = false;

  List<ProductDaySales> _window(List<ProductDaySales> all) {
    if (all.isEmpty) return all;
    if (!_month) return all.length <= 7 ? all : all.sublist(all.length - 7);
    final m = all.last.date.month;
    return [
      for (final d in all)
        if (d.date.month == m) d,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = _muted(context);
    final all = widget.days;
    final window = all == null ? const <ProductDaySales>[] : _window(all);
    final units = window.fold<int>(0, (a, d) => a + d.units);
    final revenue = window.fold<int>(0, (a, d) => a + d.revenueKobo);
    final profit = window.fold<int>(0, (a, d) => a + d.profitKobo);
    final uncosted = window.any((d) => d.hasUncosted);
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.analytics,
            title: 'Sales',
            trailing: _PeriodSwitch(
              month: _month,
              onChanged: (m) => setState(() => _month = m),
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            _month ? 'This month' : 'Last 7 days',
            style: context.regularStyle(13).copyWith(color: muted),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                all == null ? '—' : '$units',
                style: context
                    .extraBoldStyle(30)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              SizedBox(width: context.getRSize(6)),
              Expanded(
                child: Text(
                  '${unitCountNoun(widget.unit, units, crates: widget.crates)} sold',
                  style: context.regularStyle(15).copyWith(color: muted),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          Row(
            children: [
              Expanded(
                child: _FigureTile(
                  label: 'Revenue',
                  value: all == null ? '—' : formatCurrency(revenue / 100),
                ),
              ),
              if (widget.showProfit) ...[
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: _FigureTile(
                    label: 'Profit',
                    value: all == null ? '—' : formatCurrency(profit / 100),
                  ),
                ),
              ],
            ],
          ),
          if (widget.showProfit && uncosted) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              'Some sales have no cost yet, so profit leaves them out.',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
          ],
          SizedBox(height: context.getRSize(14)),
          if (all == null)
            SizedBox(
              height: context.getRSize(140),
              child: const Center(child: CircularProgressIndicator()),
            )
          else
            _DayBars(days: window, month: _month),
        ],
      ),
    );
  }
}

class _FigureTile extends StatelessWidget {
  const _FigureTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(context.getRSize(10)),
      decoration: BoxDecoration(
        color: t.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            style: context.semiBoldStyle(12).copyWith(color: _muted(context)),
          ),
          SizedBox(height: context.getRSize(2)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: context
                  .extraBoldStyle(16)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodSwitch extends StatelessWidget {
  const _PeriodSwitch({required this.month, required this.onChanged});

  final bool month;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget seg(String label, bool isMonth) {
      final on = month == isMonth;
      return Semantics(
        button: true,
        selected: on,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
          onTap: () => onChanged(isMonth),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: kMinInteractiveDimension,
              minHeight: kMinInteractiveDimension,
            ),
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(7),
                ),
                decoration: BoxDecoration(
                  color: on ? t.colorScheme.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
                ),
                child: Text(
                  label,
                  style:
                      (on ? context.boldStyle(13) : context.semiBoldStyle(13))
                          .copyWith(
                            color: on
                                ? t.colorScheme.onSurface
                                : _muted(context),
                          ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: t.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('Week', false), seg('Month', true)],
      ),
    );
  }
}

/// A bar per day, tallest = full height. The value label sits above today's
/// bar only; the labels under the bars are weekday names for a week and day
/// numbers (every fifth) for a month.
class _DayBars extends StatelessWidget {
  const _DayBars({required this.days, required this.month});

  final List<ProductDaySales> days;
  final bool month;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = _muted(context);
    final maxUnits = days.fold<int>(0, (a, d) => d.units > a ? d.units : a);
    final chartH = context.getRSize(110);
    final gap = month ? 2.0 : 8.0;
    String label(int i) {
      if (i == days.length - 1) return 'Today';
      final d = days[i].date;
      if (!month) return DateFormat('E').format(d);
      return (d.day == 1 || d.day % 5 == 0) ? '${d.day}' : '';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: gap / 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: chartH + context.getRSize(28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (i == days.length - 1)
                          Text(
                            '${days[i].units}',
                            maxLines: 1,
                            style: context
                                .semiBoldStyle(12)
                                .copyWith(color: t.colorScheme.onSurface),
                          ),
                        SizedBox(height: context.getRSize(2)),
                        Container(
                          height: maxUnits == 0 || days[i].units == 0
                              ? context.getRSize(3)
                              : chartH * days[i].units / maxUnits,
                          decoration: BoxDecoration(
                            color: days[i].units == 0
                                ? t.dividerColor
                                : t.colorScheme.primary,
                            borderRadius: BorderRadius.circular(
                              AppSpacing.borderRadiusS,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: context.getRSize(6)),
                  SizedBox(
                    height: context.getRSize(16),
                    child: OverflowBox(
                      maxWidth: context.getRSize(48),
                      child: Text(
                        label(i),
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                        style: context.regularStyle(11).copyWith(color: muted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ── Stock History ────────────────────────────────────────────────────────────

/// The last few stock movements of the product with a "View All" link.
class ProductStockHistoryCard extends StatelessWidget {
  const ProductStockHistoryCard({
    super.key,
    required this.rows,
    required this.loading,
    required this.unit,
    required this.crates,
    required this.now,
    required this.onViewAll,
  });

  final List<StockTransactionWithDetails> rows;
  final bool loading;
  final String? unit;
  final bool crates;
  final DateTime now;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DetailPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.history,
            title: 'Stock History',
            trailing: TextButton(
              onPressed: onViewAll,
              style: TextButton.styleFrom(
                minimumSize: const Size(
                  kMinInteractiveDimension,
                  kMinInteractiveDimension,
                ),
              ),
              child: Text(
                'View All',
                style: context
                    .boldStyle(14)
                    .copyWith(color: t.colorScheme.primary),
              ),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          if (loading && rows.isEmpty)
            Padding(
              padding: EdgeInsets.all(context.getRSize(20)),
              child: const Center(child: CircularProgressIndicator()),
            )
          else if (rows.isEmpty)
            Padding(
              padding: EdgeInsets.all(context.getRSize(20)),
              child: Center(
                child: Text(
                  'No stock movements yet',
                  style: context
                      .regularStyle(13)
                      .copyWith(color: _muted(context)),
                ),
              ),
            )
          else
            for (var i = 0; i < rows.length && i < 5; i++) ...[
              if (i > 0) Divider(height: 1, color: t.dividerColor),
              StockMovementRow(
                tx: rows[i],
                unit: unit,
                crates: crates,
                now: now,
              ),
            ],
        ],
      ),
    );
  }
}

/// One stock movement: type tile, title, "Store · time", signed quantity.
class StockMovementRow extends StatelessWidget {
  const StockMovementRow({
    super.key,
    required this.tx,
    required this.unit,
    required this.crates,
    required this.now,
  });

  final StockTransactionWithDetails tx;
  final String? unit;
  final bool crates;
  final DateTime now;

  static String titleOf(StockTransactionWithDetails tx) {
    switch (tx.movementType) {
      case 'adjustment':
        final r = tx.adjustmentReason?.trim();
        return (r == null || r.isEmpty) ? 'Adjustment' : 'Adjustment: $r';
      case 'transfer_in':
      case 'transfer_out':
        return 'Transfer';
      default:
        return tx.movementLabel;
    }
  }

  static (IconData, IconTileTone) _look(String type) => switch (type) {
    'sale' => (AppIcons.cart, IconTileTone.info),
    'purchase_received' => (AppIcons.download, IconTileTone.green),
    'adjustment' => (AppIcons.tune, IconTileTone.warning),
    'transfer_in' ||
    'transfer_out' ||
    'transfer_cancelled' => (AppIcons.swap, IconTileTone.info),
    'return' => (AppIcons.download, IconTileTone.green),
    'damage' => (AppIcons.warning, IconTileTone.danger),
    _ => (AppIcons.history, IconTileTone.neutral),
  };

  static String whenOf(DateTime at, DateTime now) {
    final local = at.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    final time = DateFormat('h:mm a').format(local);
    if (diff == 0) return 'Today, $time';
    if (diff == 1) return 'Yesterday, $time';
    return '${DateFormat('d MMM').format(local)}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final (icon, tone) = _look(tx.movementType);
    final q = tx.quantityDelta;
    final store = tx.storeName ?? '';
    final sub = [
      if (store.isNotEmpty) store,
      whenOf(tx.createdAt, now),
    ].join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
        child: Row(
          children: [
            IconTile(icon: icon, tone: tone, size: 44),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleOf(tx),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .boldStyle(15)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .regularStyle(12)
                        .copyWith(color: _muted(context)),
                  ),
                ],
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  q > 0 ? '+$q' : '$q',
                  style: context
                      .extraBoldStyle(16)
                      .copyWith(color: q > 0 ? f.green : f.danger),
                ),
                Text(
                  unitCountNoun(unit, q.abs(), crates: crates),
                  style: context
                      .regularStyle(12)
                      .copyWith(color: _muted(context)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
