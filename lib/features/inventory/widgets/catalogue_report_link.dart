import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/utils/factory_barcode.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/catalogue_report_sheet.dart';

/// The small "Report a problem with the shared details" link on product
/// details (ADR 0029 §6, #335). Renders nothing unless [barcode] is a factory
/// GTIN, the only codes the shared list covers. Open to anyone who can open
/// product details.
class CatalogueReportLink extends StatelessWidget {
  const CatalogueReportLink({super.key, required this.barcode});

  /// The product's barcode as stored, or null when it has none.
  final String? barcode;

  static const label = 'Report a problem with the shared details';
  static const sentMessage = "Thanks, we'll take a look.";

  @override
  Widget build(BuildContext context) {
    final code = barcode;
    if (code == null || FactoryBarcode.tryParse(code) == null) {
      return const SizedBox.shrink();
    }
    final color = Theme.of(context).textTheme.bodySmall?.color;
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(16)),
      child: Center(
        child: TextButton.icon(
          onPressed: () => _open(context, code),
          icon: Icon(
            AppIcons.flag,
            size: context.getRSize(12),
            color: color,
          ),
          label: Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(12),
              color: color,
              decoration: TextDecoration.underline,
              decorationColor: color,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String code) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CatalogueReportSheet(barcode: code),
    );
    if (sent == true && context.mounted) {
      AppNotification.showSuccess(context, sentMessage);
    }
  }
}
