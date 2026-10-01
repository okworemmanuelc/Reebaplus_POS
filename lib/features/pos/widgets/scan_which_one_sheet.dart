import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
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
    final t = Theme.of(context);
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      // Scrolls so a long list never overflows a short (landscape) viewport.
      // Bottom padding is nav-only (deviceBottomPadding), like EditItemModal.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(24),
          context.getRSize(16),
          context.getRSize(24),
          context.deviceBottomPadding + context.getRSize(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag Handle
            Center(
              child: Container(
                width: context.getRSize(40),
                height: context.getRSize(4),
                decoration: BoxDecoration(
                  color: border.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(24)),

            // Header with Icon
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(context.getRSize(14)),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primary.withValues(alpha: 0.2),
                        primary.withValues(alpha: 0.1),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    FontAwesomeIcons.barcode.data,
                    size: context.getRSize(20),
                    color: primary,
                  ),
                ),
                SizedBox(width: context.getRSize(16)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Which one?',
                        style: TextStyle(
                          fontSize: context.getRFontSize(20),
                          fontWeight: FontWeight.w900,
                          color: text,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        '${choices.length} products have this barcode',
                        style: TextStyle(
                          fontSize: context.getRFontSize(14),
                          color: text.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Material(
                  color: border.withValues(alpha: 0.1),
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.close,
                      size: context.getRSize(20),
                      color: text.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(20)),

            for (final choice in choices) ...[
              _ScanChoiceRow(choice: choice),
              SizedBox(height: context.getRSize(10)),
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
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final product = choice.product;
    // Same size + unit descriptor the POS grid tile shows under the name.
    final size = '${product.size ?? ''} ${product.unit ?? ''}'.trim();
    final reason = _reasonOf(choice.outcome);

    return Material(
      color: border.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey<String>('$kScanChoiceKeyPrefix${product.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, product),
        child: Opacity(
          opacity: choice.isSellable ? 1 : 0.45,
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(14)),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        size.isEmpty ? product.name : '${product.name} · $size',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.getRFontSize(15),
                          fontWeight: FontWeight.w800,
                          color: text,
                        ),
                      ),
                      SizedBox(height: context.getRSize(4)),
                      Text(
                        reason == null
                            ? '${choice.stock} in stock here'
                            : '${choice.stock} in stock here · $reason',
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          fontWeight: FontWeight.w600,
                          color: text.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(12)),
                Text(
                  formatCurrency(choice.unitPriceKobo / 100.0),
                  style: TextStyle(
                    fontSize: context.getRFontSize(15),
                    fontWeight: FontWeight.w900,
                    color: text,
                  ),
                ),
              ],
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
