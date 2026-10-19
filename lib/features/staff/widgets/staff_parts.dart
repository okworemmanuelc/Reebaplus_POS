import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/avatar_helpers.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the Staff screens (#440, PRD #346 Wave 2 batch C).
abstract final class StaffKeys {
  static const Key topBar = ValueKey<String>('staff-top-bar');
  static const Key list = ValueKey<String>('staff-list');
  static const Key invitesList = ValueKey<String>('staff-invites-list');
  static const Key searchStaff = ValueKey<String>('staff-search');
  static const Key searchInvites = ValueKey<String>('staff-search-invites');
  static const Key empty = ValueKey<String>('staff-empty');
  static const Key detailBack = ValueKey<String>('staff-detail-back');
  static const Key headerCard = ValueKey<String>('staff-header-card');
  static const Key statsGrid = ValueKey<String>('staff-stats-grid');
  static const Key accountCard = ValueKey<String>('staff-account-card');
  static const Key inviteBack = ValueKey<String>('staff-invite-back');
  static const Key inviteCode = ValueKey<String>('staff-invite-code');
  static const Key detailList = ValueKey<String>('staff-detail-list');
  static const Key storesSheet = ValueKey<String>('staff-stores-sheet');

  static Key row(String membershipId) =>
      ValueKey<String>('staff-row-$membershipId');
  static Key invite(String inviteId) =>
      ValueKey<String>('staff-invite-$inviteId');
  static Key revoke(String inviteId) =>
      ValueKey<String>('staff-revoke-$inviteId');
  static Key roleCard(String roleId) =>
      ValueKey<String>('staff-role-card-$roleId');
}

/// Staff top bar height: CEO Settings' rule (#369): the theme's 68dp, grown
/// when the scaled header tile would touch its edges. Repeated here because a
/// feature never reaches into another feature's widgets; shared-part
/// candidate (with `customerTopBarHeight`).
double staffTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// Solid top bar of the Staff screens: `colorScheme.surface`, a hairline and
/// the soft `topBarShadow`, never changing on scroll. Shared-part candidate.
class StaffTopBar extends StatelessWidget implements PreferredSizeWidget {
  const StaffTopBar({
    super.key,
    required this.height,
    required this.header,
    this.bottom,
  });

  final double height;
  final Widget header;

  /// An optional row under the header (Staff Management's TabBar).
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize =>
      Size.fromHeight(height + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: height,
      titleSpacing: context.getRSize(8),
      centerTitle: false,
      backgroundColor: t.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      bottom: bottom,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          border: Border(bottom: BorderSide(color: t.dividerColor, width: 1)),
          boxShadow: [
            BoxShadow(
              color: topBarShadow,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
      title: header,
    );
  }
}

/// The 48dp back arrow of a pushed Staff screen (`maybePop`, as before).
class StaffBackButton extends StatelessWidget {
  const StaffBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: kMinInteractiveDimension,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        icon: const Icon(AppIcons.arrowBackIosNew),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

/// Side gutter that centres a [maxWidth] column in [width], never under
/// `getRSize(16)`. List and form screens use the raw 720
/// ([kSettingsMaxContentWidth]); details use a raw 960.
double staffGutter(
  BuildContext context,
  double width, {
  double maxWidth = kSettingsMaxContentWidth,
}) => math.max(context.getRSize(16), (width - maxWidth) / 2);

/// Wraps a box body (not a sliver) in the centred column and a page-sized
/// scroll view. The measured width decides the gutter.
class StaffColumn extends StatelessWidget {
  const StaffColumn({
    super.key,
    required this.children,
    this.maxWidth = kSettingsMaxContentWidth,
    this.top,
    this.bottom,
    this.physics,
    this.scrollKey,
  });

  final List<Widget> children;
  final double maxWidth;
  final double? top;
  final double? bottom;
  final ScrollPhysics? physics;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final g = staffGutter(context, c.maxWidth, maxWidth: maxWidth);
        return ListView(
          key: scrollKey,
          physics: physics,
          padding: EdgeInsets.fromLTRB(
            g,
            top ?? context.getRSize(16),
            g,
            bottom ?? context.getRSize(16) + context.deviceBottomPadding,
          ),
          children: children,
        );
      },
    );
  }
}

