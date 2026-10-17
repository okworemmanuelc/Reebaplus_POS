import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/avatar_helpers.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Shared profile UI building blocks (§10.5 / §27.1 / §9.5), restyled in #442
/// (PRD #346 Wave 2 C) onto the redesign parts. One card set used by both the
/// Profile screen and the Staff Detail screen so the two look identical.
/// Purely presentational — no provider reads, callers pass the data.

/// A small pill shown under the name in [ProfileHeaderCard] (e.g. the assigned
/// store, or an Active/Suspended status badge).
class ProfilePill {
  final IconData icon;
  final String label;

  /// Tint for the pill. Null = the neutral tag tone (used for the store pill).
  final Color? color;
  const ProfilePill({required this.icon, required this.label, this.color});
}

/// A single performance metric for [ProfileStatGrid].
class ProfileStat {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const ProfileStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
}

Color _textOf(BuildContext c) => Theme.of(c).colorScheme.onSurface;
Color _subtextOf(BuildContext c) =>
    Theme.of(c).textTheme.bodySmall?.color ?? Theme.of(c).iconTheme.color!;

/// A tinted stadium tag in an arbitrary [color] (role colours come from the
/// theme, so they cannot be a fixed [TagPill] tone).
class _TintedTag extends StatelessWidget {
  const _TintedTag({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon!, size: context.getRSize(14), color: color),
            SizedBox(width: context.getRSize(4)),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.boldStyle(12).copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The header: avatar, name, role tag, and a row of pills — a flat card.
class ProfileHeaderCard extends StatelessWidget {
  final String name;
  final String avatarColorHex;
  final String roleLabel;
  final Color roleColor;
  final List<ProfilePill> pills;

  const ProfileHeaderCard({
    super.key,
    required this.name,
    required this.avatarColorHex,
    required this.roleLabel,
    required this.roleColor,
    this.pills = const [],
  });

  @override
  Widget build(BuildContext context) {
    final avatarColor =
        parseHexColor(avatarColorHex) ?? Theme.of(context).colorScheme.primary;
    final edge = context.getRSize(84);

    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(20)),
        child: Column(
          children: [
            Container(
              width: edge,
              height: edge,
              decoration: BoxDecoration(
                color: avatarColor.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(
                  color: avatarColor.withValues(alpha: 0.4),
                  width: 3,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                avatarInitials(name),
                style: context.extraBoldStyle(26).copyWith(color: avatarColor),
              ),
            ),
            SizedBox(height: context.getRSize(14)),
            Text(
              name,
              textAlign: TextAlign.center,
              style: context
                  .extraBoldStyle(20)
                  .copyWith(color: _textOf(context)),
            ),
            SizedBox(height: context.getRSize(10)),
            _TintedTag(label: roleLabel.toUpperCase(), color: roleColor),
            if (pills.isNotEmpty) ...[
              SizedBox(height: context.getRSize(10)),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: context.getRSize(8),
                runSpacing: context.getRSize(8),
                children: [
                  for (final p in pills)
                    p.color == null
                        ? TagPill(
                            label: p.label,
                            tone: TagPillTone.neutral,
                            icon: p.icon,
                          )
                        : _TintedTag(
                            label: p.label,
                            color: p.color!,
                            icon: p.icon,
                          ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A responsive grid of metric cards. 2 columns on phones, 3 when wide; fewer
/// columns when there are only 1–2 stats so they don't stretch.
class ProfileStatGrid extends StatelessWidget {
  final List<ProfileStat> stats;
  const ProfileStatGrid({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = stats.length >= 3
            ? (constraints.maxWidth > 600 ? 3 : 2)
            : stats.length.clamp(1, 3);
        final gap = context.getRSize(12);
        final rows = <Widget>[];
        for (var i = 0; i < stats.length; i += cols) {
          if (i > 0) rows.add(SizedBox(height: gap));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = 0; j < cols; j++) ...[
                    if (j > 0) SizedBox(width: gap),
                    Expanded(
                      child: i + j < stats.length
                          ? ProfileStatCard(stat: stats[i + j])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }
}

/// One metric card: icon tile on top, big value, label below.
class ProfileStatCard extends StatelessWidget {
  final ProfileStat stat;
  const ProfileStatCard({super.key, required this.stat});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(
              icon: stat.icon,
              size: 40,
              tint: stat.color.withValues(alpha: 0.14),
              iconColor: stat.color,
            ),
            SizedBox(height: context.getRSize(10)),
            Text(
              stat.value,
              style: context
                  .extraBoldStyle(18)
                  .copyWith(color: _textOf(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: context.getRSize(2)),
            Text(
              stat.label,
              style: context.regularStyle(12).copyWith(color: _subtextOf(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled card that wraps a list of [ProfileInfoRow]s (e.g. "Account Details").
class ProfileInfoCard extends StatelessWidget {
  final String title;
  final List<ProfileInfoRow> rows;
  const ProfileInfoCard({super.key, required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title: title),
            SizedBox(height: context.getRSize(8)),
            for (var i = 0; i < rows.length; i++) ...[
              rows[i],
              if (i < rows.length - 1)
                Divider(
                  height: context.getRSize(1),
                  color: Theme.of(context).dividerColor,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One row inside a [ProfileInfoCard]: icon · label · value, with an optional
/// chevron + tap (used for the staff Permission-access row, §10.2.1). At least
/// 48dp tall.
class ProfileInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onTap;

  const ProfileInfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final subtext = _subtextOf(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Row(
        children: [
          AppIcon(icon, size: context.getRSize(18), color: subtext),
          SizedBox(width: context.getRSize(12)),
          Text(
            label,
            style: context.semiBoldStyle(13).copyWith(color: subtext),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: context
                  .boldStyle(13)
                  .copyWith(color: valueColor ?? _textOf(context)),
            ),
          ),
          if (onTap != null) ...[
            SizedBox(width: context.getRSize(4)),
            AppIcon(
              AppIcons.chevronRight,
              size: context.getRSize(20),
              color: subtext,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: row,
    );
  }
}
