import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';

/// A category filter chip with a coloured dot (#352 PR 2; `tablet-pos-*.png`).
///
/// The dot uses the same colour rule as the product tiles (`categoryVisual`),
/// so a category reads the same colour everywhere. Pass a null
/// [categoryName] for the "All" chip, whose dot follows the chip's text.
/// Selected = solid primary chip with white text; idle = outlined card chip.
/// The visible pill is compact, but the tap area is at least 48dp tall.
class CategoryChip extends StatelessWidget {
  const CategoryChip({
    super.key,
    required this.label,
    this.categoryName,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// Category the dot colour comes from; null for "All".
  final String? categoryName;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final ink = selected ? t.colorScheme.onPrimary : t.colorScheme.onSurface;
    final dot = categoryName == null
        ? ink
        : categoryVisual(categoryName, f).iconColor;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
            minWidth: kMinInteractiveDimension,
          ),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(14),
                vertical: context.getRSize(8),
              ),
              decoration: ShapeDecoration(
                color: selected ? t.colorScheme.primary : t.colorScheme.surface,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: selected ? t.colorScheme.primary : t.dividerColor,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: context.getRSize(9),
                    height: context.getRSize(9),
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: context.semiBoldStyle(14).copyWith(color: ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
