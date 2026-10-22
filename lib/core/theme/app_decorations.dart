import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';

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

  /// The primary button / FAB gradient (`colorScheme.secondary` →
  /// `colorScheme.primary`, top-left → bottom-right) with the scheme's
  /// primary glow underneath. The frame's raised POS tile on the bottom bar and
  /// rail, and the drawer's selected item, use it (#352).
  ///
  /// [shape] lets the raised POS button be a circle; [radius] is ignored then.
  static BoxDecoration primaryButtonGradient(
    BuildContext context, {
    double radius = AppSpacing.borderRadiusL,
    BoxShape shape = BoxShape.rectangle,
    bool glow = true,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glowColor =
        theme.extension<AppSchemeColors>()?.primaryGlow ??
        scheme.primary.withValues(alpha: 0.3);
    return BoxDecoration(
      shape: shape,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [scheme.secondary, scheme.primary],
      ),
      borderRadius: shape == BoxShape.circle
          ? null
          : BorderRadius.circular(radius),
      boxShadow: glow
          ? [
              BoxShadow(
                color: glowColor,
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ]
          : null,
    );
  }

  /// Full-screen page background. A vertical gradient from the scaffold
  /// background to the scheme's background fade. Both stops are fully opaque.
  static BoxDecoration pageBackground(BuildContext context) {
    final theme = Theme.of(context);
    final bg = theme.scaffoldBackgroundColor;
    final fade =
        theme.extension<AppSchemeColors>()?.backgroundFade ??
        AppSchemeColors.fadeFrom(
          brightness: theme.brightness,
          background: bg,
          primary: theme.colorScheme.primary,
        );
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [bg, fade],
      ),
    );
  }

  /// Flat card decoration with soft shadow and hairline border.
  static BoxDecoration card(
    BuildContext context, {
    double? radius,
  }) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final schemeColors = theme.extension<AppSchemeColors>();
    final cardFill =
        schemeColors?.cardFill ??
        theme.colorScheme.surface.withValues(alpha: isLight ? 0.90 : 0.72);
    final cardShadow =
        schemeColors?.cardShadow ??
        Colors.black.withValues(alpha: isLight ? 0.05 : 0.25);
    return BoxDecoration(
      color: cardFill,
      borderRadius: BorderRadius.circular(radius ?? AppSpacing.borderRadiusXL),
      border: Border.all(color: theme.dividerColor, width: 1),
      boxShadow: [
        BoxShadow(
          color: cardShadow,
          blurRadius: 12,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  /// Surface card decoration — delegates to [card] for the flat-with-soft-fade look.
  static BoxDecoration surfaceCard(
    BuildContext context, {
    double radius = 20,
  }) => card(context, radius: radius);

  /// Glass card decoration for auth/onboarding screens — delegates to [card].
  static BoxDecoration glassCard(
    BuildContext context, {
    double radius = 16,
  }) => card(context, radius: radius);

  /// Theme-aware input decoration for auth/onboarding fields.
  static InputDecoration authInputDecoration(
    BuildContext context, {
    required String label,
    required IconData prefixIcon,
    String? prefixText,
    TextStyle? prefixStyle,
    String? helperText,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? Colors.white : Colors.black;

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: enabled
            ? baseColor.withValues(alpha: 0.7)
            : baseColor.withValues(alpha: 0.35),
      ),
      prefixIcon: Icon(
        prefixIcon,
        color: enabled
            ? baseColor.withValues(alpha: 0.7)
            : baseColor.withValues(alpha: 0.35),
      ),
      prefixText: prefixText,
      prefixStyle: prefixStyle ??
          TextStyle(
            color: enabled
                ? authTextPrimary(context)
                : authTextMuted(context, 0.4),
            fontWeight: FontWeight.w600,
          ),
      helperText: helperText,
      helperStyle: TextStyle(
        color: authTextMuted(context, 0.65),
        fontSize: 12,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: baseColor.withValues(alpha: 0.3)),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: baseColor.withValues(alpha: 0.15)),
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
