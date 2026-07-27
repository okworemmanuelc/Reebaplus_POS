import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The receive-side Uncosted disclosure (#199 / PRD #155 US 37).
///
/// A receipt line with no buying price is **accepted**: a stock keeper often
/// does not yet know what a delivery cost, and refusing the receipt would stop
/// the goods from being logged at all. But it must never be silent — those
/// units add nothing to the supplier's account and later sell at 0 COGS, so
/// profit reads higher than it really is until a cost is recorded. This is the
/// receive arm of the same Uncosted transparency the reports and the van trip
/// already carry (CONTEXT.md §Inventory & Costing).
///
/// Deliberately carries **no money figure**: the whole point is that the cost is
/// unknown, and naming one would be inventing it.
///
/// Non-blocking by contract — this widget only informs. It never gates the
/// Confirm button, and the copy says so ("You can add it later").
class UncostedReceiveWarning extends StatelessWidget {
  /// Receipt lines with no recorded buying price.
  final int itemCount;

  /// Units carried by those lines — the quantity that would arrive at no cost.
  final int unitCount;

  const UncostedReceiveWarning({
    super.key,
    required this.itemCount,
    required this.unitCount,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: semantic.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(context.getRSize(12)),
        border: Border.all(color: semantic.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            FontAwesomeIcons.triangleExclamation.data,
            size: context.getRSize(16),
            color: semantic.warning,
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$itemCount ${itemCount == 1 ? 'item has' : 'items have'} '
                  'no buying price',
                  style: t.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: t.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: context.getRSize(6)),
                Text(
                  '$unitCount ${unitCount == 1 ? 'unit' : 'units'} would '
                  'arrive with no recorded cost, so nothing is added to the '
                  "supplier's account for "
                  '${unitCount == 1 ? 'it' : 'them'} and profit will read '
                  'higher than it is.',
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: context.getRSize(6)),
                Text(
                  'Add what you paid so profit shows correctly. You can add it '
                  'later.',
                  style: t.textTheme.bodySmall?.copyWith(
                    color: semantic.warning,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
