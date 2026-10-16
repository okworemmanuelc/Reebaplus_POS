import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// The Inventory screen's History tab.
///
/// **This widget builds a sliver, not a box.** It is placed directly into the
/// tab's [CustomScrollView] by [TabbedSliverScaffold], so the period chips and
/// the table header scroll away with the list instead of sitting in a fixed
/// band above an [Expanded] remainder — the shape that starved the list to zero
/// height on short viewports (PRD #239).
class InventoryHistoryTab extends ConsumerStatefulWidget {
  final String? storeId;

  const InventoryHistoryTab({super.key, this.storeId});

  @override
  ConsumerState<InventoryHistoryTab> createState() =>
      _InventoryHistoryTabState();
}

class _InventoryHistoryTabState extends ConsumerState<InventoryHistoryTab> {
  String _selectedPeriod = 'Today';

  static const _periods = ['Today', '7 Days', '30 Days', 'All'];

  void _onPeriodChanged(String period) {
    setState(() {
      _selectedPeriod = period;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wId = widget.storeId is String && widget.storeId.toString() == 'all'
        ? null
        : widget.storeId;

    final pageState = ref.watch(
      paginatedStockHistoryProvider((storeId: wId, period: _selectedPeriod)),
    );
    final statsAsync = ref.watch(
      stockHistoryStatsProvider((storeId: wId, period: _selectedPeriod)),
    );

    if (pageState.isLoading) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (pageState.transactions.isEmpty) {
      return _buildEmptyState(context);
    }

    final stats = statsAsync.valueOrNull ?? StockHistoryStats.empty();
    final totalIn = stats.totalIn;
    final totalOut = stats.totalOut;

    final txns = pageState.transactions;
    final childCount = txns.length + (pageState.isLoadingMore ? 1 : 0);

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.crossAxisExtent);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(12),
            gutter,
            context.getRSize(120) + context.deviceBottomPadding,
          ),
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildPeriodSelector(context),
                    SizedBox(height: context.getRSize(12)),
                    _buildSummaryRow(context, totalIn, totalOut),
                    SizedBox(height: context.getRSize(16)),
                    _buildTableHeader(context),
                  ],
                ),
              ),
              // The rows sit in the same flat card as the header (#392).
              DecoratedSliver(
                decoration: _tableBodyDecoration(context),
                sliver: SliverList.builder(
                  itemCount: childCount,
                  itemBuilder: (context, index) {
                    if (pageState.hasMore &&
                        !pageState.isLoadingMore &&
                        index >= txns.length - 5) {
                      Future.microtask(() {
                        if (mounted) {
                          ref
                              .read(
                                paginatedStockHistoryProvider((
                                  storeId: wId,
                                  period: _selectedPeriod,
                                )).notifier,
                              )
                              .loadMore();
                        }
                      });
                    }

                    if (index == txns.length) {
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: context.spacingM,
                        ),
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    }

                    return _buildTransactionRow(context, txns[index], index);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Period pills (scroll sideways on small screens) ──────────────────────
  Widget _buildPeriodSelector(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < _periods.length; i++) ...[
            if (i > 0) SizedBox(width: context.getRSize(8)),
            InventoryPeriodChip(
              label: _periods[i],
              selected: _periods[i] == _selectedPeriod,
              onTap: () => _onPeriodChanged(_periods[i]),
            ),
          ],
        ],
      ),
    );
  }

  // ── Summary cards ────────────────────────────────────────────────────────
  Widget _buildSummaryRow(BuildContext context, int totalIn, int totalOut) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InventoryFigureCard(
              label: 'Stock In',
              value: '+${fmtNumber(totalIn)} units',
              icon: AppIcons.arrowDown,
              tone: IconTileTone.green,
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: InventoryFigureCard(
              label: 'Stock Out',
              value: '-${fmtNumber(totalOut)} units',
              icon: AppIcons.arrowUp,
              tone: IconTileTone.danger,
            ),
          ),
        ],
      ),
    );
  }

  /// The card under the header: the flat card's fill, border and shadow with
  /// only the bottom corners rounded, so header + rows read as one table.
  BoxDecoration _tableBodyDecoration(BuildContext context) {
    const radius = Radius.circular(AppSpacing.borderRadiusXL);
    return AppDecorations.card(
      context,
    ).copyWith(borderRadius: const BorderRadius.vertical(bottom: radius));
  }

  // ── Table header (all flex-based) ────────────────────────────────────────
  Widget _buildTableHeader(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final headerStyle = context
        .semiBoldStyle(11)
        .copyWith(color: muted, letterSpacing: 0.5);
    const radius = Radius.circular(AppSpacing.borderRadiusXL);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(12),
      ),
      decoration: AppDecorations.card(context).copyWith(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: radius),
        boxShadow: const [],
      ),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('PRODUCT', style: headerStyle)),
          Expanded(flex: 3, child: Text('TYPE', style: headerStyle)),
          Expanded(
            flex: 2,
            child: Text('QTY', textAlign: TextAlign.center, style: headerStyle),
          ),
          Expanded(flex: 3, child: Text('USER', style: headerStyle)),
          Expanded(
            flex: 2,
            child: Text('DATE', textAlign: TextAlign.end, style: headerStyle),
          ),
        ],
      ),
    );
  }

  // ── Transaction row (all flex-based) ─────────────────────────────────────
  Widget _buildTransactionRow(
    BuildContext context,
    StockTransactionWithDetails tx,
    int index,
  ) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final (tint, ink) = _movementTone(tx).resolve(f);
    final sign = tx.isInflow ? '+' : '';
    final dateStr = _formatDate(tx.createdAt);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(10),
      ),
      decoration: BoxDecoration(
        border: index == 0
            ? null
            : Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          // Product name
          Expanded(
            flex: 4,
            child: Text(
              tx.productName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context
                  .semiBoldStyle(12)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
          // Movement type badge
          Expanded(
            flex: 3,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tx.isAdjustment)
                  Padding(
                    padding: EdgeInsets.only(right: context.getRSize(2)),
                    child: AppIcon(
                      AppIcons.warning,
                      color: f.warning,
                      size: context.getRSize(12),
                    ),
                  ),
                Flexible(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(6),
                      vertical: context.getRSize(2),
                    ),
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(
                        AppSpacing.borderRadiusS,
                      ),
                    ),
                    child: Text(
                      tx.movementLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.semiBoldStyle(10).copyWith(color: ink),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Quantity
          Expanded(
            flex: 2,
            child: Text(
              '$sign${tx.quantityDelta}',
              textAlign: TextAlign.center,
              style: context
                  .boldStyle(12)
                  .copyWith(color: tx.isInflow ? f.green : f.danger),
            ),
          ),
          // User
          Expanded(
            flex: 3,
            child: Text(
              tx.performedByName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.regularStyle(11).copyWith(color: muted),
            ),
          ),
          // Date
          Expanded(
            flex: 2,
            child: Text(
              dateStr,
              textAlign: TextAlign.end,
              style: context.regularStyle(11).copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }

  /// The movement's fixed tone (unchanged mapping: out = red, in = green,
  /// adjustment = amber, else blue).
  IconTileTone _movementTone(StockTransactionWithDetails tx) {
    switch (tx.movementType) {
      case 'sale':
      case 'transfer_out':
      case 'damage':
        return IconTileTone.danger;
      case 'purchase_received':
      case 'transfer_in':
      case 'return':
        return IconTileTone.green;
      case 'adjustment':
        return IconTileTone.warning;
      case 'transfer_cancelled':
        return IconTileTone.info;
      default:
        return IconTileTone.info;
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inHours < 24 && now.day == dt.day) {
      return DateFormat('HH:mm').format(dt);
    }
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('dd/MM').format(dt);
  }

  Widget _buildEmptyState(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.crossAxisExtent);
        return SliverMainAxisGroup(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                context.getRSize(12),
                gutter,
                0,
              ),
              sliver: SliverToBoxAdapter(child: _buildPeriodSelector(context)),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: gutter),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const IconTile(
                        icon: AppIcons.history,
                        tone: IconTileTone.neutral,
                        size: 64,
                      ),
                      SizedBox(height: context.spacingM),
                      Text(
                        'No stock movements found',
                        textAlign: TextAlign.center,
                        style: context
                            .boldStyle(15)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                      SizedBox(height: context.spacingXs),
                      Text(
                        'Stock movements from sales, adjustments,\nand transfers will appear here.',
                        textAlign: TextAlign.center,
                        style: context.regularStyle(13).copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
