import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The fixed colour a [TagPill] takes. Fixed: identical in every design system
/// (PRD #346 decision 6) — `AppFixedColors`.
enum TagPillTone {
  /// Solid blue with white text — "PRO".
  solidInfo,

  /// Pale blue with blue text — "CEO", "Active".
  info,

  /// Pale green with green text — "Positive".
  green,

  /// Pale amber with amber text — "Pending", low stock.
  warning,

  /// Pale red with red text — "None", "Debt".
  danger,

  /// Neutral grey — "Clear", "Live".
  neutral,
}

/// A small rounded tag: PRO / CEO / status words (#352 PR 2; Home cards in
/// `phone-home-*.png`, the profile card in `phone-ceo-settings-light.png`).
///
/// Display only — never a tap target. Optional leading [icon] (an arrow or an
/// info dot for status pills). The label never wraps; at large text sizes it
/// stays on one line and the pill grows.
class TagPill extends StatelessWidget {
  const TagPill({
    super.key,
    required this.label,
    this.tone = TagPillTone.info,
    this.icon,
  });

  final String label;
  final TagPillTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final (Color fill, Color ink) = switch (tone) {
      TagPillTone.solidInfo => (f.info, f.onSolid),
      TagPillTone.info => (f.infoTint, f.info),
      TagPillTone.green => (f.greenTint, f.green),
      TagPillTone.warning => (f.warningTint, f.warning),
      TagPillTone.danger => (f.dangerTint, f.danger),
      TagPillTone.neutral => (f.neutralTile, f.neutralIcon),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon, size: context.getRSize(14), color: ink, filled: true),
            SizedBox(width: context.getRSize(4)),
          ],
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: context.boldStyle(12).copyWith(color: ink),
          ),
        ],
      ),
    );
  }
}

/// A status pill for a stat card: a [TagPill] with the arrow / info icon the
/// mockups pair with each tone ("↑ Positive", "↓ None", "ⓘ Clear").
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.tone});

  final String label;
  final TagPillTone tone;

  @override
  Widget build(BuildContext context) {
    final icon = switch (tone) {
      TagPillTone.green => AppIcons.arrowUp,
      TagPillTone.danger => AppIcons.arrowDown,
      _ => AppIcons.alertCircle,
    };
    return TagPill(label: label, tone: tone, icon: icon);
  }
}
