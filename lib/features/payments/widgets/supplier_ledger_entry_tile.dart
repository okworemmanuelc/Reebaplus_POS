import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

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

  /// §21.7 — when set, the row is tappable (the Supplier Details screen passes
  /// this for a CEO to open the void/reversal action sheet).
  final VoidCallback? onTap;

  const SupplierLedgerEntryTile({
    super.key,
    required this.entry,
    this.supplierName,
    this.storeName,
    this.onTap,
  });

  IconData get _icon {
    if (entry.referenceType == 'invoice') {
      return AppIcons.bill;
    }
    if (entry.referenceType == 'void') return AppIcons.refresh;
    return AppIcons.transfer;
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
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final text = t.colorScheme.onSurface;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    final isVoided = entry.voidedAt != null;
    final credit = entry.signedAmountKobo >= 0;
    final tone = isVoided
        ? IconTileTone.neutral
        : (credit ? IconTileTone.green : IconTileTone.danger);
    final color = isVoided ? subtext : (credit ? f.green : f.danger);
    final sign = entry.signedAmountKobo < 0 ? '-' : '+';
    final hasReceipt = (entry.receiptPath ?? '').isNotEmpty;

    final dateAndNote =
        DateFormat('d MMM y').format(entry.activityDate) +
        ((entry.referenceNote ?? '').isNotEmpty
            ? ' • ${entry.referenceNote}'
            : '');
    final subtitle = [
      if (supplierName != null) _friendlyRefType,
      dateAndNote,
      if ((storeName ?? '').isNotEmpty) storeName!,
    ].join(' • ');

    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return Opacity(
      opacity: isVoided ? 0.55 : 1,
      child: Padding(
        padding: EdgeInsets.only(bottom: context.getRSize(12)),
        child: DecoratedBox(
          decoration: AppDecorations.card(context),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: Padding(
                  padding: EdgeInsets.all(context.getRSize(14)),
                  child: Row(
                    children: [
                      IconTile(icon: _icon, tone: tone, size: 40),
                      SizedBox(width: context.getRSize(12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    supplierName ?? _friendlyRefType,
                                    style: context
                                        .boldStyle(15)
                                        .copyWith(
                                          color: text,
                                          decoration: isVoided
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (hasReceipt) ...[
                                  SizedBox(width: context.getRSize(6)),
                                  AppIcon(
                                    AppIcons.attachment,
                                    size: context.getRSize(14),
                                    color: subtext,
                                  ),
                                ],
                              ],
                            ),
                            SizedBox(height: context.getRSize(4)),
                            Text(
                              subtitle,
                              style: context
                                  .semiBoldStyle(12)
                                  .copyWith(color: subtext),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: context.getRSize(8)),
                      Text(
                        '$sign${formatCurrency(entry.amountKobo / 100)}',
                        style: context
                            .extraBoldStyle(15)
                            .copyWith(
                              color: color,
                              decoration: isVoided
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