/// Role to fixed tag tone: CEO warning, Manager info, Cashier green, the rest
/// neutral. The `roleTagColor` palette is not used (it is a raw palette).
TagPillTone staffRoleTone(String? slug) => switch (slug) {
  'ceo' => TagPillTone.warning,
  'manager' => TagPillTone.info,
  'cashier' => TagPillTone.green,
  _ => TagPillTone.neutral,
};

/// The same mapping for an [IconTile].
IconTileTone staffRoleIconTone(String? slug) => switch (slug) {
  'ceo' => IconTileTone.warning,
  'manager' => IconTileTone.info,
  'cashier' => IconTileTone.green,
  _ => IconTileTone.neutral,
};

/// Role pill (uppercase, as the role name reads on the Customers tier tags).
class StaffRoleTag extends StatelessWidget {
  const StaffRoleTag({super.key, required this.name, required this.slug});

  final String name;
  final String? slug;

  @override
  Widget build(BuildContext context) =>
      TagPill(label: name, tone: staffRoleTone(slug), dense: true);
}

/// A rounded initial tile: [avatarColor] drives the tint, else info.
class StaffInitialTile extends StatelessWidget {
  const StaffInitialTile({
    super.key,
    required this.name,
    required this.avatarColorHex,
    this.size = 44,
    this.gradient = false,
  });

  final String name;
  final String avatarColorHex;
  final double size;

  /// The detail header uses the solid primary gradient tile.
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final edge = context.getRSize(size);
    final tint = parseHexColor(avatarColorHex);
    final initial = avatarInitials(name);
    return Container(
      width: edge,
      height: edge,
      alignment: Alignment.center,
      decoration: gradient
          ? AppDecorations.primaryButtonGradient(
              context,
              radius: AppSpacing.borderRadiusL,
            )
          : BoxDecoration(
              color: tint != null ? tint.withValues(alpha: 0.14) : f.infoTint,
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
            ),
      child: Text(
        initial,
        style: context
            .boldStyle(gradient ? 22 : 17)
            .copyWith(
              color: gradient ? t.colorScheme.onPrimary : (tint ?? f.info),
            ),
      ),
    );
  }
}

/// One member on the Staff tab: a flat card, the whole card taps when
/// [onTap] is set (>= 48dp). Faded for suspended or unmanageable rows.
class StaffListRow extends StatelessWidget {
  const StaffListRow({
    super.key,
    required this.name,
    required this.avatarColorHex,
    required this.roleName,
    required this.roleSlug,
    required this.lines,
    required this.lastLoginLabel,
    required this.isSelf,
    required this.suspended,
    required this.faded,
    required this.showChevron,
    this.onTap,
  });

  final String name;
  final String avatarColorHex;
  final String roleName;
  final String? roleSlug;

  /// Email, phone, address: the non-empty ones, in that order.
  final List<String> lines;
  final String lastLoginLabel;
  final bool isSelf;
  final bool suspended;
  final bool faded;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final card = DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  StaffInitialTile(name: name, avatarColorHex: avatarColorHex),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        for (final line in lines) ...[
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            line,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: muted),
                          ),
                        ],
                        SizedBox(height: context.getRSize(6)),
                        Wrap(
                          spacing: context.getRSize(6),
                          runSpacing: context.getRSize(4),
                          children: [
                            StaffRoleTag(name: roleName, slug: roleSlug),
                            if (isSelf)
                              const TagPill(
                                label: 'You',
                                tone: TagPillTone.info,
                                dense: true,
                              ),
                            if (suspended)
                              const TagPill(
                                label: 'Suspended',
                                tone: TagPillTone.neutral,
                                dense: true,
                              ),
                          ],
                        ),
                        SizedBox(height: context.getRSize(6)),
                        Text(
                          lastLoginLabel,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (showChevron)
                    Icon(
                      AppIcons.chevronRight,
                      size: context.getRSize(18),
                      color: muted,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return faded ? Opacity(opacity: 0.55, child: card) : card;
  }
}

