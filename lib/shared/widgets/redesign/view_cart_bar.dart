import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The floating "View Cart" bar the app frame shows at the foot of POS (#352,
/// PRD #346 "App frame"): a primary-gradient bar with the cart count, the
/// customer, the cart total and a chevron.
///
/// Pure display: the frame decides when it shows and what a tap does (open the
/// Cart tab under 600dp wide, open the cart panel at 600dp+). One of the
/// shared parts (#352 PR 2); the frame (`MainLayout`) is its only user so far.
class ViewCartBar extends StatelessWidget {
  const ViewCartBar({
    super.key,
    required this.itemCount,
    required this.customerName,
    required this.total,
    required this.onTap,
  });

  /// Number of cart lines (the same count as the Cart tab's badge).
  final int itemCount;
  final String customerName;

  /// The cart's Total as the Cart screen shows it (subtotal − discounts).
  final double total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onPrimary = t.colorScheme.onPrimary;
    final fixed = t.extension<AppFixedColors>();
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final textTheme = t.textTheme;
    final itemsLabel = '$itemCount item${itemCount == 1 ? '' : 's'}';

    return Semantics(
      button: true,
      label: 'View Cart, $itemsLabel',
      child: DecoratedBox(
        decoration: AppDecorations.primaryButtonGradient(
          context,
          radius: AppSpacing.borderRadiusXL,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('view-cart-bar'),
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(10),
                ),
                child: Row(
                  children: [
                    Badge(
                      label: Text(itemCount.toString()),
                      backgroundColor: fixed?.danger ?? t.colorScheme.error,
                      child: Container(
                        width: context.getRSize(40),
                        height: context.getRSize(40),
                        decoration: BoxDecoration(
                          color: onPrimary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(
                            AppSpacing.borderRadiusM,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: AppIcon(
                          AppIcons.cart,
                          filled: true,
                          color: onPrimary,
                          size: context.getRSize(22),
                        ),
                      ),
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'View Cart',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleMedium?.copyWith(
                              color: onPrimary,
                            ),
                          ),
                          Text(
                            '$itemsLabel · $customerName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: onPrimary.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Text(
                      formatCurrency(total),
                      style: textTheme.titleLarge?.copyWith(color: onPrimary),
                    ),
                    SizedBox(width: context.getRSize(4)),
                    AppIcon(
                      AppIcons.chevronRight,
                      color: onPrimary,
                      size: context.getRSize(22),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
