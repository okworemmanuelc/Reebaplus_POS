import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';

// Local parts for the sales sheets (#393, PRD #346 Wave 2 A): Checkout, Edit
// Item, Quick Sale, the scan sheets and the Cart's two pickers. Plain data and
// callbacks only — nothing here computes money.
//
// Shared-part candidates: [SalesSheetHeader] (handle + title + subtitle, the
// same block in every sheet), [SalesChoiceCard] (the selectable card the
// customer payment sheet also draws) and [SalesTopBar] (a pushed screen's
// solid bar with a back button).

/// Height of a pushed sales screen's top bar: room for the 44 icon tile (or a
/// 48dp control) plus 8 above and below, never less than the app's bar height.
double salesTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// A pushed screen's solid top bar (as Home / POS / Cart): Surface, hairline,
/// `topBarShadow`, with the shared [ScreenHeader].
class SalesTopBar extends StatelessWidget implements PreferredSizeWidget {
  const SalesTopBar({
    super.key,
    required this.height,
    required this.icon,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final double height;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// The back / close button, a 48dp target.
  final Widget? leading;
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: height,
      titleSpacing: context.getRSize(leading == null ? 16 : 4),
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
      title: Padding(
        padding: EdgeInsets.only(right: context.getRSize(12)),
        child: ScreenHeader(
          icon: icon,
          title: title,
          subtitle: subtitle,
          leading: leading,
          actions: actions,
        ),
      ),
    );
  }
}

/// A 48dp back (or close) button for [SalesTopBar].
class SalesBackButton extends StatelessWidget {
  const SalesBackButton({
    super.key,
    required this.onPressed,
    this.icon = AppIcons.arrowBackIosNew,
    this.tooltip,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      icon: AppIcon(
        icon,
        size: context.getRSize(22),
        color: Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: onPressed,
    );
  }
}

/// The sheet's hairline grab handle (40×4, divider colour).
class SalesSheetHandle extends StatelessWidget {
  const SalesSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: context.getRSize(40),
        height: context.getRSize(4),
        decoration: BoxDecoration(
          color: Theme.of(context).dividerColor,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
        ),
      ),
    );
  }
}

/// A sheet's head: handle, then an optional [leading] tile, the title in
/// `screenTitleStyle` and a primary SemiBold [subtitle], with [trailing]
/// actions on the right.
class SalesSheetHeader extends StatelessWidget {
  const SalesSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing = const [],
    this.showHandle = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> trailing;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHandle) ...[
          const SalesSheetHandle(),
          SizedBox(height: context.getRSize(16)),
        ],
        Row(
          children: [
            if (leading != null) ...[
              leading!,
              SizedBox(width: context.getRSize(12)),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: context.screenTitleStyle.copyWith(
                      color: t.colorScheme.onSurface,
                    ),
                  ),
                  if (subtitle != null) ...[
                    SizedBox(height: context.getRSize(2)),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .semiBoldStyle(13)
                          .copyWith(color: t.colorScheme.primary),
                    ),
                  ],
                ],
              ),
            ),
            ...trailing,
          ],
        ),
      ],
    );
  }
}

