import 'package:flutter/material.dart';

/// Theme-aware primary text colour for auth / onboarding screens. Adapts to
/// light/dark mode and to the active accent via [ColorScheme.onSurface], so
/// content (titles, labels, typed input text) is always legible on the
/// theme-aware auth backdrop. Use this instead of a hardcoded palette colour.
Color authTextPrimary(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

/// Theme-aware muted/secondary text colour for auth / onboarding screens.
Color authTextMuted(BuildContext context, [double alpha = 0.65]) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: alpha);

/// Reusable decorations for the Ribaplus design system.
class AppDecorations {
  AppDecorations._();

  /// Primary gradient box decoration (adapts to current theme).
  static BoxDecoration primaryGradient(
    BuildContext context, {
    double radius = 12,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [primary.withValues(alpha: 0.8), primary],
      ),
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: primary.withValues(alpha: 0.3),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  /// Surface card decoration — adapts to current theme.
  static BoxDecoration surfaceCard(
    BuildContext context, {
    double radius = 20,
  }) => BoxDecoration(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Theme.of(context).dividerColor),
  );

  /// Glass card decoration for auth/onboarding screens.
  static BoxDecoration glassCard(BuildContext context, {double radius = 16}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: isDark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.black.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.2)
            : Colors.black.withValues(alpha: 0.1),
      ),
    );
  }

  /// Theme-aware input decoration for auth/onboarding fields.
  static InputDecoration authInputDecoration(
    BuildContext context, {
    required String label,
    required IconData prefixIcon,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? Colors.white : Colors.black;

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: baseColor.withValues(alpha: 0.7)),
      prefixIcon: Icon(prefixIcon, color: baseColor.withValues(alpha: 0.7)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: baseColor.withValues(alpha: 0.3)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.redAccent, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}

/// A 2 px top-edge shimmer line (amber gradient) that fades from
/// transparent → amberPrimary → transparent.
class AmberGlowLine extends StatelessWidget {
  final double height;
  const AmberGlowLine({super.key, this.height = 2});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, primary, Colors.transparent],
        ),
      ),
    );
  }
}
