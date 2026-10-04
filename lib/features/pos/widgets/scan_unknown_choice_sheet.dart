import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// What a permitted person chose to do with an unknown scanned barcode (#321).
enum ScanUnknownChoice { addNew, linkExisting }

/// Key of the "Add as new product" option (tests tap it).
const ValueKey<String> kScanUnknownAddNewKey = ValueKey<String>(
  'scan-unknown-add-new',
);

/// Key of the "Link to an existing product" option (tests tap it).
const ValueKey<String> kScanUnknownLinkKey = ValueKey<String>(
  'scan-unknown-link',
);

/// The small choice shown over the scanner when a code matches no product and
/// the person may do something about it (#321, PRD #316): "Add as new product"
/// (only with [canAdd] — `Gates.addProduct`) and "Link to an existing product"
/// (only with [canLink] — `Gates.editProductPrice`). With exactly one gate the
/// sheet still shows, with that single option, so the person knows what's
/// happening. The scanned code is shown. Dismissing returns null: nothing
/// happens and scanning carries on.
class ScanUnknownChoiceSheet extends StatelessWidget {
  const ScanUnknownChoiceSheet({
    super.key,
    required this.code,
    required this.canAdd,
    required this.canLink,
  });

  final String code;
  final bool canAdd;
  final bool canLink;

  /// Opens the choice over [context]; returns the picked option, or null when
  /// dismissed.
  static Future<ScanUnknownChoice?> show(
    BuildContext context, {
    required String code,
    required bool canAdd,
    required bool canLink,
  }) {
    return showModalBottomSheet<ScanUnknownChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          ScanUnknownChoiceSheet(code: code, canAdd: canAdd, canLink: canLink),
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
      // Scrolls so it never overflows a short (landscape) viewport. Bottom
      // padding is nav-only (deviceBottomPadding), like EditItemModal.
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
                    AppIcons.barcode,
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
                        'New barcode',
                        style: TextStyle(
                          fontSize: context.getRFontSize(20),
                          fontWeight: FontWeight.w900,
                          color: text,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
            SizedBox(height: context.getRSize(12)),
            Text(
              'No product has this barcode yet.',
              style: TextStyle(
                fontSize: context.getRFontSize(14),
                color: text.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: context.getRSize(20)),

            if (canAdd) ...[
              _ScanUnknownOption(
                key: kScanUnknownAddNewKey,
                icon: AppIcons.addSquare,
                title: 'Add as new product',
                subtitle: 'Create a product with this barcode',
                onTap: () => Navigator.pop(context, ScanUnknownChoice.addNew),
              ),
              SizedBox(height: context.getRSize(10)),
            ],
            if (canLink)
              _ScanUnknownOption(
                key: kScanUnknownLinkKey,
                icon: AppIcons.link,
                title: 'Link to an existing product',
                subtitle: 'Save this barcode on a product you already have',
                onTap: () =>
                    Navigator.pop(context, ScanUnknownChoice.linkExisting),
              ),
          ],
        ),
      ),
    );
  }
}

/// One tappable option row of [ScanUnknownChoiceSheet].
class _ScanUnknownOption extends StatelessWidget {
  const _ScanUnknownOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    return Material(
      color: border.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(14)),
          child: Row(
            children: [
              Icon(icon, size: context.getRSize(22), color: primary),
              SizedBox(width: context.getRSize(14)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: context.getRFontSize(15),
                        fontWeight: FontWeight.w800,
                        color: text,
                      ),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        fontWeight: FontWeight.w600,
                        color: text.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                AppIcons.chevronRight,
                size: context.getRSize(13),
                color: text.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
