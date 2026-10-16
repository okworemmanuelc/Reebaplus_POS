import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// The "New Product" cell at the start of the Receive Stock grid (#394): the
/// same card frame as a `ProductTile` with a primary border, a pale primary
/// add tile and the primary "New Product" label. The whole cell is one tap
/// target. Shown only with `Gates.addProduct` (the grid decides).
class NewProductCard extends StatelessWidget {
  final VoidCallback? onTap;

  const NewProductCard({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        primary.withValues(alpha: 0.12);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return Semantics(
      button: true,
      label: 'New Product',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            decoration: AppDecorations.card(
              context,
            ).copyWith(border: Border.all(color: primary, width: 1.5)),
            padding: EdgeInsets.all(context.getRSize(10)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconTile(
                  icon: AppIcons.add,
                  tint: tint,
                  iconColor: primary,
                  size: 48,
                ),
                SizedBox(height: context.getRSize(12)),
                Text(
                  'New Product',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.boldStyle(14).copyWith(color: primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
