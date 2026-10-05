import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

/// One destination of the app frame's main navigation (#352).
///
/// The bottom bar (under 600dp wide) and the side rail (600dp+) draw the SAME
/// list, built once by `MainLayout` from the permission gates, so the two can
/// never disagree on which items a role sees, their order, or what a tap does.
@immutable
class FrameNavItem {
  const FrameNavItem({
    required this.tabIndex,
    required this.icon,
    required this.label,
    this.raised = false,
    this.badgeCount = 0,
    this.flyTarget,
  });

  /// Index into MainLayout's tab list (0 Home, 1 POS, 2 Stock, 3 Orders,
  /// 8 Cart).
  final int tabIndex;
  final IconData icon;
  final String label;

  /// POS: drawn as the big primary-gradient button with its label in primary,
  /// whether selected or not (PRD #346, "only POS is raised").
  final bool raised;

  /// Red count badge on the icon; hidden at 0.
  final int badgeCount;

  /// When set, this item's icon is a landing spot for fly-to-cart flights
  /// (the Cart item, #352 PR 3).
  final FlyTargetId? flyTarget;
}

/// Key of the item for [tabIndex] on the bottom bar or the rail.
Key frameNavItemKey(int tabIndex) =>
    ValueKey<String>('frame-nav-item-$tabIndex');

/// Colours shared by the bar and the rail: selected = primary, idle = muted.
Color _idleColor(ThemeData t) =>
    t.textTheme.bodySmall?.color ??
    t.iconTheme.color ??
    t.colorScheme.onSurface;

TextStyle _labelStyle(BuildContext context, Color color, {bool bold = false}) {
  final base = Theme.of(context).textTheme.labelMedium ?? const TextStyle();
  if (bold) {
    // The raised POS label is ExtraBold (PRD #346 decision 2).
    return context.screenTitleStyle.copyWith(
      fontSize: base.fontSize ?? context.getRFontSize(12),
      color: color,
    );
  }
  return base.copyWith(color: color);
}

/// An item's icon with its count badge, filled when [selected].
class _NavIcon extends StatelessWidget {
  const _NavIcon({
    required this.item,
    required this.selected,
    required this.color,
    required this.size,
  });

  final FrameNavItem item;
  final bool selected;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fixed = Theme.of(context).extension<AppFixedColors>();
    final badge = Badge(
      label: Text(item.badgeCount.toString()),
      isLabelVisible: item.badgeCount > 0,
      backgroundColor: fixed?.danger ?? Theme.of(context).colorScheme.error,
      child: AppIcon(item.icon, filled: selected, color: color, size: size),
    );
    final target = item.flyTarget;
    return target == null ? badge : FlyTarget(id: target, child: badge);
  }
}

/// The big primary-gradient POS button: a circle on the bottom bar, a rounded
/// tile on the rail.
class _RaisedPosButton extends StatelessWidget {
  const _RaisedPosButton({
    required this.item,
    required this.extent,
    required this.circle,
  });

  final FrameNavItem item;
  final double extent;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final decoration = AppDecorations.primaryButtonGradient(
      context,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      radius: AppSpacing.borderRadiusXL,
    );
    return Container(
      width: extent,
      height: extent,
      // The bottom bar's circle sits in a Surface ring so it reads as lifted
      // off the bar (phone-home-light.png).
      decoration: circle
          ? decoration.copyWith(
              border: Border.all(
                color: t.colorScheme.surface,
                width: context.getRSize(4),
              ),
            )
          : decoration,
      alignment: Alignment.center,
      child: _NavIcon(
        item: item,
        selected: true,
        color: t.colorScheme.onPrimary,
        size: extent * 0.46,
      ),
    );
  }
}

