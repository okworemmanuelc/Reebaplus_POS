import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

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
    final colorScheme = Theme.of(context).colorScheme;

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
      return const Center(child: CircularProgressIndicator());
    }

    if (pageState.transactions.isEmpty) {
      return _buildEmptyState(context, colorScheme);
    }

    final stats = statsAsync.valueOrNull ?? StockHistoryStats.empty();
    final totalIn = stats.totalIn;
    final totalOut = stats.totalOut;

    final txns = pageState.transactions;
    final childCount = txns.length + (pageState.isLoadingMore ? 1 : 0);

    return Column(
      children: [
        _buildPeriodSelector(context, colorScheme),
        SizedBox(height: context.spacingS),
        _buildSummaryRow(context, colorScheme, totalIn, totalOut),
        SizedBox(height: context.spacingS),
        _buildTableHeader(context, colorScheme),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: context.spacingM),
            itemCount: childCount,
            itemBuilder: (context, index) {
              if (pageState.hasMore &&
                  !pageState.isLoadingMore &&
                  index >= txns.length - 5) {
                Future.microtask(() {
                  if (mounted) {
                    ref
                        .read(
                          paginatedStockHistoryProvider(
                            (storeId: wId, period: _selectedPeriod),
                          ).notifier,
                        )
                        .loadMore();
                  }
                });
              }

              if (index == txns.length) {
                return Padding(
                  padding: EdgeInsets.symmetric(vertical: context.spacingM),
                  child: const Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              return _buildTransactionRow(
                context,
                colorScheme,
                txns[index],
                index,
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Period chips (scrollable for small screens) ──────────────────────────
  Widget _buildPeriodSelector(BuildContext context, ColorScheme colorScheme) {
    return SizedBox(
      height: context.getRSize(40),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.spacingM),
        separatorBuilder: (_, __) => SizedBox(width: context.spacingXs),
        itemCount: _periods.length,
        itemBuilder: (_, i) {
          final period = _periods[i];
          final isSelected = period == _selectedPeriod;
          return ChoiceChip(
            label: Text(
              period,
              style: context.bodySmall.copyWith(
                color: isSelected
                    ? Colors.white
                    : colorScheme.onSurface.withValues(alpha: 0.7),
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            selectedColor: colorScheme.primary,
            backgroundColor: colorScheme.surface,
            side: BorderSide(
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.outline.withValues(alpha: 0.3),
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) => _onPeriodChanged(period),
          );
        },
      ),
    );
  }

  // ── Summary cards ────────────────────────────────────────────────────────
  Widget _buildSummaryRow(
    BuildContext context,
    ColorScheme colorScheme,
    int totalIn,
    int totalOut,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.spacingM),
      child: Row(
        children: [
          Expanded(
            child: _summaryCard(
              context,
              'Stock In',
              '+${fmtNumber(totalIn)} units',
              AppColors.success,
              Icons.arrow_downward_rounded,
            ),
          ),
          SizedBox(width: context.spacingS),
          Expanded(
            child: _summaryCard(
              context,
              'Stock Out',
              '-${fmtNumber(totalOut)} units',
              AppColors.danger,
              Icons.arrow_upward_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(
    BuildContext context,
    String label,
    String value,
    Color color,
    IconData icon,
  ) {
    return Container(
      padding: EdgeInsets.all(context.spacingS),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(context.radiusM),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: context.getRSize(14)),
              SizedBox(width: context.spacingXs),
              Flexible(
                child: Text(
                  label,
                  style: context.bodySmall.copyWith(
                    color: color,
                    fontSize: context.getRFontSize(11),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.spacingXs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: context.bodyMedium.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Table header (all flex-based) ────────────────────────────────────────
  Widget _buildTableHeader(BuildContext context, ColorScheme colorScheme) {
    final headerStyle = context.bodySmall.copyWith(
      fontWeight: FontWeight.w600,
      fontSize: context.getRFontSize(10),
      color: colorScheme.onSurface.withValues(alpha: 0.5),
    );

    return Container(
      margin: EdgeInsets.symmetric(horizontal: context.spacingM),
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingS,
        vertical: context.spacingS,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.radiusM),
        ),
        border: Border(
          bottom: BorderSide(color: colorScheme.outline.withValues(alpha: 0.2)),
        ),
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
    ColorScheme colorScheme,
    StockTransactionWithDetails tx,
    int index,
  ) {
    final isEven = index % 2 == 0;
    final typeColor = _getMovementColor(tx);
    final sign = tx.isInflow ? '+' : '';
    final dateStr = _formatDate(tx.createdAt);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingS,
        vertical: context.spacingS,
      ),
      decoration: BoxDecoration(
        color: isEven
            ? colorScheme.onSurface.withValues(alpha: 0.02)
            : Colors.transparent,
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
              style: context.bodySmall.copyWith(
                fontWeight: FontWeight.w500,
                fontSize: context.getRFontSize(11),
              ),
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
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      color: AppColors.warning,
                      size: context.getRSize(10),
                    ),
                  ),
                Flexible(
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(4),
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: typeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tx.movementLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.bodySmall.copyWith(
                        color: typeColor,
                        fontSize: context.getRFontSize(9),
                        fontWeight: FontWeight.w600,
                      ),
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
              style: context.bodySmall.copyWith(
                color: tx.isInflow ? AppColors.success : AppColors.danger,
                fontWeight: FontWeight.bold,
                fontSize: context.getRFontSize(11),
              ),
            ),
          ),
          // User
          Expanded(
            flex: 3,
            child: Text(
              tx.performedByName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.bodySmall.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: context.getRFontSize(9),
              ),
            ),
          ),
          // Date
          Expanded(
            flex: 2,
            child: Text(
              dateStr,
              textAlign: TextAlign.end,
              style: context.bodySmall.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
                fontSize: context.getRFontSize(9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getMovementColor(StockTransactionWithDetails tx) {
    switch (tx.movementType) {
      case 'sale':
      case 'transfer_out':
      case 'damage':
        return AppColors.danger;
      case 'purchase_received':
      case 'transfer_in':
      case 'return':
        return AppColors.success;
      case 'adjustment':
        return AppColors.warning;
      case 'transfer_cancelled':
        return AppColors.info;
      default:
        return AppColors.info;
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

  Widget _buildEmptyState(BuildContext context, ColorScheme colorScheme) {
    return Column(
      children: [
        _buildPeriodSelector(context, colorScheme),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.history_rounded,
                  size: context.getRSize(48),
                  color: colorScheme.onSurface.withValues(alpha: 0.2),
                ),
                SizedBox(height: context.spacingM),
                Text(
                  'No stock movements found',
                  style: context.bodyMedium.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
                SizedBox(height: context.spacingXs),
                Text(
                  'Stock movements from sales, adjustments,\nand transfers will appear here.',
                  textAlign: TextAlign.center,
                  style: context.bodySmall.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.3),
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