/// One pending invite: code in mono, role tag, three meta lines, Revoke.
class StaffInviteCard extends StatelessWidget {
  const StaffInviteCard({
    super.key,
    required this.code,
    required this.roleName,
    required this.roleSlug,
    required this.email,
    required this.byLine,
    required this.expiryLabel,
    required this.onRevoke,
    this.revokeKey,
  });

  final String code;
  final String roleName;
  final String? roleSlug;
  final String email;
  final String byLine;
  final String expiryLabel;
  final VoidCallback onRevoke;
  final Key? revokeKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.monoStyle.copyWith(
                      color: t.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: context.getRFontSize(18),
                      letterSpacing: 2,
                    ),
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                StaffRoleTag(name: roleName, slug: roleSlug),
              ],
            ),
            SizedBox(height: context.getRSize(8)),
            StaffMetaLine(icon: AppIcons.email, text: email),
            SizedBox(height: context.getRSize(4)),
            StaffMetaLine(icon: AppIcons.userEdit, text: byLine),
            SizedBox(height: context.getRSize(4)),
            StaffMetaLine(icon: AppIcons.time, text: expiryLabel),
            SizedBox(height: context.getRSize(8)),
            Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: TextButton.icon(
                  key: revokeKey,
                  onPressed: onRevoke,
                  icon: Icon(AppIcons.block, size: 16, color: f.danger),
                  label: Text(
                    'Revoke',
                    style: context.boldStyle(14).copyWith(color: f.danger),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An icon + one muted line (invite meta).
class StaffMetaLine extends StatelessWidget {
  const StaffMetaLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: context.getRSize(14), color: muted),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.regularStyle(12).copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// Neutral empty state (icon tile + message), as Customers' empty message.
class StaffEmpty extends StatelessWidget {
  const StaffEmpty({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      key: StaffKeys.empty,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTile(icon: icon, tone: IconTileTone.neutral),
          SizedBox(height: context.getRSize(16)),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.semiBoldStyle(16).copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

/// Staff detail header: gradient initials tile, name, role tag, status and
/// store pills. Local copy of the Profile header (#440; `profile_ui.dart`
/// belongs to another issue). Shared-part candidate.
class StaffHeaderCard extends StatelessWidget {
  const StaffHeaderCard({
    super.key,
    required this.name,
    required this.avatarColorHex,
    required this.roleName,
    required this.roleSlug,
    required this.suspended,
    required this.storeLabel,
  });

  final String name;
  final String avatarColorHex;
  final String roleName;
  final String? roleSlug;
  final bool suspended;
  final String storeLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      key: StaffKeys.headerCard,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(20)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StaffInitialTile(
              name: name,
              avatarColorHex: avatarColorHex,
              size: 60,
              gradient: true,
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .extraBoldStyle(18)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  SizedBox(height: context.getRSize(8)),
                  Wrap(
                    spacing: context.getRSize(6),
                    runSpacing: context.getRSize(6),
                    children: [
                      StaffRoleTag(name: roleName, slug: roleSlug),
                      TagPill(
                        label: suspended ? 'Suspended' : 'Active',
                        tone: suspended
                            ? TagPillTone.neutral
                            : TagPillTone.green,
                        icon: suspended
                            ? AppIcons.userSuspended
                            : AppIcons.checkCircle,
                        dense: true,
                      ),
                      TagPill(
                        label: storeLabel,
                        tone: TagPillTone.info,
                        icon: AppIcons.store,
                        dense: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One figure on Staff detail: tile, big value, muted label.
class StaffStat {
  const StaffStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
  });

  final String label;
  final String value;
  final IconData icon;
  final IconTileTone tone;
}

/// The stat tiles: measured columns (2 under 480, 3 under 760, else 5), each
/// card sized by its content so large text never overflows.
class StaffStatGrid extends StatelessWidget {
  const StaffStatGrid({super.key, required this.stats});

  final List<StaffStat> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 760 ? 5 : (c.maxWidth >= 480 ? 3 : 2);
        final gap = context.getRSize(12);
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          key: StaffKeys.statsGrid,
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final s in stats)
              SizedBox(
                width: w,
                child: _StaffStatCard(stat: s),
              ),
          ],
        );
      },
    );
  }
}

class _StaffStatCard extends StatelessWidget {
  const _StaffStatCard({required this.stat});

  final StaffStat stat;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(icon: stat.icon, tone: stat.tone, size: 36),
            SizedBox(height: context.getRSize(10)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                stat.value,
                maxLines: 1,
                style: context
                    .extraBoldStyle(18)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
            ),
            SizedBox(height: context.getRSize(2)),
            Text(
              stat.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.regularStyle(12).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row inside [StaffInfoCard]: icon, muted label, value, and a chevron when
/// it taps (>= 48dp).
class StaffInfoRow extends StatelessWidget {
  const StaffInfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: onTap != null ? kMinInteractiveDimension : 0,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
        child: Row(
          children: [
            Icon(icon, size: context.getRSize(18), color: muted),
            SizedBox(width: context.getRSize(12)),
            Text(
              label,
              style: context.semiBoldStyle(13).copyWith(color: muted),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: context
                    .boldStyle(13)
                    .copyWith(color: valueColor ?? t.colorScheme.onSurface),
              ),
            ),
            if (onTap != null) ...[
              SizedBox(width: context.getRSize(4)),
              Icon(
                AppIcons.chevronRight,
                size: context.getRSize(18),
                color: muted,
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      onTap: onTap,
      child: row,
    );
  }
}

/// A titled flat card around [StaffInfoRow]s (Account Details).
class StaffInfoCard extends StatelessWidget {
  const StaffInfoCard({super.key, required this.title, required this.rows});

  final String title;
  final List<StaffInfoRow> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      key: StaffKeys.accountCard,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: context
                  .boldStyle(15)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            SizedBox(height: context.getRSize(4)),
            for (var i = 0; i < rows.length; i++) ...[
              rows[i],
              if (i < rows.length - 1)
                Divider(height: 1, color: t.dividerColor),
            ],
          ],
        ),
      ),
    );
  }
}

