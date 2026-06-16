import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// A standardized Floating Action Button for the Ribaplus design system.
/// Features a theme-aware gradient, custom shadow, and specific minimum width.
class AppFAB extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final String? heroTag;
  final double? width;
  final Widget? trailing;

  /// Lift the FAB above the system navigation bar on edge-to-edge devices
  /// (3-button nav / gesture pill). Default true. Set false ONLY on bottom-nav
  /// tab roots (POS, Stock) whose visible bottom bar already lifts the FAB clear
  /// of the system nav — adding the inset there would leave a gap above the bar.
  final bool reserveBottomInset;

  const AppFAB({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.heroTag,
    this.width,
    this.trailing,
    this.reserveBottomInset = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Width should match "Add Store" style (~160-180px responsive)
    final double defaultWidth = rSize(context, 165);

    Widget fab = Container(
      height: rSize(context, 50),
      constraints: BoxConstraints(minWidth: width ?? defaultWidth),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colorScheme.primary, colorScheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
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
            padding: EdgeInsets.symmetric(horizontal: rSize(context, 16)),
            child: Row(
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
                  label,
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
            ),
          ),
        ),
      ),
    );

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
