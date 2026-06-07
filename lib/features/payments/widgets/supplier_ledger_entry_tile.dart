import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// §21.10 — one supplier ledger row (invoice / payment / void). Invoices are
/// red/negative, payments green/positive, voids muted with strikethrough.
/// Pass [supplierName] when the tile is shown outside a single supplier's
/// detail (the all-suppliers Transaction history screen).
class SupplierLedgerEntryTile extends StatelessWidget {
  final SupplierLedgerEntryData entry;
  final String? supplierName;

  /// §21.11 — when set (an "All Stores" aggregate view), the store that recorded
  /// the entry is appended to the subtitle.
  final String? storeName;

  const SupplierLedgerEntryTile({
    super.key,
    required this.entry,
    this.supplierName,
    this.storeName,
  });

  IconData get _icon {
    if (entry.referenceType == 'invoice') {
      return FontAwesomeIcons.fileInvoiceDollar;
    }
    if (entry.referenceType == 'void') return FontAwesomeIcons.rotateLeft;
    return FontAwesomeIcons.moneyBillTransfer;
  }

  String get _friendlyRefType {
    switch (entry.referenceType) {
      case 'invoice':
        return 'Invoice';
      case 'payment_cash':
        return 'Payment (Cash)';
      case 'payment_transfer':
        return 'Payment (Transfer)';
      case 'payment_pos':
        return 'Payment (POS)';
      case 'payment_other':
        return 'Payment (Other)';
      case 'void':
        return 'Void / reversal';
      default:
        return entry.referenceType;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardBg = Theme.of(context).cardColor;
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext = Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final border = Theme.of(context).dividerColor;

    final isVoided = entry.voidedAt != null;
    final credit = entry.signedAmountKobo >= 0;
    final color = isVoided ? subtext : (credit ? success : danger);
    final sign = entry.signedAmountKobo < 0 ? '-' : '+';
    final hasReceipt = (entry.receiptPath ?? '').isNotEmpty;

    final dateAndNote = DateFormat('d MMM y').format(entry.activityDate) +
        ((entry.referenceNote ?? '').isNotEmpty ? ' • ${entry.referenceNote}' : '');
    final subtitle = [
      if (supplierName != null) _friendlyRefType,
      dateAndNote,
      if ((storeName ?? '').isNotEmpty) storeName!,
    ].join(' • ');

    return Opacity(
      opacity: isVoided ? 0.55 : 1,
      child: Container(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(40),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_icon, color: color, size: context.getRSize(16)),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          supplierName ?? _friendlyRefType,
                          style: TextStyle(
                            fontSize: context.getRFontSize(15),
                            fontWeight: FontWeight.bold,
                            color: text,
                            decoration:
                                isVoided ? TextDecoration.lineThrough : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasReceipt) ...[
                        SizedBox(width: context.getRSize(6)),
                        Icon(FontAwesomeIcons.paperclip,
                            size: context.getRSize(11), color: subtext),
                      ],
                    ],
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: subtext,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              '$sign${formatCurrency(entry.amountKobo / 100)}',
              style: TextStyle(
                fontSize: context.getRFontSize(15),
                fontWeight: FontWeight.w800,
                color: color,
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
