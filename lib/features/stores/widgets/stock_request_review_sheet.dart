import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/stores/state/stock_request_list.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/cart_line.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// Keys for tests.
abstract final class StockRequestReviewKeys {
  static const sheet = Key('request-review-sheet');
  static const send = Key('request-review-send');
  static ValueKey<String> line(String productId) =>
      ValueKey<String>('request-review-line-$productId');
  static ValueKey<String> remove(String productId) =>
      ValueKey<String>('request-review-remove-$productId');
}

/// Request Stock's review sheet (#380): every product on the request with a
/// stepper (at 1 the minus becomes remove, so a line never drops below 1) and
/// a remove button, then "Send request". Pops `true` when the user taps Send;
/// the screen confirms and writes. Closes by itself when the last line goes.
class StockRequestReviewSheet extends ConsumerStatefulWidget {
  const StockRequestReviewSheet({
    super.key,
    required this.sourceStoreId,
    required this.sourceStoreName,
    required this.destStoreName,
    required this.categoryNames,
  });

  final String sourceStoreId;
  final String sourceStoreName;

  /// Null while "Deliver to" is still unchosen.
  final String? destStoreName;
  final Map<String, String> categoryNames;

  static Future<bool?> show(
    BuildContext context, {
    required String sourceStoreId,
    required String sourceStoreName,
    required String? destStoreName,
    required Map<String, String> categoryNames,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StockRequestReviewSheet(
        sourceStoreId: sourceStoreId,
        sourceStoreName: sourceStoreName,
        destStoreName: destStoreName,
        categoryNames: categoryNames,
      ),
    );
  }

  @override
  ConsumerState<StockRequestReviewSheet> createState() =>
      _StockRequestReviewSheetState();
}

class _StockRequestReviewSheetState
    extends ConsumerState<StockRequestReviewSheet> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final sourceStoreId = widget.sourceStoreId;
    final sourceStoreName = widget.sourceStoreName;
    final destStoreName = widget.destStoreName;
    final categoryNames = widget.categoryNames;
    // The last line was removed: nothing left to review. Once only, so a
    // rebuild during the closing animation never pops the screen too.
    ref.listen(stockRequestListProvider, (_, next) {
      if (next.isEmpty && !_closing) {
        _closing = true;
        Navigator.of(context).pop(false);
      }
    });
    final items = ref.watch(stockRequestListProvider);
    final notifier = ref.read(stockRequestListProvider.notifier);
    final available = {
      for (final p
          in ref.watch(productsByStoreProvider(sourceStoreId)).valueOrNull ??
              const <ProductDataWithStock>[])
        p.product.id: p.totalStock,
    };
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gutter = context.getRSize(20);
    final units = totalRequestedUnits(items);
    final route = destStoreName == null
        ? 'From $sourceStoreName'
        : 'From $sourceStoreName to $destStoreName';

    return ConstrainedBox(
      key: StockRequestReviewKeys.sheet,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: context.getRSize(12)),
          Center(
            child: Container(
              width: context.getRSize(40),
              height: context.getRSize(4),
              decoration: BoxDecoration(
                color: t.dividerColor,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(16),
              gutter,
              context.getRSize(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Review request',
                  style: context.screenTitleStyle.copyWith(
                    color: t.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  route,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.primary),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.symmetric(horizontal: gutter),
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  SizedBox(height: context.getRSize(10)),
              itemBuilder: (context, i) {
                final item = items[i];
                final id = item.product.id;
                return _ReviewLine(
                  key: StockRequestReviewKeys.line(id),
                  productId: id,
                  name: item.product.name,
                  categoryName: categoryNames[item.product.categoryId],
                  detail: '$sourceStoreName has ${available[id] ?? 0}',
                  quantity: item.quantity,
                  onIncrement: () => notifier.increment(id),
                  onDecrement: () => notifier.decrement(id),
                  onRemove: () => notifier.remove(id),
                );
              },
            ),
          ),
          Container(
            margin: EdgeInsets.only(top: context.getRSize(12)),
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(12),
              gutter,
              context.getRSize(16) + context.deviceBottomPadding,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.dividerColor)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${items.length} ${items.length == 1 ? 'product' : 'products'}'
                  ' · $units ${units == 1 ? 'unit' : 'units'}',
                  style: context.semiBoldStyle(14).copyWith(color: muted),
                ),
                SizedBox(height: context.getRSize(12)),
                AppButton(
                  key: StockRequestReviewKeys.send,
                  text: 'Send request',
                  icon: AppIcons.send,
                  isFullWidth: true,
                  onPressed: items.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewLine extends StatelessWidget {
  const _ReviewLine({
    super.key,
    required this.productId,
    required this.name,
    required this.categoryName,
    required this.detail,
    required this.quantity,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
  });

  final String productId;
  final String name;
  final String? categoryName;
  final String detail;
  final int quantity;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final visual = categoryVisual(categoryName, f);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          context.getRSize(12),
          context.getRSize(10),
          context.getRSize(4),
          context.getRSize(10),
        ),
        child: Column(
          children: [
            Row(
              children: [
                IconTile(
                  icon: visual.icon,
                  tint: visual.tint,
                  iconColor: visual.iconColor,
                  size: 40,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .boldStyle(15)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.regularStyle(12).copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: StockRequestReviewKeys.remove(productId),
                  tooltip: 'Remove',
                  icon: Icon(
                    AppIcons.close,
                    size: context.getRSize(20),
                    color: f.danger,
                  ),
                  onPressed: onRemove,
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: QuantityStepper(
                quantityLabel: '$quantity',
                isLastUnit: quantity <= 1,
                onIncrement: onIncrement,
                onDecrement: onDecrement,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