/// A selectable option card (payment mode, tender, discount kind): flat card,
/// selected = primary border + `primaryTint` fill + filled primary icon. At
/// least 48dp tall; the whole card taps.
class SalesChoiceCard extends StatelessWidget {
  const SalesChoiceCard({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.trailingCheck = false,
    this.centered = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// A second, muted line under the label.
  final String? subtitle;

  /// Draws a round check on the right (on when [selected]).
  final bool trailingCheck;

  /// Centres a one-line label + icon (the side-by-side chips).
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    final base = AppDecorations.card(context, radius: AppSpacing.borderRadiusM);
    final labelText = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: centered ? TextAlign.center : TextAlign.start,
      style: context
          .semiBoldStyle(14)
          .copyWith(color: selected ? primary : t.colorScheme.onSurface),
    );
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: AppAnimations.fast,
        decoration: selected
            ? base.copyWith(
                color: Color.alphaBlend(
                  t.extension<AppSchemeColors>()?.primaryTint ??
                      primary.withValues(alpha: 0.12),
                  t.colorScheme.surface,
                ),
                border: Border.all(color: primary, width: 1.5),
              )
            : base,
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
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(10),
                ),
                child: Row(
                  mainAxisAlignment: centered
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      AppIcon(
                        icon!,
                        filled: selected,
                        size: context.getRSize(20),
                        color: selected ? primary : muted,
                      ),
                      SizedBox(width: context.getRSize(8)),
                    ],
                    if (subtitle == null)
                      Flexible(child: labelText)
                    else
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            labelText,
                            SizedBox(height: context.getRSize(2)),
                            Text(
                              subtitle!,
                              style: context
                                  .regularStyle(12)
                                  .copyWith(color: muted),
                            ),
                          ],
                        ),
                      ),
                    if (trailingCheck) ...[
                      SizedBox(width: context.getRSize(8)),
                      AppIcon(
                        selected
                            ? AppIcons.checkCircle
                            : AppIcons.radioButtonUnchecked,
                        filled: selected,
                        size: context.getRSize(22),
                        color: selected ? primary : t.dividerColor,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tint of a notice box.
enum SalesNoticeTone { warning, danger, info }

/// A tinted notice: icon, then [title] (Bold) and/or [message]. Warning /
/// danger use the fixed tint + outline pairs; info uses the primary tint.
class SalesNotice extends StatelessWidget {
  const SalesNotice({
    super.key,
    required this.tone,
    this.title,
    this.message,
    this.messageInTone = false,
  });

  final SalesNoticeTone tone;
  final String? title;
  final String? message;

  /// Draws [message] in the tone's colour (SemiBold) instead of muted.
  final bool messageInTone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final (Color fill, Color outline, Color ink) = switch (tone) {
      SalesNoticeTone.warning => (f.warningTint, f.warningOutline, f.warning),
      SalesNoticeTone.danger => (f.dangerTint, f.dangerOutline, f.danger),
      SalesNoticeTone.info => (
        t.extension<AppSchemeColors>()?.primaryTint ??
            t.colorScheme.primary.withValues(alpha: 0.12),
        t.colorScheme.primary.withValues(alpha: 0.25),
        t.colorScheme.primary,
      ),
    };
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            tone == SalesNoticeTone.info
                ? AppIcons.infoCircle
                : AppIcons.warning,
            filled: true,
            size: context.getRSize(18),
            color: ink,
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: context
                        .boldStyle(13)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                if (title != null && message != null)
                  SizedBox(height: context.getRSize(4)),
                if (message != null)
                  Text(
                    message!,
                    style: messageInTone
                        ? context.semiBoldStyle(12).copyWith(color: ink)
                        : context.regularStyle(12).copyWith(color: muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A 48dp square step button (the Cart line's stepper look): a pale primary
/// square with a primary icon, or a red one for remove.
class SalesStepButton extends StatelessWidget {
  const SalesStepButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final ink = danger ? f.danger : t.colorScheme.primary;
    final fill = danger
        ? f.dangerTint
        : (t.extension<AppSchemeColors>()?.primaryTint ??
              t.colorScheme.primary.withValues(alpha: 0.12));
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    final button = Material(
      color: fill,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: SizedBox(
          width: kMinInteractiveDimension,
          height: kMinInteractiveDimension,
          child: Center(
            child: AppIcon(icon, size: context.getRSize(22), color: ink),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      child: tooltip == null
          ? button
          : Tooltip(message: tooltip!, child: button),
    );
  }
}

/// Bottom-sheet surface for sheets that draw their own container: Surface,
/// the theme's 20dp top corners. No hand-drawn shadow (the barrier dims).
BoxDecoration salesSheetDecoration(BuildContext context) => BoxDecoration(
  color: Theme.of(context).colorScheme.surface,
  borderRadius: const BorderRadius.vertical(
    top: Radius.circular(AppSpacing.borderRadiusXL),
  ),
);
