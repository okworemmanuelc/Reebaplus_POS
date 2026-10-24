import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/settings_row.dart';

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
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    return Container(
      decoration: salesSheetDecoration(context),
      // Scrolls so it never overflows a short (landscape) viewport. Bottom
      // padding is nav-only (deviceBottomPadding), like EditItemModal.
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
              title: 'New barcode',
              subtitle: code,
              leading: const IconTile(icon: AppIcons.barcode, size: 44),
              trailing: [
                SalesBackButton(
                  icon: AppIcons.close,
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),
            Text(
              'No product has this barcode yet.',
              style: context.semiBoldStyle(14).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(16)),

            if (canAdd) ...[
              SettingsRow(
                key: kScanUnknownAddNewKey,
                icon: AppIcons.addSquare,
                tone: IconTileTone.green,
                title: 'Add as new product',
                subtitle: 'Create a product with this barcode',
                onTap: () => Navigator.pop(context, ScanUnknownChoice.addNew),
              ),
              SizedBox(height: context.getRSize(10)),
            ],
            if (canLink)
              SettingsRow(
                key: kScanUnknownLinkKey,
                icon: AppIcons.link,
                tone: IconTileTone.info,
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
