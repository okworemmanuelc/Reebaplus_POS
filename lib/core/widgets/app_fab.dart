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

  const AppFAB({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.heroTag,
    this.width,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    // Width should match "Add Store" style (~160-180px responsive)
    final double defaultWidth = rSize(context, 165);
    
    Widget fab = Container(
      height: rSize(context, 50),
      constraints: BoxConstraints(
        minWidth: width ?? defaultWidth,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary,
            colorScheme.secondary,
          ],
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

    if (heroTag != null) {
      return Hero(
        tag: heroTag!,
        child: fab,
      );
    }
    return fab;
  }
}
