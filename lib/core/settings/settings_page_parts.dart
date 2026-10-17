import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Local building blocks for the settings pages behind CEO Settings and for
/// Profile / Staff Settings (#442, PRD #346 Wave 2 C). Shared-part candidates:
/// they follow the CEO Settings menu (`settings_screen.dart`) exactly — a
/// solid top bar with [ScreenHeader], content capped at the raw
/// [kSettingsMaxContentWidth] and centred.

/// Side gutter that centres a [kSettingsMaxContentWidth] column in the
/// MEASURED [width], never under `getRSize(16)`.
double settingsGutter(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kSettingsMaxContentWidth) / 2);

/// The top bar height shared by every settings page: the theme's bar height,
/// grown when the scaled header tile would touch its edges.
double settingsBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid top bar of a settings page: Surface, a hairline and the soft
/// `topBarShadow`, never changing on scroll; back arrow when the route can pop.
class SettingsPageBar extends StatelessWidget implements PreferredSizeWidget {
  const SettingsPageBar({
    super.key,
    required this.height,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final double height;
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    final canGoBack = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: height,
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
      title: ScreenHeader(
        icon: icon,
        title: title,
        subtitle: subtitle,
        leading: canGoBack
            ? IconButton(
                key: const Key('settings-page-back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                constraints: const BoxConstraints(
                  minWidth: kMinInteractiveDimension,
                  minHeight: kMinInteractiveDimension,
                ),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: AppIcon(
                  AppIcons.arrowBack,
                  size: context.getRSize(24),
                  color: t.colorScheme.onSurface,
                ),
              )
            : null,
        actions: actions,
      ),
    );
  }
}

/// A settings page frame: flat page background, [SettingsPageBar] and a
/// [body]. Transparent Scaffold so [AppDecorations.pageBackground] shows.
class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: SettingsPageBar(
          height: settingsBarHeight(context),
          icon: icon,
          title: title,
          subtitle: subtitle,
          actions: actions,
        ),
        body: body,
      ),
    );
  }
}

/// A scrolling column of [children], capped at [kSettingsMaxContentWidth] and
/// centred; clears side insets and the bottom navigation inset.
class SettingsPageList extends StatelessWidget {
  const SettingsPageList({super.key, required this.children, this.listKey});

  final List<Widget> children;
  final Key? listKey;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gutter = settingsGutter(context, constraints.maxWidth);
          return ListView(
            key: listKey,
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(16),
              gutter,
              context.getRSize(24) + context.deviceBottomPadding,
            ),
            children: children,
          );
        },
      ),
    );
  }
}

/// A flat card with the standard padding.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      // A transparent Material so a ListTile / SwitchListTile inside the card
      // paints its ink on top of the card's fill instead of under it.
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: padding ?? EdgeInsets.all(context.getRSize(16)),
          child: child,
        ),
      ),
    );
  }
}

/// An icon tile + bold title + muted subtitle (+ optional trailing control)
/// row inside a [SettingsCard]. At least 48dp tall.
class SettingsControlRow extends StatelessWidget {
  const SettingsControlRow({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
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
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.regularStyle(13).copyWith(color: muted),
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
  }
}

/// The M3 bottom-sheet content cap (640).
const double kSettingsSheetMaxWidth = 640;
