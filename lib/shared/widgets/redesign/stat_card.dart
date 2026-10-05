import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

/// A Home stat card (#352 PR 2; `phone-home-*.png`,
/// `phone-landscape-home-dark.png`): a fixed-colour icon tile, a muted title
/// with a status pill on the right, a big figure, and a one-line muted
/// subtitle that ends in "…" when long.
///
/// Plain data only: the caller formats [value] (e.g. with `formatCurrency`).
/// With [onTap] the whole card is one tap target.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    required this.value,
    required this.subtitle,
    this.pillLabel,
    this.pillTone = TagPillTone.neutral,
    this.onTap,
  });

  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String value;
  final String subtitle;

  /// Status pill text ("Positive", "Clear"…); no pill when null.
  final String? pillLabel;
  final TagPillTone pillTone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final content = Padding(
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconTile(icon: icon, tone: tone),
          SizedBox(width: context.getRSize(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.semiBoldStyle(14).copyWith(color: muted),
                      ),
                    ),
                    if (pillLabel != null) ...[
                      SizedBox(width: context.getRSize(8)),
                      StatusPill(label: pillLabel!, tone: pillTone),
                    ],
                  ],
                ),
                SizedBox(height: context.getRSize(4)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: context
                        .boldStyle(26)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: onTap == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
                onTap: onTap,
                child: content,
              ),
            ),
    );
  }
}
