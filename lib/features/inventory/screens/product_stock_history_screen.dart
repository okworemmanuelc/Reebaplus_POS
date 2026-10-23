import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_sales_history_cards.dart';

/// "View All" on Product Details (#487 PR 5): this product's whole stock
/// history, newest first, paged like the Inventory History tab.
class ProductStockHistoryScreen extends ConsumerWidget {
  const ProductStockHistoryScreen({
    super.key,
    required this.productId,
    required this.unit,
    required this.crates,
    this.clock,
  });

  final String productId;
  final String? unit;
  final bool crates;

  @visibleForTesting
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arg = (storeId: null, period: 'All', productId: productId);
    final page = ref.watch(paginatedStockHistoryProvider(arg));
    final rows = page.transactions;
    final now = (clock ?? DateTime.now)();
    final t = Theme.of(context);
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: ProductDetailTopBar(
          title: 'Stock History',
          height: inventoryTopBarHeight(context),
          onBack: () => Navigator.pop(context),
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            final gutter = (c.maxWidth - 720) / 2 > context.getRSize(16)
                ? (c.maxWidth - 720) / 2
                : context.getRSize(16);
            if (page.isLoading && rows.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (rows.isEmpty) {
              return Center(
                child: Text(
                  'No stock movements yet',
                  style: context
                      .regularStyle(14)
                      .copyWith(color: t.textTheme.bodySmall?.color),
                ),
              );
            }
            return ListView.separated(
              padding: EdgeInsets.fromLTRB(
                gutter,
                context.getRSize(16),
                gutter,
                context.getRSize(16) + context.deviceBottomPadding,
              ),
              itemCount: rows.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: t.dividerColor),
              itemBuilder: (context, i) {
                if (page.hasMore &&
                    !page.isLoadingMore &&
                    i >= rows.length - 5) {
                  Future.microtask(
                    () => ref
                        .read(paginatedStockHistoryProvider(arg).notifier)
                        .loadMore(),
                  );
                }
                return StockMovementRow(
                  tx: rows[i],
                  unit: unit,
                  crates: crates,
                  now: now,
                );
              },
            );
          },
        ),
      ),
    );
  }
}
