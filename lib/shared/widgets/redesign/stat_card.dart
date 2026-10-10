import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

/// How tightly a [StatCard] is drawn.
enum StatCardDensity {
  /// The upright-phone card (`phone-home-*.png`): 16 padding, 52 tile.
  regular,

  /// The narrow grid card of `phone-landscape-home-dark.png` (#374), measured
  /// at 844×390 (1×): 12 padding, 44 tile, title 13, figure 22, subtitle 12,
  /// and a [TagPill.dense] status pill. The tile-to-text gap (9; mockup 10)
  /// and title-to-pill gap (4) are a little tighter so "Pending Orders" +
  /// "ⓘ Attention" fit beside a 48dp sideways navigation bar. Same base-dp
  /// convention as every part: the values go through `getRSize` /
  /// `getRFontSize`.
  compact,
}

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
    this.trailing,
    this.density = StatCardDensity.regular,
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

  /// Optional widget after the text column (e.g. an expand chevron on a card
  /// that opens a breakdown, #374). Nothing is drawn there when null.
  final Widget? trailing;

  /// Defaults to [StatCardDensity.regular] (unchanged since #352).
  final StatCardDensity density;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final compact = density == StatCardDensity.compact;
    // (padding, tile, tile gap, line gap, title, figure, subtitle) in base dp.
    final (pad, tile, tileGap, lineGap, titleSize, valueSize, subSize) = compact
        ? (12.0, 44.0, 9.0, 2.0, 13.0, 22.0, 12.0)
        : (16.0, 52.0, 16.0, 4.0, 14.0, 26.0, 13.0);
    final content = Padding(
      padding: EdgeInsets.all(context.getRSize(pad)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconTile(icon: icon, tone: tone, size: tile),
          SizedBox(width: context.getRSize(tileGap)),
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
                        style: context
                            .semiBoldStyle(titleSize)
                            .copyWith(color: muted),
                      ),
                    ),
                    if (pillLabel != null) ...[
                      SizedBox(width: context.getRSize(compact ? 4 : 8)),
                      StatusPill(
                        label: pillLabel!,
                        tone: pillTone,
                        dense: compact,
                      ),
                    ],
                  ],
                ),
                SizedBox(height: context.getRSize(lineGap)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: context
                        .boldStyle(valueSize)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
                SizedBox(height: context.getRSize(lineGap)),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.regularStyle(subSize).copyWith(color: muted),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: context.getRSize(8)),
            trailing!,
          ],
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
