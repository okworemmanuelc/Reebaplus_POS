import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';

/// Key prefix for a "Which one?" row; the product id follows (tests find a row
/// by it).
const String kScanChoiceKeyPrefix = 'scan-choice-';

/// The "Which one?" list (#318, PRD #316): shown when more than one product
/// carries the scanned barcode. Each row is the name (+ size), the price at the
/// active tier and the stock in the active store. Rows that can't be sold right
/// now (switched off, out of stock here, all already in the cart) are still
/// listed, dimmed with a short reason — tapping any row pops the list with that
/// product and the caller re-runs the single-product checks on it. Dismissing
/// returns null, so nothing is added.
class ScanWhichOneSheet extends StatelessWidget {
  const ScanWhichOneSheet({super.key, required this.choices});

  final List<ScanChoice> choices;

  /// Opens the list over [context]; returns the picked product, or null when
  /// dismissed.
  static Future<ProductData?> show(
    BuildContext context, {
    required List<ScanChoice> choices,
  }) {
    return showModalBottomSheet<ProductData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ScanWhichOneSheet(choices: choices),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: salesSheetDecoration(context),
      // Scrolls so a long list never overflows a short (landscape) viewport.
      // Bottom padding is nav-only (deviceBottomPadding), like EditItemModal.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(12),
          context.getRSize(20),
          context.deviceBottomPadding + context.getRSize(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SalesSheetHeader(
              title: 'Which one?',
              subtitle: '${choices.length} products have this barcode',
              leading: const IconTile(icon: AppIcons.barcode, size: 44),
              trailing: [
                SalesBackButton(
                  icon: AppIcons.close,
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(16)),

            for (final choice in choices) ...[
              _ScanChoiceRow(choice: choice),
              SizedBox(height: context.getRSize(8)),
            ],
          ],
        ),
      ),
    );
  }
}

/// One tappable row of the "Which one?" list. Unsellable rows are dimmed and
/// name their reason, but stay tappable: the pick shows that product's message.
class _ScanChoiceRow extends StatelessWidget {
  const _ScanChoiceRow({required this.choice});

  final ScanChoice choice;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? text;
    final product = choice.product;
    // Same size + unit descriptor the POS grid tile shows under the name.
    final size = '${product.size ?? ''} ${product.unit ?? ''}'.trim();
    final reason = _reasonOf(choice.outcome);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);

    return DecoratedBox(
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey<String>('$kScanChoiceKeyPrefix${product.id}'),
          borderRadius: radius,
          onTap: () => Navigator.pop(context, product),
          child: Opacity(
            opacity: choice.isSellable ? 1 : 0.45,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.all(context.getRSize(12)),
                child: Row(
                  children: [
                    const IconTile(icon: AppIcons.box, size: 40),
                    SizedBox(width: context.getRSize(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            size.isEmpty
                                ? product.name
                                : '${product.name} · $size',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.boldStyle(15).copyWith(color: text),
                          ),
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            reason == null
                                ? '${choice.stock} in stock here'
                                : '${choice.stock} in stock here · $reason',
                            style: context
                                .regularStyle(12)
                                .copyWith(color: muted),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Text(
                      formatCurrency(choice.unitPriceKobo / 100.0),
                      style: context
                          .boldStyle(15)
                          .copyWith(color: t.colorScheme.primary),
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

  /// The short reason an unsellable row is dimmed; null when it can be sold.
  static String? _reasonOf(ScanMatchOutcome outcome) => switch (outcome) {
    ScanAddSheet() => null,
    ScanSwitchedOff() => 'Switched off for sale',
    ScanOutOfStockHere() => 'Out of stock',
    ScanAllInCart() => 'All already in cart',
  };
}
