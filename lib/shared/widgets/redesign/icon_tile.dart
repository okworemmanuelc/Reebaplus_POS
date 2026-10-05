import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The fixed (tile, icon) colour pairs used by pale icon tiles on stat cards,
/// settings rows and cart lines (PRD #346 decision 6: identical in every
/// design system).
enum IconTileTone {
  info,
  green,
  warning,
  danger,
  neutral,
  malt;

  /// The (tile fill, icon colour) pair for this tone.
  (Color, Color) resolve(AppFixedColors f) => switch (this) {
    IconTileTone.info => (f.infoTint, f.info),
    IconTileTone.green => (f.greenTint, f.green),
    IconTileTone.warning => (f.warningTint, f.warning),
    IconTileTone.danger => (f.dangerTint, f.danger),
    IconTileTone.neutral => (f.neutralTile, f.neutralIcon),
    IconTileTone.malt => (f.maltTile, f.info),
  };
}

/// A pale rounded square with a filled icon in the middle (#352 PR 2): the
/// tile on Home stat cards, settings rows and cart lines.
///
/// Give it a [tone] for the fixed pairs, or explicit [tint] / [iconColor]
/// (e.g. from `categoryVisual`). Display only.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.tone = IconTileTone.info,
    this.tint,
    this.iconColor,
    this.size = 52,
  });

  final IconData icon;
  final IconTileTone tone;

  /// Overrides the tone's tile fill.
  final Color? tint;

  /// Overrides the tone's icon colour.
  final Color? iconColor;

  /// Base edge length, scaled with `getRSize`.
  final double size;

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final (fill, ink) = tone.resolve(f);
    final edge = context.getRSize(size);
    return Container(
      width: edge,
      height: edge,
      decoration: BoxDecoration(
        color: tint ?? fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      alignment: Alignment.center,
      child: AppIcon(
        icon,
        filled: true,
        size: edge * 0.46,
        color: iconColor ?? ink,
      ),
    );
  }
}
