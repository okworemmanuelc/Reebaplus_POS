import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// A standardized Floating Action Button for the Ribaplus design system.
/// Features a theme-aware gradient, custom shadow, and specific minimum width.
class AppFAB extends StatelessWidget {
  final String? label;
  final IconData icon;
  final VoidCallback onPressed;
  final String? heroTag;
  final double? width;
  final double? height;
  final Widget? trailing;
  final String? tooltip;

  /// Lift the FAB above the system navigation bar on edge-to-edge devices
  /// (3-button nav / gesture pill). Default true. Set false ONLY on bottom-nav
  /// tab roots (POS, Stock) whose visible bottom bar already lifts the FAB clear
  /// of the system nav — adding the inset there would leave a gap above the bar.
  final bool reserveBottomInset;

  const AppFAB({
    super.key,
    this.label,
    required this.icon,
    required this.onPressed,
    this.heroTag,
    this.width,
    this.height,
    this.trailing,
    this.tooltip,
    this.reserveBottomInset = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final bool isIconOnly = label == null || label!.isEmpty;
    final double fabHeight = height ?? rSize(context, 48);

    Widget fabContent;
    if (isIconOnly) {
      fabContent = Icon(
        icon,
        color: colorScheme.onPrimary,
        size: rSize(context, 20),
      );
    } else {
      fabContent = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            color: colorScheme.onPrimary,
            size: rSize(context, 18),
          ),
          SizedBox(width: rSize(context, 10)),
          Text(
            label!,
            style: TextStyle(
              color: colorScheme.onPrimary,
              fontWeight: FontWeight.bold,
              fontSize: rFontSize(context, 15),
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: rSize(context, 8)),
            trailing!,
          ],
        ],
      );
    }

    final double defaultWidth = isIconOnly ? fabHeight : rSize(context, 165);

    Widget fab = Container(
      height: fabHeight,
      width: isIconOnly ? fabHeight : width,
      constraints: isIconOnly
          ? BoxConstraints(minWidth: fabHeight, minHeight: fabHeight)
          : BoxConstraints(minWidth: width ?? defaultWidth),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colorScheme.primary, colorScheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(isIconOnly ? 16 : 16),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isIconOnly ? 0 : rSize(context, 16),
            ),
            // `widthFactor: 1.0` is load-bearing: a bare `Center` is an
            // `Align` that shrink-wraps ONLY when its incoming maxWidth is
            // infinite. The Scaffold FAB slot hands down loose but BOUNDED
            // constraints, so without this the labelled button expands to the
            // full screen width and `endFloat` pushes its left edge off screen.
            // Shrink-wrapping leaves the Container's `minWidth` to set the
            // 165dp floor. Harmless on the icon-only path, whose explicit
            // `width: fabHeight` already constrains this box to a square.
            child: Center(widthFactor: 1.0, child: fabContent),
          ),
        ),
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      fab = Tooltip(message: tooltip!, child: fab);
    }

    Widget result = fab;
    if (heroTag != null) {
      result = Hero(tag: heroTag!, child: fab);
    }
    // Edge-to-edge: the Scaffold FAB slot places the button ~16px above the
    // content bottom, which on a 3-button system nav lands UNDER that nav bar.
    // Lift it by the real system-nav inset (keyboard excluded — the Scaffold
    // already handles the keyboard). Skipped on visible-bottom-bar tab roots.
    if (reserveBottomInset) {
      result = Padding(
        padding: EdgeInsets.only(bottom: context.deviceBottomPadding),
        child: result,
      );
    }
    return result;
  }
}
