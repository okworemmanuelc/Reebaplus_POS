import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/crates/crate_value_change_impact.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart';

/// Test keys for [CrateValueChangeSheet] (#295).
const String kCrateValueChangeSheetKey = 'crate_value_change_sheet';
const String kCrateValueChangeConfirmKey = 'crate_value_change_confirm';
const String kCrateValueChangeCancelKey = 'crate_value_change_cancel';
const String kCrateValueChangeUnsetLinesKey = 'crate_value_change_unset_lines';

/// The confirmation shown before a crate value change is written (#295, PRD
/// #284 §10): what moves, in naira, and what does not. Resolves `true` only
/// when the owner confirms; backing out (Cancel, swipe, scrim) resolves
/// `false`/null and the caller writes nothing.
class CrateValueChangeSheet extends StatelessWidget {
  const CrateValueChangeSheet({
    super.key,
    required this.brandName,
    required this.impact,
    this.unsetLines = 0,
  });

  final String brandName;
  final CrateValueChangeImpact impact;

  /// Past crate lines sold while the brand had no crate value; they take the
  /// new value once it is set (#298). Zero unless this is the first value.
  final int unsetLines;

  static Future<bool> show(
    BuildContext context, {
    required String brandName,
    required CrateValueChangeImpact impact,
    int unsetLines = 0,
  }) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CrateValueChangeSheet(
        brandName: brandName,
        impact: impact,
        unsetLines: unsetLines,
      ),
    );
    return confirmed ?? false;
  }

  static String _signed(int kobo) {
    final text = formatCurrency(kobo.abs() / 100);
    if (kobo == 0) return text;
    return kobo > 0 ? '+$text' : '-$text';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = [...impact.statusMoves, ?impact.supplierDebt];
    final body = context
        .regularStyle(14)
        .copyWith(color: theme.colorScheme.onSurface);
    final heading = context
        .extraBoldStyle(14)
        .copyWith(color: theme.colorScheme.onSurface);
    return CrateSheetFrame(
      frameKey: const ValueKey(kCrateValueChangeSheetKey),
      title: 'Change crate value?',
      subtitle:
          '$brandName: ${formatCurrency(impact.oldKobo / 100)} → '
          '${formatCurrency(impact.newKobo / 100)} per crate',
      children: [
        InventoryFormCard(
          children: [
            Text('What moves', style: heading),
            SizedBox(height: context.getRSize(6)),
            if (lines.isEmpty)
              Text(
                'No crates are counted for this brand yet, so no figure moves.',
                style: body,
              )
            else
              for (final m in lines)
                Padding(
                  padding: EdgeInsets.only(bottom: context.getRSize(4)),
                  child: Text(
                    '${m.label} (${m.count} crates): '
                    '${formatCurrency(m.beforeKobo / 100)} to '
                    '${formatCurrency(m.afterKobo / 100)} '
                    '(${_signed(m.deltaKobo)})',
                    style: body,
                  ),
                ),
            SizedBox(height: context.getRSize(4)),
            Text(
              'Daily Reconciliation shows these same crates at the new value '
              '(${_signed(impact.totalDeltaKobo)} in total).',
              style: body,
            ),
            if (unsetLines > 0) ...[
              SizedBox(height: context.getRSize(8)),
              Text(
                '$unsetLines past crate ${unsetLines == 1 ? 'line' : 'lines'} '
                'sold before this brand had a crate value will be filled in at '
                '${formatCurrency(impact.newKobo / 100)}. No money is collected '
                'or refunded for them.',
                key: const ValueKey(kCrateValueChangeUnsetLinesKey),
                style: body,
              ),
            ],
          ],
        ),
        SizedBox(height: context.getRSize(12)),
        InventoryFormCard(
          children: [
            Text('What does not move', style: heading),
            SizedBox(height: context.getRSize(6)),
            Text(
              'Past sales, damages, write-offs and refunds stay at the value '
              'they were recorded at. Customer deposit already paid stays as '
              'paid.',
              style: body,
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              'New sales, including carts already open, charge the new value.',
              style: context
                  .extraBoldStyle(14)
                  .copyWith(color: theme.colorScheme.onSurface),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(24)),
        CrateSheetActions(
          cancelKey: const ValueKey(kCrateValueChangeCancelKey),
          confirmKey: const ValueKey(kCrateValueChangeConfirmKey),
          confirmText: 'Change value',
          onCancel: () => Navigator.pop(context, false),
          onConfirm: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
