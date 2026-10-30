import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the Dashboard report screens (#413, PRD #346 Wave 2 B).
abstract final class ReportKeys {
  static const Key topBar = ValueKey<String>('report-top-bar');
  static const Key back = ValueKey<String>('report-back');
  static const Key export = ValueKey<String>('report-export');
  static const Key period = ValueKey<String>('report-period');
  static const Key empty = ValueKey<String>('report-empty');
}

/// The report top bar's height: CEO Settings' rule (#369) — the theme's 68dp,
/// grown when the scaled header tile would touch its edges. Repeated here
/// because a feature never reaches into another feature's widgets;
/// shared-part candidate (with `customerTopBarHeight` and friends).
double reportTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid top bar of the report screens (#413): `colorScheme.surface`, a
/// hairline at the bottom and the soft `topBarShadow`, never changing on
/// scroll (PRD #346 decision 4). [header] is the shared `ScreenHeader`.
/// Shared-part candidate (a copy of `CustomerTopBar`).
class ReportTopBar extends StatelessWidget implements PreferredSizeWidget {
  const ReportTopBar({super.key, required this.height, required this.header});

  final double height;
  final Widget header;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: preferredSize.height,
      titleSpacing: context.getRSize(8),
      centerTitle: false,
      backgroundColor: t.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
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

/// The 48dp back arrow of a pushed report screen: `maybePop`, as the
/// `BackButton` it replaces.
class ReportBackButton extends StatelessWidget {
  const ReportBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: ReportKeys.back,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      icon: AppIcon(
        AppIcons.arrowBack,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }
}

/// A 48dp icon button in the report top bar (Export CSV).
class ReportBarAction extends StatelessWidget {
  const ReportBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;

  /// Null disables the button (as the old `IconButton` did).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      icon: AppIcon(
        icon,
        color: onPressed == null ? t.disabledColor : t.colorScheme.onSurface,
      ),
      onPressed: onPressed,
    );
  }
}

/// The side gutter that centres a [maxWidth] column in [width] (the batch-wide
/// rule: lists and forms 720 = [kSettingsMaxContentWidth], details a fixed 960).
/// Always at least `getRSize(16)`. Pass the MEASURED width.
double reportGutter(
  BuildContext context,
  double width, {
  double maxWidth = kSettingsMaxContentWidth,
}) => math.max(context.getRSize(16), (width - maxWidth) / 2);

/// A flat card holding report content.
class ReportCard extends StatelessWidget {
  const ReportCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: padding ?? EdgeInsets.all(context.getRSize(16)),
        child: child,
      ),
    );
  }
}

AppFixedColors _fixed(BuildContext context) =>
    Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

/// The headline figure of a report: [IconTile] + muted label, the big
/// ExtraBold figure, an optional muted note, then [chips].
class ReportHeadlineCard extends StatelessWidget {
  const ReportHeadlineCard({
    super.key,
    required this.icon,
    required this.tone,
    required this.label,
    required this.figure,
    required this.figureColor,
    this.note,
    this.chips = const [],
  });

  final IconData icon;
  final IconTileTone tone;
  final String label;
  final String figure;

  /// The figure's colour (a fixed green / danger, or the scheme's primary).
  final Color figureColor;
  final String? note;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return ReportCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: icon, tone: tone, size: 40),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.semiBoldStyle(14).copyWith(color: muted),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          // A money figure never ellipsises: it scales down instead.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              figure,
              maxLines: 1,
              style: context.extraBoldStyle(28).copyWith(color: figureColor),
            ),
          ),
          if (note != null) ...[
            SizedBox(height: context.getRSize(4)),
            Text(note!, style: context.regularStyle(13).copyWith(color: muted)),
          ],
          if (chips.isNotEmpty) ...[
            SizedBox(height: context.getRSize(12)),
            Wrap(
              spacing: context.getRSize(8),
              runSpacing: context.getRSize(8),
              children: chips,
            ),
          ],
        ],
      ),
    );
  }
}

/// A "Label: value" chip under a headline figure. Wraps instead of
/// overflowing, so a long label survives 320dp at text scale 1.3.
class ReportChip extends StatelessWidget {
  const ReportChip(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _fixed(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: f.neutralTile,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
      ),
      child: Text(
        text,
        style: context.boldStyle(12).copyWith(color: t.colorScheme.onSurface),
      ),
    );
  }
}

/// A label on the left, a value on the right (breakdown rows). The value never
/// ellipsises.
class ReportValueRow extends StatelessWidget {
  const ReportValueRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 3,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: (bold ? context.boldStyle(15) : context.mediumStyle(14))
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Flexible(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                maxLines: 1,
                style: context
                    .extraBoldStyle(bold ? 16 : 14)
                    .copyWith(color: valueColor ?? t.colorScheme.onSurface),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A hairline between rows of a report card.
class ReportDivider extends StatelessWidget {
  const ReportDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: context.getRSize(16),
    thickness: 1,
    color: Theme.of(context).dividerColor,
  );
}

/// A muted group label over a card (`SectionHeader.group`).
class ReportGroupLabel extends StatelessWidget {
  const ReportGroupLabel(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) =>
      SectionHeader(title: title, variant: SectionHeaderVariant.group);
}

/// The empty state: a neutral tile and one muted line.
class ReportEmpty extends StatelessWidget {
  const ReportEmpty({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      key: ReportKeys.empty,
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTile(icon: icon, tone: IconTileTone.neutral, size: 64),
            SizedBox(height: context.getRSize(12)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.mediumStyle(14).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// One report on the Reports hub: a flat card, the whole card taps (>= 48dp):
/// 44 [IconTile], title Bold 16, muted subtitle, then the pending-count badge
/// (when [badgeCount] > 0) or the chevron. The card is the keyed, tappable
/// area (`reportCardKey`), so the badge sits inside it.
class ReportHubCard extends StatelessWidget {
  const ReportHubCard({
    super.key,
    required this.cardKey,
    required this.badgeKey,
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badgeCount = 0,
  });

  final Key cardKey;
  final Key badgeKey;
  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = _fixed(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        key: cardKey,
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
                  IconTile(icon: icon, tone: tone, size: 48),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(16)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .regularStyle(13)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  if (badgeCount > 0)
                    Container(
                      key: badgeKey,
                      constraints: BoxConstraints(
                        minWidth: context.getRSize(24),
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(8),
                        vertical: context.getRSize(3),
                      ),
                      decoration: BoxDecoration(
                        color: f.warning,
                        borderRadius: BorderRadius.circular(
                          AppSpacing.borderRadiusXL,
                        ),
                      ),
                      child: Text(
                        '$badgeCount',
                        textAlign: TextAlign.center,
                        style: context
                            .extraBoldStyle(12)
                            .copyWith(color: f.onSolid),
                      ),
                    )
                  else
                    AppIcon(
                      AppIcons.chevronRight,
                      color: muted,
                      size: context.getRSize(22),
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
