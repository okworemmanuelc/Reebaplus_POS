import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

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
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final text = t.colorScheme.onSurface;
    // The amber card of the redesign (as the Cart's crate-value warning,
    // #385): warning tint + outline, a warning icon tile, then the three
    // lines.
    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: f.warningTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        border: Border.all(color: f.warningOutline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconTile(
            icon: AppIcons.warning,
            tone: IconTileTone.warning,
            size: 40,
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$itemCount ${itemCount == 1 ? 'item has' : 'items have'} '
                  'no buying price',
                  style: context.boldStyle(15).copyWith(color: text),
                ),
                SizedBox(height: context.getRSize(6)),
                Text(
                  '$unitCount ${unitCount == 1 ? 'unit' : 'units'} would '
                  'arrive with no recorded cost, so nothing is added to the '
                  "supplier's account for "
                  '${unitCount == 1 ? 'it' : 'them'} and profit will read '
                  'higher than it is.',
                  style: context.regularStyle(13).copyWith(color: text),
                ),
                SizedBox(height: context.getRSize(6)),
                Text(
                  'Add what you paid so profit shows correctly. You can add it '
                  'later.',
                  style: context.semiBoldStyle(13).copyWith(color: f.warning),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
