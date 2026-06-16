import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/avatar_helpers.dart';

/// Shared profile UI building blocks (§10.5 / §27.1 / §9.5). One modern card set
/// used by both the Profile screen and the Staff Detail screen so the two look
/// identical. Purely presentational — no provider reads, callers pass the data.

/// A small pill shown under the name in [ProfileHeaderCard] (e.g. the assigned
/// store, or an Active/Suspended status badge).
class ProfilePill {
  final IconData icon;
  final String label;

  /// Tint for the pill. Null = a neutral subtext tint (used for the store pill).
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

Color _surfaceOf(BuildContext c) => Theme.of(c).colorScheme.surface;
Color _textOf(BuildContext c) => Theme.of(c).colorScheme.onSurface;
Color _subtextOf(BuildContext c) =>
    Theme.of(c).textTheme.bodySmall?.color ?? Theme.of(c).iconTheme.color!;
Color _borderOf(BuildContext c) => Theme.of(c).dividerColor;

/// The header: large role-tinted avatar, name, role chip, and a row of pills.
/// A soft role-tinted gradient at the top gives the card a modern lift while
/// staying theme-aware (light/dark + the active business accent).
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
    final surface = _surfaceOf(context);
    final text = _textOf(context);
    final avatarColor =
        parseHexColor(avatarColorHex) ?? Theme.of(context).colorScheme.primary;

    return Container(
      padding: EdgeInsets.all(context.getRSize(24)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [roleColor.withValues(alpha: 0.14), surface],
          stops: const [0.0, 0.55],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _borderOf(context)),
      ),
      child: Column(
        children: [
          Container(
            width: context.getRSize(84),
            height: context.getRSize(84),
            decoration: BoxDecoration(
              color: avatarColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: avatarColor.withValues(alpha: 0.35),
                width: 3,
              ),
            ),
            child: Center(
              child: Text(
                avatarInitials(name),
                style: TextStyle(
                  color: avatarColor,
                  fontSize: context.getRFontSize(26),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.getRFontSize(20),
              fontWeight: FontWeight.w900,
              color: text,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          _chip(context, roleLabel.toUpperCase(), roleColor, ring: true),
          if (pills.isNotEmpty) ...[
            SizedBox(height: context.getRSize(10)),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: context.getRSize(8),
              runSpacing: context.getRSize(8),
              children: [for (final p in pills) _pill(context, p)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String label,
    Color color, {
    bool ring = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(6),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: ring ? Border.all(color: color.withValues(alpha: 0.3)) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.getRFontSize(11),
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, ProfilePill p) {
    final tint = p.color ?? _subtextOf(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(5),
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(p.icon, size: context.getRSize(11), color: tint),
          SizedBox(width: context.getRSize(6)),
          Text(
            p.label,
            style: TextStyle(
              fontSize: context.getRFontSize(12),
              fontWeight: FontWeight.w600,
              color: tint,
            ),
          ),
        ],
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
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: cols,
          mainAxisSpacing: context.getRSize(12),
          crossAxisSpacing: context.getRSize(12),
          childAspectRatio: 1.45,
          children: [for (final s in stats) ProfileStatCard(stat: s)],
        );
      },
    );
  }
}

/// One metric card: icon on top, big value, label below.
class ProfileStatCard extends StatelessWidget {
  final ProfileStat stat;
  const ProfileStatCard({super.key, required this.stat});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: _surfaceOf(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _borderOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: EdgeInsets.all(context.getRSize(8)),
            decoration: BoxDecoration(
              color: stat.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              stat.icon,
              color: stat.color,
              size: context.getRSize(16),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stat.value,
                style: TextStyle(
                  fontSize: context.getRFontSize(18),
                  fontWeight: FontWeight.w900,
                  color: _textOf(context),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: context.getRSize(2)),
              Text(
                stat.label,
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: _subtextOf(context),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
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
    return Container(
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        color: _surfaceOf(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _borderOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(14),
              color: _textOf(context),
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          for (var i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i < rows.length - 1)
              Divider(height: context.getRSize(20), color: _borderOf(context)),
          ],
        ],
      ),
    );
  }
}

/// One row inside a [ProfileInfoCard]: icon · label · value, with an optional
/// chevron + tap (used for the staff Permission-access row, §10.2.1).
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
    final row = Row(
      children: [
        Icon(icon, size: context.getRSize(14), color: subtext),
        SizedBox(width: context.getRSize(12)),
        Text(
          label,
          style: TextStyle(
            color: subtext,
            fontSize: context.getRFontSize(13),
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: valueColor ?? _textOf(context),
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(13),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onTap != null) ...[
          SizedBox(width: context.getRSize(4)),
          Icon(Icons.chevron_right, size: context.getRSize(18), color: subtext),
        ],
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: row,
    );
  }
}
