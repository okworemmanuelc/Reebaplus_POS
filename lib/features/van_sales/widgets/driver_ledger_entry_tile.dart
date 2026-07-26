import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

/// One driver-ledger row (#146, van-sales spec §4.4).
///
/// Modelled on `SupplierLedgerEntryTile`, and for the same reason: a balance is
/// only defensible if every line that made it can be read back on its own.
/// Loads and restocks are debits (red, negative), returns / remittances /
/// write-offs / the credit half of a restatement are credits (green, positive),
/// and a voided row is struck through and muted — never removed, because the
/// void appended its own compensating row and both belong in the story.
///
/// The **type is the event**, not the sign (spec §4.4), so the title names the
/// event in shop-owner words and the sign is left to do only its own job.
class DriverLedgerEntryTile extends StatelessWidget {
  final DriverLedgerEntryData entry;

  /// The van this entry's trip ran on, when known — a cross-trip ledger read
  /// end to end is otherwise a list of amounts with no places attached.
  final String? vanName;

  const DriverLedgerEntryTile({super.key, required this.entry, this.vanName});

  /// Shop-owner words for the ledger type. Deliberately not the raw enum: a
  /// manager disputing a line reads "Goods loaded onto the van", not `load`.
  static String labelFor(String type) {
    switch (type) {
      case kDriverLedgerTypeLoad:
        return 'Goods loaded onto the van';
      case kDriverLedgerTypeRestock:
        return 'More goods loaded (restock)';
      case kDriverLedgerTypeReturnGood:
        return 'Goods returned in good condition';
      case kDriverLedgerTypePaymentCash:
        return 'Cash handed in';
      case kDriverLedgerTypePaymentTransfer:
        return 'Payment handed in (transfer)';
      case kDriverLedgerTypeShortageWriteoff:
        return 'Missing stock written off';
      case kDriverLedgerTypeDamageWriteoff:
        return 'Damaged stock written off';
      case kDriverLedgerTypeRestatement:
        return 'Correction after the trip closed';
      case kDriverLedgerTypeVoid:
        return 'Entry reversed';
      default:
        return type;
    }
  }

  IconData? get _icon {
    switch (entry.type) {
      case kDriverLedgerTypeLoad:
      case kDriverLedgerTypeRestock:
        return FontAwesomeIcons.boxesPacking.data;
      case kDriverLedgerTypeReturnGood:
        return FontAwesomeIcons.arrowRotateLeft.data;
      case kDriverLedgerTypePaymentCash:
      case kDriverLedgerTypePaymentTransfer:
        return FontAwesomeIcons.moneyBillTransfer.data;
      case kDriverLedgerTypeShortageWriteoff:
        return FontAwesomeIcons.magnifyingGlassMinus.data;
      case kDriverLedgerTypeDamageWriteoff:
        return FontAwesomeIcons.wineGlassEmpty.data;
      case kDriverLedgerTypeRestatement:
        return FontAwesomeIcons.penToSquare.data;
      default:
        return FontAwesomeIcons.rotateLeft.data;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    final isVoided = entry.voidedAt != null;
    final isCredit = entry.signedAmountKobo >= 0;
    final color = isVoided
        ? subtext
        : (isCredit ? semantic.success : t.colorScheme.error);
    final sign = entry.signedAmountKobo < 0 ? '-' : '+';

    final subtitle = [
      DateFormat('d MMM y').format(entry.activityDate),
      if ((vanName ?? '').isNotEmpty) vanName!,
      if ((entry.referenceNote ?? '').isNotEmpty) entry.referenceNote!,
    ].join(' • ');

    return Opacity(
      opacity: isVoided ? 0.55 : 1,
      child: GlassyCard(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        radius: 16,
        padding: EdgeInsets.all(context.getRSize(16)),
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
                  Text(
                    labelFor(entry.type),
                    style: TextStyle(
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.bold,
                      color: t.colorScheme.onSurface,
                      decoration: isVoided ? TextDecoration.lineThrough : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