/// A selectable role card on Invite Staff: radio dot, role name, tag and the
/// capability lines. Selected = primary border on `primaryTint`.
class StaffRoleOptionCard extends StatelessWidget {
  const StaffRoleOptionCard({
    super.key,
    required this.roleName,
    required this.roleSlug,
    required this.capabilities,
    required this.selected,
    required this.onTap,
  });

  final String roleName;
  final String? roleSlug;
  final List<String> capabilities;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final scheme = t.extension<AppSchemeColors>();
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final base = AppDecorations.card(context);
    return DecoratedBox(
      decoration: base.copyWith(
        color: selected ? (scheme?.primaryTint ?? f.infoTint) : base.color,
        border: Border.all(
          color: selected ? primary : t.dividerColor,
          width: selected ? 2 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        selected
                            ? AppIcons.radioButtonChecked
                            : AppIcons.radioButtonUnchecked,
                        size: context.getRSize(20),
                        color: selected ? primary : muted,
                      ),
                      SizedBox(width: context.getRSize(12)),
                      Expanded(
                        child: Text(
                          roleName,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                      ),
                      StaffRoleTag(name: roleName, slug: roleSlug),
                    ],
                  ),
                  if (capabilities.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(12)),
                    for (final cap in capabilities)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.getRSize(6)),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(
                                top: context.getRSize(3),
                                right: context.getRSize(8),
                              ),
                              child: Icon(
                                AppIcons.checkCircle,
                                size: context.getRSize(14),
                                color: selected ? primary : muted,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                cap,
                                style: context
                                    .regularStyle(13)
                                    .copyWith(color: muted, height: 1.3),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sheet frame for Staff sheets: handle, title, primary subtitle, one
/// shrink-wrapped scroll capped at 90% of the screen height, bottom inset.
/// Shared-part candidate (with `CustomerSheetFrame`).
class StaffSheetFrame extends StatelessWidget {
  const StaffSheetFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.footer,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final h = context.screenHeight;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: h * 0.9),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(12),
          context.getRSize(20),
          context.getRSize(16) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(12)),
            Text(title, style: context.screenTitleStyle),
            SizedBox(height: context.getRSize(4)),
            Text(
              subtitle,
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.primary),
            ),
            SizedBox(height: context.getRSize(12)),
            Flexible(child: SingleChildScrollView(child: child)),
            if (footer != null) ...[
              SizedBox(height: context.getRSize(12)),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}
