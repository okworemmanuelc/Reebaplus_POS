import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// A cart line card with a quantity stepper (#352 PR 2;
/// `tablet-cart-panel-*.png`, `wide-pos-cart-*.png`).
///
/// Top row: an icon tile, the name, "2 × ₦9,600" and the line total in
/// primary. Bottom row: the size / pack in muted text and the stepper. At a
/// quantity of 1 the minus becomes a red delete. Every stepper button is a
/// 48dp tap target (the visible square is smaller).
///
/// Plain data: the caller formats money and resolves [icon] (today's cart
/// uses `productIconFromCodePoint` for a product's stored icon, which keeps
/// the #350 FontAwesome translation) and the tile colours.
class CartLine extends StatelessWidget {
  const CartLine({
    super.key,
    required this.name,
    required this.icon,
    this.tileTint,
    this.tileIconColor,
    required this.quantityLabel,
    required this.unitPriceLabel,
    required this.totalLabel,
    this.detail,
    required this.isLastUnit,
    required this.onIncrement,
    required this.onDecrement,
    this.onTap,
  });

  final String name;
  final IconData icon;

  /// Icon tile colours (e.g. from `categoryVisual`); fixed info by default.
  final Color? tileTint;
  final Color? tileIconColor;

  /// The quantity as shown between the stepper buttons ("2", "1.5").
  final String quantityLabel;
  final String unitPriceLabel;
  final String totalLabel;

  /// Size / pack line, e.g. "60cl · Crate of 12".
  final String? detail;

  /// True when one unit is left: the minus becomes delete.
  final bool isLastUnit;
  final VoidCallback onIncrement;

  /// Decrease by one — or remove the line when [isLastUnit].
  final VoidCallback onDecrement;

  /// Tap the line (e.g. open the edit sheet).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(14)),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconTile(
                      icon: icon,
                      tint: tileTint,
                      iconColor: tileIconColor,
                      tone: IconTileTone.info,
                      size: 44,
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .boldStyle(15)
                                .copyWith(color: t.colorScheme.onSurface),
                          ),
                          Text(
                            '$quantityLabel × $unitPriceLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(13)
                                .copyWith(color: muted),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Text(
                      totalLabel,
                      maxLines: 1,
                      style: context
                          .boldStyle(16)
                          .copyWith(color: t.colorScheme.primary),
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(4)),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        detail ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.regularStyle(12).copyWith(color: muted),
                      ),
                    ),
                    QuantityStepper(
                      quantityLabel: quantityLabel,
                      isLastUnit: isLastUnit,
                      onIncrement: onIncrement,
                      onDecrement: onDecrement,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// − / quantity / + as on the cart lines and the Empty Crates row. Each button
/// is a 48dp tap target around a smaller visible square: minus on Surface 2,
/// plus on the primary tint, delete (when [isLastUnit]) on the danger tint.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.quantityLabel,
    this.isLastUnit = false,
    required this.onIncrement,
    required this.onDecrement,
  });

  final String quantityLabel;
  final bool isLastUnit;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final scheme = t.extension<AppSchemeColors>();
    final surface2 =
        t.inputDecorationTheme.fillColor ?? t.colorScheme.surfaceContainerHigh;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(
          key: const Key('stepper-decrement'),
          icon: isLastUnit ? AppIcons.delete : AppIcons.minus,
          fill: isLastUnit ? f.dangerTint : surface2,
          ink: isLastUnit ? f.danger : t.colorScheme.onSurface,
          tooltip: isLastUnit ? 'Remove' : 'Decrease',
          onPressed: onDecrement,
        ),
        ConstrainedBox(
          constraints: BoxConstraints(minWidth: context.getRSize(28)),
          child: Text(
            quantityLabel,
            textAlign: TextAlign.center,
            style: context
                .boldStyle(16)
                .copyWith(color: t.colorScheme.onSurface),
          ),
        ),
        _StepButton(
          key: const Key('stepper-increment'),
          icon: AppIcons.add,
          fill: scheme?.primaryTint ?? f.infoTint,
          ink: t.colorScheme.primary,
          tooltip: 'Increase',
          onPressed: onIncrement,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final Color fill;
  final Color ink;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final square = math.min(context.getRSize(36), kMinInteractiveDimension);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: kMinInteractiveDimension / 2,
        child: SizedBox(
          width: kMinInteractiveDimension,
          height: kMinInteractiveDimension,
          child: Center(
            child: Container(
              width: square,
              height: square,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
              ),
              child: AppIcon(icon, size: context.getRSize(20), color: ink),
            ),
          ),
        ),
      ),
    );
  }
}
