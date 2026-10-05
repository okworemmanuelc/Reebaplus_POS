import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The redesigned screen header row (#352 PR 2; every mockup's top bar): a
/// solid primary-gradient icon tile, an ExtraBold title and a primary
/// subtitle, then [actions] on the right.
///
/// It is the content of a top bar, not the bar itself: put it in an `AppBar`
/// `title` (or a sliver header) so the bar keeps the flat surface, hairline
/// and shadow from the theme. Plain data — pass the live bell as an action
/// (the app's `NotificationBell`, or [HeaderBell] with a count).
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final IconData icon;
  final String title;

  /// Usually the store name, in primary.
  final String? subtitle;

  /// Menu or back button before the tile (each must be a 48dp target).
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tile = context.getRSize(44);
    return Row(
      children: [
        if (leading != null) ...[
          leading!,
          SizedBox(width: context.getRSize(4)),
        ],
        Container(
          width: tile,
          height: tile,
          alignment: Alignment.center,
          decoration: AppDecorations.primaryButtonGradient(
            context,
            radius: AppSpacing.borderRadiusL,
          ),
          child: AppIcon(
            icon,
            filled: true,
            size: tile * 0.5,
            color: t.colorScheme.onPrimary,
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.screenTitleStyle.copyWith(
                  color: t.colorScheme.onSurface,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.primary),
                ),
            ],
          ),
        ),
        ...actions,
      ],
    );
  }
}

/// A primary bell with a red count badge, as in the mockups' headers. Plain
/// data: give it the unread [count] and what a tap does. A 48dp target.
class HeaderBell extends StatelessWidget {
  const HeaderBell({super.key, required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    return IconButton(
      tooltip: 'Notifications',
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        backgroundColor: f.danger,
        textColor: f.onSolid,
        child: AppIcon(
          AppIcons.notification,
          filled: true,
          size: context.getRSize(26),
          color: t.colorScheme.primary,
        ),
      ),
    );
  }
}