/// The bottom bar shown under 600dp wide (#352). Restyle of the old Material
/// `BottomNavigationBar`: solid Surface with a hairline top border, POS raised
/// in a gradient circle, selected = filled primary icon + primary label, idle =
/// outlined icon + muted label.
///
/// The POS circle rises above the bar's top edge. Only the part inside the bar
/// takes taps; the whole POS slot (full bar height) is its tap target, so the
/// target is never smaller than the other items.
class FrameBottomBar extends StatelessWidget {
  const FrameBottomBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<FrameNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Height of the bar's row, above the system navigation inset.
  static double rowHeight(BuildContext context) => math.max(
    kMinInteractiveDimension + context.getRSize(8),
    context.getRSize(64),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.extension<AppSchemeColors>();
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final height = rowHeight(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
        boxShadow: [
          if (scheme != null)
            BoxShadow(
              color: scheme.topBarShadow,
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              for (final item in items)
                Expanded(
                  child: _BottomBarSlot(
                    key: frameNavItemKey(item.tabIndex),
                    item: item,
                    selected: item.tabIndex == currentIndex,
                    height: height,
                    onTap: () => onTap(item.tabIndex),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBarSlot extends StatelessWidget {
  const _BottomBarSlot({
    super.key,
    required this.item,
    required this.selected,
    required this.height,
    required this.onTap,
  });

  final FrameNavItem item;
  final bool selected;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final color = item.raised || selected ? primary : _idleColor(t);
    final label = Text(
      item.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _labelStyle(context, color, bold: item.raised),
    );

    final Widget content;
    if (item.raised) {
      final diameter = context.getRSize(60);
      content = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          Positioned(bottom: context.getRSize(6), child: label),
          Positioned(
            // Rises above the bar by ~40% of the circle.
            top: -diameter * 0.4,
            child: _RaisedPosButton(item: item, extent: diameter, circle: true),
          ),
        ],
      );
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _NavIcon(
            item: item,
            selected: selected,
            color: color,
            size: context.getRSize(24),
          ),
          SizedBox(height: context.getRSize(4)),
          label,
        ],
      );
    }

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(height: height, child: content),
        ),
      ),
    );
  }
}

/// The side rail shown at 600dp+ (#352), styled after
/// `phone-landscape-home-dark.png`: solid Surface, the menu (☰) button on top,
/// then the same items as the bottom bar. POS is a raised gradient tile; the
/// selected item is a filled primary icon + primary label with no pill.
///
/// The menu button opens the drawer of MainLayout's Scaffold and is the
/// first-run tour's [SpotlightTargetId.menuButton] at this size.
class FrameNavRail extends StatelessWidget {
  const FrameNavRail({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<FrameNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Below this much height (after the system insets) the rail compacts:
  /// a smaller POS tile and tighter item padding, so a sideways phone
  /// (~360dp minus a 24dp status bar) fits all five items and the menu.
  static const double _kCompactBelowHeight = 440;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final insets = MediaQuery.paddingOf(context);
    // The rail owns the left system inset (a display cutout, or a landscape
    // navigation bar on the left): its Surface extends under it, its items
    // sit beside it.
    return Container(
      width: context.navRailWidth + insets.left,
      color: t.colorScheme.surface,
      child: SafeArea(
        right: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < _kCompactBelowHeight;
            final children = <Widget>[
              const _RailMenuButton(),
              for (final item in items)
                _RailItem(
                  key: frameNavItemKey(item.tabIndex),
                  item: item,
                  compact: compact,
                  selected: item.tabIndex == currentIndex,
                  onTap: () => onTap(item.tabIndex),
                ),
            ];
            // Items are spread over the height when they fit; if a window is
            // ever too short even when compact, the rail scrolls rather than
            // clipping anything.
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.spaceEvenly
                        : MainAxisAlignment.start,
                    children: compact
                        ? children
                        : [
                            for (final child in children) ...[
                              SizedBox(height: context.getRSize(8)),
                              child,
                            ],
                          ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RailMenuButton extends StatelessWidget {
  const _RailMenuButton();

  @override
  Widget build(BuildContext context) {
    return SpotlightTarget(
      id: SpotlightTargetId.menuButton,
      child: Builder(
        builder: (ctx) => IconButton(
          key: const Key('frame-rail-menu'),
          tooltip: MaterialLocalizations.of(ctx).openAppDrawerTooltip,
          constraints: const BoxConstraints(
            minWidth: kMinInteractiveDimension,
            minHeight: kMinInteractiveDimension,
          ),
          icon: AppIcon(
            AppIcons.menu,
            size: context.getRSize(26),
            color: Theme.of(ctx).colorScheme.onSurface,
          ),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    super.key,
    required this.item,
    required this.compact,
    required this.selected,
    required this.onTap,
  });

  final FrameNavItem item;

  /// Short window: smaller POS tile, tighter padding (see FrameNavRail).
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final color = item.raised || selected ? primary : _idleColor(t);
    final railWidth = context.navRailWidth;

    final Widget icon = item.raised
        ? _RaisedPosButton(
            item: item,
            extent: compact
                ? railWidth * 0.56
                : math.max(kMinInteractiveDimension, railWidth * 0.72),
            circle: false,
          )
        : _NavIcon(
            item: item,
            selected: selected,
            color: color,
            size: context.getRSize(24),
          );

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: railWidth,
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: context.getRSize(compact ? 2 : 6),
                horizontal: context.getRSize(4),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon,
                  SizedBox(height: context.getRSize(compact ? 2 : 4)),
                  // Never ellipsized: a label too wide for the rail (large
                  // system text size) shrinks to fit instead, so "Orders"
                  // always reads in full.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      style: _labelStyle(context, color, bold: item.raised),
                    ),
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
